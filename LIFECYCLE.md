# State and lifecycle

Every component has a known set of states, an ordered boot sequence, and an
ordered shutdown sequence. Everything that matters is written to disk before
the next step in the sequence runs, so any component can crash at any point
and resume from where it stopped.

## Four lifecycles to coordinate

| Lifecycle | Controlled by | Survives across |
|---|---|---|
| **iOS app process** | iOS scheduler + user | foreground / background / suspended / terminated |
| **Agent A** (health ingest, OpenClaw skill) | OpenClaw daemon | reboots, skill upgrades, crashes |
| **Agent B** (GSuite ingest, OpenClaw skill) | OpenClaw daemon | reboots, skill upgrades, crashes |
| **Pilot daemons** (iOS embedded + homelab) | App / daemon process | network changes, NAT renegotiation |

These four are independent. Each side's recovery does not depend on the
others being healthy; Pilot envelopes + acks bridge the iOS ↔ Agent A link;
OAuth tokens and Pilot ports bridge Agent A ↔ Agent B.

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

```
┌────────────────────────────────────────────────────────────────────┐
│ OpenClaw daemon boot (launchd/systemd user service)                │
├────────────────────────────────────────────────────────────────────┤
│ 1. OpenClaw loads ~/.openclaw/openclaw.json                        │
│ 2. Loads skill manifests from skills.toml                          │
│                                                                    │
│ 3. Agent A skill (Health Ingest) initializes:                      │
│      a. Open DuckDB at infra/data/health.duckdb                    │
│      b. Bind Pilot listener on port 1001 (ingest)                  │
│      d. Bind Pilot listener on port 1003 (query)                   │
│      e. Start ChangeEvent publisher (port 1004)                    │
│      f. Open MCP connection to shared G-Brain                      │
│      g. Drain any unacked envelopes in inbox (rare; crash recovery) │
│                                                                    │
│ 4. Agent B skill (GSuite Ingest) initializes:                      │
│      a. Load OAuth credentials from .env                           │
│      b. Open DuckDB at infra/data/gsuite.duckdb                    │
│      c. Hydrate GSuite sync tokens from DB                         │
│         (Calendar nextSyncToken, Drive pageToken, Gmail historyId) │
│      e. Open MCP connection to shared G-Brain                      │
│      f. Subscribe to Pilot port 1004 (Agent A ChangeEvents)        │
│      g. Schedule first GSuite pull cycle                           │
│                                                                    │
│ 5. health-intelligence server starts (separate process):           │
│      a. Load MetricIndex + EmbeddingStore from cache               │
│      b. Warm SentenceTransformer model                             │
│      c. Listen on http://127.0.0.1:8741                            │
│                                                                    │
│ 6. All processes report healthy                                    │
└────────────────────────────────────────────────────────────────────┘
```

Either skill can crash and OpenClaw restarts only that skill — the other is
unaffected. Both skills are idempotent on restart: A re-binds to the same
Pilot ports and replays DuckDB; B reloads OAuth tokens and GSuite sync tokens
from its DuckDB, then resumes incremental pull from the last known checkpoint.

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

### Agent B states (GSuite sync cycle)

```
        ┌──────────┐
        │   IDLE   │◄──────────────────────────────┐
        └────┬─────┘                               │
             │ sync timer fires                    │
             │   OR Agent A ChangeEvent received   │
             ▼                                     │
        ┌──────────────────┐                       │
        │   PULLING        │                       │
        │ (OAuth API:      │                       │
        │  Calendar,       │                       │
        │  Drive, Gmail)   │                       │
        └────┬─────────────┘                       │
             │ items fetched (or 0 → IDLE)          │
             ▼                                     │
        ┌──────────────────┐                       │
        │   WAREHOUSING    │                       │
        │ (DuckDB inserts, │                       │
        │  sync token      │                       │
        │  advance)        │                       │
        └────┬─────────────┘                       │
             │ commit ok                           │
             ▼                                     │
        ┌──────────────────┐                       │
        │   ROLLUP         │                       │
        │ (G-Brain daily   │                       │
        │  summary write)  │                       │
        └────┬─────────────┘                       │
             └────────────────────────────────────►┘
```

Each pull cycle is idempotent: sync tokens are persisted inside DuckDB in the
same transaction as the data rows. A crash mid-pull resets to the previous
committed token; the next cycle replays from that checkpoint.

## Cross-process state contract

| State item | Owner | Shape | Recovery |
|---|---|---|---|
| HK anchors (per type) | iOS | `Data` blob in `UserDefaults`, key `anchor:<type>` | Anchor advance is the LAST step after envelope ack |
| Outbox rows | iOS | SQLite table, `state` column | On boot: `UPDATE state='sending' → 'pending'` |
| Pilot identity | iOS + homelab | Ed25519 keypair on disk | Identity persists across reinstalls if same App Group |
| Trust list | iOS + homelab | List of trusted node IDs | First handshake on cold-install needs one-time approve |
| Health warehouse | Agent A | DuckDB file `infra/data/health.duckdb` | Transactional; partial commits roll back |
| GSuite sync tokens | Agent B | Rows in `infra/data/gsuite.duckdb` (`sync_tokens` table) | Committed in same txn as data rows; crash resets to prior token |
| GSuite warehouse | Agent B | DuckDB file `infra/data/gsuite.duckdb` | Transactional; partial inserts roll back |
| G-Brain memory | Agent A + B shared | PGLite DB at `infra/data/gbrain/` | MCP-managed; PGLite is transactional |
| Embedding cache | health-intelligence | `health-intelligence/data/embed_cache.npz` | Hash-invalidated; rebuilt automatically if source JSON changes |

The only piece of state that exists in two places: **Pilot trust**. iOS
stores who it trusts; homelab stores the same independently. Both must
agree before a connection works. Re-handshake fixes drift.

## Boot order (full system, fresh box)

```
1. OpenClaw daemon up              ┐
2. G-Brain MCP server up           ├── infra one-time setup
3. Google OAuth credentials in .env┘
4. Pilot daemon up (homelab) → identity persisted, listener bound
5. Agent A skill loads → health.duckdb open, Pilot ports bound, G-Brain connected
6. Agent B skill loads → gsuite.duckdb open, OAuth loaded, port 1004 subscribed
7. health-intelligence server starts → embeddings warm (~10 s cold start)

8. iOS app cold-launches
9. iOS PilotBoot.start → embedded daemon up, identity persisted
10. iOS trust-handshake → homelab pilotctl approve <id> (one-time)
11. iOS OutboxWorker starts draining (empty on first run)

12. First HK observer fires → sync pipeline kicks in
13. Envelope lands at Agent A → DuckDB INSERT → ChangeEvent fires on port 1004
14. Agent B receives ChangeEvent → schedules next GSuite pull
15. Agent B completes first GSuite pull → G-Brain rollup written
```

After step 15, the system is in steady state. Both agents are writing to
G-Brain; health-intelligence can query Agent A and rerank via ZeroEntropy.
Kill any process at any point — each restarts from its last durable checkpoint.

## Failure modes (and their resolution)

| Failure | Effect | Resolves when |
|---|---|---|
| iOS process killed mid-send | One envelope row stays in `state='sending'` | Cold launch: `recover()` moves it back to `pending` |
| Pilot daemon dies inside iOS | OutboxWorker.send fails with `pilot.state ≠ .running` | `PilotBoot.ensureRunning()` on next foreground / BG wake |
| Network unreachable | Sends fail with timeout | `NetworkMonitor` flips to `.offline`, worker stays in `BACKOFF` |
| Agent A skill crashes | New envelopes pile up at Pilot inbox | OpenClaw restarts skill; A's inbox-drain catches up; iOS sees delayed acks but no data loss |
| Agent B skill crashes | GSuite pull pauses; sync tokens safe on disk | OpenClaw restarts skill; B resumes from last committed sync token |
| OpenClaw daemon down | Both ingest workers stop, no acks from A | launchd/systemd KeepAlive restarts; whole stack rehydrates from disk |
| DuckDB write fails (disk full) | A returns no ack; B pull aborts | iOS outbox grows until disk recovers; B retries from last sync token |
| Google OAuth token expired | Agent B pull fails with 401 | Re-run `python agent-b/coach/calendar_sync.py` OAuth flow to get a new refresh token; update `.env` |
| Google API rate-limited | Agent B pull throttled | Exponential backoff; next cycle resumes from last successful sync token |
| health-intelligence server down | Retrieval unavailable | Restart with `.venv/bin/python server.py`; embeddings load from cache in ~10 s |
| ZeroEntropy unreachable | Reranking unavailable | health-intelligence falls back to raw cosine scores; no data loss |
| User reinstalls iOS app | New identity, fresh trust | Re-handshake; UUIDs prevent re-ingesting same samples |
| User changes bundle id | New identity, new UserDefaults, fresh anchors | Anchor paging + UUID dedupe handles the re-flood gracefully |

## Observability checkpoints

Each component exposes a `health()` endpoint or status field that the
operator can check:

```sh
# iOS — surfaced on Status tab + widget
outbox.pending  outbox.totalBytes  outbox.oldestAge  outbox.lastAck

# homelab — agents
openclaw doctor                    # OpenClaw daemon + both skills
duckdb infra/data/health.duckdb \
  'SELECT count(*), max(ingested_utc) FROM samples'   # Agent A row count + recency
duckdb infra/data/gsuite.duckdb \
  'SELECT count(*), max(synced_utc) FROM calendar_events' # Agent B sync recency
pilotctl trust                     # peers (expect: iOS + homelab)
pilotctl peers                     # connectivity table

# homelab — health-intelligence
curl http://127.0.0.1:8741/health  # {"status":"ok","papers":17,"interventions":89}

# composite
infra/scripts/healthcheck.sh       # exit 0 = all green
```

Any single check that fails names which component is unwell. Recovery for
each is documented in the failure modes table above.

## See also

- [README.md](README.md) — overall architecture and data flow
- [agent-a/SCHEMA.md](agent-a/SCHEMA.md) — wire format: envelope, ack, query, change-event
- [agent-a/CHUNKING.md](agent-a/CHUNKING.md) — outbox + retry strategy
- [agent-a/README.md](agent-a/README.md) — Health ingest agent
- [agent-b/README.md](agent-b/README.md) — GSuite ingest agent
- [health-intelligence/SKILL.md](health-intelligence/SKILL.md) — RAG retrieval tool
- [infra/README.md](infra/README.md) — operator runbook
