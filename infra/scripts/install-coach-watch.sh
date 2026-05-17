#!/usr/bin/env bash
# Install a systemd user service+timer for the Coach's proactive loop.
#
# Runs on the HOST (not inside the agent-b container) because:
#   - the host already has the canonical gbrain CLI (~/.bun/bin/gbrain)
#     pointing at infra/data/gbrain-coach-home (PGLite),
#   - the host already has OpenClaw + the @yccoachbot Telegram pairing,
#   - the host has ~/.env with the bot token.
#
# The script (agent-b/coach/host_proactive.py):
#   * uses `docker exec g-stack-agent-b pilotctl …` to query the Collector
#     via the existing pilot tunnel (no second daemon),
#   * writes daily-summary + insight pages to the coach gbrain on disk,
#   * sends proactive Telegram nudges via the SAME bot openclaw uses
#     (Telegram Bot API allows out-of-band sends — no second bot needed).
#
# Idempotent.

set -euo pipefail

USER_HOME="${HOME}"
REPO="${G_STACK_REPO:-$USER_HOME/g-stack-hackathon}"
VENV_PY="$REPO/.venv/bin/python"
SCRIPT="$REPO/agent-b/coach/host_proactive.py"

SERVICE_NAME=coach-proactive.service
TIMER_NAME=coach-proactive.timer
SERVICE_PATH="$USER_HOME/.config/systemd/user/$SERVICE_NAME"
TIMER_PATH="$USER_HOME/.config/systemd/user/$TIMER_NAME"

if [ ! -x "$VENV_PY" ]; then
    echo "✖ no python venv at $VENV_PY — run bootstrap step 7 first" >&2
    exit 1
fi
if [ ! -f "$SCRIPT" ]; then
    echo "✖ proactive script missing: $SCRIPT" >&2
    exit 1
fi

# Stop any leftover container-side watcher from earlier iterations.
if systemctl --user list-units --all 2>/dev/null | grep -q 'coach-watch.service'; then
    echo "▶ disabling legacy coach-watch.service (replaced by coach-proactive.timer)"
    systemctl --user disable --now coach-watch.service || true
    rm -f "$USER_HOME/.config/systemd/user/coach-watch.service"
fi

echo "▶ writing $SERVICE_NAME"
mkdir -p "$(dirname "$SERVICE_PATH")"
cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=g-stack Coach proactive tick (rules + brain growth + Telegram nudges)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
EnvironmentFile=${USER_HOME}/.env
# gbrain's shebang is "#!/usr/bin/env -S bun run …", so bun must be on PATH.
Environment=PATH=${USER_HOME}/.bun/bin:${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=G_STACK_REPO=${REPO}
Environment=COACH_GBRAIN_HOME=${REPO}/infra/data/gbrain-coach-home
Environment=GBRAIN_BIN=${USER_HOME}/.bun/bin/gbrain
Environment=AGENT_B_CONTAINER=g-stack-agent-b
WorkingDirectory=${REPO}
ExecStart=${VENV_PY} ${SCRIPT}
TimeoutStartSec=180
UNIT

echo "▶ writing $TIMER_NAME"
cat > "$TIMER_PATH" <<UNIT
[Unit]
Description=Run g-stack Coach proactive tick every 15 minutes
Requires=$SERVICE_NAME

[Timer]
# First fire 90s after boot so docker + pilot are up; then every 15min.
OnBootSec=90
OnUnitActiveSec=15min
AccuracySec=20s
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now "$TIMER_NAME"

echo
echo "--- timer status ---"
systemctl --user --no-pager status "$TIMER_NAME" | head -12 || true
echo
echo "▶ one immediate dry-run (so you can see the first tick in the log):"
systemctl --user start "$SERVICE_NAME" || true
sleep 2
echo
echo "--- recent log ---"
journalctl --user-unit "$SERVICE_NAME" --no-pager -n 30 --since '1 min ago' || true
