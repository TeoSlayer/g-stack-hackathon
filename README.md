# g-stack-hackathon

Personal-data substrate: two ingestion agents backed by G-Brain memory, a
health-intelligence retrieval layer, and Pilot Protocol as the communication
shim connecting everything — phone, agents, and retrieval — with no extra
infrastructure.

## Architecture

```
                                 ┌─────────────────────────────────────────────────────┐
                                 │                  Pilot overlay network               │
                                 │                                                      │
  iPhone (HealthKit + Watch)     │  ┌────────────────────┐    ┌────────────────────┐   │
    PilotSyncTransport  ─────────┼─►│  agent-a           │    │  agent-b           │   │
    (embedded pilot-swift)       │  │  Health Ingest     │◄──►│  GSuite Ingest     │   │
                                 │  │  DuckDB warehouse  │    │  Calendar / Drive  │   │
  Google / GSuite  ──────────────┼─►│  G-Brain memory    │    │  G-Brain memory    │   │
    (OAuth pull)                 │  └────────┬───────────┘    └────────┬───────────┘   │
                                 │           │                         │               │
                                 │           └────────────┬────────────┘               │
                                 │                        │ Pilot                      │
                                 └────────────────────────┼────────────────────────────┘
                                                          │
                                              ┌───────────▼───────────┐
                                              │  health-intelligence  │
                                              │  FastAPI RAG server   │
                                              │  17 peer-reviewed     │
                                              │  papers · 89 interv.  │
                                              │  ZeroEntropy reranker │
                                              └───────────────────────┘
```

Five principles:

1. **Two agents, one memory model.** Agent A warehouses health data from the
   iPhone via Pilot; agent B warehouses Google/GSuite data via OAuth. Both
   share G-Brain for long-term semantic memory. Neither runs an LLM — they
   are durable ingest workers, not reasoning engines.

2. **Pilot is the data shim.** The iOS app embeds the Pilot daemon
   (`pilot-swift`) and pushes HealthKit envelopes directly to Agent A over
   an encrypted, NAT-traversed tunnel. No port forwarding, no VPN, no shared
   HTTP endpoint. The same overlay carries agent-to-agent messages.

3. **Health intelligence is a retrieval layer, not a chatbot.** A FastAPI
   server backed by 17 systematic reviews and meta-analyses returns ranked,
   citable intervention recommendations given alert values or a free-text
   query. ZeroEntropy reranks results before they surface to any LLM.

4. **gstack-ios is how the iOS app gets built.** Claude Code with the
   `gstack-ios` skill pack drives `xcodebuild`, simulators, signing, perf
   traces, and TestFlight uploads — the iOS development loop runs entirely in
   the agent.

5. **Data never leaves hardware you control.** iPhone collects, Pilot
   transports, agents warehouse. G-Brain and DuckDB are local files. The only
   external surface is the OAuth pull from Google and the ZeroEntropy rerank
   call.

## Sub-projects

| Path | What it is | Status |
|---|---|---|
| [`pilot-swift/`](pilot-swift/) | Swift package embedding the Pilot daemon inside iOS/macOS apps. Static `Pilot.xcframework` + idiomatic Swift wrapper. alice/bob encrypted handshake smoke test passes on iOS sim. | **Working** |
| [`health-sync/`](health-sync/) | iOS + watchOS + widget app. Reads HealthKit, runs 27 on-device models, charts trends and forecasts, hex-binned location heatmap. Pushes envelopes to Agent A via `PilotSyncTransport`. | **iOS app working standalone. Pilot transport wired, pending activation.** |
| [`agent-a/`](agent-a/) | Health ingest. Pilot listener (port 1001), DuckDB warehouse, SQL query gate (port 1003), change-event broadcaster (port 1004). G-Brain rollup. 84 tests passing. | **Core built, PilotctlTransport stub → real pending.** |
| [`agent-b/`](agent-b/) | GSuite ingest. Pulls calendar, Drive, Gmail via OAuth. Warehouses to DuckDB. G-Brain rollup. Speaks to Agent A via Pilot for cross-source reasoning. | **Spec + framework. OAuth pull and warehouse not yet built.** |
| [`health-intelligence/`](health-intelligence/) | FastAPI RAG server. 17 peer-reviewed papers, 89 interventions. Alert-match + semantic retrieval + ZeroEntropy reranking. LLM-ready prompt output. | **Server running. ZeroEntropy reranking integration pending.** |
| [`gstack-ios/`](gstack-ios/) | iOS/watchOS/WidgetKit skill pack for Claude Code. 13 skills covering build, test, signing, perf, TestFlight. Used to develop health-sync itself. | **Working — all 13 skills active.** |
| [`infra/`](infra/) | Operator runbook. OpenClaw config, Pilot identity/trust, DuckDB/G-Brain locations, launchd/systemd units, backup scripts. | **Spec complete, materialises on first agent launch.** |

## Data flow

```
1.  iPhone HealthSyncManager polls HealthKit (anchored queries)
2.  Samples encoded → Pilot envelope (JSON)
3.  PilotSyncTransport sends to Agent A on port 1001 (E2E encrypted)
4.  Agent A dedupes by UUID, writes to DuckDB, acks back
5.  iOS advances HK anchor only after ack received
6.  Agent A emits ChangeEvent on port 1004
7.  Agent B subscribes; cross-source inference available via SQL queries
8.  health-intelligence retrieval layer queries DuckDB for alert values,
    looks up interventions, ZeroEntropy reranks, returns to LLM
```

## Pilot ports (Agent A)

| Port | Direction | Message |
|---|---|---|
| 1001 | → A | HealthKit envelope from iOS |
| 1002 | ← A | Ack (accepted / duplicate / rejected UUIDs) |
| 1003 | ↔ A | SQL query + result (Coach or health-intelligence) |
| 1004 | ← A | ChangeEvent broadcast to subscribers |

## Running today

```sh
# iOS app, standalone (no homelab required):
cd health-sync
xcodegen generate
open HealthSync.xcworkspace

# Pilot Swift SDK smoke test:
cd pilot-swift
scripts/run-smoke-sim.sh info

# Agent A (health ingest) with mock envelopes:
./scripts/run_e2e.sh          # 84 tests pass, 8 E2E scenarios
python -m collector.server    # real-time daemon

# Agent B CLI (queries Agent A):
python -m coach query "SELECT type, COUNT(*) FROM samples GROUP BY type"
python -m coach readiness

# health-intelligence retrieval server:
cd health-intelligence
.venv/bin/python server.py    # http://127.0.0.1:8741
curl http://127.0.0.1:8741/health
```

## Cross-cutting docs

| Doc | Covers |
|---|---|
| [`LIFECYCLE.md`](LIFECYCLE.md) | State machines for iOS sync pipeline, Pilot, and agents; boot/suspend/terminate sequences; failure-resolution table |
| [`agent-a/SCHEMA.md`](agent-a/SCHEMA.md) | Wire format: envelope, sample variants, workout routes, ack, query, change-event |
| [`agent-a/CHUNKING.md`](agent-a/CHUNKING.md) | Outbox SQLite schema, splitter algorithm, retry/backoff, route_chunks |
| [`health-intelligence/SKILL.md`](health-intelligence/SKILL.md) | Tool manifest, request/response schema, metric ID reference, error codes |
| [`health-sync/misc/METRICS.md`](health-sync/misc/METRICS.md) | All 27 on-device metrics: formula, data sources, alert thresholds |

## What's next

| Work item | Blocks |
|---|---|
| Wire `PilotSyncTransport` in iOS app | Full phone → agent E2E |
| Real `pilotctl` transport in Agent A | Production ingest from device |
| Agent B GSuite OAuth pull + warehouse | Cross-source inference |
| ZeroEntropy reranker integration in health-intelligence | Better retrieval quality |
| G-Brain rollup from both agents | Long-term semantic memory |
| infra launchd/systemd units | Homelab deployment |

## License

AGPL-3.0-or-later, matching upstream Pilot Protocol.
