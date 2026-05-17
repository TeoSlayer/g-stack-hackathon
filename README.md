# g-stack-hackathon

Offsite data feeds via Pilot Protocol for distributed OpenClaw data ingestion.

A personal-data substrate where the things that know about you (a phone, a
calendar, a music app, a bank statement) push into agents you own. No SaaS in
the middle, no vendor sees the raw data, conversations happen on channels you
already use.

## The shape

```
                Sources                 Ingest / Storage              Interaction
                ───────                  ────────────────              ───────────
   iPhone (HealthKit + location)
   Calendar (future)                   ┌──────────────────┐         ┌──────────────┐
   Music (future)              ───►    │  Collector       │   ───►  │  Coach       │
   Bank (future)              Pilot    │  (OpenClaw skill)│ Pilot   │  (OpenClaw + │
   …                          E2E      │  DuckDB warehouse│         │   Telegram)  │
                              tunnel   │  Idempotent      │         │  + gbrain    │
                                       │  Per-source      │         │  + gstack    │
                                       │   dedupe         │         │  + specialists│
                                       └──────────────────┘         └──────┬───────┘
                                                                            │
                                                                            ▼
                                                                            You
```

Three principles:

- **The data never leaves hardware you control.** Sources run on your devices.
  Ingest runs on your homelab. Memory (DuckDB + gbrain) is local files.
  Telegram is the one external surface — and the only thing it carries is the
  conversation, not the raw data.
- **Pilot is the spine.** Each source has its own identity on the Pilot
  overlay; messages are encrypted, NAT-traversed, idempotent. No port
  forwarding, no VPN, no shared HTTP endpoint that has to be reachable.
- **OpenClaw is the substrate, not the product.** Channel adapters,
  tool-calling LLM glue, process isolation, and skill plumbing are all
  carried by OpenClaw. We write small skills, not infrastructure.

## Why this matters

Every consumer data product asks you to hand over your data so they can sell
you back an interpretation of it. The interpretation is locked in their
dashboard, the data is locked on their servers, and the inference is trained
on a population that isn't you.

This is the opposite arrangement: **your data feeds your agents, your agents
talk to you in plain language, the only company in the loop is the one that
ships the channel you happen to chat through**. The agent can ask its own
data warehouse anything; you can ask the agent anything. Cross-source
inference (health × location × calendar) becomes a query, not a feature
request.

It's the personal-AI premise actually built, instead of marketed.

## Sub-projects

| Path | What it is | Status |
|---|---|---|
| [`pilot-swift/`](pilot-swift/) | Swift package that embeds the Pilot daemon inside iOS / macOS apps so they become first-class Pilot nodes. Static `libPilot.a` + idiomatic Swift wrapper. | Working — alice/bob smoke passes on iOS sim |
| [`health-sync/`](health-sync/) | iOS + watchOS + widget app that reads Apple Watch + iPhone HealthKit data, runs 7 on-device models, charts trends and forecasts, plots a hex-binned location heatmap. Pushes envelopes to Agent A via embedded Pilot once that lands. | iOS app working end-to-end standalone; Pilot integration is next |
| [`agent-a/`](agent-a/) | Collector. OpenClaw skill: Pilot listener, dedupe, DuckDB warehouse, change events. No reasoning, no LLM. | Spec only — not built yet |
| [`agent-b/`](agent-b/) | Coach. OpenClaw skill: Telegram channel, LLM agent with tools (query A, gbrain memory, gstack skills, Pilot specialists). Plus a pro-active rule loop. | Spec only — not built yet |
| [`infra/`](infra/) | Operator's surface. OpenClaw config, Pilot identity / trust, DuckDB + gbrain locations, Telegram bot setup, launchd / systemd units, backup + health-check scripts. | Spec only — fills in as Agent A and B land |

Future sources sit at the same level: `calendar-sync/`, `bank-sync/`,
`music-sync/`, etc. They share Pilot for transport and DuckDB / gbrain for
storage; otherwise they're independent.

## Cross-cutting docs

| Doc | Covers |
|---|---|
| [`LIFECYCLE.md`](LIFECYCLE.md) | State machines (sync pipeline, Pilot, agents) + boot/wake/suspend/terminate sequences for all three lifecycles (iOS, OpenClaw, Pilot) + cross-process state contract + failure-resolution table |
| [`agent-a/SCHEMA.md`](agent-a/SCHEMA.md) | Wire format: envelope, sample variants, workout routes, ack, query, change-event |
| [`agent-a/CHUNKING.md`](agent-a/CHUNKING.md) | Splitter algorithm, outbox SQLite schema, retry/backoff, eviction, route_chunks |

## The two agents

Both run as OpenClaw skills on the homelab. They share a DuckDB file for raw
facts and a gbrain (PGLite) instance for semantic memory.

| Agent | Role | Side it sees |
|---|---|---|
| **Collector** | Listens on Pilot for envelopes from any source. Dedupes by sample UUID. Writes to DuckDB. Publishes a "new facts" event to Coach. No reasoning, no LLM. | Sources only |
| **Coach** | Telegram channel. Conversational LLM agent with tools: `query-collector` (DuckDB SQL), `gbrain.search` / `gbrain.write` (semantic memory), `gstack.run` (skills like `/investigate`, `/office-hours`), `pilot.specialist` (~436 public agents on the overlay). | You only |

The hard line: Collector is the warehouse, Coach is the front. Either
restarts without losing the other's work.

## Status

| Piece | State |
|---|---|
| Pilot Swift SDK | ✓ working |
| iOS app (collection layer + on-device analysis) | ✓ working standalone |
| **Embedded Pilot in iOS + outbox** | ✓ live, iOS pushing BINARY envelopes to the VM |
| **Collector agent** (Pilot 1001 + DuckDB + read-only SQL on 1003) | ✓ running |
| **Coach agent** (Telegram bot, change-event subscriber, gbrain memory) | ✓ running on `@yccoachbot` |
| **Per-agent gbrains** (separate PGLite, MCP-exposed) | ✓ both populated with calendar |
| **health-intelligence RAG** (17 papers, 89 interventions, ZeroEntropy + zerank-2) | ✓ wired into both agents |
| gstack tool invocations in Coach | next |
| Seven rule-loop models (port from `Models.swift`) | next |
| Additional sources beyond health | future |

## Getting started

The whole production stack runs on a GCP VM (`hackathon-openclaw`). Locally
you only need `gcloud` to reach it. To set up the `claw` shell helpers in
your zsh (so you can talk to either agent from your laptop):

```zsh
# One-time in ~/.zshrc — see infra/CLAW_HELPER.sh for the canonical block.
unalias claw  2>/dev/null
unalias clawj 2>/dev/null
claw() {
  local agent="$1"; shift
  local msg="$*"
  gcloud compute ssh hackathon-openclaw --zone us-central1-a \
    --command="set -a; source ~/.env; set +a; openclaw agent --agent $agent --local --message $(printf '%q' "$msg")"
}
```

Then:

```zsh
claw collector "How many samples in the warehouse by type? One SQL."
claw coach     "Was 5/14 a tough recovery day? Cite calendar + bio."
```

Or message **`@yccoachbot`** on Telegram for the Coach.

For local builds (iOS + Swift SDK):

```sh
cd health-sync && xcodegen generate && open HealthSync.xcworkspace
cd pilot-swift && scripts/run-smoke-sim.sh info
```

Each sub-project's `README.md` has the deep build/run details. For the
big-picture narrative of what runs where, read **[SPEC.md](SPEC.md)**.
For role contracts read **[ROLES.md](ROLES.md)**. For the deployment
playbook read **[infra/REDEPLOY_GCP.md](infra/REDEPLOY_GCP.md)**.

## License

AGPL-3.0-or-later, matching upstream Pilot Protocol.
