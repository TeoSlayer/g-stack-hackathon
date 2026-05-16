"""DuckDB warehouse.

Tables:
  batches            — one row per envelope; PK (batch_id) gives replay safety
  samples            — one row per HK sample; PK (uuid) gives per-sample dedupe
  workouts           — one row per workout
  route_points       — flattened GPS polyline; PK (workout_uuid, idx)
  route_chunks_inflight  — buffer rows for incomplete multi-envelope routes

The warehouse never raises on duplicate inserts — callers learn what was
new vs duplicate from the row counts returned by `insert_*` methods.
"""

from __future__ import annotations

import json
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable, Optional

import duckdb


DDL = """
CREATE TABLE IF NOT EXISTS batches (
    batch_id      TEXT PRIMARY KEY,
    source        TEXT,
    device_id     TEXT,
    device_model  TEXT,
    os_version    TEXT,
    app_version   TEXT,
    sent_at       DOUBLE,
    ingested_at   DOUBLE,
    sample_count  INTEGER,
    workout_count INTEGER,
    schema_v      INTEGER,
    raw_metadata  JSON
);

CREATE TABLE IF NOT EXISTS samples (
    uuid           TEXT PRIMARY KEY,
    batch_id       TEXT,
    device_id      TEXT,
    source         TEXT,
    kind           TEXT,
    type           TEXT,
    value          DOUBLE,
    unit           TEXT,
    category_value INTEGER,
    category_name  TEXT,
    start_utc      DOUBLE,
    end_utc        DOUBLE,
    source_name    TEXT,
    source_bundle  TEXT,
    device         TEXT,
    loc_lat        DOUBLE,
    loc_lon        DOUBLE,
    loc_accuracy_m DOUBLE,
    loc_source     TEXT,
    raw            JSON
);

CREATE INDEX IF NOT EXISTS idx_samples_type_start ON samples(type, start_utc);
CREATE INDEX IF NOT EXISTS idx_samples_device_start ON samples(device_id, start_utc);
CREATE INDEX IF NOT EXISTS idx_samples_batch ON samples(batch_id);

CREATE TABLE IF NOT EXISTS workouts (
    uuid              TEXT PRIMARY KEY,
    batch_id          TEXT,
    device_id         TEXT,
    activity_type     INTEGER,
    activity_name     TEXT,
    start_utc         DOUBLE,
    end_utc           DOUBLE,
    duration_s        DOUBLE,
    total_energy_kcal DOUBLE,
    total_distance_m  DOUBLE,
    source_name       TEXT,
    device            TEXT,
    route_point_count INTEGER,
    route_complete    BOOLEAN DEFAULT FALSE,
    raw               JSON
);

CREATE INDEX IF NOT EXISTS idx_workouts_start ON workouts(start_utc);

CREATE TABLE IF NOT EXISTS route_points (
    workout_uuid TEXT,
    idx          INTEGER,
    lat          DOUBLE,
    lon          DOUBLE,
    elevation_m  DOUBLE,
    ts_utc       DOUBLE,
    speed_mps    DOUBLE,
    PRIMARY KEY (workout_uuid, idx)
);

CREATE TABLE IF NOT EXISTS route_chunks_inflight (
    workout_uuid TEXT,
    chunk_idx    INTEGER,
    chunk_total  INTEGER,
    batch_id     TEXT,
    points       JSON,
    received_at  DOUBLE,
    PRIMARY KEY (workout_uuid, chunk_idx)
);

-- Permanent dedupe ledger: a chunk is "seen" forever once we've processed it.
-- Survives reassembly (which clears route_chunks_inflight) so replays are
-- recognized as duplicates.
CREATE TABLE IF NOT EXISTS route_chunks_seen (
    workout_uuid TEXT,
    chunk_idx    INTEGER,
    PRIMARY KEY (workout_uuid, chunk_idx)
);
"""


class Warehouse:
    """Thread-safe wrapper around a single DuckDB connection.

    DuckDB allows only one writer at a time; serializing with a lock keeps the
    Collector simple. Readers (queries from the SQL listener) share the same
    connection.
    """

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._con = duckdb.connect(str(self.path))
        self._init_schema()

    def _init_schema(self):
        with self._lock:
            self._con.execute(DDL)

    def close(self):
        with self._lock:
            self._con.close()

    @contextmanager
    def transaction(self):
        with self._lock:
            self._con.execute("BEGIN")
            try:
                yield self._con
                self._con.execute("COMMIT")
            except Exception:
                self._con.execute("ROLLBACK")
                raise

    # ── reads ───────────────────────────────────────────────────────────────

    def has_batch(self, batch_id: str) -> bool:
        with self._lock:
            row = self._con.execute(
                "SELECT 1 FROM batches WHERE batch_id = ?", [batch_id]
            ).fetchone()
        return row is not None

    def has_sample(self, uuid: str) -> bool:
        with self._lock:
            row = self._con.execute(
                "SELECT 1 FROM samples WHERE uuid = ?", [uuid]
            ).fetchone()
        return row is not None

    def existing_sample_uuids(self, uuids: Iterable[str]) -> set[str]:
        uuids = list(uuids)
        if not uuids:
            return set()
        with self._lock:
            placeholders = ",".join(["?"] * len(uuids))
            rows = self._con.execute(
                f"SELECT uuid FROM samples WHERE uuid IN ({placeholders})", uuids
            ).fetchall()
        return {r[0] for r in rows}

    def existing_workout_uuids(self, uuids: Iterable[str]) -> set[str]:
        uuids = list(uuids)
        if not uuids:
            return set()
        with self._lock:
            placeholders = ",".join(["?"] * len(uuids))
            rows = self._con.execute(
                f"SELECT uuid FROM workouts WHERE uuid IN ({placeholders})", uuids
            ).fetchall()
        return {r[0] for r in rows}

    def connection(self):
        """Return the underlying DuckDB connection (for SELECT queries)."""
        return self._con

    def lock(self):
        return self._lock

    # ── writes ──────────────────────────────────────────────────────────────

    def upsert_batch(
        self,
        *,
        batch_id: str,
        source: str,
        device_id: str,
        device_model: Optional[str],
        os_version: Optional[str],
        app_version: Optional[str],
        sent_at: float,
        ingested_at: float,
        sample_count: int,
        workout_count: int,
        schema_v: int,
        raw_metadata: Optional[dict],
        con: Optional[duckdb.DuckDBPyConnection] = None,
    ) -> bool:
        """Insert a batch row. Returns True if newly inserted, False if duplicate."""
        c = con or self._con
        with self._lock:
            existed = c.execute(
                "SELECT 1 FROM batches WHERE batch_id = ?", [batch_id]
            ).fetchone()
            if existed:
                return False
            c.execute(
                """INSERT INTO batches (batch_id, source, device_id, device_model,
                       os_version, app_version, sent_at, ingested_at, sample_count,
                       workout_count, schema_v, raw_metadata)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                [batch_id, source, device_id, device_model, os_version, app_version,
                 sent_at, ingested_at, sample_count, workout_count, schema_v,
                 json.dumps(raw_metadata) if raw_metadata else None],
            )
            return True

    def insert_sample(
        self,
        *,
        sample: dict,
        batch_id: str,
        device_id: str,
        source: str,
        con: Optional[duckdb.DuckDBPyConnection] = None,
    ) -> bool:
        """Insert one sample row. Returns True if inserted, False if duplicate."""
        c = con or self._con
        loc = sample.get("location") or {}
        with self._lock:
            existed = c.execute(
                "SELECT 1 FROM samples WHERE uuid = ?", [sample["uuid"]]
            ).fetchone()
            if existed:
                return False
            c.execute(
                """INSERT INTO samples
                   (uuid, batch_id, device_id, source, kind, type, value, unit,
                    category_value, category_name, start_utc, end_utc, source_name,
                    source_bundle, device, loc_lat, loc_lon, loc_accuracy_m,
                    loc_source, raw)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    sample["uuid"], batch_id, device_id, source,
                    sample.get("kind"), sample.get("type"),
                    sample.get("value"), sample.get("unit"),
                    sample.get("category_value"), sample.get("category_name"),
                    sample.get("start_utc"), sample.get("end_utc"),
                    sample.get("source_name"), sample.get("source_bundle"),
                    sample.get("device"),
                    loc.get("lat"), loc.get("lon"),
                    loc.get("accuracy_m"), loc.get("source"),
                    json.dumps(sample),
                ],
            )
            return True

    def insert_workout(
        self,
        *,
        workout: dict,
        batch_id: str,
        device_id: str,
        con: Optional[duckdb.DuckDBPyConnection] = None,
    ) -> bool:
        c = con or self._con
        route = workout.get("route") or {}
        point_count = route.get("point_count") or len(route.get("points") or [])
        with self._lock:
            existed = c.execute(
                "SELECT 1 FROM workouts WHERE uuid = ?", [workout["uuid"]]
            ).fetchone()
            if existed:
                return False
            c.execute(
                """INSERT INTO workouts
                   (uuid, batch_id, device_id, activity_type, activity_name,
                    start_utc, end_utc, duration_s, total_energy_kcal,
                    total_distance_m, source_name, device, route_point_count,
                    route_complete, raw)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    workout["uuid"], batch_id, device_id,
                    workout.get("activity_type"), workout.get("activity_name"),
                    workout.get("start_utc"), workout.get("end_utc"),
                    workout.get("duration_s"),
                    workout.get("total_energy_kcal"),
                    workout.get("total_distance_m"),
                    workout.get("source_name"), workout.get("device"),
                    point_count,
                    bool(route.get("inline", True)) and point_count > 0,
                    json.dumps(workout),
                ],
            )
            # Inline route points (if the workout had its route fully inline).
            if route.get("inline") and route.get("points"):
                self._insert_route_points(
                    workout["uuid"], 0, route["points"], con=c, mark_complete=True,
                )
            return True

    def _insert_route_points(
        self,
        workout_uuid: str,
        start_idx: int,
        points: list,
        con: duckdb.DuckDBPyConnection,
        mark_complete: bool = False,
    ):
        rows = []
        for offset, pt in enumerate(points):
            # pt is [lat, lon, elevation_m, ts_utc, speed_mps], any may be null
            lat = pt[0] if len(pt) > 0 else None
            lon = pt[1] if len(pt) > 1 else None
            ele = pt[2] if len(pt) > 2 else None
            ts = pt[3] if len(pt) > 3 else None
            spd = pt[4] if len(pt) > 4 else None
            rows.append([workout_uuid, start_idx + offset, lat, lon, ele, ts, spd])
        if rows:
            con.executemany(
                """INSERT OR IGNORE INTO route_points
                   (workout_uuid, idx, lat, lon, elevation_m, ts_utc, speed_mps)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                rows,
            )
        if mark_complete:
            con.execute(
                "UPDATE workouts SET route_complete = TRUE WHERE uuid = ?",
                [workout_uuid],
            )

    # ── route chunks ────────────────────────────────────────────────────────

    def buffer_route_chunk(
        self,
        *,
        workout_uuid: str,
        chunk_idx: int,
        chunk_total: Optional[int],
        batch_id: str,
        points: list,
        received_at: float,
    ) -> bool:
        """Store a route chunk for later reassembly. Returns True if new.

        Dedupe is checked against `route_chunks_seen`, which persists across
        reassembly. So a chunk that's been buffered, assembled, and cleared
        from `route_chunks_inflight` is still recognized as a duplicate on
        replay.
        """
        with self._lock, self.transaction() as c:
            existed = c.execute(
                "SELECT 1 FROM route_chunks_seen WHERE workout_uuid = ? AND chunk_idx = ?",
                [workout_uuid, chunk_idx],
            ).fetchone()
            if existed:
                return False
            c.execute(
                """INSERT INTO route_chunks_seen (workout_uuid, chunk_idx)
                   VALUES (?, ?)""",
                [workout_uuid, chunk_idx],
            )
            c.execute(
                """INSERT INTO route_chunks_inflight
                   (workout_uuid, chunk_idx, chunk_total, batch_id, points, received_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                [workout_uuid, chunk_idx, chunk_total, batch_id,
                 json.dumps(points), received_at],
            )
            return True

    def try_assemble_route(self, workout_uuid: str) -> Optional[int]:
        """If every chunk has arrived, materialize route_points and clear buffers.

        Returns the total point count materialized, or None if still incomplete.
        """
        with self._lock, self.transaction() as c:
            rows = c.execute(
                """SELECT chunk_idx, chunk_total, points FROM route_chunks_inflight
                   WHERE workout_uuid = ? ORDER BY chunk_idx""",
                [workout_uuid],
            ).fetchall()
            if not rows:
                return None
            # Determine chunk_total: prefer the explicit value, fall back to "max idx + 1".
            totals = {r[1] for r in rows if r[1] is not None}
            if not totals:
                return None
            if len(totals) > 1:
                # Inconsistent chunk_total values — choose the largest, log later.
                chunk_total = max(totals)
            else:
                chunk_total = totals.pop()
            received_idxs = {r[0] for r in rows}
            if received_idxs != set(range(chunk_total)):
                return None
            # All chunks present — flatten in order.
            # Check whether workout header exists; if not, we still materialize points.
            total_points = 0
            running_idx = 0
            for chunk_idx, _ct, points_json in rows:
                pts = json.loads(points_json)
                self._insert_route_points(workout_uuid, running_idx, pts, con=c)
                running_idx += len(pts)
                total_points += len(pts)
            c.execute(
                "UPDATE workouts SET route_complete = TRUE, route_point_count = ? WHERE uuid = ?",
                [total_points, workout_uuid],
            )
            c.execute(
                "DELETE FROM route_chunks_inflight WHERE workout_uuid = ?",
                [workout_uuid],
            )
            return total_points
