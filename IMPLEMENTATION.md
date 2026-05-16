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

Lives in `agent-a/collector/`. Its only job: **accept envelopes, dedupe,
write to DuckDB, ack the sender, tell Agent B that new facts landed.**
No LLM, no reasoning, no human-facing surface.

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

The Collector owns three Pilot ports of its **single identity**:

| Port | Direction | Message |
|---|---|---|
| 1001 | inbound  | Envelopes + RouteChunkEnvelopes from sources |
| 1003 | inbound  | Queries from Coaches |
| 1004 | outbound | ChangeEvents broadcast to Coaches |

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

All three are **separate Pilot identities**, even when two of them run on
the same homelab box. Identity isolation matters: the Collector is the
only writer to DuckDB; the Coach is read-only over Pilot. The trust list
on each identity is what enforces that.

The two homelab identities run in their own Docker containers (see
`infra/docker/`) so each one has its own `~/.pilot/` socket. **No two
Pilot daemons fight for one socket — that's the deal-breaker the
docker isolation solves.**

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

## What's left

In priority order, sized so each is a few hours of work.

### Phase A — Pilot transport correctness

- [ ] **Real `pilot-daemon` Linux binary** in each container. Today the
      Docker stack runs in "stub pilot" mode (shared inbox volume between
      containers) so the e2e is provable without the binary. Production
      needs the actual daemon to register with the registry/beacon.
- [ ] **`PilotctlTransport` end-to-end test** against a real overlay.
      Should send an Ack via `pilotctl send-message` and have a real
      Pilot node receive it. The Coach's `PilotctlPilot` needs the same
      treatment.
- [ ] **Source identity allowlist enforcement.** The trust gate is in
      code; the actual identity-to-label mapping (e.g. `ios.healthsync.calin`
      → the Pilot node_id printed by `pilotctl info`) needs an
      `infra/pilot/trust.json` file format and a config loader for it.

### Phase B — Coach completes the loop

- [ ] **OpenClaw skill manifest** for agent-b. The README sketches `skill.json`;
      it needs the actual file plus the channel adapter wiring.
- [ ] **Telegram channel registration.** Per `infra/README.md` step 3.
      Needs `infra/.env.example`, `TELEGRAM_BOT_TOKEN` plumbing, and the
      Telegram-side `/start` handshake.
- [ ] **`query_collector` tool** wrapped for the LLM. The Coach client has
      `.query(sql)` working; we need the OpenClaw tool descriptor + the
      LLM prompt that explains the warehouse schema.
- [ ] **Rule loop** — port `Models.swift` to Python. Seven rules:
      sleep-regularity, autonomic-balance, sedentary-stress, cognitive-debt,
      burnout-cusum, circadian-drift, kalman-hrv. Each reads DuckDB via
      `coach.client.query`, computes a band, fires a Telegram nudge if
      warn/bad and cooldown has elapsed.
- [ ] **gbrain integration.** `gbrain_search` / `gbrain_write` as
      tools. Cron a `gbrain import infra/data/brain/` after the Coach
      rebuilds markdown (or use the gbrain MCP directly).
- [ ] **`gstack_run` and `pilot_specialist` tools** — shell-out skill calls
      and Pilot directory queries, both with the existing CLIs.

### Phase C — Production deployment

- [ ] **launchd / systemd units** at `infra/services/` per the spec.
      Two services on the homelab: `g-stack-agent-a` and `g-stack-agent-b`
      (Docker compose'd up, autostart on boot).
- [ ] **`infra/scripts/backup.sh`** — pause agent-a, `COPY` DuckDB to
      Parquet, snapshot gbrain, tar Pilot identity + trust, resume.
- [ ] **`infra/scripts/healthcheck.sh`** — checks daemon, both skills,
      DuckDB row movement in last hour, Pilot peer count, Telegram ping.
- [ ] **iOS-side Pilot integration.** The HealthSync app currently
      collects locally; the embedded Pilot piece is the next iOS task.
      The Collector is ready to receive whenever the iOS source ships
      the embedded `pilot-swift` SDK.

### Phase D — Schema evolution

- [ ] **v=2 envelope handling.** The version gate already accepts `v` and
      `v-1`; when iOS bumps to `v=2`, write a migration script in
      `agent-a/migrations/` and bump `CURRENT_VERSION`.
- [ ] **Additional sources.** `calendar-sync/`, `bank-sync/`,
      `music-sync/` join via their own Pilot identity → port 1001.
      No Collector code change needed beyond adding their identities to
      the source allowlist.

### Phase E — Polish

- [ ] **Observability counters surfaced on Telegram `/status`.**
      `outbox.pending`, `outbox.lastAck`, `samples_total`, `events_today`.
- [ ] **Route stream-mode upload.** The 1500-pt chunked datagram path
      already works; future work moves >5k-pt routes onto Pilot streams
      (`pilot.dial`) per the CHUNKING.md "Future" note.

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

| OpenClaw agent | Python entry | Pilot ports |
|---|---|---|
| `agent-a` | `python -m collector.server` | 1001, 1003 in; 1004 out |
| `agent-b` | `python -m coach watch` + Telegram channel | watches 1004; 1003 out; reply_port in |

The skill manifests (`agent-a/skill.json`, `agent-b/skill.json`) are the
remaining bridge — they tell OpenClaw how to start each process, what
permissions to grant, and how channels (Telegram) attach.
