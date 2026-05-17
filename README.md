# g-stack

> Personal health intelligence. Your data, your agents, your network.

**→ [teoslayer.github.io/g-stack-hackathon](https://teoslayer.github.io/g-stack-hackathon/)**

---

Getting data out of Apple Health means Shortcuts automations, third-party sync apps, and a fragile stack that breaks every iOS update. We eliminated all of it.

We compiled a **Pilot Protocol daemon into the iOS app** and stream HealthKit samples directly to an AI agent. No message queues. No transport infrastructure. No data custodian between your wrist and your agent.

The result: two **OpenClaw** agents, each with its own **G-Brain** memory, reasoning over your health data in real time. Every LLM turn draws from three knowledge sources at once — your raw biometric rows, your agent's accumulated memory, and 17 peer-reviewed papers with **zerank-2** neural reranking. Ask a question on Telegram — get a cited, personalised answer in under 500 ms.

---

## The stack

### OpenClaw — agent runtime

Both agents are **OpenClaw LLM agents**, not dumb Python daemons. Each has a full workspace: SOUL.md, IDENTITY.md, skill manifests, tool definitions, and its own G-Brain. OpenClaw handles the reasoning loop, tool dispatch, and the Telegram channel binding that makes the Coach answerable on demand.

```
.openclaw/
├── collector-workspace/   # Agent A identity, skills, tools
└── coach-workspace/       # Agent B identity, skills, tools
```

### G-Brain — per-agent memory

Each agent has its own **G-Brain** — a local PGLite semantic memory that accumulates context over time. They are deliberately separate:

- `gbrain-collector-home` — factual observations: what HealthKit reported, when, raw counts. Never interpreted.
- `gbrain-coach-home` — interpretations, prior nudges, follow-up hypotheses, calendar context. Never raw data.

Each G-Brain exposes **70 MCP tools** to its agent — `search`, `query`, `get_page`, `put_page`, `list_pages`, and more. G-Brains communicate without a lot of shared priors. They converge on meaning through message exchange. Add a new agent, share its Pilot node ID — it joins the network and starts building its own memory from scratch.

### Pilot Protocol — zero-infrastructure transport

Every message between every node in this system is one primitive:

```sh
pilotctl send-message <target-node-id> --data '<json>'
```

No message queues. No brokers. No shared sockets. No port forwarding. The Pilot daemon delivers JSON to the target's inbox as a file. E2E encrypted with Ed25519 identity per node. NAT-traversed — works from any network.

**Any endpoint that can run a Pilot daemon can feed data into an AI agent.** We compiled one into an iOS app. The same approach works for a Raspberry Pi, a Docker container, a browser extension, a wearable. The agent network expands by adding node IDs, not infrastructure.

### gstack-ios — iOS development with Claude Code

We extended **Claude Code** with 13 skills covering the full iOS development loop:

| Skill area | What it covers |
|---|---|
| Build & run | `xcodebuild`, simulator boot, scheme selection |
| Test | `XCTest`, `xcresult` parsing, test filtering |
| Signing | Provisioning profiles, entitlements, code signing |
| Performance | Instruments traces, memory, CPU flamegraphs |
| Distribution | TestFlight uploads, archive, export |

`health-sync` was developed using these skills. The iOS loop — build, test, install, inspect — runs entirely inside the agent.

---

## What was built

| | Component | What it does | Status |
|---|---|---|---|
| 📱 | `pilot-swift` | Precompiled Pilot daemon as iOS xcframework + Swift wrapper. Smoke test passes on Simulator. | ✅ Working |
| ⌚ | `health-sync` | iOS + watchOS + Widget. 27 on-device models. `PilotSyncTransport` streaming envelopes to Collector. | ✅ Working |
| 🏥 | `agent-a` — Collector | OpenClaw agent. HealthKit ingest, UUID dedup, DuckDB warehouse, SQL gate, ChangeEvents. 84 tests. | ✅ Deployed |
| 💬 | `agent-b` — Coach | OpenClaw agent. ProactiveCoach loop, 3 rule models, Google Calendar OAuth, Telegram UI, RAG skill. | ✅ Deployed |
| 📚 | `health-intelligence` | FastAPI RAG sidecar. 17 peer-reviewed papers, 89 interventions. **zerank-2** neural reranking via ZeroEntropy. | ✅ Running |
| 🛠 | `gstack-ios` | 13 Claude Code skills for iOS: build, test, signing, perf traces, TestFlight. | ✅ Active |
| ⚙️ | `infra` | Docker Compose on GCP. Two OpenClaw containers, Pilot identities, G-Brain volumes, secrets. | ✅ Deployed |

---

## Architecture

```
iPhone (HealthKit + Apple Watch)
  └── pilot-swift — Pilot daemon compiled into app sandbox
        │
        │  pilotctl send-message → Collector
        │  E2E encrypted · NAT-traversed · no infra needed
        ▼
┌──────────────────────────────────────────────────────────────┐
│  GCP · Docker Compose · hackathon-openclaw                   │
│                                                              │
│  ┌────────────────────────────┐  ┌────────────────────────┐  │
│  │  g-stack-agent-a           │  │  g-stack-agent-b       │  │
│  │  OpenClaw · Collector      │  │  OpenClaw · Coach      │  │
│  │                            │  │                        │  │
│  │  facts.duckdb              │◄─►  gbrain-coach-home     │  │
│  │  gbrain-collector-home     │  │  calendar_sync.py      │  │
│  │  inbox_watcher.py          │  │  7 rule models         │  │
│  └────────────────────────────┘  └──────────┬─────────────┘  │
│                                             │ OpenClaw       │
│                                       ┌─────▼──────┐        │
│                                       │  Telegram  │        │
│                                       └────────────┘        │
└──────────────────────────────────────────────────────────────┘
        │  127.0.0.1:8741
        ▼
  health-intelligence — FastAPI · 17 papers · 89 interventions
  registered as OpenClaw skill in both agent workspaces
```

### Three-layer LLM reasoning

Every turn either agent takes draws from three independent knowledge stores simultaneously:

```
LLM turn
   ├─ DuckDB SQL      — factual rows: samples, workouts, route_points, batches
   ├─ gbrain MCP      — 70 tools: semantic memory, calendar context, prior nudges
   └─ ZeroEntropy RAG — 17 papers, 89 interventions, zerank-2 neural reranker
        ↓
     answer with inline citations, ≤ 200 words
```

No pre-fetching, no batch summarisation — every query is live against the warehouse. The RAG only fires when the topic touches recovery, training, sleep, or a biometric metric.

### Message classification — no port routing

The receiver classifies messages by JSON content shape. No virtual ports, no routing table, no middleware.

| Content | Classified as | Action |
|---|---|---|
| `samples` array | HealthKit envelope | Dedupe → DuckDB → Ack to iPhone |
| `sql` field | SQL query from Coach | Execute read-only → QueryResult |
| `kind: "samples_added"` | ChangeEvent | Coach runs 7 rule models |
| `agent` / `command` | Pilot overlay reply | G-Brain ingester |

---

## The 27 on-device models

Every model runs on the iPhone. No server dependency for analysis.

| Tier | Models |
|---|---|
| Base | Sleep Regularity · Autonomic Balance · Sedentary Stress · Cognitive Recovery Debt · Burnout CUSUM · Circadian Drift · Kalman HRV |
| Tier 1 | RR Deviation · Vagal Rebound · RHR Trajectory · Morning HR Surge · ACWR · HRV Stability (CV) |
| Tier 2 | Sleep Architecture Efficiency · WASO · SOL Spike · Social Jetlag |
| Tier 3 | SpO₂ Desaturation · Acoustic Load · Light Deficit · Movement Rate · Body Mass Volatility · VO₂max Trend · Burnout Velocity |
| Tier 4 | Training Monotony · Nocturnal HR Dip · NEAT Proxy |

## Coach rule engine

The `ProactiveCoach` triggers on every ChangeEvent from the Collector. The `RuleEngine` evaluates all rules, respects per-rule cooldowns (disk-backed JSON), and when a rule fires: writes an insight page to `gbrain-coach-home` and sends a Telegram nudge.

**Implemented (3 of 7)** — data-cheap rules that work with weeks of history:

1. **Sleep regularity** — circular stddev of sleep-onset time, 14-night window. Bands: good ≤ 45 min · warn ≤ 75 min · bad > 75 min.
2. **Autonomic balance** — HRV / RHR z-score vs 30-day trailing baseline.
3. **Sedentary stress** — today's step count vs trailing-7d median.

**Planned (4 of 7)** — require 3–8 weeks of baseline to be statistically meaningful:

4. **Cognitive recovery debt** — sleep debt × HRV depression composite
5. **Burnout CUSUM** — Page-Shewhart control chart on resting HR
6. **Circadian drift** — Mann-Kendall trend on bedtime series
7. **Kalman HRV** — state-space denoised HRV estimator

---

## Running

```sh
# Production — GCP:
cd ~/g-stack-hackathon/infra/docker && docker compose up -d
docker logs g-stack-agent-b --follow

# Query the warehouse:
docker exec g-stack-agent-b python -m coach query \
  "SELECT type, COUNT(*) FROM samples GROUP BY type ORDER BY 2 DESC"

# Trigger the proactive rule loop manually:
python -m coach proactive

# Local — Collector tests:
pytest agent-a/tests/      # 84 unit tests
./scripts/run_e2e.sh       # 8 E2E scenarios

# Local — iOS app:
cd health-sync && xcodegen generate && open HealthSync.xcworkspace

# VM bootstrap (one-shot, idempotent):
bash infra/scripts/bootstrap-vm.sh
```

---

## Sub-projects

| Path | Description |
|---|---|
| [`pilot-swift/`](pilot-swift/) | Swift Pilot SDK — xcframework + wrapper |
| [`health-sync/`](health-sync/) | iOS + watchOS + Widget app |
| [`agent-a/`](agent-a/) | Collector — ingest, warehouse, SQL gate |
| [`agent-b/`](agent-b/) | Coach — rule models, Telegram, calendar |
| [`health-intelligence/`](health-intelligence/) | RAG server — papers + interventions |
| [`gstack-ios/`](gstack-ios/) | 13 iOS dev skills for Claude Code |
| [`infra/`](infra/) | Docker Compose + GCP runbook |

## License

AGPL-3.0-or-later — matching upstream Pilot Protocol.
