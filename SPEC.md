# g-stack — system spec

The point of the system in one sentence: **your own data feeds your own
agent, your agent talks to you on a channel you already use, no third
party sees the raw data.**

This file is the narrative of what's been built, why it's split the way
it is, and what runs where. For the file map see `IMPLEMENTATION.md`;
for role contracts see `ROLES.md`.

## The premise

Every consumer data product asks you to hand over your data so they can
sell you back an interpretation. The data is locked on their servers and
the interpretation is trained on a population that isn't you. g-stack is
the inversion: your devices push to your agents; the agents talk to you
on the channel of your choosing; nothing in the loop sees raw data
except the things you own.

```
  Your devices                Your agents               You
  (iPhone, calendar,          (Collector + Coach        (Telegram chat,
   bank, music, …)             on your homelab)         CLI, future channels)
       │                             ▲
       └── encrypted overlay ────────┘
              (Pilot Protocol)
```

## The two agents — why both

The system is two agents, not one. The split is non-negotiable.

**Collector (`agent-a`)** is the warehouse. It accepts envelopes from
sources over Pilot, dedupes by sample UUID, writes to DuckDB, and serves
read-only SQL. No LLM in the ingest path. **You also talk to it** —
when you do, the LLM combines DuckDB + its own gbrain + the
peer-reviewed RAG into an opinionated answer.

**Coach (`agent-b`)** is the front. It subscribes to ChangeEvents from
the Collector, runs rule models over the warehouse, and reaches you via
Telegram with proactive nudges and on-demand replies. Its gbrain holds
interpretations and prior observations; the Collector's gbrain holds
raw provenance.

Why the split:

| Concern | If they shared an identity |
|---|---|
| Ingest SLO (30s ack budget) | LLM turns would block envelope ingest. Sources would time out. |
| Trust scoping | Sources need write access. The coach is read-only by design. One identity = both, breaking the model. |
| Restart isolation | Coach restart shouldn't drop iPhone deliveries. |
| Memory ownership | Provenance and interpretation are two different jobs. One brain, one voice each. |

Both agents run as OpenClaw agents under one OpenClaw gateway on a GCP
VM. Each has its own Pilot identity in its own Docker container so the
daemons don't share `/tmp/pilot.sock`.

## The wire

Pilot Protocol is the transport. Three application-layer ports:

| Port | Direction | Message |
|---|---|---|
| **1001** | Source → Collector | `Envelope` (HealthKit samples + workouts + route chunks) |
| **1003** | Coach → Collector | `Query` (read-only SQL) |
| **1004** | Collector → Coach | `ChangeEvent` (broadcast after each batch commit) |
| ack_port | Collector → Source | `Ack` (per-sample accepted/duplicate/rejected) |

iOS sends BINARY-typed messages with `base64(deflate(JSON))` payloads.
The Collector's `inbox_watcher.unwrap_pilot_transport` handles raw
deflate (wbits=-15), zlib, gzip, and uncompressed JSON in that order.

## The three knowledge layers (per agent)

Both Collector and Coach reason over three independent stores:

1. **DuckDB warehouse** — raw rows. Tables: `samples`, `workouts`,
   `route_points`, `batches`. The Collector is the only writer; queries
   go through Pilot port 1003 with a read-only SQL gate.

2. **Per-agent gbrain (PGLite + MCP server)** — semantic memory.
   `gbrain-collector` and `gbrain-coach` are registered as separate MCP
   servers in `~/.openclaw/openclaw.json`, each pinned to its agent's
   `HOME` via `env`. 70 MCP tools exposed per agent: `search`, `query`,
   `get_page`, `put_page`, `list_pages`, etc. Calendar data flows into
   both via the Coach's calendar-sync; insights flow back via the agent
   writing `gbrain-{collector,coach}__put_page` at the end of a turn.

3. **Health-intelligence RAG (ZeroEntropy)** — peer-reviewed evidence.
   17 systematic reviews / meta-analyses, 89 interventions, all indexed
   in a ZeroEntropy collection called `health-intelligence`. Queries
   use `zerank-2` for reranking. Exposed as a local FastAPI server at
   `127.0.0.1:8741`; the agents call it via `curl` per turn when the
   topic touches recovery / training / sleep / metrics.

```
LLM turn
   ├─ DuckDB SQL (factual rows)
   ├─ gbrain MCP (interpretations + calendar)
   └─ ZeroEntropy RAG (peer-reviewed evidence)
        ↓
     answer with citations
```

## Where each thing runs

```
GCP VM: hackathon-openclaw  (us-central1-a, 35.224.83.34, e2-standard-4)
├── systemd: openclaw-gateway.service
│      Telegram polling (@yccoachbot → coach)
│      HTTP API (`openclaw agent --local --message ...` → collector|coach)
│      EnvironmentFile=/home/alexgodo/.env (ANTHROPIC_API_KEY, etc.)
│
├── systemd: health-intelligence.service
│      FastAPI on :8741 backed by ZeroEntropy SDK + zerank-2 reranker
│      Source: ~/g-stack-hackathon/health-intelligence/
│
├── Docker compose stack (infra/docker/docker-compose.yml)
│   ├── g-stack-agent-a (Pilot node 193232)
│   │     /opt/pilot/bin/pilot-daemon v1.10.1-rc-gstack-hackathon
│   │     python -m collector.server
│   │     /var/collector_data/facts.duckdb
│   │     /root/.pilot/inbox/ ← iOS envelopes land here
│   └── g-stack-agent-b (Pilot node 193233)
│         /opt/pilot/bin/pilot-daemon v1.10.1-rc-gstack-hackathon
│         python -m coach watch
│
├── OpenClaw agents (~/.openclaw/openclaw.json)
│   ├── collector   workspace=~/g-stack-hackathon/.openclaw/collector-workspace
│   │               model=anthropic/claude-opus-4-7
│   │               skills=[health-intelligence, response-style]
│   └── coach       workspace=~/g-stack-hackathon/.openclaw/coach-workspace
│                   model=anthropic/claude-opus-4-7
│                   routing=[telegram]
│                   skills=[health-intelligence, response-style]
│
├── Per-agent gbrains (PGLite)
│   ├── ~/g-stack-hackathon/infra/data/gbrain-collector-home/.gbrain/
│   └── ~/g-stack-hackathon/infra/data/gbrain-coach-home/.gbrain/
│
└── MCP servers (registered globally, scoped per-agent via env+identity)
    ├── gbrain-collector
    └── gbrain-coach
```

## Why ZeroEntropy for the RAG

The previous implementation used local sentence-transformers + a numpy
cache. Two reasons we switched:

1. **Reranking quality.** `zerank-2` measurably surfaces better hits than
   raw cosine similarity, especially when intervention text shares
   vocabulary across papers.
2. **Operational profile.** No local model weights, no CPU spike at
   server boot, no cache-invalidation logic. The trade is a managed
   service call per query; latency is ~50–500ms which is within budget.

The `EmbeddingStore` class preserves its public interface (`.query()`
returns `(score, record)` pairs sorted descending). Only the internals
changed. `retrieve.py`, `format.py`, `server.py` are unchanged in shape.

## Response shape contract

A response from either agent must:

- Lead with the answer in the first sentence
- Stay ≤ 200 words unless the user asked for a deep dive
- **Never use pipe markdown tables** — Telegram doesn't render them
- Use code-fenced ASCII tables when alignment matters
- Cite tools inline as they're called (no trailing `## Tools used` block)
- Append an "Evidence-based recommendations" section iff the
  health-intelligence RAG returned hits ≥ threshold

The `skills/response-style/SKILL.md` file in each workspace enforces
this. Updating that file changes the agent's voice across all channels.

## Lifecycle decisions

- **Trust** between Pilot nodes persists via `~/.pilot/trust.json` on
  each container volume. Survives `docker compose restart`. Re-handshake
  is only needed after a `--force-recreate` that drops the volume.
- **DuckDB** is single-writer. The Collector's daemon owns the lock; all
  reads must go through Pilot port 1003.
- **OpenClaw agent state** lives under `.openclaw/<agent>-workspace/`.
  Per-agent `agentDir` (under `.openclaw/<agent>-agent/`) is *runtime*
  state and is gitignored.
- **Per-agent gbrains** are PGLite DBs under
  `infra/data/gbrain-*-home/.gbrain/`. Gitignored. The Coach is the only
  writer to its brain; the Collector is the only writer to its brain.
  Calendar data is seeded into both via the calendar-sync.

## Failure modes already handled

- **iOS BINARY raw-deflate**: `inbox_watcher` tries multiple wbits modes;
  passes through.
- **Pilot NAT relay slowness**: containers advertise the VM public
  endpoint via `-endpoint`, so b↔a tunnels are direct.
- **OpenClaw missing API key**: gateway service has
  `EnvironmentFile=~/.env` in its systemd unit; restart picks up new
  keys without rebuild.
- **ZE overwrite disabled**: emulated with delete+add in the upload
  loop; idempotent on rebuild.
- **ZE list metadata rejected**: metric_ids/names stored as
  comma-separated strings.

## What's not built yet

- The seven rule-loop models (sleep regularity, autonomic balance, etc.)
  port from `health-sync/HealthSync/Models.swift` — still TS sketches.
- gstack tool wrappers (`/investigate`, `/office-hours`) in the Coach.
- Calendar / bank / music sources beyond iOS HealthSync.
- A non-trivial HealthKit historical backfill on the iOS side.

These are all additions; nothing here needs to change to support them.

## See also

- `README.md` — quickstart
- `ROLES.md` — exact contracts for Collector vs Coach
- `IMPLEMENTATION.md` — code-level file map and what to look at
- `LIFECYCLE.md` — state machines (iOS, OpenClaw, Pilot)
- `agent-a/SCHEMA.md` — wire format
- `agent-a/CHUNKING.md` — iOS outbox + retry strategy
- `infra/REDEPLOY_GCP.md` — deployment playbook
- `health-intelligence/SKILL.md` — RAG contract
