"""Coach CLI: demonstrates the Query + ChangeEvent surface.

Two subcommands:

  python -m coach watch         # subscribe to ChangeEvents and surface them
  python -m coach query "<sql>" # one-shot SQL query, prints rows as JSON
  python -m coach readiness     # canned readiness check (today's HRV vs baseline)
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time

from .client import Coach, make_pilot_from_env


def cmd_query(args):
    coach = Coach(make_pilot_from_env())
    result = coach.query(args.sql, limit=args.limit)
    print(json.dumps(result, indent=2, default=str))
    return 0 if result.get("ok") else 1


def cmd_watch(args):
    coach = Coach(make_pilot_from_env())
    logging.info("coach watch started — waiting for ChangeEvents")

    def on_event(ev):
        ts = ev.get("ts")
        by_type = ev.get("by_type", {})
        types_summary = ", ".join(f"{k}={v}" for k, v in by_type.items())
        print(f"[{ts}] samples_added device={ev.get('device_id')} {types_summary}", flush=True)

    deadline = time.time() + (args.duration or 0)
    while True:
        coach.consume_change_events(on_event)
        if args.duration and time.time() > deadline:
            return 0
        time.sleep(args.poll)


def cmd_readiness(args):
    coach = Coach(make_pilot_from_env())
    sql = """
        SELECT AVG(value) AS hrv_avg, COUNT(*) AS n
        FROM samples
        WHERE type = 'heartRateVariabilitySDNN'
          AND start_utc > ?
    """
    cutoff = time.time() - 86400 * 7
    result = coach.query(sql, params=[cutoff])
    if not result.get("ok"):
        print(json.dumps(result, indent=2), file=sys.stderr)
        return 1
    rows = result.get("rows", [])
    if not rows:
        print("no HRV samples in the last 7 days")
        return 0
    row = rows[0]
    print(f"HRV avg (last 7d): {row.get('hrv_avg')} ms over {row.get('n')} samples")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Coach client")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_query = sub.add_parser("query")
    p_query.add_argument("sql")
    p_query.add_argument("--limit", type=int, default=None)
    p_query.set_defaults(fn=cmd_query)

    p_watch = sub.add_parser("watch")
    p_watch.add_argument("--poll", type=float, default=1.0)
    p_watch.add_argument("--duration", type=float, default=0.0,
                         help="seconds to watch (0 = forever)")
    p_watch.set_defaults(fn=cmd_watch)

    p_ready = sub.add_parser("readiness")
    p_ready.set_defaults(fn=cmd_readiness)

    args = parser.parse_args()
    logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
