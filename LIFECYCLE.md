# State and lifecycle

Every component has a known set of states, an ordered boot sequence, and an
ordered shutdown sequence. Everything that matters is written to disk before
the next step in the sequence runs, so any component can crash at any point
and resume from where it stopped.

## Four lifecycles to coordinate

| Lifecycle | Controlled by | Survives across |
|---|---|---|
| **iOS app process** | iOS scheduler + user | foreground / background / suspended / terminated |
| **Collector (agent-a)** | Docker Compose on GCP | container restarts, code redeploys |
| **Coach (agent-b)** | Docker Compose on GCP | container restarts, code redeploys |
| **Pilot daemons** (iOS embedded + GCP containers) | App / daemon process | network changes, NAT renegotiation |

These four are independent. Each side's recovery does not depend on the
others being healthy; Pilot `send-message` + acks bridge the iOS ↔ Collector link;
`send-message` bridges Collector ↔ Coach (ChangeEvents and SQL queries).

## State machine: per-type sync pipeline (iOS)

One instance of this state machine per HK sample type. They run in parallel
with the inFlight guard preventing same-type concurrency.

```
                      ┌───────────────────┐
                ┌────►│   IDLE            │◄──────────┐
                │     │ (observer armed)  │           │
                │     └──────┬────────────┘           │
                │            │ observer fires         │
                │            │   OR throttle expired  │
                │            │   OR manual sync       │
                │            ▼                        │
                │     ┌───────────────────┐           │
                │     │   QUERYING_HK     │           │
                │     │ (anchored query) │            │
                │     └──────┬────────────┘           │
                │            │ samples returned       │
                │            │   (or empty → IDLE)    │
                │            ▼                        │
                │     ┌───────────────────┐           │
                │     │   SPLITTING       │           │
                │     │ (off main thread, │           │
                │     │  gzip + outbox    │           │
                │     │  insert)          │           │
                │     └──────┬────────────┘           │
                │            │ envelopes persisted    │
                │            ▼                        │
                │     ┌───────────────────┐           │
                │     │   SENDING         │           │
                │     │ (ONE envelope,    │           │
                │     │  sync, ack wait)  │           │
                │     └──┬─────────────┬──┘           │
                │        │ ack received│              │
                │        │             │ timeout      │
                │        ▼             ▼              │
                │   ┌──────────┐  ┌──────────┐        │
                │   │ALL ACKED?│  │ BACKOFF  │        │
                │   └──┬───────┘  └────┬─────┘        │
                │      │   yes         │              │
                │      ▼               │              │
                │   commit anchor      │              │
                │   delete envelopes   │              │
                │      │               │              │
                │      ▼               │              │
                │  ┌─────────┐         │              │
                │  │ PACING  │         │              │
                │  │ (1.5 s) │         │              │
                │  └────┬────┘         │              │
                │       │              │              │
                │       ├──more pending┴──► SENDING   │
                │       │                              │
                │       └── outbox empty ───────────► IDLE
                │
                └── on permanent error or eviction: log, drop ─► IDLE
```

The PACING step is **mandatory after every successful send**, not an
optimization. Skipping it is how Pilot's datagram path drops acks under
sustained load. See `agent-a/CHUNKING.md` for the rationale.

Every transition is durable: the next state is committed to disk (HK
anchor in `UserDefaults`, outbox rows in SQLite) before the transition is
considered complete. A process crash anywhere lands the next launch back in
a consistent state — at worst, the previous step's work is repeated, which
is idempotent.

## App lifecycle (iOS)

```
┌────────────────────────────────────────────────────────────────────┐
│ Cold launch                                                        │
├────────────────────────────────────────────────────────────────────┤
│ 1. HealthSyncApp.init                                              │
│      • BGTaskScheduler.register handlers (must run before          │
│        application(didFinishLaunching))                            │
│      • No I/O, no async, no Pilot                                  │
│                                                                    │
│ 2. ContentView appears → .task fires (off main, but actor-safe)    │
│      • HealthSyncManager.bootstrap()                               │
│                                                                    │
│ 3. bootstrap() — fixed order, each step blocks the next:           │
│      a. HK authorization (modal; user-blocking)                    │
│      b. LocationProvider.requestAuth (modal)                       │
│      c. Photos auth (deferred to first use of Map view)            │
│      d. Notification auth (deferred to first use of Settings)      │
│      e. PilotBoot.start(dataDir: appSupport/pilot, ackPort: 1002)  │
│         • opens IPC socket, persists identity                      │
│         • spawns receive loop on Pilot inbox                       │
│      f. Trust handshake to homelab node (skipped if already        │
│         trusted from prior install)                                │
│      g. OutboxStore.open() + recover():                            │
│         • mark 'sending' rows back to 'pending' (interrupted)      │
│         • report counts to UI                                      │
│      h. install HKObserver queries (with bg-delivery)              │
│      i. start OutboxWorker drain loop                              │
│      j. compute readiness + models eagerly (read-only HK)          │
│                                                                    │
│ 4. SplashView dissolves once Readiness.band ≠ .unknown OR          │
│    recentSyncs non-empty                                           │
└────────────────────────────────────────────────────────────────────┘
```

### Warm resume from background

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. scenePhase: background → active                                 │
│ 2. PilotBoot.ensureRunning() — restart if iOS reaped the daemon    │
│ 3. OutboxWorker.kick() — wake the drain loop                       │
│ 4. NetworkMonitor refresh                                          │
│ 5. UI rehydrates from @Published properties (no re-fetch unless    │
│    lastSyncDate is stale)                                          │
└────────────────────────────────────────────────────────────────────┘
```

### Background task wake (BGAppRefreshTask, ≤30 s)

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. iOS calls our registered handler                                │
│ 2. task.expirationHandler = { cancel current sync }                │
│ 3. Schedule next BGAppRefreshTask before doing work                │
│ 4. syncAll(reason: "bg-refresh") — bounded by 25 s budget          │
│ 5. OutboxWorker drains opportunistically                           │
│ 6. task.setTaskCompleted(success: true)                            │
└────────────────────────────────────────────────────────────────────┘
```

### Backgrounding → suspended

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. scenePhase: active → background                                 │
│ 2. OutboxWorker pauses after the current in-flight envelope        │
│    (don't start another)                                           │
│ 3. PilotBoot pauses; embedded daemon suspends with the process     │
│ 4. HKObservers continue to fire via background delivery (paid      │
│    entitlement required; otherwise foreground only)                │
│ 5. On wake (next foreground or BG task), resume from above         │
└────────────────────────────────────────────────────────────────────┘
```

### Termination

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. No deinit guarantees from iOS — assume crash semantics          │
│ 2. All durable state already on disk:                              │
│      • HK anchors → UserDefaults                                   │
│      • Outbox envelopes → SQLite                                   │
│      • Pilot identity → appSupport/pilot/identity.json             │
│      • Trust list → appSupport/pilot/trust.json                    │
│      • Settings (wakeWindow, deviceID, serverURL) → UserDefaults   │
│ 3. Next cold launch picks up where we stopped                      │
└────────────────────────────────────────────────────────────────────┘
```

## Pilot state (iOS embedded daemon)

```
              ┌────────┐
              │STOPPED │
              └───┬────┘
                  │ PilotBoot.start()
                  ▼
              ┌────────┐  init() fails
              │STARTING│──────────► STOPPED + error
              └───┬────┘
                  │ socket open
                  ▼
              ┌────────┐
   ┌─────────►│RUNNING │◄────────┐
   │          └───┬────┘         │
   │              │ first send   │
   │              │ to untrusted │
   │              │ peer         │
   │              ▼              │
   │       ┌──────────────┐      │
   │       │TRUST_PENDING │──────┘ trust granted
   │       └──────────────┘
   │              │ trust rejected
   │              ▼
   │       ┌──────────────┐
   │       │   DEGRADED   │ pilot up, can't reach this peer
   │       └──────────────┘
   │              │ trust re-established
   │              │ OR app rebuilt
   │              ▼
   └──────────────┘
```

`PilotBoot` is a singleton with one of these states. Views observe it; the
OutboxWorker checks `pilot.state == .running` before starting a send.

## Authorization states (iOS)

Each system permission is independently tracked:

| Permission | States | Where checked |
|---|---|---|
| HealthKit | `.notDetermined` → `.granted-some` / `.denied` (read-only is always "denied" per Apple privacy) | `Readiness`, `Models`, `TimeSeries` skip cleanly if read-probe returns 0 |
| Location | `.notDetermined` → `.authorizedWhenInUse` / `.denied` | `LocationProvider.currentFix()` returns nil if denied |
| Photos | `.notDetermined` → `.authorized` / `.limited` / `.denied` | `PhotosLocationProvider.fetchGeotaggedPhotos` returns `[]` if missing |
| Notifications | `.notDetermined` → `.granted` / `.provisional` / `.denied` | `NotificationManager.notify(...)` no-ops if missing |
| Background App Refresh | system-wide, not per-app | `BGTaskScheduler.submit` succeeds anyway; iOS decides whether to fire |

The app degrades gracefully on every denial — no permission failure stops
sync from working, only specific features (map heatmap needs Photos; wear
reminders need Notifications; etc.).

## OpenClaw / Agent lifecycle

Both agents run as Docker containers on GCP VM `hackathon-openclaw`, managed by Docker Compose. Each container starts its own Pilot daemon and Python entry point.

```
┌────────────────────────────────────────────────────────────────────┐
│ Docker Compose up (GCP: hackathon-openclaw)                        │
├────────────────────────────────────────────────────────────────────┤
│ g-stack-agent-a (Collector):                                       │
│   1. entrypoint-agent-a.sh starts Pilot daemon                     │
│   2. Waits for Pilot IPC socket                                    │
│   3. python -m collector.server:                                   │
│        a. Open facts.duckdb at /var/collector_data/facts.duckdb    │
│           (Docker volume docker_agent_a_data)                      │
│        b. Start inbox_watcher polling ~/.pilot/inbox every 1 s     │
│        c. Drain any unprocessed inbox files (crash recovery)       │
│        d. OpenClaw workspace: .openclaw/collector-workspace/       │
│                                                                    │
│ g-stack-agent-b (Coach):                                           │
│   1. entrypoint-agent-b.sh starts Pilot daemon                     │
│   2. Waits for Pilot IPC socket                                    │
│   3. python -m coach watch:                                        │
│        a. Load Google OAuth credentials from /run/secrets/.env     │
│        b. Open G-Brain at gbrain-coach-home/                       │
│        c. Start draining Pilot inbox for ChangeEvents              │
│        d. OpenClaw workspace: .openclaw/coach-workspace/           │
│                                                                    │
│ health-intelligence (sidecar, separate process):                   │
│   1. Load MetricIndex + EmbeddingStore from cache                  │
│   2. Warm SentenceTransformer model (~11 s cold start)             │
│   3. Listen on http://127.0.0.1:8741                               │
└────────────────────────────────────────────────────────────────────┘
```

Either container can crash and Docker Compose restarts only that container. Volumes persist across restarts — Pilot identities, DuckDB, and G-Brain data are not lost.

### Agent A states

```
            ┌─────────────┐
            │  INITIALIZING│
            └──────┬───────┘
                   │ DB + listeners ready
                   ▼
       ┌────────────────────────┐
       │      LISTENING         │
       └────┬───────────────────┘
            │ envelope arrives
            ▼
       ┌────────────────────────┐
       │      INGESTING         │
       │ (transaction open)     │
       └────┬───────────────────┘
            │ commit ok
            ▼
       ┌────────────────────────┐
       │  PUBLISHING (ack +     │
       │   ChangeEvent)         │
       └────┬───────────────────┘
            │ both sent
            └────► LISTENING
```

Single-writer model on DuckDB means A serializes ingest internally. Queries
from B run concurrently — DuckDB supports MVCC reads.

### Agent B (Coach) states

```
        ┌──────────┐
        │ WATCHING │◄──────────────────────────────┐
        └────┬─────┘                               │
             │ ChangeEvent received                │
             │   (kind: samples_added)             │
             ▼                                     │
        ┌──────────────────┐                       │
        │  QUERYING        │                       │
        │ (send SQL query  │                       │
        │  to Collector,   │                       │
        │  await result)   │                       │
        └────┬─────────────┘                       │
             │ QueryResult received                │
             ▼                                     │
        ┌──────────────────┐                       │
        │  RULE MODELS     │                       │
        │ (7 rules, each   │                       │
        │  checks band +   │                       │
        │  cooldown)       │                       │
        └────┬─────────────┘                       │
             │ rule fires (+ cooldown elapsed)     │
             ▼                                     │
        ┌──────────────────┐                       │
        │  NUDGE + ROLLUP  │                       │
        │ (Telegram send,  │                       │
        │  G-Brain write)  │                       │
        └────┬─────────────┘                       │
             └────────────────────────────────────►┘
```

Also handles on-demand Telegram questions from the user at any point — those take priority over the rule loop and follow the same DuckDB + G-Brain + RAG path.

## Cross-process state contract

| State item | Owner | Shape | Recovery |
|---|---|---|---|
| HK anchors (per type) | iOS | `Data` blob in `UserDefaults`, key `anchor:<type>` | Anchor advance is the LAST step after envelope ack |
| Outbox rows | iOS | SQLite table, `state` column | On boot: `UPDATE state='sending' → 'pending'` |
| Pilot identity (iOS) | iOS | Ed25519 keypair in `appSupport/pilot/` | Persists across reinstalls if same App Group |
| Pilot identity (GCP) | Each container | Ed25519 keypair in Docker volume `docker_agent_X_pilot` | Persists across container restarts and rebuilds |
| Trust list | iOS + GCP containers | Per-daemon trusted node ID list | First handshake needs one-time `pilotctl approve` |
| Health warehouse | Collector | `facts.duckdb` in Docker volume `docker_agent_a_data:/var/collector_data` | Transactional; partial commits roll back |
| G-Brain (Collector) | Collector | PGLite at `infra/data/gbrain-collector-home/` (bind mount) | MCP-managed; PGLite is transactional |
| G-Brain (Coach) | Coach | PGLite at `infra/data/gbrain-coach-home/` (bind mount) | MCP-managed; PGLite is transactional |
| Calendar markdown | Coach | `~/brain/daily/calendar/` (bind mount into `/root/brain`) | Re-pulled via `calendar_sync.py --days N` |
| Embedding cache | health-intelligence | `health-intelligence/data/embed_cache.npz` | Hash-invalidated; rebuilt automatically if source JSON changes |

The only piece of state that exists in two places: **Pilot trust**. iOS
stores who it trusts; homelab stores the same independently. Both must
agree before a connection works. Re-handshake fixes drift.

## Boot order (full system, fresh GCP box)

```
1. Clone repo, copy secrets to infra/secrets/.env     ┐
2. Initialize G-Brain instances (gbrain init × 2)      ├── one-time setup
3. docker compose up --build -d                        ┘
4. Collector container starts → Pilot daemon up, identity persisted
5. Coach container starts → Pilot daemon up, identity persisted
6. health-intelligence server starts → embeddings warm (~11 s cold start)

7. iOS app cold-launches
8. iOS PilotBoot.start → embedded daemon up, identity persisted
9. iOS trust-handshake → docker exec g-stack-agent-a pilotctl approve <id>  (one-time)
10. iOS OutboxWorker starts draining (empty on first run)

11. First HK observer fires → sync pipeline kicks in
12. Envelope lands at Collector → facts.duckdb INSERT → send-message ChangeEvent to Coach
13. Coach receives ChangeEvent → runs 7 rule models → SQL queries back to Collector
14. If rule fires + cooldown elapsed → G-Brain insight written + Telegram nudge sent
```

After step 14 the system is in steady state. Kill any container — Docker Compose restarts it; volumes preserve all state. Kill the iOS process — OutboxWorker resumes from SQLite outbox on next launch.

## Failure modes (and their resolution)

| Failure | Effect | Resolves when |
|---|---|---|
| iOS process killed mid-send | One envelope row stays in `state='sending'` | Cold launch: `recover()` moves it back to `pending` |
| Pilot daemon dies inside iOS | OutboxWorker.send fails with `pilot.state ≠ .running` | `PilotBoot.ensureRunning()` on next foreground / BG wake |
| Network unreachable | Sends fail with timeout | `NetworkMonitor` flips to `.offline`, worker stays in `BACKOFF` |
| Collector container crashes | New envelopes pile up at Pilot inbox (iOS sees delayed acks) | Docker Compose restarts container; inbox-drain catches up; no data loss |
| Coach container crashes | Rule loop pauses; ChangeEvents queue in inbox | Docker Compose restarts container; inbox-drain catches up |
| Docker Compose down | Both containers stop; no acks from Collector | `docker compose up -d`; volumes preserve all state |
| DuckDB write fails (disk full) | Collector returns no ack | iOS outbox grows until disk recovers; UUID dedupe handles replays |
| Google OAuth token expired | Coach calendar pull fails with 401 | Re-run `python agent-b/coach/calendar_sync.py --auth-only`; update `infra/secrets/.env`; `docker compose restart agent-b` |
| Google API rate-limited | Calendar pull throttled | Exponential backoff in `calendar_sync.py`; next pull resumes from `nextSyncToken` |
| health-intelligence server down | RAG retrieval unavailable for Coach answers | `nohup .venv/bin/python health-intelligence/server.py &`; embeddings load from cache in ~11 s |
| ZeroEntropy unreachable | Reranking unavailable | health-intelligence falls back to cosine similarity order; no data loss |
| User reinstalls iOS app | New Pilot identity, fresh trust needed | Re-handshake via `pilotctl approve`; UUID dedupe prevents re-ingesting same samples |
| User changes bundle id | New identity, new UserDefaults, fresh anchors | Anchor paging + UUID dedupe handles the re-flood gracefully |

## Observability checkpoints

```sh
# iOS — surfaced on Status tab + widget
outbox.pending  outbox.totalBytes  outbox.oldestAge  outbox.lastAck

# GCP — containers
docker ps                                          # both containers running
docker logs g-stack-agent-a --tail 20             # Collector: envelope + query log
docker logs g-stack-agent-b --tail 20             # Coach: ChangeEvent + Telegram log

# GCP — Collector warehouse
docker exec g-stack-agent-b python -m coach query \
  'SELECT type, COUNT(*) FROM samples GROUP BY type ORDER BY 2 DESC'

# GCP — Coach readiness
docker exec g-stack-agent-b python -m coach readiness

# GCP — Pilot connectivity
docker exec g-stack-agent-a /opt/pilot/bin/pilotctl peers

# GCP — health-intelligence
curl http://127.0.0.1:8741/health  # {"status":"ok","papers":17,"interventions":89}
```

## See also

- [README.md](README.md) — overall architecture and data flow
- [agent-a/SCHEMA.md](agent-a/SCHEMA.md) — wire format: envelope, ack, query, change-event
- [agent-a/CHUNKING.md](agent-a/CHUNKING.md) — outbox + retry strategy
- [agent-a/README.md](agent-a/README.md) — Health ingest agent
- [agent-b/README.md](agent-b/README.md) — Coach agent
- [health-intelligence/SKILL.md](health-intelligence/SKILL.md) — RAG retrieval tool
- [infra/README.md](infra/README.md) — operator runbook
