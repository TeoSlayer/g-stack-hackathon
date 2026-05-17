#!/usr/bin/env bash
# sync-calendar-both.sh
#
# Pull Google Calendar events into BOTH agent brains so the Collector
# can join schedule context with health data and the Coach can reason
# about upcoming meetings when giving recommendations.
#
# Run order:
#   1. Hit the Google Calendar API once, write markdown to a shared
#      scratch dir under the repo (so we don't pay the API cost twice).
#   2. `gbrain import` from that scratch dir with HOME pinned to the
#      Collector brain.
#   3. `gbrain import` again with HOME pinned to the Coach brain.
#
# Idempotent: re-running with the same date range overwrites the same
# daily pages. User notes appended below the calendar autogen block
# survive (see _merge_with_existing_notes in calendar_sync.py).
#
# Driven entirely by env:
#   G_STACK_REPO        repo root (default: ~/g-stack-hackathon)
#   CAL_START           start date YYYY-MM-DD  (default: today - 30 days)
#   CAL_END             end date   YYYY-MM-DD  (default: today + 30 days)
#   CAL_ACCOUNT_LABEL   account: frontmatter   (default: primary)
#   GBRAIN_BIN          gbrain CLI             (default: ~/.bun/bin/gbrain)
#
# Exit codes: 0 on success, non-zero if either import fails.

set -euo pipefail

REPO="${G_STACK_REPO:-$HOME/g-stack-hackathon}"
SCRATCH="$REPO/infra/data/calendar-markdown"
COLLECTOR_HOME="$REPO/infra/data/gbrain-collector-home"
COACH_HOME="$REPO/infra/data/gbrain-coach-home"
CLIENT="$REPO/infra/secrets/google-oauth-client.json"
TOKEN="$REPO/infra/secrets/google-calendar-token.json"
GBRAIN_BIN="${GBRAIN_BIN:-$HOME/.bun/bin/gbrain}"
PY="$REPO/.venv/bin/python"
ACCOUNT_LABEL="${CAL_ACCOUNT_LABEL:-primary}"

# Default range: trailing month + lookahead month. Lets the brains
# carry both historical context (for explanations) and upcoming
# obligations (for proactive nudges like "you have a 23:00 call
# tonight, protect sleep tomorrow").
TODAY="$(date -u +%Y-%m-%d)"
START="${CAL_START:-$(date -u -d "$TODAY - 30 days" +%Y-%m-%d)}"
END="${CAL_END:-$(date -u -d "$TODAY + 30 days" +%Y-%m-%d)}"

# ── preflight ────────────────────────────────────────────────────────
[ -x "$PY" ]         || { echo "✖ no venv python at $PY" >&2; exit 1; }
[ -f "$CLIENT" ]     || { echo "✖ missing $CLIENT (OAuth client)" >&2; exit 1; }
[ -f "$TOKEN" ]      || { echo "✖ missing $TOKEN (run interactive OAuth once)" >&2; exit 1; }
[ -x "$GBRAIN_BIN" ] || { echo "✖ no gbrain at $GBRAIN_BIN" >&2; exit 1; }
mkdir -p "$SCRATCH"

echo "▶ syncing Google Calendar $START → $END (account: $ACCOUNT_LABEL)"

# ── 1) hit the API + write markdown (no gbrain import here) ──────────
# We disable the inline import via --no-gbrain so the script does it
# manually once per brain below. That avoids double-fetching events.
PATH="$(dirname "$GBRAIN_BIN"):$PATH" \
HOME="$COLLECTOR_HOME" \
PYTHONPATH="$REPO/agent-b" \
"$PY" -m coach.calendar_sync \
  --client-secret "$CLIENT" \
  --token         "$TOKEN" \
  --brain-dir     "$SCRATCH" \
  --start "$START" --end "$END" \
  --account-label "$ACCOUNT_LABEL" \
  --no-browser \
  --no-gbrain

# ── 2) import into the Collector brain ───────────────────────────────
echo "▶ gbrain import → collector ($COLLECTOR_HOME)"
PATH="$(dirname "$GBRAIN_BIN"):$PATH" \
HOME="$COLLECTOR_HOME" \
"$GBRAIN_BIN" import "$SCRATCH" --no-embed

# ── 3) import into the Coach brain ───────────────────────────────────
echo "▶ gbrain import → coach ($COACH_HOME)"
PATH="$(dirname "$GBRAIN_BIN"):$PATH" \
HOME="$COACH_HOME" \
"$GBRAIN_BIN" import "$SCRATCH" --no-embed

# ── 4) re-embed stale pages in both brains (best-effort) ─────────────
# embed is what makes hybrid search RAG work; skip silently on failure.
for h in "$COLLECTOR_HOME" "$COACH_HOME"; do
  PATH="$(dirname "$GBRAIN_BIN"):$PATH" HOME="$h" \
    "$GBRAIN_BIN" embed --stale 2>/dev/null || echo "(embed --stale skipped for $h)"
done

echo "✓ calendar sync complete (range $START → $END)"
