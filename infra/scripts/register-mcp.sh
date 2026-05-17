#!/usr/bin/env bash
# Register the two per-agent gbrain MCP servers in OpenClaw.
#
# Both run `gbrain serve` (stdio MCP) with HOME pinned to the agent's
# isolated gbrain dir, so the LLM gets that agent's PGLite — not a shared
# brain. Idempotent: `openclaw mcp set` overwrites in place.

set -euo pipefail

USER_HOME="${HOME}"
REPO="${G_STACK_REPO:-$USER_HOME/g-stack-hackathon}"
GBRAIN_BIN="${GBRAIN_BIN:-$USER_HOME/.bun/bin/gbrain}"

if [ ! -x "$GBRAIN_BIN" ]; then
    echo "gbrain binary not found at $GBRAIN_BIN — install gbrain first" >&2
    exit 1
fi

echo "▶ registering gbrain-collector MCP (HOME=${REPO}/infra/data/gbrain-collector-home)"
openclaw mcp set gbrain-collector "$(cat <<JSON
{
  "command": "${GBRAIN_BIN}",
  "args": ["serve"],
  "env": {"HOME": "${REPO}/infra/data/gbrain-collector-home"}
}
JSON
)"

echo
echo "▶ registering gbrain-coach MCP (HOME=${REPO}/infra/data/gbrain-coach-home)"
openclaw mcp set gbrain-coach "$(cat <<JSON
{
  "command": "${GBRAIN_BIN}",
  "args": ["serve"],
  "env": {"HOME": "${REPO}/infra/data/gbrain-coach-home"}
}
JSON
)"

echo
echo "▶ verifying"
openclaw mcp list

echo
echo "▶ restarting gateway so it picks up the MCP config"
systemctl --user restart openclaw-gateway.service
sleep 4
systemctl --user is-active openclaw-gateway.service
