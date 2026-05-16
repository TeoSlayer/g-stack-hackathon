#!/usr/bin/env bash
# agent-a entrypoint: real Linux pilot-daemon + Python collector.
set -euo pipefail

PILOT_BIN="/opt/pilot/bin/pilot-daemon"
PILOT_IDENT="${PILOT_HOME}/identity.json"
mkdir -p "$PILOT_HOME" "$COLLECTOR_INBOX" "$COLLECTOR_VAR"

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

# Pilot daemon delivers inbound messages into $PILOT_HOME/inbox; the collector
# watches there directly. $COLLECTOR_INBOX is kept as a volume mount for
# operator-side mock data drops (e.g. e2e tests via shared volume).
PILOT_INBOX="${PILOT_HOME}/inbox"
mkdir -p "$PILOT_INBOX"

echo "[entrypoint] launching collector (inbox=$PILOT_INBOX var=$COLLECTOR_VAR)"
exec python -m collector.server \
    --inbox "$PILOT_INBOX" \
    --var "$COLLECTOR_VAR" \
    --pilotctl \
    --poll "${COLLECTOR_POLL:-1.0}"
