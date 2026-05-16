#!/usr/bin/env bash
# End-to-end smoke test for the agent-a (Collector) pipeline.
#
# Drops mock messages into the inbox, runs the Collector for one tick, and
# reports what landed in DuckDB + acks + change events. Re-running with the
# same --seed exercises the duplicate-batch path.
#
# Usage: scripts/run_e2e.sh [--inbox PATH] [--var PATH] [--seed STR] [--keep]

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INBOX="${HOME}/.pilot/inbox"
VAR="${REPO}/infra/data"
SEED="${E2E_SEED:-e2e-$(date +%s)}"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inbox) INBOX="$2"; shift 2;;
    --var) VAR="$2"; shift 2;;
    --seed) SEED="$2"; shift 2;;
    --keep) KEEP=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

PY="${REPO}/.venv/bin/python"
if [[ ! -x "$PY" ]]; then
  echo "venv missing at $PY — run 'uv venv && uv pip install -e .[dev]' first" >&2
  exit 1
fi
export G_STACK_HOME="$REPO"

echo "═══════════════════════════════════════════════════════════════"
echo " g-stack — Collector end-to-end smoke test"
echo "═══════════════════════════════════════════════════════════════"
echo "  inbox: $INBOX"
echo "  var:   $VAR"
echo "  seed:  $SEED"
echo

if [[ $KEEP -eq 0 ]]; then
  rm -f "$VAR/facts.duckdb" "$VAR/facts.duckdb.wal" 2>/dev/null || true
  rm -rf "$VAR/acks_out" "$VAR/events_log" 2>/dev/null || true
fi
mkdir -p "$VAR" "$INBOX"

echo "▶ Step 1: generate mock messages into $INBOX"
"$PY" "${REPO}/scripts/make_mock_envelopes.py" --out "$INBOX" --seed "$SEED" \
  --wrap-sender ios.healthsync.calin

echo
echo "▶ Step 2: run Collector (single tick)"
"$PY" -m collector.server --inbox "$INBOX" --var "$VAR" --once

echo
echo "▶ Step 3: warehouse contents"
"$PY" - <<EOF
import duckdb
con = duckdb.connect("$VAR/facts.duckdb")
def q(label, sql):
    rows = con.execute(sql).fetchall()
    print(f"  {label}:")
    for r in rows:
        print(f"    {r}")
q("batches",  "SELECT batch_id, source, sample_count, workout_count FROM batches")
q("samples by type", "SELECT type, COUNT(*) FROM samples GROUP BY type ORDER BY 2 DESC")
q("workouts", "SELECT uuid, activity_name, route_point_count, route_complete FROM workouts")
q("route_points (count by workout)",
   "SELECT workout_uuid, COUNT(*) FROM route_points GROUP BY workout_uuid")
q("inflight chunks (should be 0)",
   "SELECT workout_uuid, COUNT(*) FROM route_chunks_inflight GROUP BY workout_uuid")
EOF

echo
echo "▶ Step 4: ack outputs"
"$PY" - <<EOF
import json, pathlib
d = pathlib.Path("$VAR/acks_out")
for p in sorted(d.glob("*.json")):
    body = json.loads(p.read_text())
    kind = body.get("kind"); b = body.get("body", {})
    if kind == "ack":
        print(f"  {p.name[:60]} -> ack batch={(b.get('batch_id') or '')[:8]}.. "
              f"accepted={len(b.get('accepted', []))} "
              f"duplicates={len(b.get('duplicates', []))} "
              f"rejected={len(b.get('rejected', []))}")
    elif kind == "query_result":
        print(f"  {p.name[:60]} -> query_result rid={(b.get('request_id') or '')[:8]}.. "
              f"ok={b.get('ok')} rows={b.get('row_count')} ms={b.get('ms')}")
        for row in b.get("rows", [])[:5]:
            print(f"      {row}")
EOF

echo
echo "▶ Step 5: change events"
"$PY" - <<EOF
import json, pathlib
d = pathlib.Path("$VAR/events_log")
for p in sorted(d.glob("*.json")):
    body = json.loads(p.read_text()).get("body", {})
    print(f"  device={body.get('device_id')} by_type={body.get('by_type')}")
EOF

echo
echo "▶ Step 6: inbox state"
echo "  archived:"
ls "$INBOX/.archive/" 2>/dev/null | sed 's/^/    /' | head -20
echo "  unrecognized:"
ls "$INBOX/.unrecognized/" 2>/dev/null | sed 's/^/    /' | head -20

echo
echo "✓ done. Same --seed twice exercises the duplicate-batch path."
