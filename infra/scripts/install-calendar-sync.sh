#!/usr/bin/env bash
# install-calendar-sync.sh
#
# Install a systemd user service + timer that pulls Google Calendar
# events into BOTH agent brains every 6 hours. Idempotent.
#
# Cadence justification: 6h gives same-day responsiveness to
# rescheduled meetings without spamming the Calendar API or the brain
# import path. The autogen markers in each daily page keep manual user
# notes intact across re-runs.

set -euo pipefail

USER_HOME="${HOME}"
REPO="${G_STACK_REPO:-$USER_HOME/g-stack-hackathon}"
RUNNER="$REPO/infra/scripts/sync-calendar-both.sh"

SERVICE_NAME=calendar-sync.service
TIMER_NAME=calendar-sync.timer
SERVICE_PATH="$USER_HOME/.config/systemd/user/$SERVICE_NAME"
TIMER_PATH="$USER_HOME/.config/systemd/user/$TIMER_NAME"

[ -x "$RUNNER" ] || { echo "✖ runner not executable: $RUNNER" >&2; exit 1; }

echo "▶ writing $SERVICE_NAME"
mkdir -p "$(dirname "$SERVICE_PATH")"
cat > "$SERVICE_PATH" <<UNIT
[Unit]
Description=g-stack Google Calendar → collector + coach brains
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# gbrain shebang is "#!/usr/bin/env -S bun run ..."
Environment=PATH=${USER_HOME}/.bun/bin:${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=G_STACK_REPO=${REPO}
Environment=GBRAIN_BIN=${USER_HOME}/.bun/bin/gbrain
WorkingDirectory=${REPO}
ExecStart=${RUNNER}
TimeoutStartSec=300
UNIT

echo "▶ writing $TIMER_NAME"
cat > "$TIMER_PATH" <<UNIT
[Unit]
Description=Run g-stack Google Calendar sync every 6 hours
Requires=$SERVICE_NAME

[Timer]
# First fire 2 min after boot (after docker + gateway are up), then 6h.
OnBootSec=2min
OnUnitActiveSec=6h
AccuracySec=1min
Persistent=true
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
echo "▶ one immediate dry-run so the brains pick up the latest schedule:"
systemctl --user start "$SERVICE_NAME" || true
sleep 4
echo
echo "--- recent log ---"
journalctl --user-unit "$SERVICE_NAME" --no-pager -n 40 --since '1 min ago' || true
