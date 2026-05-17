# g-stack

Personal health intelligence system: two OpenClaw agents backed by separate
G-Brain memories, a health-intelligence retrieval layer, and Pilot Protocol as
the transport shim — connecting iPhone, cloud agents, and Telegram with no
extra infrastructure.

The user talks to the **Coach on Telegram**. The Collector warehouses health
data silently. Both are OpenClaw LLM agents, not dumb Python daemons.

## Architecture

```
  iPhone (HealthKit + Apple Watch)
    pilot-swift embedded daemon
    PilotSyncTransport
          │
          │  pilotctl send-message → Collector node
          │  (E2E encrypted, NAT-traversed over Pilot overlay)
          ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  GCP: hackathon-openclaw  — Docker Compose                      │
  │                                                                  │
  │  ┌─────────────────────────┐   ┌──────────────────────────────┐ │
  │  │  g-stack-agent-a        │   │  g-stack-agent-b             │ │
  │  │  OpenClaw: Collector    │   │  OpenClaw: Coach             │ │
  │  │  Pilot node (Collector) │◄──►  Pilot node (Coach)          │ │
  │  │  python -m collector    │   │  python -m coach watch       │ │
  │  │  facts.duckdb           │   │  G-Brain: gbrain-coach-home  │ │
  │  │  G-Brain:               │   │  calendar_sync.py            │ │
  │  │    gbrain-collector-home│   │  health-intelligence skill   │ │
  │  │  health-intelligence    │   │                              │ │
  │  │    skill                │   └──────────────┬───────────────┘ │
  │  └─────────────────────────┘                  │                 │
  │                                               │ OpenClaw        │
  │                                        ┌──────▼──────┐         │
  │                                        │  Telegram   │         │
  │                                        │  channel    │         │
  │                                        └─────────────┘         │
  └──────────────────────────────────────────────────────────────────┘
          │
          │  HTTP 127.0.0.1:8741
          ▼
  ┌────────────────────┐
  │  health-intelligence│
  │  FastAPI sidecar    │
  │  17 papers          │
  │  89 interventions   │
  └────────────────────┘
```

## How Pilot transport actually works

Every message between nodes uses one primitive:

```sh
pilotctl send-message <target-node-id> --data '<json>'
```

The Pilot daemon delivers that JSON to the target's `~/.pilot/inbox/` as a
file. The receiving process (Collector's `inbox_watcher.py` or Coach's
`client.py`) polls that directory and classifies messages by their **content
shape** — no virtual port routing at the application level:

| Message content | Classified as | Action |
|---|---|---|
| Has `samples` array | HealthKit envelope | Dedupe → write DuckDB → send Ack |
| Has `sql` field | SQL query from Coach | Execute → send QueryResult back |
| Has `kind: "samples_added"` | ChangeEvent | Coach runs rule models |
| Has `agent`/`command` but no `samples`/`sql` | Pilot reply | Passed to G-Brain ingester |

Acks and QueryResults are sent back with another `send-message` call to the
original sender. The `reply_port` field in query bodies (value `1005`) is
just a metadata tag the Coach embeds so it can correlate replies — not a
Pilot routing mechanism.

Pilot's built-in services: `send-message` uses port 1001 (dataexchange),
echo/ping uses port 7, handshakes use port 444.

## How the two agents work

**Collector (agent-a)** is a Python daemon running inside an OpenClaw
workspace. It receives HealthKit envelopes from the iPhone, dedupes by sample
UUID (`INSERT OR IGNORE`), writes to `facts.duckdb` in a Docker volume, and
emits ChangeEvents to the Coach. It answers factual SQL queries — raw numbers,
no interpretation. Its G-Brain (`gbrain-collector-home`) holds calendar
context and factual observations it has written.

**Coach (agent-b)** is an OpenClaw LLM agent that runs `python -m coach watch`
at container start to subscribe to Collector ChangeEvents. It runs 7 rule
models (HRV stability, autonomic balance, sleep regularity, burnout CUSUM,
circadian drift, sedentary stress, cognitive recovery debt), writes insights
to its own G-Brain (`gbrain-coach-home`), and sends proactive Telegram nudges
when rules fire. It answers on-demand health questions via the Telegram channel
OpenClaw binds to it, combining DuckDB queries + G-Brain recall +
health-intelligence RAG evidence.

Both agents have separate OpenClaw workspaces (`.openclaw/collector-workspace/`
and `.openclaw/coach-workspace/`) with separate G-Brain instances, identity
files, SOUL.md, IDENTITY.md, and skill manifests.

## Data flow

```
1.  iPhone polls HealthKit (anchored queries — each sample captured once)
2.  Samples compressed + encoded → Pilot envelope JSON
3.  PilotSyncTransport calls pilotctl send-message → Collector node
4.  Pilot delivers to Collector's inbox as a JSON file
5.  inbox_watcher classifies: has "samples" → envelope path
6.  Collector dedupes by UUID (INSERT OR IGNORE), writes to facts.duckdb
7.  Collector sends Ack back to iPhone via send-message (accepted/dup/rejected)
8.  iOS advances HealthKit anchor only after Ack received
9.  Collector emits ChangeEvent (kind: "samples_added") → Coach inbox
10. Coach runs rule models: send-message to Collector with sql query →
    Collector executes + sends back QueryResult
11. If rule fires + cooldown elapsed → Coach writes insight to G-Brain
    + sends proactive Telegram nudge via OpenClaw
12. On-demand Telegram question → Coach queries DuckDB + G-Brain + RAG
    → answers on Telegram (≤200 words, no pipe tables)
```

## Sub-projects

| Path | What it is | Status |
|---|---|---|
| [`pilot-swift/`](pilot-swift/) | Swift package embedding the Pilot daemon inside iOS/macOS apps. Static `Pilot.xcframework` + Swift wrapper. Smoke test passes on iOS simulator. | **Working** |
| [`health-sync/`](health-sync/) | iOS + watchOS + widget app. Reads HealthKit, runs 27 on-device models, charts trends and forecasts. `PilotSyncTransport` implemented and sending envelopes. | **Working. Requires Collector reachable via Pilot.** |
| [`agent-a/`](agent-a/) | Collector. Receives envelopes, dedupes, warehouses to DuckDB, serves SQL queries, emits ChangeEvents. 84 tests passing. OpenClaw workspace at `.openclaw/collector-workspace/`. | **Deployed on GCP.** |
| [`agent-b/`](agent-b/) | Coach. OpenClaw LLM agent. Monitors health warehouse via rule models, answers on Telegram, imports Google Calendar into G-Brain. OpenClaw workspace at `.openclaw/coach-workspace/`. | **Deployed on GCP. Calendar import working.** |
| [`health-intelligence/`](health-intelligence/) | FastAPI RAG server. 17 peer-reviewed papers, 89 interventions. Alert-match + semantic retrieval. OpenClaw skill in both agent workspaces. | **Running on GCP at port 8741. ZeroEntropy integration in progress.** |
| [`gstack-ios/`](gstack-ios/) | iOS/watchOS/WidgetKit skill pack for Claude Code. 13 skills covering build, test, signing, perf, TestFlight. Used to develop health-sync itself. | **Working — all 13 skills active.** |
| [`infra/`](infra/) | Docker Compose, Dockerfiles, OpenClaw workspace configs, G-Brain setup, secrets layout. Deployed on GCP `hackathon-openclaw`. | **Deployed and running.** |

## Running (production — GCP)

```sh
# On hackathon-openclaw (GCP):
cd ~/g-stack-hackathon/infra/docker
docker compose up -d          # starts both containers

docker logs g-stack-agent-a   # Collector: envelope + query log
docker logs g-stack-agent-b   # Coach: ChangeEvent + Telegram log

# Query the Collector warehouse:
docker exec g-stack-agent-b python -m coach query \
  "SELECT type, COUNT(*) FROM samples GROUP BY type"

# Import calendar into Coach's G-Brain:
~/g-stack-hackathon/infra/bin/gbrain-coach import ~/brain/daily/calendar
```

## Running (local dev)

```sh
# iOS app, standalone:
cd health-sync && xcodegen generate && open HealthSync.xcworkspace

# Pilot Swift SDK smoke test:
cd pilot-swift && scripts/run-smoke-sim.sh info

# Collector unit + integration tests:
pytest agent-a/tests/          # 84 tests
./scripts/run_e2e.sh           # 8 E2E scenarios

# health-intelligence server:
cd health-intelligence && .venv/bin/python server.py
curl http://127.0.0.1:8741/health
```

## Cross-cutting docs

| Doc | Covers |
|---|---|
| [`LIFECYCLE.md`](LIFECYCLE.md) | Boot sequences, state machines, failure modes |
| [`agent-a/SCHEMA.md`](agent-a/SCHEMA.md) | Wire format: envelope, sample variants, ack, query, change-event |
| [`agent-a/CHUNKING.md`](agent-a/CHUNKING.md) | iOS outbox SQLite schema, chunk splitter, retry/backoff |
| [`health-intelligence/SKILL.md`](health-intelligence/SKILL.md) | Skill manifest, request/response schema, metric ID reference |
| [`health-sync/misc/METRICS.md`](health-sync/misc/METRICS.md) | All 27 on-device models: formula, data sources, alert thresholds |

## What's next

| Work item | Status |
|---|---|
| Google Drive + Gmail pull in Coach | Not started |
| ZeroEntropy reranker in health-intelligence | Integration in progress |
| G-Brain rollup from Collector after each batch | Not started |
| Source identity allowlist from config (trust.py) | Currently hardcoded |

## License

AGPL-3.0-or-later, matching upstream Pilot Protocol.
