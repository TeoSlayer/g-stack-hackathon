#!/usr/bin/env bash
# One-shot bootstrap for a fresh GCP VM.
#
# Assumes the repo is already at ~/g-stack-hackathon. The companion
# `infra/REDEPLOY_GCP.md` is the narrative; this script is the
# executable, idempotent version.
#
# Run as the workspace user (alexgodo):
#   bash infra/scripts/bootstrap-vm.sh
#
# Steps:
#   1. Install Docker / Node / Bun / uv / OpenClaw / gbrain (skipped if present)
#   2. Set up Python venv + install workspace deps
#   3. Build + start the docker compose stack (pilot daemons)
#   4. OpenClaw gateway + patch env-file
#   5. Register MCP servers
#   6. Health-intelligence service
#   7. Coach proactive watch
#   8. Calendar sync (collector + coach gbrains, every 6h)
#
# Each step is idempotent and prints a section header so you can grep
# the output for failures.

set -euo pipefail

REPO="${G_STACK_REPO:-$HOME/g-stack-hackathon}"
SCRIPTS="$REPO/infra/scripts"

section() { echo; echo "═══ $* ═══"; }

section "1. system deps (apt + unzip)"
if ! command -v unzip >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg unzip jq
fi
unzip -v | head -1
echo "jq: $(jq --version)"

section "2. docker"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    echo "RELOG: docker installed but you may need to re-login for group membership"
fi
docker --version

section "3. node 22"
if ! node --version 2>/dev/null | grep -q '^v22'; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
fi
node --version

section "4. bun + uv"
[ -x "$HOME/.bun/bin/bun" ] || curl -fsSL https://bun.sh/install | bash
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
bun --version
uv --version

section "5. openclaw"
command -v openclaw >/dev/null 2>&1 || sudo npm install -g openclaw@latest
openclaw --version 2>&1 | head -1

section "6. gbrain (canonical git-clone install)"
if [ ! -d "$HOME/gbrain" ]; then
    git clone --depth 1 https://github.com/garrytan/gbrain.git "$HOME/gbrain"
    (cd "$HOME/gbrain" && bun install && bun link)
fi
gbrain --version 2>&1 | head -1 || true

section "7. workspace venv"
cd "$REPO"
[ -d .venv ] || uv venv
uv pip install -e '.[dev]' >/dev/null
uv pip install -r health-intelligence/requirements.txt >/dev/null
.venv/bin/python -c "import collector, coach; print('python imports OK')"

section "8. linux pilot binary"
bash "$REPO/infra/docker/pilot-bin/update-pilot.sh" || true

section "9. docker compose stack"
docker compose -f "$REPO/infra/docker/docker-compose.yml" up -d --build
sleep 8
docker ps --format '{{.Names}}: {{.Status}}'

section "10. openclaw gateway"
if ! systemctl --user list-units 2>/dev/null | grep -q openclaw-gateway; then
    openclaw gateway install
fi
bash "$SCRIPTS/patch-gateway-env.sh"

section "11. MCP servers (gbrain-collector / gbrain-coach)"
bash "$SCRIPTS/register-mcp.sh"

section "12. health-intelligence service"
bash "$SCRIPTS/install-health-intelligence.sh"

section "13. coach proactive watch"
bash "$SCRIPTS/install-coach-watch.sh"

section "14. calendar sync (collector + coach, every 6h)"
# Skipped automatically if the OAuth token is missing — run once
# interactively (see REDEPLOY_GCP.md step 7) before this step is useful.
if [ -f "$REPO/infra/secrets/google-calendar-token.json" ]; then
    bash "$SCRIPTS/install-calendar-sync.sh"
else
    echo "(skip) no google-calendar-token.json — re-OAuth then rerun this step manually"
fi

section "DONE — fast acceptance checks"
echo "--- containers ---"
docker ps --format '{{.Names}}: {{.Status}}'
echo "--- services ---"
systemctl --user --no-pager --type=service | grep -E 'openclaw|health-intel|coach-|calendar-' || true
echo "--- HTTP smoke ---"
curl -sS http://127.0.0.1:8741/health 2>/dev/null || echo "(health-intelligence not ready yet)"
echo "--- next: re-OAuth Google Calendar via SSH tunnel; see REDEPLOY_GCP.md step 7"
