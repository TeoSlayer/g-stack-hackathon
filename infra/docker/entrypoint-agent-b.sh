#!/usr/bin/env bash
# agent-b entrypoint: real Linux pilot-daemon + Python coach.
set -euo pipefail

PILOT_BIN="/opt/pilot/bin/pilot-daemon"
PILOT_IDENT="${PILOT_HOME}/identity.json"
mkdir -p "$PILOT_HOME" "$COACH_INBOX"

echo "[entrypoint] starting pilot-daemon (registry=$PILOT_REGISTRY beacon=$PILOT_BEACON listen=$PILOT_LISTEN)"
"$PILOT_BIN" \
    -registry "$PILOT_REGISTRY" \
    -beacon "$PILOT_BEACON" \
    -listen "$PILOT_LISTEN" \
    -socket /tmp/pilot.sock \
    -identity "$PILOT_IDENT" \
    -email "$PILOT_EMAIL" \
    -hostname "$PILOT_HOSTNAME" \
    -encrypt \
    >/var/log/pilot.log 2>&1 &
PILOT_PID=$!
echo "[entrypoint] pilot-daemon pid=$PILOT_PID; waiting for socket"
for i in $(seq 1 30); do
    [ -S /tmp/pilot.sock ] && break
    sleep 0.5
done
if [ ! -S /tmp/pilot.sock ]; then
    echo "[entrypoint] pilot-daemon failed to come up" >&2
    tail -50 /var/log/pilot.log >&2 || true
    exit 1
fi

echo "[entrypoint] pilot socket up; node config:"
/opt/pilot/bin/pilotctl config 2>&1 | head -12 || true

# Real pilot mode: the Coach reads replies + ChangeEvents from the local
# pilot-daemon's inbox.
export COACH_INBOX="${PILOT_HOME}/inbox"
export COACH_PILOT_MODE=pilotctl
mkdir -p "$COACH_INBOX"

CMD="${1:-watch}"
shift || true
echo "[entrypoint] launching coach ${CMD} (mode=$COACH_PILOT_MODE inbox=$COACH_INBOX)"
exec python -m coach "$CMD" "$@"
