# agent-b — Coach

OpenClaw LLM agent. Monitors the health warehouse, runs rule models, answers
the user on **Telegram**, and builds context from Google Calendar.

Runs as Docker container `g-stack-agent-b` on the GCP deployment VM.
OpenClaw workspace at `../.openclaw/coach-workspace/`.

## What it owns

| Concern | How |
|---|---|
| Health monitoring | Subscribes to Collector ChangeEvents; runs 7 rule models on each |
| User interface | Telegram channel registered in OpenClaw; answers ≤200 words, no pipe tables |
| Cross-source queries | Sends JSON with `sql` field to Collector via `send-message`; Collector executes read-only + replies |
| Calendar context | `calendar_sync.py` pulls from Google Calendar OAuth → daily markdown → imported into G-Brain |
| G-Brain memory | `gbrain-coach-home` — interpretations, prior nudges, calendar context. Sole writer. |
| Evidence backing | `health-intelligence` skill: calls `http://127.0.0.1:8741/retrieve` for paper-backed interventions |

## Why two separate G-Brains

The Collector writes factual observations (what happened, when, raw counts).
The Coach writes interpretations (what it noticed, what it told the user,
follow-up hypotheses). Keeping them separate means the Coach can never
overwrite the Collector's factual record, and each agent's memory is scoped
to its role.

## The 7 rule models

Ported from `health-sync/HealthSync/Models.swift`. The Coach runs these
against the Collector's DuckDB after each ChangeEvent:

1. **Sleep regularity** — variance of bedtimes over last 14 nights
2. **Autonomic balance** — HRV / RHR ratio z-score
3. **Sedentary stress** — daily steps deficit vs trailing baseline
4. **Cognitive recovery debt** — sleep debt × HRV depression
5. **Burnout CUSUM** — running sum of negative RHR deviations
6. **Circadian drift** — bedtime Mann-Kendall trend
7. **Kalman HRV** — denoised HRV state estimator

If a rule fires and cooldown has elapsed: Coach writes an insight to its
G-Brain and sends a proactive Telegram nudge.

## How messaging works

All Pilot communication is `pilotctl send-message <target> --data <json>`.
The Collector's inbox_watcher classifies by content shape:
- JSON with `sql` → handled as a query; QueryResult sent back
- JSON with `kind: "samples_added"` → ChangeEvent the Coach sent

There are no virtual port numbers at the application level. See
[`../README.md`](../README.md) for how message classification works.

## Status

| Module | Status | What it does |
|---|---|---|
| `client.py` | ✓ Done | `PilotctlPilot` — sends queries via pilotctl, reads results from Pilot inbox |
| `__main__.py` | ✓ Done | CLI: `coach query`, `coach watch`, `coach readiness` |
| `gbrain_rollup.py` | ✓ Done (health path) | Derives daily markdown summaries from health data |
| `calendar_sync.py` | ✓ Standalone | Google Calendar OAuth + incremental event pull → daily markdown files |
| `tools/gbrain.py` | ⚠ Skeleton | G-Brain MCP tool wrappers |
| Google Drive + Gmail pull | ✗ Not started | |
| Drive/Gmail → G-Brain import | ✗ Not started | |

## Running (production)

```sh
# On the GCP VM:
docker compose -f infra/docker/docker-compose.yml up -d
docker logs g-stack-agent-b --follow

# One-off calendar import:
docker exec g-stack-agent-b python -m coach.calendar_sync --days 30
~/g-stack-hackathon/infra/bin/gbrain-coach import ~/brain/daily/calendar
```

## Running (local dev)

```sh
# Query the Collector (requires Collector running):
python -m coach query "SELECT type, COUNT(*) FROM samples GROUP BY type"

# Subscribe to ChangeEvents (runs until interrupted):
python -m coach watch

# 7-day HRV readiness:
python -m coach readiness

# One-time Google OAuth consent (opens browser, persists refresh token):
python agent-b/coach/calendar_sync.py --auth-only

# Pull 30 days of calendar → ~/brain/daily/calendar/:
python agent-b/coach/calendar_sync.py --days 30
```

## Google Calendar integration

`calendar_sync.py` implements the full OAuth 2.0 flow with incremental sync
via `nextSyncToken`. Events are written as daily markdown files under
`~/brain/daily/calendar/`. The `seed_vm.sh` script on the GCP VM copies
these files and imports them into both `gbrain-collector-home` and
`gbrain-coach-home` so both agents have calendar context for cross-source
reasoning ("HRV dropped on the week with 14 back-to-back calls").

## Coach response style

- Default ≤200 words. Lead with the answer in the first sentence.
- **No pipe tables** — Telegram doesn't render them. Use bullets, prose,
  or space-aligned ASCII tables inside code fences.
- Cite tools inline: `(via coach query)`, `(per gbrain 2026/2026-05-13)`.
- When answering health questions, end with an "Evidence-based
  recommendations" section from the health-intelligence skill.
- One Telegram message per proactive nudge; rate-limited per rule.

## What's next

1. Google Drive changed-files feed with plain-text extraction
2. Gmail label-filtered thread sync
3. Drive/Gmail → G-Brain import wired into main flow
4. G-Brain rollup triggered on Coach after each ChangeEvent

## Where it fits

```
Google Calendar (OAuth pull)
    │  calendar_sync.py → ~/brain/daily/calendar/
    ▼
┌─────────────────────────────────┐
│  g-stack-agent-b  (Coach)       │
│  python -m coach watch          │
│  G-Brain: gbrain-coach-home     │
│  OpenClaw workspace             │
└──────────┬──────────────────────┘
           │  send-message (SQL queries)
           │  receives ChangeEvents
     ┌─────▼─────────────────────────┐
     │  g-stack-agent-a  (Collector) │
     └───────────────────────────────┘
           │  OpenClaw channel
     ┌─────▼──────┐
     │  Telegram  │
     └────────────┘
```

See [`../README.md`](../README.md) for the full picture and
[`../infra`](../infra) for Docker Compose setup and secrets layout.
