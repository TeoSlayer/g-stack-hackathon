#!/usr/bin/env python3
"""Generate 14 days of plausible HealthSync samples and ship them through
the live Pilot overlay so they land in agent-a's DuckDB.

What it produces (autocorrelated so plots look like a real person):

  - 14 days of heartRate samples (one every ~10 min during waking hours)
  - 1 restingHeartRate per day (slow drift)
  - 1 heartRateVariabilitySDNN per night (anticorrelated with sleep debt)
  - 1 respiratoryRate per night
  - 1 oxygenSaturation per night
  - 1 vo2Max per week
  - 1 bodyMass per day
  - hourly stepCount totals (waking only)
  - daily distanceWalkingRunning (from steps × stride)
  - daily activeEnergyBurned, basalEnergyBurned
  - daily appleExerciseTime, appleStandTime
  - 7 nights of sleepAnalysis (asleepCore/Deep/REM stages, brief awakes)
  - 2 workouts in the window (outdoor run w/ inline route + indoor bike)

The samples are bucketed into 14 daily envelopes (one batch per day) and
each envelope is sent via `docker exec g-stack-agent-b pilotctl send-message
193232 --data ...`. agent-a's Collector ingests, dedupes, ACKs.

Deterministic via --seed so re-runs produce the same UUIDs (replays land
as duplicates, exercising the per-uuid dedupe path).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import random
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Iterable


# ─── Helpers ─────────────────────────────────────────────────────────────────

def det_uuid(seed: str, *parts) -> str:
    h = hashlib.sha256(f"{seed}|{'|'.join(map(str, parts))}".encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def epoch(d: _dt.datetime) -> float:
    return d.replace(tzinfo=_dt.UTC).timestamp() if d.tzinfo is None else d.timestamp()


# ─── Generators ──────────────────────────────────────────────────────────────

def heart_rate_for_minute(minute_of_day: int, rng: random.Random, base: float = 62.0) -> float:
    """Diurnal HR curve: low at night, peak mid-afternoon, noise."""
    hour = minute_of_day / 60.0
    # Sinusoidal day cycle, lowest ~04:00, highest ~16:00
    cycle = math.sin((hour - 10) / 24 * 2 * math.pi)
    diurnal = 15 * max(0.0, cycle)  # +15 bpm at peak, 0 at trough
    noise = rng.gauss(0, 4)
    return max(40, base + diurnal + noise)


def gen_day(seed: str, date: _dt.date, *,
            device_id: str, source_name: str,
            workout_today: str | None) -> tuple[list[dict], list[dict]]:
    """Return (samples, workouts) for one day, all plausible."""
    rng = random.Random(f"{seed}|{date.isoformat()}")
    samples: list[dict] = []
    workouts: list[dict] = []

    # Slowly-drifting day-of baselines
    sleep_debt = max(0.0, rng.gauss(0.7, 0.4))           # hours
    rhr_base = 52 + rng.gauss(0.0, 1.5) + sleep_debt * 1.5
    hrv_base = max(20, 55 - sleep_debt * 7 + rng.gauss(0, 4))

    day_start = _dt.datetime.combine(date, _dt.time(6, 0), tzinfo=_dt.UTC)

    # Resting HR (one reading at ~07:00)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "rhr", date),
        "type": "restingHeartRate",
        "value": round(rhr_base, 1), "unit": "count/min",
        "start_utc": epoch(day_start.replace(hour=7)),
        "end_utc": epoch(day_start.replace(hour=7)),
        "source_name": source_name, "device": source_name,
    })

    # HRV (one reading overnight)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "hrv", date),
        "type": "heartRateVariabilitySDNN",
        "value": round(hrv_base, 1), "unit": "ms",
        "start_utc": epoch(day_start.replace(hour=4)),
        "end_utc": epoch(day_start.replace(hour=4)),
        "source_name": source_name, "device": source_name,
    })

    # SpO2 (one reading overnight)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "spo2", date),
        "type": "oxygenSaturation",
        "value": round(rng.gauss(97.5, 0.7), 1), "unit": "%",
        "start_utc": epoch(day_start.replace(hour=4, minute=30)),
        "end_utc": epoch(day_start.replace(hour=4, minute=30)),
        "source_name": source_name, "device": source_name,
    })

    # Respiratory rate
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "rr", date),
        "type": "respiratoryRate",
        "value": round(rng.gauss(15.5, 0.6), 1), "unit": "count/min",
        "start_utc": epoch(day_start.replace(hour=4, minute=45)),
        "end_utc": epoch(day_start.replace(hour=4, minute=45)),
        "source_name": source_name, "device": source_name,
    })

    # Body mass (daily morning weigh-in)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "mass", date),
        "type": "bodyMass",
        "value": round(rng.gauss(68.0, 0.3), 2), "unit": "kg",
        "start_utc": epoch(day_start.replace(hour=7, minute=5)),
        "end_utc": epoch(day_start.replace(hour=7, minute=5)),
        "source_name": source_name, "device": source_name,
    })

    # heartRate every 10 min, 06:00-23:00 (waking hours)
    base_hr = rhr_base + 8  # daytime baseline above RHR
    for minute in range(6 * 60, 23 * 60, 10):
        t = day_start.replace(hour=minute // 60, minute=minute % 60)
        v = heart_rate_for_minute(minute, rng, base=base_hr)
        samples.append({
            "kind": "quantity",
            "uuid": det_uuid(seed, "hr", date, minute),
            "type": "heartRate", "value": round(v, 1), "unit": "count/min",
            "start_utc": epoch(t), "end_utc": epoch(t),
            "source_name": source_name, "device": source_name,
        })

    # hourly stepCount totals (waking 06:00-22:00)
    weekend = date.weekday() >= 5
    daily_step_target = rng.gauss(11000 if weekend else 8500, 1500)
    daily_step_target = max(3000, daily_step_target)
    # Distribute by hour with a midday bump
    hour_weights = [0.5, 0.6, 0.6, 0.7, 1.0, 1.2, 1.4, 1.6,
                    1.4, 1.2, 1.1, 1.0, 1.1, 1.3, 1.4, 1.1, 0.6]
    total_w = sum(hour_weights)
    for h_idx, h in enumerate(range(6, 23)):
        w = hour_weights[h_idx] / total_w
        steps = max(0, int(daily_step_target * w + rng.gauss(0, 80)))
        if steps == 0:
            continue
        t = day_start.replace(hour=h)
        samples.append({
            "kind": "quantity",
            "uuid": det_uuid(seed, "steps", date, h),
            "type": "stepCount", "value": steps, "unit": "count",
            "start_utc": epoch(t),
            "end_utc": epoch(t.replace(minute=0) + _dt.timedelta(hours=1)),
            "source_name": source_name, "device": source_name,
        })

    # Distance walking/running (single daily total, derived from steps)
    daily_distance_m = int(daily_step_target * 0.78)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "dist", date),
        "type": "distanceWalkingRunning",
        "value": daily_distance_m, "unit": "m",
        "start_utc": epoch(day_start.replace(hour=6)),
        "end_utc": epoch(day_start.replace(hour=22)),
        "source_name": source_name, "device": source_name,
    })

    # Active energy + basal energy
    active_kcal = round(daily_step_target * 0.04 + rng.gauss(50, 25), 0)
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "active-kcal", date),
        "type": "activeEnergyBurned",
        "value": active_kcal, "unit": "kcal",
        "start_utc": epoch(day_start.replace(hour=6)),
        "end_utc": epoch(day_start.replace(hour=22)),
        "source_name": source_name, "device": source_name,
    })
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "basal-kcal", date),
        "type": "basalEnergyBurned",
        "value": round(rng.gauss(1450, 25), 0), "unit": "kcal",
        "start_utc": epoch(day_start.replace(hour=0)),
        "end_utc": epoch(day_start.replace(hour=23, minute=59)),
        "source_name": source_name, "device": source_name,
    })

    # Apple Exercise Time + Stand Time
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "exercise", date),
        "type": "appleExerciseTime",
        "value": round(rng.gauss(40, 15)), "unit": "min",
        "start_utc": epoch(day_start),
        "end_utc": epoch(day_start.replace(hour=23, minute=59)),
        "source_name": source_name, "device": source_name,
    })
    samples.append({
        "kind": "quantity",
        "uuid": det_uuid(seed, "stand", date),
        "type": "appleStandTime",
        "value": round(rng.gauss(12, 2)), "unit": "min",
        "start_utc": epoch(day_start),
        "end_utc": epoch(day_start.replace(hour=23, minute=59)),
        "source_name": source_name, "device": source_name,
    })

    # Sleep analysis: ~22:30 → 06:30 with realistic stage transitions
    # We model sleep on the PREVIOUS night (carrying into this day's date)
    bedtime = day_start.replace(hour=22, minute=30) - _dt.timedelta(days=1) + \
              _dt.timedelta(minutes=int(rng.gauss(0, 30)))
    cur = bedtime
    night_end = day_start.replace(hour=6, minute=30)
    stages = [
        ("asleepCore", 4, 70),   # value, average minutes
        ("asleepDeep", 5, 30),
        ("asleepREM",  5, 25),
        ("asleepCore", 4, 60),
        ("awake",      2, 5),
        ("asleepCore", 4, 50),
        ("asleepDeep", 5, 25),
        ("asleepREM",  5, 30),
        ("asleepCore", 4, 50),
    ]
    for idx, (name, val, mean_min) in enumerate(stages):
        if cur >= night_end:
            break
        dur = max(2, int(rng.gauss(mean_min, mean_min * 0.25)))
        end = min(night_end, cur + _dt.timedelta(minutes=dur))
        samples.append({
            "kind": "category",
            "uuid": det_uuid(seed, "sleep", date, idx),
            "type": "sleepAnalysis",
            "category_value": val,
            "category_name": name,
            "start_utc": epoch(cur), "end_utc": epoch(end),
            "source_name": source_name, "device": source_name,
        })
        cur = end

    # Weekly VO2max (Sundays)
    if date.weekday() == 6:
        samples.append({
            "kind": "quantity",
            "uuid": det_uuid(seed, "vo2", date),
            "type": "vo2Max",
            "value": round(rng.gauss(43, 0.5), 1), "unit": "ml/kg*min",
            "start_utc": epoch(day_start.replace(hour=9)),
            "end_utc": epoch(day_start.replace(hour=9)),
            "source_name": source_name, "device": source_name,
        })

    # Workouts: only on specified days
    if workout_today == "run":
        wo_start = day_start.replace(hour=7, minute=15)
        wo_end = wo_start + _dt.timedelta(minutes=42)
        # Build a small inline GPS route — 25 points around a 5k loop in SF
        route_pts = []
        center_lat, center_lon = 37.7785, -122.4192
        for i in range(25):
            angle = i / 25 * 2 * math.pi
            route_pts.append([
                round(center_lat + 0.005 * math.cos(angle), 6),
                round(center_lon + 0.005 * math.sin(angle), 6),
                round(20 + rng.gauss(0, 3), 1),
                epoch(wo_start) + i * 100,
                round(rng.gauss(3.3, 0.2), 2),
            ])
        workouts.append({
            "uuid": det_uuid(seed, "workout-run", date),
            "activity_type": 37,
            "activity_name": "running",
            "start_utc": epoch(wo_start), "end_utc": epoch(wo_end),
            "duration_s": (wo_end - wo_start).total_seconds(),
            "total_energy_kcal": 360.0,
            "total_distance_m": 5100.0,
            "source_name": source_name, "device": source_name,
            "route": {"point_count": 25, "inline": True, "points": route_pts},
        })
    elif workout_today == "bike":
        wo_start = day_start.replace(hour=18, minute=0)
        wo_end = wo_start + _dt.timedelta(minutes=45)
        workouts.append({
            "uuid": det_uuid(seed, "workout-bike", date),
            "activity_type": 13,
            "activity_name": "cycling",
            "start_utc": epoch(wo_start), "end_utc": epoch(wo_end),
            "duration_s": (wo_end - wo_start).total_seconds(),
            "total_energy_kcal": 420.0,
            "total_distance_m": 14000.0,
            "source_name": source_name, "device": source_name,
            # Indoor — no route
        })

    return samples, workouts


def build_envelope(*, batch_id: str, device_id: str,
                   samples: list[dict], workouts: list[dict],
                   sent_at: float) -> dict:
    return {
        "v": 1,
        "source": "ios.healthsync",
        "device_id": device_id,
        "device_model": "iPhone 15 Pro",
        "os_version": "iOS 17.6",
        "app_version": "0.1.0",
        "batch_id": batch_id,
        "sent_at": sent_at,
        "ack_port": 1002,
        "samples": samples,
        "workouts": workouts,
        "metadata": {"network": "wifi", "battery_level": 0.78},
    }


# ─── Shipping via real Pilot ─────────────────────────────────────────────────

def ship(envelope: dict, *, target_node: str, container: str) -> dict:
    """Use `docker exec <container> pilotctl send-message <target> --data <json>`.

    Returns the parsed `ack` envelope from pilotctl (delivery ack, not the
    semantic Ack — that comes back asynchronously to our inbox).
    """
    body = json.dumps(envelope, separators=(",", ":"))
    cp = subprocess.run(
        ["docker", "exec", "-i", container,
         "pilotctl", "send-message", target_node,
         "--data", body, "--type", "json"],
        check=True, capture_output=True, text=True, timeout=30,
    )
    return json.loads(cp.stdout)


# ─── Orchestrator ────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--seed", default="amelina-1")
    p.add_argument("--device-id", default="iPhone-Amelina")
    p.add_argument("--source-name", default="Apple Watch")
    p.add_argument("--start", default="2026-05-03")
    p.add_argument("--end", default="2026-05-16")
    p.add_argument("--target", default="193232",
                   help="agent-a Pilot node id (collector)")
    p.add_argument("--sender-container", default="g-stack-agent-b",
                   help="container whose pilot identity sends (agent-b)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print envelopes, don't ship")
    p.add_argument("--workout-days", default="2026-05-05,2026-05-10",
                   help="comma-separated YYYY-MM-DD list (alternates run/bike)")
    args = p.parse_args()

    start = _dt.date.fromisoformat(args.start)
    end = _dt.date.fromisoformat(args.end)
    workout_set = {d.strip() for d in args.workout_days.split(",") if d.strip()}

    totals = {"days": 0, "samples": 0, "workouts": 0, "shipped": 0}
    cur = start
    workout_kinds = ["run", "bike"]
    seen_workouts = 0
    while cur <= end:
        workout_today = None
        if cur.isoformat() in workout_set:
            workout_today = workout_kinds[seen_workouts % len(workout_kinds)]
            seen_workouts += 1
        samples, workouts = gen_day(
            args.seed, cur,
            device_id=args.device_id,
            source_name=args.source_name,
            workout_today=workout_today,
        )
        env = build_envelope(
            batch_id=det_uuid(args.seed, "batch", cur),
            device_id=args.device_id,
            samples=samples, workouts=workouts,
            sent_at=_dt.datetime.now(_dt.UTC).timestamp(),
        )
        if args.dry_run:
            print(json.dumps({
                "date": cur.isoformat(),
                "batch_id": env["batch_id"],
                "samples": len(samples),
                "workouts": len(workouts),
            }))
        else:
            try:
                ack = ship(env, target_node=args.target,
                           container=args.sender_container)
                print(f"  {cur.isoformat()} batch={env['batch_id'][:8]}.. "
                      f"samples={len(samples)} workouts={len(workouts)} "
                      f"bytes={ack.get('bytes')}")
                totals["shipped"] += 1
            except subprocess.CalledProcessError as e:
                print(f"  {cur.isoformat()} FAILED: {e.stderr.strip()}",
                      file=sys.stderr)
        totals["days"] += 1
        totals["samples"] += len(samples)
        totals["workouts"] += len(workouts)
        cur += _dt.timedelta(days=1)

    print(json.dumps(totals, indent=2))


if __name__ == "__main__":
    main()
