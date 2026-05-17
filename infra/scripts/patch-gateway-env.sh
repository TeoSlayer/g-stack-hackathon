#!/usr/bin/env bash
# OpenClaw gateway's systemd unit doesn't load ~/.env by default, so
# providers like Anthropic see no API key and turns fail with
# "Missing API key for provider". This patch adds EnvironmentFile=~/.env
# to the unit and restarts the gateway. Idempotent — re-running is safe.

set -euo pipefail

USER_HOME="${HOME}"
UNIT="$USER_HOME/.config/systemd/user/openclaw-gateway.service"

if [ ! -f "$UNIT" ]; then
    echo "openclaw-gateway.service not installed at $UNIT — run 'openclaw gateway install' first" >&2
    exit 1
fi

echo "▶ ensuring EnvironmentFile=$USER_HOME/.env on openclaw-gateway.service"
# Drop any prior EnvironmentFile= line so we don't end up with stale dupes.
sed -i '/^EnvironmentFile=/d' "$UNIT"
# Insert right after [Service] header.
sed -i "/^\[Service\]$/a EnvironmentFile=${USER_HOME}/.env" "$UNIT"

grep -E '(EnvironmentFile|ExecStart)=' "$UNIT" | head -3

echo
echo "▶ reload + restart"
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
sleep 5
systemctl --user is-active openclaw-gateway.service

PID=$(systemctl --user show -p MainPID openclaw-gateway.service | cut -d= -f2)
if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    echo
    echo "--- API keys visible to gateway process ---"
    sudo tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null \
      | grep -E '^(OPENAI|ANTHROPIC|ZERO_ENTROPY|TELEGRAM)' \
      | sed 's/=.*$/=<set>/' || true
fi
