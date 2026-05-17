# g-stack

> Personal health intelligence. Your data, your agents, your network.

Getting data out of Apple Health means Shortcuts automations, third-party sync apps, and a fragile stack that breaks every iOS update. We eliminated all of it.

We compiled a **Go network daemon into the iOS app** and stream HealthKit samples directly to an AI agent over an encrypted, NAT-traversed tunnel — no HTTP server, no cloud middleware, no data custodian between your wrist and your agent.

Ask a question on Telegram, get an answer backed by your actual biometric history and 17 peer-reviewed papers. Proactive nudges fire when your HRV drops or your burnout score crosses a threshold — before you notice it yourself.

**→ [teoslayer.github.io/g-stack-hackathon](https://teoslayer.github.io/g-stack-hackathon/)**

---

## The insight

The iPhone is already a computer. We made it a **network node**.

`pilot-swift` is a precompiled Pilot Protocol daemon distributed as a static `.xcframework`, embedded inside the iOS app sandbox. There is no separate server, no cloud relay, no port forwarding. The iPhone calls one command:

```sh
pilotctl send-message <collector-node-id> --data '<json>'
```

The sample lands on the agent. E2E encrypted. NAT-traversed. Works from any network.

---

## What was built

### Seven deliverables

| | Component | What it does | Status |
|---|---|---|---|
| 📱 | `pilot-swift` | Precompiled Pilot daemon as iOS xcframework + Swift wrapper | ✅ Working |
| ⌚ | `health-sync` | iOS + watchOS + Widget. 27 on-device models. `PilotSyncTransport` sending envelopes. | ✅ Working |
| 🏥 | `agent-a` — Collector | HealthKit ingest, UUID dedup, DuckDB warehouse, SQL gate, ChangeEvents. 84 tests. | ✅ Deployed |
| 💬 | `agent-b` — Coach | 7 rule models, Google Calendar, Telegram via OpenClaw, RAG evidence. | ✅ Deployed |
| 📚 | `health-intelligence` | FastAPI RAG: 17 peer-reviewed papers, 89 interventions. Alert-match + semantic retrieval. | ✅ Running |
| 🛠 | `gstack-ios` | 13 Claude Code skills for iOS: build, test, signing, perf, TestFlight. | ✅ Active |
| ⚙️ | `infra` | Docker Compose on GCP. Two containers, volumes, secrets, OpenClaw workspaces. | ✅ Deployed |

### Two agents, two memories

Both are **OpenClaw LLM agents** — not dumb Python daemons. Full reasoning context, skills, and G-Brain memory. Each owns its data and can't corrupt the other's record.

**Collector (`agent-a`)** — *owns facts*
- `facts.duckdb` in Docker volume — every sample ever ingested
- `gbrain-collector-home` — factual observations, calendar context
- Deduplicates by UUID; acks back to iPhone before cursor advances

**Coach (`agent-b`)** — *owns interpretations*
- `gbrain-coach-home` — what it noticed, what it told you, follow-up hypotheses
- Calendar context from Google OAuth already in memory
- Answers on Telegram in ≤200 words with inline citations

### 27 on-device models

Every model runs on the iPhone. No server dependency for analysis.

| Tier | Models |
|---|---|
| Base | Sleep Regularity · Autonomic Balance · Sedentary Stress · Cognitive Recovery Debt · Burnout CUSUM · Circadian Drift · Kalman HRV |
| Tier 1 | RR Deviation · Vagal Rebound · RHR Trajectory · Morning HR Surge · ACWR · HRV Stability (CV) |
| Tier 2 | Sleep Architecture Efficiency · WASO · SOL Spike · Social Jetlag |
| Tier 3 | SpO₂ Desaturation · Acoustic Load · Light Deficit · Movement Rate · Body Mass Volatility · VO₂max Trend · Burnout Velocity |
| Tier 4 | Training Monotony · Nocturnal HR Dip · NEAT Proxy |

### 7 Coach rule models

Run against `facts.duckdb` after every ChangeEvent. If a rule fires and cooldown has elapsed — insight written to G-Brain, Telegram nudge sent.

1. **Sleep regularity** — bedtime variance over last 14 nights
2. **Autonomic balance** — HRV / RHR ratio z-score
3. **Sedentary stress** — steps deficit vs trailing baseline
4. **Cognitive recovery debt** — sleep debt × HRV depression
5. **Burnout CUSUM** — Page-Shewhart control chart on RHR
6. **Circadian drift** — bedtime Mann-Kendall trend
7. **Kalman HRV** — denoised HRV state estimator

---

## Architecture

```
iPhone (HealthKit + Apple Watch)
  └── pilot-swift — embedded Go daemon
        │
        │  send-message → Collector  (E2E encrypted · NAT-traversed)
        ▼
┌─────────────────────────────────────────────────────────┐
│  GCP · Docker Compose · hackathon-openclaw              │
│                                                         │
│  ┌──────────────────────┐   ┌───────────────────────┐  │
│  │  Collector (agent-a) │   │  Coach (agent-b)      │  │
│  │  OpenClaw agent      │◄──►  OpenClaw agent       │  │
│  │  facts.duckdb        │   │  gbrain-coach-home    │  │
│  │  gbrain-collector    │   │  calendar_sync.py     │  │
│  └──────────────────────┘   └──────────┬────────────┘  │
│                                        │               │
│                                  Telegram (you)        │
└─────────────────────────────────────────────────────────┘
        │  127.0.0.1:8741
        ▼
  health-intelligence  ←  FastAPI · 17 papers · 89 interventions
```

### How messages are classified

Everything goes through one primitive. The receiver classifies by JSON content shape — no virtual port routing, no message broker.

| Content | Classified as | Action |
|---|---|---|
| `samples` array | HealthKit envelope | Dedupe → DuckDB → Ack |
| `sql` field | SQL query | Execute read-only → QueryResult |
| `kind: "samples_added"` | ChangeEvent | Coach runs rule models |
| `agent` / `command` | Pilot reply | G-Brain ingester |

---

## The bigger idea

Each agent is a fully independent unit — its own identity, its own G-Brain, its own container. To add a new one: get its Pilot node ID, share it with the others. Done. No schema migration, no coordinator.

**G-Brains can communicate without a lot of shared priors.** They converge on meaning through message exchange. The more agents, the more data they pool, the sharper they reason. Distributed data, distributed compute, federated via Pilot Protocol.

---

## Running

```sh
# Production — on GCP:
cd ~/g-stack-hackathon/infra/docker && docker compose up -d
docker logs g-stack-agent-b --follow

# Query the warehouse:
docker exec g-stack-agent-b python -m coach query \
  "SELECT type, COUNT(*) FROM samples GROUP BY type ORDER BY 2 DESC"

# Local — Collector tests:
pytest agent-a/tests/      # 84 unit tests
./scripts/run_e2e.sh       # 8 E2E scenarios

# Local — iOS app:
cd health-sync && xcodegen generate && open HealthSync.xcworkspace
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
