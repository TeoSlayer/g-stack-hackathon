#!/usr/bin/env python3
"""Generate realistic mock messages following the wire schema.

Drops a mix of message kinds into a target directory (default: ~/.pilot/inbox):

  - 1 multi-sample HealthSync envelope (quantity + category samples + workout)
  - 1 envelope with one bad sample (NaN value) — exercises the rejected path
  - 1 envelope replayed (same batch_id) — exercises duplicate detection
  - 1 workout with non-inline route + 3 route_chunk envelopes
  - 1 Coach query envelope (SQL)

All UUIDs and batch_ids are deterministic via --seed so re-runs idempotently
produce the same identifiers (useful for "did the dedupe actually work" checks).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
import uuid
from pathlib import Path


def det_uuid(seed: str, kind: str, idx: int) -> str:
    h = hashlib.sha256(f"{seed}|{kind}|{idx}".encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def make_quantity(seed, idx, *, type="heartRate", value=60.0, unit="count/min",
                  start=1701234560.0, dur=0.0):
    return {
        "kind": "quantity",
        "uuid": det_uuid(seed, "q", idx),
        "type": type,
        "value": value,
        "unit": unit,
        "start_utc": start,
        "end_utc": start + dur,
        "source_name": "Apple Watch",
        "source_bundle": "com.apple.health.5C2E…",
        "device": "Apple Watch Series 9",
    }


def make_category(seed, idx, *, type="sleepAnalysis", category_value=5,
                  category_name="asleepREM", start=1701208800.0, dur=1020.0):
    return {
        "kind": "category",
        "uuid": det_uuid(seed, "c", idx),
        "type": type,
        "category_value": category_value,
        "category_name": category_name,
        "start_utc": start,
        "end_utc": start + dur,
        "source_name": "Apple Watch",
        "device": "Apple Watch Series 9",
    }


def make_workout(seed, idx, *, inline_route=True, n_points=6, start=1701180000.0):
    points = [
        [47.610 + 0.0001 * i, -122.333 + 0.0001 * i, 10.0 + i,
         start + i * 10.0, 3.1 + 0.05 * i]
        for i in range(n_points)
    ]
    workout = {
        "uuid": det_uuid(seed, "w", idx),
        "activity_type": 37,
        "activity_name": "running",
        "start_utc": start,
        "end_utc": start + 3600,
        "duration_s": 3600,
        "total_energy_kcal": 450.2,
        "total_distance_m": 10500.3,
        "source_name": "Apple Watch",
        "device": "Apple Watch Series 9",
    }
    if inline_route:
        workout["route"] = {
            "point_count": n_points, "inline": True, "points": points,
        }
    else:
        workout["route"] = {
            "point_count": n_points, "inline": False, "points": [],
            "chunk_total": 3,
        }
    return workout, points


def make_envelope(seed, idx, samples, workouts=None, *, ack_port=1002, v=1):
    return {
        "v": v,
        "source": "ios.healthsync",
        "device_id": "iPhone-Calin",
        "device_model": "iPhone 15 Pro Max",
        "os_version": "iOS 17.6",
        "app_version": "0.1.0",
        "batch_id": det_uuid(seed, "b", idx),
        "sent_at": time.time(),
        "ack_port": ack_port,
        "samples": samples,
        "workouts": workouts or [],
        "metadata": {
            "location": {
                "lat": 47.6097, "lon": -122.3331, "accuracy_m": 12.5,
                "altitude_m": 53.2, "ts": 1701234560.0,
            },
            "network": "wifi",
            "battery_level": 0.82,
            "wake_window": [7, 23],
        },
    }


def make_route_chunk(seed, idx, *, workout_uuid, chunk_idx, chunk_total, points):
    return {
        "v": 1,
        "kind": "route_chunk",
        "source": "ios.healthsync",
        "device_id": "iPhone-Calin",
        "batch_id": det_uuid(seed, "rc", idx),
        "workout_uuid": workout_uuid,
        "chunk_idx": chunk_idx,
        "chunk_total": chunk_total,
        "points": points,
        "ack_port": 1002,
        "sent_at": time.time(),
    }


def make_query(seed, idx, *, sql, params=None, reply_port=1005):
    return {
        "v": 1,
        "request_id": det_uuid(seed, "q-req", idx),
        "reply_port": reply_port,
        "kind": "sql",
        "sql": sql,
        "params": params or [],
        "limit": 100,
    }


def wrap_pilot(sender: str, command: str, payload: dict) -> dict:
    """Mirror the Pilot inbox wrapper used by pilotd."""
    return {
        "agent": sender,
        "command": command,
        "data": json.dumps(payload),
    }


def write_message(out_dir: Path, basename: str, body: dict, *, wrap_sender: str | None):
    out_dir.mkdir(parents=True, exist_ok=True)
    if wrap_sender is not None:
        body = wrap_pilot(wrap_sender, "ingest", body)
    path = out_dir / f"{basename}.json"
    path.write_text(json.dumps(body, indent=2))
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.expanduser("~/.pilot/inbox"),
                        help="Output directory (default: ~/.pilot/inbox)")
    parser.add_argument("--seed", default="demo-1",
                        help="Deterministic seed for IDs")
    parser.add_argument("--wrap-sender", default="ios.healthsync.calin",
                        help="Pilot agent identity to use as the 'agent' wrapper")
    parser.add_argument("--no-wrap", action="store_true",
                        help="Emit raw envelopes (no Pilot wrapper)")
    parser.add_argument("--scenarios", default="all",
                        help="Comma-separated subset: clean,bad_sample,replay,route_chunks,query")
    args = parser.parse_args()

    out = Path(args.out).expanduser()
    sender = None if args.no_wrap else args.wrap_sender
    seed = args.seed
    scenarios = set(s.strip() for s in args.scenarios.split(",")) if args.scenarios != "all" \
                else {"clean", "bad_sample", "replay", "route_chunks", "query"}

    written = []
    now = time.time()

    # 1. Clean batch with mixed samples + a small inline workout
    if "clean" in scenarios:
        samples = [
            make_quantity(seed, 10 + i, type="heartRate", value=62 + i, start=now - 60 + i)
            for i in range(5)
        ] + [
            make_quantity(seed, 100 + i, type="stepCount", value=120, unit="count",
                          start=now - 600 + i * 60, dur=60)
            for i in range(3)
        ] + [
            make_quantity(seed, 200, type="heartRateVariabilitySDNN",
                          value=47.2, unit="ms", start=now - 30),
            make_quantity(seed, 201, type="oxygenSaturation",
                          value=98.0, unit="%", start=now - 25),
            make_category(seed, 1, start=now - 8 * 3600, dur=900),
            make_category(seed, 2, category_value=4, category_name="asleepDeep",
                          start=now - 7 * 3600, dur=1200),
        ]
        workout, _pts = make_workout(seed, 1, inline_route=True, n_points=8,
                                      start=now - 4 * 3600)
        env = make_envelope(seed, 1, samples, workouts=[workout])
        written.append(write_message(out, "01-clean-envelope", env, wrap_sender=sender))

    # 2. Envelope with a deliberately bad sample
    if "bad_sample" in scenarios:
        import math
        good = make_quantity(seed, 300, type="heartRate", value=70, start=now - 10)
        bad = {
            "kind": "quantity",
            "uuid": det_uuid(seed, "q-bad", 1),
            "type": "heartRate",
            "value": math.nan,  # NaN gets serialized as a string by json.dumps in most ways…
            "unit": "count/min",
            "start_utc": now - 10,
            "end_utc": now - 10,
        }
        weird = {
            "kind": "made_up",
            "uuid": det_uuid(seed, "q-weird", 1),
            "type": "foo", "start_utc": now, "end_utc": now,
        }
        env = make_envelope(seed, 2, [good, bad, weird])
        # We need NaN to actually be NaN in the JSON. json.dumps emits NaN by default in Python.
        body = wrap_pilot(sender, "ingest", env) if sender else env
        path = out / "02-bad-sample-envelope.json"
        path.write_text(json.dumps(body))
        written.append(path)

    # 3. Replay of envelope 1 — same batch_id, same samples (tests dedupe)
    if "replay" in scenarios and "clean" in scenarios:
        # Re-run envelope 1 builder verbatim
        samples = [
            make_quantity(seed, 10 + i, type="heartRate", value=62 + i, start=now - 60 + i)
            for i in range(5)
        ] + [
            make_quantity(seed, 100 + i, type="stepCount", value=120, unit="count",
                          start=now - 600 + i * 60, dur=60)
            for i in range(3)
        ] + [
            make_quantity(seed, 200, type="heartRateVariabilitySDNN",
                          value=47.2, unit="ms", start=now - 30),
            make_quantity(seed, 201, type="oxygenSaturation",
                          value=98.0, unit="%", start=now - 25),
            make_category(seed, 1, start=now - 8 * 3600, dur=900),
            make_category(seed, 2, category_value=4, category_name="asleepDeep",
                          start=now - 7 * 3600, dur=1200),
        ]
        workout, _ = make_workout(seed, 1, inline_route=True, n_points=8,
                                   start=now - 4 * 3600)
        env = make_envelope(seed, 1, samples, workouts=[workout])  # same batch_id
        written.append(write_message(out, "03-replay-envelope", env, wrap_sender=sender))

    # 4. Workout with non-inline route + 3 route chunks
    if "route_chunks" in scenarios:
        workout, all_points = make_workout(seed, 2, inline_route=False, n_points=9,
                                            start=now - 2 * 3600)
        env = make_envelope(seed, 3, [], workouts=[workout])
        written.append(write_message(out, "04-workout-no-route", env, wrap_sender=sender))

        # Split points across 3 chunks
        chunks = [all_points[0:3], all_points[3:6], all_points[6:9]]
        for idx, pts in enumerate(chunks):
            ch = make_route_chunk(seed, idx, workout_uuid=workout["uuid"],
                                   chunk_idx=idx, chunk_total=3, points=pts)
            written.append(write_message(out, f"05-route-chunk-{idx}", ch, wrap_sender=sender))

    # 5. Coach query
    if "query" in scenarios:
        q = make_query(seed, 1,
                        sql="SELECT type, COUNT(*) AS n FROM samples GROUP BY type ORDER BY n DESC")
        # Coach wraps with its own agent identity
        coach_sender = "coach.readiness" if sender else None
        written.append(write_message(out, "06-coach-query", q, wrap_sender=coach_sender))

    print(f"wrote {len(written)} messages to {out}")
    for p in written:
        print(f"  {p.name}")


if __name__ == "__main__":
    main()
