# HealthSync

A personal-health agent loop you own end to end. Apple Watch and iPhone collect
the data, a GCP-hosted agent reasons over it, and you talk to it through Telegram. No
SaaS in the middle, no vendor knows your HRV.

## Why this exists

Wearables sell you a chart and a subscription. The chart is read-only, the
subscription rents you back access to your own body's data, and the inference
("recovered", "strained") is a black box trained on someone else's population.

The actual loop that changes behaviour is:

> Body signal → context-aware interpretation → conversational nudge → action

No commercial product closes that loop honestly, because the loop requires the
product to *talk to you* about *your specific patterns* with *full access to
all your data*. SaaS health apps can do at most two of those three.

This is the three-box version of the loop, all running on hardware you own:

```
                  Body & context                Interpretation                 You
                  ─────────────                  ──────────────              ─────
  ┌─────────────────────────────┐  envelopes ┌────────────────────┐ insights ┌──────────┐
  │  iOS HealthSync             │  ────────► │  Collector         │ ───────► │ Coach    │
  │   • HealthKit deltas        │            │   (OpenClaw skill) │          │ (OpenClaw│
  │   • Apple Watch HR/HRV/etc  │            │   • DuckDB warehouse│          │  + LLM)  │
  │   • Location, Photos geotag │            │   • Dedupe by UUID │          │          │
  │   • Embedded Pilot node     │  ◄──────── │   • Models / rules │ ◄──────  │ tools:   │
  │   • Outbox + retry          │  acks      │                    │ queries  │  query   │
  └─────────────────────────────┘            └────────────────────┘          │  gbrain  │
                                                                              │  gstack  │
                                                                              │  pilot   │
                                                                              │  speclsts│
                                                                              └────┬─────┘
                                                                                   │
                                                                              Telegram
                                                                                   │
                                                                                   ▼
                                                                                  You
```

Three pieces, each owns one thing:

| Box | Owns | Loud about |
|---|---|---|
| **iOS HealthSync** | reading HealthKit, attaching location, persisting an outbox | data collection |
| **Collector** | the durable record (DuckDB), idempotent ingest, fast queries | "what happened" |
| **Coach** | conversation, models, tool calling, pro-active nudges via Telegram | "what does it mean and what should you do" |

## What's built today

### iOS app (`HealthSync/`)

A working iOS + watchOS + widget bundle.

| Feature | Where |
|---|---|
| HealthKit paged anchored sync | `HealthSyncManager.swift` |
| Per-type observer queries with throttle | same |
| 7 on-device models (Sleep Regularity, Autonomic Balance, Sedentary Stress, Cognitive Recovery Debt, Burnout CUSUM, Circadian Drift, Kalman-smoothed HRV) | `Models.swift` |
| Holt's exponential smoothing + 7-day forecast | `TimeSeries.swift` |
| Readiness score (overnight HRV vs personal 7-day baseline) | `Readiness.swift` |
| Status / Calendar / Trends / Models / Settings tabs | `ContentView.swift`, `CalendarView.swift`, `TrendsView.swift`, `ModelsView.swift` |
| Hex-binned location heatmap (HRV/RHR/HR by photo-geotag join) | `LocationMapView.swift`, `HexGrid.swift` |
| iOS widget extension (lock-screen + home-screen, readiness + sparklines) | `HealthSyncWidget/` |
| Info sheets with diagrams (bell curve, Holt equations, band gradient) for every model | `InfoSheets.swift` |
| Animated splash with live boot checklist | `SplashView.swift` |
| Wear-watch detection, wake-window setting, watch app, WCSession bridge | `HealthSyncManager.swift`, `HealthSyncWatch/`, `Shared/` |

The iOS app is functional on its own — every model, every chart, every widget
reads HealthKit directly. The agent pipeline below is an *augmentation*, not a
dependency.

### Agent pipeline

| Component | Status |
|---|---|
| pilot-swift package | ✅ at `../pilot-swift`, smoke tests pass on Simulator |
| Embedded Pilot in iOS (`PilotBoot`) | ✅ running — sends envelopes via `PilotSyncTransport` |
| Outbox + retry in iOS (`OutboxStore`, `OutboxWorker`) | ✅ SQLite-backed, crash-safe |
| Collector OpenClaw agent (ingest + DuckDB) | ✅ deployed on GCP — 84 tests, 8 E2E scenarios |
| Coach OpenClaw agent (Telegram + 7 rule models) | ✅ deployed on GCP — calendar sync working |
| G-Brain wired in both agents (separate instances) | ✅ `gbrain-collector-home` + `gbrain-coach-home` |
| health-intelligence RAG skill (17 papers, 89 interventions) | ✅ running on GCP port 8741 |

## Why each substrate choice

| Substrate | Why this and not the obvious alternative |
|---|---|
| **Pilot** (E2E-encrypted overlay) | Works from any network without VPN, NAT, or port forwarding. Trust is per-peer identity, not per-network. iOS doesn't need a stable address. |
| **OpenClaw** (skill gateway) | Channel adapters (Telegram, Signal, Matrix, ...) are free. Tool-calling LLM glue is free. Process isolation between skills is free. We write skills, not infrastructure. |
| **DuckDB** (column store) | Health time series are exactly DuckDB's wheelhouse: append-mostly, analytical reads, no separate service. Single file on disk. |
| **gbrain** (semantic memory) | Long-term recall (*"what was my HRV like last winter?"*) needs vectors, not SQL. PGLite-backed, MCP-exposed, local. Future agents share it. |
| **gstack** (reasoning skills) | Multi-step chain-of-thought (`/investigate`, `/office-hours`) lifts the Coach above one-LLM-turn responses without owning the chain logic. |
| **Telegram** (channel) | Already on every device you carry, zero new UI to build, push notifications free. Honest caveat: Telegram-the-company sees the chat — swap for Signal/Matrix when that matters. |

## Data flow, end to end

```
1.  HKObserverQuery fires on iPhone (heart-rate sample lands)
2.  HealthSyncManager runs paged HKAnchoredObjectQuery from saved anchor
3.  encode(sample) → JSON envelope with sample UUID, type, value, unit,
    ts, location? (from CoreLocation OR retroactively via Photos geotag)
4.  envelope → LocalOutbox (SQLite, atomic write)
5.  OutboxWorker: pilotctl send-message <collector-node-id> --data '<envelope-json>'
6.  Collector inbox_watcher classifies by content shape, ingests, dedupes by UUID, INSERT into DuckDB
7.  Collector sends Ack back to iPhone via send-message
8.  iOS advances the HK anchor, drops envelope from outbox
9.  Collector sends ChangeEvent (kind: samples_added) to Coach via send-message
10. Coach's rule loop receives ChangeEvent; queries Collector DuckDB via send-message; fires model
11. Coach composes a Telegram message: facts from DuckDB,
    recall from gbrain, optionally invokes a gstack skill
12. Coach writes the summary back to gbrain for tomorrow's recall
13. You see the message on Telegram; reply if you want to talk about it
```

Every step persists before acking. iOS can suspend at step 5, homelab can
restart at step 6, Telegram can be offline at step 11 — none of those lose
data; they just delay it.

## What "live insights" actually means

Concrete examples the agent loop produces:

- **Morning:** *"HRV 12 % below your 7-day baseline. You had three < 6 h
  nights this week — the trend's been visible since Tuesday. Easy day."*
- **Pre-meeting:** *"You have a high-stakes call in 30 min and your last
  hour of HR has been elevated while sitting still. Try 4×4×4×4 breathing."*
- **Pattern:** *"On weeks you walk over 10 k steps/day, your next-week
  sleep duration averages 22 min higher. Worth keeping the streak."*
- **Geographic:** *"Your HRV in the bottom 20 % of the city is the office.
  Top 20 % is the gym at 7 am. Probably not a coincidence."*
- **Recall:** *"You asked the same question in March; here's what we found
  then, and how it's changed."*

None of those require an LLM hallucinating — they're SQL queries plus a
narration step.

## Privacy claim, honest

| Data | Lives where | Who can see it |
|---|---|---|
| Raw HK samples | iPhone, then facts.duckdb in Docker volume on GCP | you |
| Locations (sync-time + photo-joined) | facts.duckdb | you |
| Daily summaries / patterns | G-Brain (PGLite) on GCP — two separate instances | you |
| Your Telegram chat with Coach | Telegram servers | you + Telegram |
| Coach's LLM context per turn | Wherever your OpenClaw is configured to call (local llama.cpp → nobody; hosted API → that vendor) | depends on LLM choice |

If the LLM provider matters for your threat model, run llama.cpp locally on
the homelab and pin OpenClaw's model selection there. The architecture
doesn't change.

## Build (iOS app)

You need:

- Xcode 16+
- A paid Apple Developer account (for the HealthKit background-delivery
  entitlement and the iOS widget extension; Personal Team won't grant either)
- An iPhone paired with an Apple Watch
- `xcodegen` (`brew install xcodegen`)

```sh
cd ~/Development/g-stack-hackathon/health-sync
xcodegen generate
open HealthSync.xcworkspace
```

In Xcode:

1. Select your Team in each target's *Signing & Capabilities*.
2. The bundle id is `io.vulturelabs.healthsyncs`. Either keep it or rename in
   `project.yml` (it's already wired through entitlements, App Group, widget,
   watch app, and Info.plist references).
3. Enable the App Group `group.io.vulturelabs.healthsyncs` on the main app,
   widget, and watch app in the Developer Portal if Xcode doesn't auto-add it.
4. Build the `HealthSync` scheme onto the iPhone. First launch will ask for
   HealthKit, Location ("While Using App"), Photos, and Notification
   permissions in sequence.

The app works standalone from this point — no homelab needed yet.

## Project layout

```
health-sync/
├── HealthSync/                     iOS app target
│   ├── HealthSyncApp.swift         @main, BG tasks
│   ├── HealthSyncManager.swift     core: HK auth, observers, paged anchored sync
│   ├── DataTypes.swift             which HK types to sync + their units
│   ├── SyncEndpoint.swift          HTTP client → POST /ingest (will become Pilot)
│   ├── Readiness.swift             daily readiness score
│   ├── Models.swift                7 research-backed models
│   ├── TimeSeries.swift            HK aggregation + Holt forecaster
│   ├── LocationProvider.swift      one-shot CL fixes for sync tagging
│   ├── PhotosLocationProvider.swift photo geotag → retroactive HK location
│   ├── LocationSources.swift       union all location-bearing data sources
│   ├── HexGrid.swift               pointy-top hex math for the heatmap
│   ├── WorkoutRoutes.swift         HKWorkoutRoute extraction
│   ├── ContentView.swift           tab bar + Status tab
│   ├── CalendarView.swift          5-week readiness grid
│   ├── TrendsView.swift            30-day trends + 7-day forecasts per metric
│   ├── ModelsView.swift            model cards with info sheets
│   ├── LocationMapView.swift       hex heatmap with metric picker
│   ├── InfoSheets.swift            in-app explanations + animated diagrams
│   ├── SplashView.swift            animated boot screen
│   ├── DiagnosticsView.swift       reachable from Settings
│   ├── NetworkMonitor.swift        Wi-Fi / cellular / offline state
│   ├── NotificationManager.swift   UN notifications, wake-window rate limiting
│   ├── Diagnostics.swift           DNS/TCP/HTTP/HK probes
│   ├── Info.plist                  usage strings, BG modes, ATS, color scheme
│   └── HealthSync.entitlements     HealthKit + bg-delivery + App Group
├── HealthSyncWatch/                watchOS app target (independent)
├── HealthSyncWidget/               iOS widget extension (lock + home screen)
├── Shared/
│   ├── WCSessionBridge.swift       phone↔watch state mirror
│   └── WidgetSnapshot.swift        App-Group UserDefaults blob
├── project.yml                     xcodegen source of truth
└── README.md                       this file
```

## What this is not

- **Not a polished consumer product.** Setup requires a GCP VM, Docker Compose, and Pilot trust approval.
- **Not a medical device.** None of the inferences are clinically validated for
  your specific physiology; treat them as informed prompts to your own attention.
- **Not a real-time monitor.** Pilot envelopes are async; insights are minute
  or hour-scale, not millisecond. Don't use this for cardiac alerts.
- **Not a wearable replacement.** Your Apple Watch still does the sensing. This
  is the layer that does something useful with the data afterwards.

## Status

### Working today (iOS)

- HealthKit sync with paged anchored queries and recoverable outbox semantics
- 27 on-device models, trend forecasts, readiness score
- Calendar grid, location heatmap, widgets, info sheets, splash
- Photos-geotag join for retroactive location-tagged HRV/HR/RHR
- pilot-swift embedded — `PilotSyncTransport` sending envelopes to Collector
- Outbox + retry (SQLite-backed, crash-safe, HK anchor only advances after Ack)

### Working today (GCP agents)

- Collector receiving envelopes, deduplicating, warehousing to `facts.duckdb`
- Coach running 7 rule models on each ChangeEvent, answering on Telegram
- Google Calendar OAuth + incremental sync imported into Coach G-Brain
- health-intelligence RAG sidecar serving paper-backed interventions

### What's next

- Google Drive + Gmail pull in Coach
- G-Brain rollup from Collector after each batch commit
- ZeroEntropy reranker in health-intelligence

---

License: AGPL-3.0-or-later, matching upstream Pilot Protocol.
