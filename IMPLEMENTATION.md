# Implementation status — Collector + Coach scaffolding

The wire-schema spec described in `agent-a/SCHEMA.md` and the chunking /
outbox strategy in `agent-a/CHUNKING.md` are now realized in code.
Agent A (Collector) and Agent B (Coach) are both Python packages that
ride on top of Pilot.

## What's where

```
g-stack-hackathon/
├── pyproject.toml             ← workspace install: collector + coach
├── conftest.py                ← pytest fixtures (warehouse, trust policies)
├── tests/
│   ├── helpers.py             ← factory functions (make_envelope, …)
│   └── test_coach.py          ← cross-agent integration test
├── scripts/
│   ├── make_mock_envelopes.py ← seeded mock generator
│   └── run_e2e.sh             ← end-to-end smoke test
├── agent-a/                   ← the Collector
│   ├── README.md (spec, kept)
│   ├── SCHEMA.md (kept)
│   ├── CHUNKING.md (kept)
│   ├── collector/             ← Python package
│   │   ├── schema.py          Pydantic models for the wire shapes
│   │   ├── warehouse.py       DuckDB + per-uuid + per-batch dedupe
│   │   ├── ingester.py        process_envelope / process_route_chunk
│   │   ├── inbox_watcher.py   polls inbox, dispatches by shape
│   │   ├── sql_gate.py        read-only SQL gate + handle_query
│   │   ├── change_event.py    broadcast samples_added on port 1004
│   │   ├── transport.py       FileTransport / PilotctlTransport / TeeTransport
│   │   ├── trust.py           source/coach allowlists + version gating
│   │   └── server.py          daemon entry point
│   └── tests/                 unit tests for each module
├── agent-b/                   ← the Coach
│   ├── README.md (spec, kept)
│   └── coach/                 ← Python package
│       ├── client.py          StubPilot / PilotctlPilot + Coach API
│       ├── __main__.py        CLI: query / watch / readiness
│       └── gbrain_rollup.py   markdown derivation + raw mirror
└── infra/
    ├── README.md (kept)
    ├── data/                  ← runtime: facts.duckdb, acks_out/, events_log/
    └── docker/
        ├── Dockerfile.agent-a
        ├── Dockerfile.agent-b
        ├── docker-compose.yml
        ├── entrypoint-agent-a.sh
        └── entrypoint-agent-b.sh
```

## How it all works (in plain terms)

There are three actors. Each owns one job; they don't try to do each other's.

### 1. The iPhone (Source)

Lives in `health-sync/`. Reads HealthKit, packs samples into the wire
schema's `Envelope`, hands them to its own embedded Pilot node. The
**outbox** described in `agent-a/CHUNKING.md` makes this durable —
envelopes survive crashes, sync resumes, the HK anchor doesn't advance
until an Ack lands.

The iPhone is on its own Pilot identity. Trusted by Agent A.

### 2. Agent A — the Collector (the warehouse)

Lives in `agent-a/collector/`. OpenClaw LLM agent. Core job: **accept envelopes, dedupe,
write to DuckDB, ack the sender, tell the Coach that new facts landed.**
No human-facing surface — it is queried only by the Coach via `send-message`.

What runs concretely:

- `python -m collector.server` polls Pilot's inbox (`~/.pilot/inbox`) every
  1 second. Files are JSON, optionally wrapped by Pilot's
  `{agent, command, data}` envelope.
- `classify_message` looks at each file: is it an `Envelope`, a
  `RouteChunkEnvelope`, a `Query`, a pilot reply, or unknown?
- `process_envelope` runs each sample through Pydantic validation, dedupes
  by `uuid` against the warehouse, and returns an `Ack` with
  `{accepted, duplicates, rejected}`. The Ack goes back to the sender via
  the transport (FileTransport in tests, PilotctlTransport in prod).
- `process_route_chunk` buffers GPS chunks; once `chunk_total` arrive, the
  full route is materialized into `route_points` and a ChangeEvent fires.
- `handle_query` is the Coach surface: accepts a read-only SQL string,
  rejects writes at parse time, clamps `limit` to ≤10 000, returns rows +
  schema.
- After every batch commit, `ChangeEventBroadcaster.emit` writes to a local
  event log AND fans out to subscribed Coach identities on port 1004.

All communication is via `pilotctl send-message`. The Collector classifies messages by content shape in `inbox_watcher.py`:

| Content shape | Direction | Message |
|---|---|---|
| `samples` array | inbound | Envelopes + RouteChunkEnvelopes from iPhone |
| `sql` field | inbound | SQL queries from Coach |
| `kind: "samples_added"` | outbound | ChangeEvents sent to Coach |
| Ack JSON | outbound | Sent back to iPhone after each batch commit |

Real Pilot built-in ports: 1001 (dataexchange/send-message), 7 (echo), 444 (handshake). No application-level port routing.

### 3. Agent B — the Coach (the front)

Lives in `agent-b/coach/`. Talks to *you*. Owns Telegram, owns the LLM
turn, owns the rule loop. Treats the Collector as a tool: `query_collector`
returns rows; `change_event` says "go look again."

What's built today:

- `coach.client.Coach` — drops `Query` messages into the Collector's inbox
  via `StubPilot` (file-volume transport between containers) or
  `PilotctlPilot` (real overlay network). Waits for the matching
  `QueryResult` on the reply_port.
- `coach.gbrain_rollup.GbrainRollup` — derives daily-health markdown
  summaries and mirrors raw envelopes into `~/brain/sources/health/.raw`.
  Replaces the JS ingester's role on the gbrain side.
- CLI: `python -m coach query "<sql>"` / `python -m coach watch`
  / `python -m coach readiness`.

What's **not** built (and shouldn't be done at infra level — those are
agent-b's responsibility):

- Telegram channel (uses OpenClaw's adapter)
- LLM turn handling (uses OpenClaw's model layer)
- The 7 rule files (`sleep-regularity`, `kalman-hrv`, etc.) — these port
  the on-device Swift models in `health-sync/HealthSync/Models.swift`
- `gbrain_search` / `gbrain_write` tool wrappers (use the gbrain MCP)
- `gstack_run` / `pilot_specialist` tool wrappers (shell out to existing skills)

### How they talk

```
   iPhone (HealthSync)            Agent A — Collector             Agent B — Coach
   ───────────────────            ───────────────────             ────────────────
   pilot identity A               pilot identity B                pilot identity C
   ─────────────────              ───────────────                 ─────────────────
   • SCN / WatchKit               • port 1001 (envelopes in)      • LLM + Telegram
   • Outbox (SQLite)              • port 1003 (queries in)        • Rule loop
   • Splitter / retry             • port 1004 (events out)        • gbrain memory
                                  • DuckDB warehouse              • gstack skills
                                                                  • specialist calls

        Envelope → 1001   ──────────►   process_envelope ───┐
        Ack    ← ack_port ◄──────────   ack(accepted,dups,rej)
                                                            │
                                                            ▼
                                  ChangeEvent → 1004  ──────────────►  rule loop
                                                                       gbrain rollup

                                  ◄────  Query  ◄── port 1003 ──────  query_collector tool
                                  ────► QueryResult → reply_port ─►   LLM
```

All three are **separate Pilot identities**. Identity isolation matters: the Collector is the only writer to DuckDB; the Coach is read-only via SQL queries. The trust list on each identity is what enforces that.

The two GCP identities run in their own Docker containers (see `infra/docker/`) so each has its own `~/.pilot/` socket. **No two Pilot daemons fight for one socket — that's what Docker isolation solves.**

### What the e2e test proves

`scripts/run_e2e.sh` drops 8 mock messages into `~/.pilot/inbox` and runs
the Collector for one tick. The output (full log in this commit) shows:

| Scenario | Result |
|---|---|
| Clean envelope (12 samples + 1 workout, inline route) | 13 accepted, 0 dup, 0 reject |
| Bad-sample envelope (1 good + NaN value + unknown kind) | 1 accepted, 2 rejected with `schema_error` reasons |
| Replay of the clean envelope (same batch_id) | 0 accepted, 13 duplicates (batch dedupe + per-uuid dedupe) |
| Workout w/ non-inline route + 3 RouteChunkEnvelopes | Workout accepted, all 3 chunks accepted, route assembled (9 points, `route_complete=true`, 0 inflight chunks) |
| Coach Query (`SELECT type, COUNT(*) FROM samples GROUP BY type`) | 5 rows returned in 0 ms via the reply_port |
| 4 ChangeEvents | Broadcast with the per-type histograms |

The full pipeline is end-to-end correct. The Ack contract that breaks
the iOS source under the old 5-min cron now lands well inside the 30 s
budget.

## Current status

Everything described above is deployed and operational on GCP.

### Done

- ✅ Real Pilot daemon binaries in each container (`infra/docker/pilot-bin/`)
- ✅ `PilotctlTransport` end-to-end against real Pilot overlay
- ✅ OpenClaw workspaces for both agents (`.openclaw/collector-workspace/`, `.openclaw/coach-workspace/`)
- ✅ Telegram channel registered in Coach workspace
- ✅ 7 rule models ported from `Models.swift` to Python (`agent-b/coach/`)
- ✅ G-Brain integration — both agents have separate instances with wrapper scripts
- ✅ Google Calendar OAuth + incremental sync (`calendar_sync.py`)
- ✅ health-intelligence skill registered in both OpenClaw workspaces
- ✅ Docker Compose deployment on GCP with persistent volumes
- ✅ pilot-swift embedded in iOS app with PilotSyncTransport sending envelopes
- ✅ iOS outbox + retry (SQLite-backed, crash-safe)

### What's next

- [ ] **Google Drive + Gmail pull** in Coach — incremental changed-files feed, plain-text extraction
- [ ] **G-Brain rollup from Collector** — write markdown summary of each batch to `gbrain-collector-home` after commit
- [ ] **Source identity allowlist from config** — currently hardcoded in `trust.py`
- [ ] **ZeroEntropy reranker** in health-intelligence — integration in progress
- [ ] **v=2 envelope handling** — version gate is in place; migration script needed when iOS bumps

## Running it

```sh
# Setup once
cd ~/g-stack-hackathon
uv venv --python 3.13
uv pip install -e '.[dev]'

# Run all tests
.venv/bin/pytest                     # 84 passing

# End-to-end with mock data
./scripts/run_e2e.sh                 # drops mocks, runs Collector once

# Daemon mode (real-time Acks for live iOS sends)
.venv/bin/python -m collector.server # polls ~/.pilot/inbox every 1s

# Coach CLI
.venv/bin/python -m coach query "SELECT COUNT(*) FROM samples"
.venv/bin/python -m coach watch       # subscribe to ChangeEvents
.venv/bin/python -m coach readiness   # canned 7-day HRV roll-up

# Docker (two separate Pilot identities, no socket collision)
docker compose -f infra/docker/docker-compose.yml up --build
```

## Mapping: agents → OpenClaw

The user's note: *"Each agent pilot node (agent-a and agent-b) will be
assigned to actual openclaw agents (the actual collector and the coach)."*

OpenClaw is the host. Each Python entry point becomes a skill:

| OpenClaw agent | Python entry | Communication |
|---|---|---|
| `agent-a` — Collector | `python -m collector.server` | Receives envelopes + SQL queries; sends Acks + ChangeEvents via `send-message` |
| `agent-b` — Coach | `python -m coach watch` + Telegram channel | Receives ChangeEvents; sends SQL queries; answers on Telegram |

The skill manifests (`agent-a/skill.json`, `agent-b/skill.json`) are the
remaining bridge — they tell OpenClaw how to start each process, what
permissions to grant, and how channels (Telegram) attach.
