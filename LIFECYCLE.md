# State and lifecycle

Every component has a known set of states, an ordered boot sequence, and an
ordered shutdown sequence. Everything that matters is written to disk before
the next step in the sequence runs, so any component can crash at any point
and resume from where it stopped.

## Three lifecycles to coordinate

| Lifecycle | Controlled by | Survives across |
|---|---|---|
| **iOS app process** | iOS scheduler + user | foreground / background / suspended / terminated |
| **OpenClaw skills** (Agent A + B) | OpenClaw daemon | reboots, skill upgrades, individual skill crashes |
| **Pilot daemons** (iOS embedded + homelab) | App / daemon process | network changes, NAT renegotiation |

These three are independent. Each side's recovery does not depend on the
other being healthy; the wire protocol (envelopes + acks) bridges them.

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
│ 3. Agent A skill (Collector) initializes:                          │
│      a. Open DuckDB at infra/data/facts.duckdb                     │
│      b. Apply pending migrations from agent-a/migrations/          │
│      c. Bind Pilot listener on port 1001 (ingest)                  │
│      d. Bind Pilot listener on port 1003 (query)                   │
│      e. Start ChangeEvent publisher (port 1004)                    │
│      f. Drain any unacked envelopes in inbox (rare; only if        │
│         daemon crashed mid-batch)                                  │
│                                                                    │
│ 4. Agent B skill (Coach) initializes:                              │
│      a. Open MCP connection to gbrain                              │
│      b. Subscribe to Pilot port 1004                               │
│      c. Connect Telegram channel via OpenClaw adapter              │
│      d. Hydrate conversation state from OpenClaw session store     │
│      e. Start rule-loop scheduler (cron, 15 min default)           │
│                                                                    │
│ 5. Daemon reports healthy via `openclaw doctor`                    │
└────────────────────────────────────────────────────────────────────┘
```

Either skill can crash and OpenClaw restarts only that skill — the other is
unaffected. Both skills are idempotent on restart: A re-binds to the same
ports and replays from DuckDB; B re-subscribes to ChangeEvent and queries A
on the next conversational turn.

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

### Agent B states (per turn)

```
        ┌──────────┐
        │   IDLE   │◄────────────────┐
        └────┬─────┘                 │
             │ Telegram message      │
             │   OR ChangeEvent      │
             │   OR rule-loop tick   │
             ▼                       │
        ┌──────────────┐             │
        │   READING    │             │
        │ (query A,    │             │
        │  gbrain.search)│           │
        └────┬─────────┘             │
             ▼                       │
        ┌──────────────┐             │
        │   REASONING  │             │
        │   (LLM turn) │             │
        └────┬─────────┘             │
             │ tool call needed?     │
             ├─ yes → call tool      │
             │   (gstack, pilot      │
             │   specialist, gbrain  │
             │   write) → REASONING  │
             ▼                       │
        ┌──────────────┐             │
        │   REPLYING   │             │
        │ (Telegram +  │             │
        │  gbrain.write│             │
        │  summary)    │             │
        └────┬─────────┘             │
             └─────────────────────►─┘
```

Each turn is its own transaction. LLM call may take seconds; OpenClaw
buffers user messages while a turn is in flight.

## Cross-process state contract

| State item | Owner | Shape | Recovery |
|---|---|---|---|
| HK anchors (per type) | iOS | `Data` blob in `UserDefaults`, key `anchor:<type>` | Anchor advance is the LAST step after envelope ack |
| Outbox rows | iOS | SQLite table, `state` column | On boot: `UPDATE state='sending' → 'pending'` |
| Pilot identity | iOS + homelab | Ed25519 keypair on disk | Identity persists across reinstalls if same App Group |
| Trust list | iOS + homelab | List of trusted node IDs | First handshake on cold-install needs one-time approve |
| DuckDB facts | Agent A | Single file `infra/data/facts.duckdb` | Transactional; partial commits roll back |
| gbrain memory | Coach | PGLite DB at `infra/data/gbrain/` | MCP-managed; PGLite is transactional |
| Telegram thread | OpenClaw daemon | OpenClaw session store | Hydrated on skill boot |
| Conversation context | Coach skill | OpenClaw session store + gbrain | LLM gets last N turns + relevant gbrain hits |
| Rule cooldowns | Coach skill | `infra/data/gbrain/cooldowns` | Persisted; survives Coach restart |

The only piece of state that exists in two places: **Pilot trust**. iOS
stores who it trusts; homelab stores the same independently. Both must
agree before a connection works. Re-handshake fixes drift.

## Boot order (full system, fresh box)

```
1. OpenClaw daemon up        ┐
2. gbrain MCP server up      ├── infra one-time setup
3. Telegram bot registered   ┘
4. Pilot daemon up (homelab) → identity persisted, listener bound
5. Agent A skill loads → DuckDB open, listeners bound
6. Agent B skill loads → MCP + Telegram + subscriptions

7. iOS app cold-launches
8. iOS PilotBoot.start → embedded daemon up, identity persisted
9. iOS trust-handshake → homelab pilotctl approve <id> (one-time)
10. iOS OutboxWorker starts draining (was empty on first run)

11. First HK observer fires → sync pipeline kicks in
12. Envelope lands at Agent A → DuckDB INSERT → ChangeEvent fires
13. Agent B receives ChangeEvent → rule loop evaluates → no nudge yet
14. User opens Telegram → "/start" → Coach replies "Ready, I have N samples"
```

After step 14, the system is in steady state. From here, every step in the
hot path is observable in disk state — kill any process at any point and
re-running it picks up from disk.

## Failure modes (and their resolution)

| Failure | Effect | Resolves when |
|---|---|---|
| iOS process killed mid-send | One envelope row stays in `state='sending'` | Cold launch: `recover()` moves it back to `pending` |
| Pilot daemon dies inside iOS | OutboxWorker.send fails with `pilot.state ≠ .running` | `PilotBoot.ensureRunning()` on next foreground / BG wake |
| Network unreachable | sends fail with timeout | `NetworkMonitor` flips to `.offline`, worker stays in `BACKOFF` |
| Agent A skill crashes | New envelopes pile up at Pilot inbox | OpenClaw restarts skill; A's inbox-drain catches up; iOS sees a queue of delayed acks but no data loss |
| OpenClaw daemon down | Telegram silent, no acks | launchd/systemd KeepAlive restarts; on resume, the whole stack rehydrates |
| DuckDB write fails (disk full) | A returns no ack | iOS outbox grows until disk recovers; eventual eviction |
| Telegram outage | Coach can't deliver pro-active nudges | Nudges still written to gbrain; user sees them on resume |
| LLM provider down | Coach reasoning fails | OpenClaw model-failover or graceful degradation: "checking back in a few min" |
| User reinstalls iOS app | New identity, fresh trust | Re-handshake; UUIDs prevent re-ingesting same samples |
| User changes bundle id | New identity, new UserDefaults, fresh anchors | Anchor paging + UUID dedupe handles the re-flood gracefully (already tested in this codebase) |

## Observability checkpoints

Each component exposes a `health()` endpoint or status field that the
operator can check:

```sh
# iOS — surfaced on Status tab + widget
outbox.pending  outbox.totalBytes  outbox.oldestAge  outbox.lastAck

# homelab
openclaw doctor                  # daemon + skills
duckdb infra/data/facts.duckdb 'SELECT count(*), max(ingested_utc) FROM samples'
pilotctl trust                   # peers
pilotctl peers                   # connectivity
infra/scripts/healthcheck.sh     # composite, exit 0 = green
```

Any single check that fails names which component is unwell. Recovery for
each is documented above.

## See also

- [README.md](README.md) — overall architecture
- [agent-a/SCHEMA.md](agent-a/SCHEMA.md) — wire format
- [agent-a/CHUNKING.md](agent-a/CHUNKING.md) — outbox + retry strategy
- [agent-a/README.md](agent-a/README.md) — Collector spec
- [agent-b/README.md](agent-b/README.md) — Coach spec
- [infra/README.md](infra/README.md) — operator runbook
