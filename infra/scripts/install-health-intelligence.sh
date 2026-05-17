#!/usr/bin/env bash
# Install + start the health-intelligence FastAPI server as a systemd user
# unit. Idempotent: re-running replaces the unit + restarts the service.
#
# Run on the VM after the workspace venv exists and after
# `infra/scripts/bootstrap-vm.sh` has set up runtime deps.

set -euo pipefail

USER_HOME="${HOME}"
REPO="${G_STACK_REPO:-$USER_HOME/g-stack-hackathon}"
SERVICE_NAME=health-intelligence.service
UNIT_PATH="$USER_HOME/.config/systemd/user/$SERVICE_NAME"

echo "▶ installing $SERVICE_NAME"
mkdir -p "$(dirname "$UNIT_PATH")"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=g-stack health-intelligence FastAPI server (ZeroEntropy-backed retrieval)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${REPO}/health-intelligence
EnvironmentFile=${USER_HOME}/.env
Environment=PORT=8741
Environment=PYTHONPATH=${REPO}/health-intelligence
ExecStart=${REPO}/.venv/bin/python ${REPO}/health-intelligence/server.py
Restart=always
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"
sleep 4
systemctl --user is-active "$SERVICE_NAME"
echo
echo "--- recent log ---"
journalctl --user-unit "$SERVICE_NAME" --no-pager -n 12 --since '30 sec ago' || true
echo
echo "--- HTTP smoke ---"
if command -v curl >/dev/null 2>&1; then
    curl -sS http://127.0.0.1:8741/health || echo "(server not responding yet)"
fi
