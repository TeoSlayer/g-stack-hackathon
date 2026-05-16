"""Coach-side gbrain rollup.

Derives human-readable markdown summaries from raw HealthSync envelopes
and stores them under `~/brain/daily/health/YYYY-MM-DD.md`. Also keeps a
mirror of each raw envelope under `~/brain/sources/health/.raw/<batch_id>.json`
for re-aggregation.

The Coach calls this in one of two situations:

  1. **ChangeEvent path (preferred)** — when the Collector publishes a
     `samples_added` ChangeEvent on port 1004, the Coach queries the
     Collector via Pilot port 1003 for the new rows, materializes them as
     a synthetic envelope shape, and feeds them here. No raw file is
     written in this path because the Collector is the source of truth.

  2. **Raw-mirror path (compat)** — for migration from the old JS
     ingester, an operator can call `on_envelope(env_dict)` directly with
     a raw envelope. The raw is mirrored to disk and the daily markdown
     is rebuilt from the on-disk archive (same shape as the old pipeline).

This module is data-shape-agnostic — it accepts plain dicts that match
the wire schema (see `agent-a/SCHEMA.md`). No dependency on the Collector
Python package.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
from pathlib import Path


log = logging.getLogger("coach.gbrain")


def _epoch_to_local_date(epoch_s: float) -> str:
    return _dt.datetime.fromtimestamp(epoch_s, tz=_dt.UTC).date().isoformat()


def _fmt_dur(seconds: float) -> str:
    minutes = round(seconds / 60)
    h, m = divmod(minutes, 60)
    return f"{h}h {m}m" if h else f"{m}m"


class GbrainRollup:
    def __init__(self, *, raw_dir: Path, daily_dir: Path):
        self.raw_dir = Path(raw_dir)
        self.daily_dir = Path(daily_dir)
        self.raw_dir.mkdir(parents=True, exist_ok=True)
        self.daily_dir.mkdir(parents=True, exist_ok=True)

    def on_envelope(self, env: dict) -> list[str]:
        """Persist the raw envelope and rebuild daily markdown for touched dates.

        Returns the list of dates touched (ISO strings).
        """
        batch_id = env.get("batch_id") or "unknown"
        path = self.raw_dir / f"{batch_id}.json"
        path.write_text(json.dumps(env, indent=2))

        dates: set[str] = set()
        for s in env.get("samples", []):
            if isinstance(s, dict) and s.get("start_utc"):
                dates.add(_epoch_to_local_date(s["start_utc"]))
        for w in env.get("workouts", []):
            if isinstance(w, dict) and w.get("start_utc"):
                dates.add(_epoch_to_local_date(w["start_utc"]))

        for d in dates:
            self._rebuild_daily(d)

        log.info(
            "gbrain rollup batch=%s samples=%d workouts=%d dates=%s",
            batch_id, len(env.get("samples", [])), len(env.get("workouts", [])),
            sorted(dates),
        )
        return sorted(dates)

    def _rebuild_daily(self, date: str):
        samples: list[dict] = []
        workouts: list[dict] = []
        batches: set[str] = set()
        device_id: str | None = None

        for raw_file in sorted(self.raw_dir.glob("*.json")):
            try:
                env = json.loads(raw_file.read_text())
            except Exception:
                continue
            if env.get("device_id"):
                device_id = env["device_id"]
            touched = False
            for s in env.get("samples", []):
                if s.get("start_utc") and _epoch_to_local_date(s["start_utc"]) == date:
                    samples.append(s)
                    touched = True
            for w in env.get("workouts", []):
                if w.get("start_utc") and _epoch_to_local_date(w["start_utc"]) == date:
                    workouts.append(w)
                    touched = True
            if touched:
                batches.add(env.get("batch_id") or raw_file.stem)

        by_type: dict[str, list[dict]] = {}
        for s in samples:
            by_type.setdefault(s["type"], []).append(s)

        def total(t: str) -> float:
            return sum(s.get("value", 0) for s in by_type.get(t, []))

        lines: list[str] = ["---", "type: daily", "source: ios.healthsync",
                            f"date: {date}"]
        if device_id:
            lines.append(f"device_id: {device_id}")
        lines += ["tags: [health, ios.healthsync]", "---", "",
                  f"# Health {date}", ""]

        step = total("stepCount")
        dist = total("distanceWalkingRunning")
        cycdist = total("distanceCycling")
        kcal = total("activeEnergyBurned")
        ex_min = total("appleExerciseTime")
        stand_min = total("appleStandTime")
        flights = total("flightsClimbed")
        if any((step, dist, kcal, ex_min)):
            lines.append("## Activity")
            if step:    lines.append(f"- Steps: {round(step):,}")
            if dist:    lines.append(f"- Distance (walking/running): {dist/1000:.2f} km")
            if cycdist: lines.append(f"- Distance (cycling): {cycdist/1000:.2f} km")
            if kcal:    lines.append(f"- Active energy: {round(kcal)} kcal")
            if ex_min:  lines.append(f"- Exercise time: {round(ex_min)} min")
            if stand_min: lines.append(f"- Stand time: {round(stand_min)} min")
            if flights: lines.append(f"- Flights climbed: {round(flights)}")
            lines.append("")

        def stat(t: str, label: str, unit: str, mode: str = "avg"):
            xs = [s["value"] for s in by_type.get(t, [])
                  if isinstance(s.get("value"), (int, float))]
            if not xs:
                return None
            if mode == "last":
                return f"- {label}: {xs[-1]:.1f} {unit}"
            avg = sum(xs) / len(xs)
            return (f"- {label}: avg {avg:.1f} {unit} "
                    f"({len(xs)} samples, min {min(xs):.1f}, max {max(xs):.1f})")

        vitals = [
            stat("heartRate", "Heart rate", "bpm"),
            stat("restingHeartRate", "Resting HR", "bpm"),
            stat("heartRateVariabilitySDNN", "HRV (SDNN)", "ms"),
            stat("respiratoryRate", "Respiratory rate", "breaths/min"),
            stat("oxygenSaturation", "SpO₂", "%"),
            stat("bodyTemperature", "Body temp", "°C"),
            stat("vo2Max", "VO₂max", "ml/kg·min", "last"),
            stat("bodyMass", "Body mass", "kg", "last"),
        ]
        vitals = [v for v in vitals if v]
        if vitals:
            lines.append("## Vitals")
            lines.extend(vitals)
            lines.append("")

        sleep = by_type.get("sleepAnalysis", [])
        if sleep:
            stage_ms: dict[str, float] = {}
            for s in sleep:
                dur = (s["end_utc"] - s["start_utc"]) * 1000
                stage = s.get("category_name") or f"value_{s.get('category_value')}"
                stage_ms[stage] = stage_ms.get(stage, 0) + dur
            lines.append("## Sleep")
            for stage, ms in stage_ms.items():
                lines.append(f"- {stage}: {_fmt_dur(ms / 1000)}")
            lines.append("")

        if workouts:
            lines.append("## Workouts")
            for w in workouts:
                t1 = _dt.datetime.fromtimestamp(w["start_utc"], _dt.UTC).strftime("%H:%M")
                t2 = _dt.datetime.fromtimestamp(w["end_utc"], _dt.UTC).strftime("%H:%M")
                dist_s = f", {w['total_distance_m']/1000:.2f} km" if w.get("total_distance_m") else ""
                kcal_s = f", {round(w['total_energy_kcal'])} kcal" if w.get("total_energy_kcal") else ""
                route_s = ""
                if isinstance(w.get("route"), dict) and w["route"].get("point_count"):
                    route_s = f", route {w['route']['point_count']} pts"
                name = w.get("activity_name") or f"activity_{w.get('activity_type')}"
                lines.append(f"- {t1}–{t2} **{name}**{dist_s}{kcal_s}{route_s}")
            lines.append("")

        lines.append(f"<!-- batches: {', '.join(sorted(batches))} -->")
        lines.append("")

        (self.daily_dir / f"{date}.md").write_text("\n".join(lines))


def make_envelope_from_query(rows: list[dict], *, device_id: str,
                              batch_id: str = "from-query") -> dict:
    """Translate `SELECT * FROM samples WHERE start_utc BETWEEN ? AND ?` rows
    into a synthetic envelope dict that `on_envelope` can consume.

    Used by the Coach's ChangeEvent handler to feed rollup from live SQL
    results rather than from raw envelope files.
    """
    samples = []
    for row in rows:
        if row.get("kind") == "category":
            samples.append({
                "kind": "category",
                "uuid": row["uuid"],
                "type": row["type"],
                "category_value": row.get("category_value"),
                "category_name": row.get("category_name"),
                "start_utc": row["start_utc"],
                "end_utc": row["end_utc"],
                "source_name": row.get("source_name"),
            })
        else:
            samples.append({
                "kind": row.get("kind", "quantity"),
                "uuid": row["uuid"],
                "type": row["type"],
                "value": row.get("value"),
                "unit": row.get("unit"),
                "start_utc": row["start_utc"],
                "end_utc": row["end_utc"],
                "source_name": row.get("source_name"),
            })
    return {
        "v": 1, "source": "coach.rollup", "device_id": device_id,
        "batch_id": batch_id, "sent_at": 0.0, "samples": samples, "workouts": [],
    }
