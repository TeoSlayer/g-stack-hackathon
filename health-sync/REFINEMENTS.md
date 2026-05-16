# health-sync refinements

A running queue of concrete improvements surfaced by `gstack-ios` skills (or
by manual code-walks pending the right skill). Each entry is small enough to
fix in a single iteration.

## How entries work

Every entry has:

- **ID** — `REFINEMENT-NNN`, monotonic, never reused.
- **Surfaced by** — which skill (or "manual / iter N") found it.
- **Status** — `open` | `in-progress` | `fixed` (commit SHA) | `wontfix` (reason).
- **Severity** — `bug` | `polish` | `perf` | `unsafe` | `dx`.
- **Description** — what is wrong, in two sentences max.
- **Where** — file:line.
- **Why it matters** — the user-visible or developer-visible consequence.
- **Fix sketch** — one paragraph. Not a binding plan, just enough that the
  fixing iteration doesn't have to re-think from scratch.

The loop fixes entries in priority order (`bug` > `unsafe` > `perf` > `polish`
> `dx`), oldest first within a severity. A finding without a clear fix
sketch may be deferred until the right skill exists to refine it.

---

## REFINEMENT-001 — `WCSessionBridge.publishStatus` is dead code

- **Surfaced by:** manual code-walk during iteration 1 (motivating case for
  the planned `/ios-wiring-check` skill, BACKLOG #8).
- **Status:** wontfix (Watch target removed in 91dc238 — `Shared/WCSessionBridge.swift` and the entire `HealthSyncWatch/` directory deleted; phone↔watch wiring is no longer in scope.)
- **Severity:** bug
- **Where:** `Shared/WCSessionBridge.swift:21` (definition);
  `HealthSync/HealthSyncManager.swift` (no call site).

### Description

`WCSessionBridge.publishStatus(lastSyncAt:serverReachable:)` is defined with a
doc-comment that says *"Call this after every sync or reachability change in
HealthSyncManager"*, but `grep -rn "publishStatus" --include="*.swift"` in
`health-sync/` returns only the definition. The Watch's
`WatchHealthManager.phoneLastSync` and `phoneServerReachable` therefore stay
at their initial values forever.

### Why it matters

The Watch UI displays "last phone sync" and "phone's server reachability".
With the wiring missing, those fields are permanently stale unless the user
manually nudges via "Sync now" — and even then, the nudge triggers a sync but
no status push back. The Watch app silently lies about the system's state.

### Fix sketch

Call `WCSessionBridge.shared.publishStatus(lastSyncAt: lastSyncDate, serverReachable: serverReachable)`
at the end of `HealthSyncManager.syncAll(reason:)` (after `lastSyncDate` is
assigned) and inside `pingServer()` whenever `serverReachable` transitions.
Verify on the Watch: launch both sims via `/ios-watch-pair` (skill #5), trigger
a sync, observe the Watch's `phoneLastSync` update. The fix is ~4 lines; the
verification is what motivates `/ios-watch-pair`.

---

## REFINEMENT-002 — `HealthSyncWidget` has no standalone scheme

- **Surfaced by:** `/ios-build` scheme-discovery step (procedure step 3),
  iteration 1.
- **Status:** fixed (this commit) — `HealthSyncWidget` scheme added to `project.yml`; `xcodegen generate` now emits it. `xcodebuild -list` returns two schemes (`HealthSync` and `HealthSyncWidget`).
- **Severity:** dx
- **Where:** `health-sync/project.yml:82-97` (the `schemes:` block).

### Description

`project.yml` declares `HealthSyncWidget` as an `app-extension` target
(line 46), but the `schemes:` block at the bottom defines only `HealthSync`
and `HealthSyncWatch`. `xcodebuild -list -workspace HealthSync.xcworkspace`
returns the same two schemes — no `HealthSyncWidget` entry. The widget is
only ever built as a dependency of the parent app.

### Why it matters

Every widget-only change forces a full HealthSync rebuild + reinstall cycle to
test, because there's no scheme to build or run the extension in isolation.
This is the kind of friction that makes `/ios-widget-preview` (skill #7) worth
building, but a standalone scheme is the prerequisite — without it,
`/ios-widget-preview` can't even target the widget.

### Fix sketch

Add a `HealthSyncWidget` entry to the `schemes:` block in `project.yml`, with
`build.targets.HealthSyncWidget: all` and `run.config: Debug`. Regenerate via
`xcodegen generate` (verifies REFINEMENT will pair with `/ios-xcodegen` skill
work). Confirm `xcodebuild -list` now shows three schemes. No code changes
required.

---

## REFINEMENT-003 — `PilotSyncTransport.ping()` never probed the peer

- **Surfaced by:** manual run-through of the Activity tab ("Ping peer" button
  produced no visible result).
- **Status:** fixed (this commit).
- **Severity:** bug
- **Where:** `HealthSync/PilotSyncTransport.swift:14-16` (old `ping()`).

### Description

The Pilot transport's `ping()` returned `PilotBoot.shared.isReady` without
ever dialing the peer. `HealthSyncManager.pingServer()` then set
`serverReachable` to that boolean and only recorded an activity event when
the value transitioned, so a manual tap on **Ping peer** in Activity logged
nothing if the daemon was already running — the user concluded the button
was broken.

### Why it matters

The whole point of "Ping peer" is to *confirm overlay reachability before
trusting Pilot for a sync*. The previous behaviour answered "is the daemon
running locally?", a distinct question already shown by the trust chip in
the Status hero. Sending an envelope without the peer probe risked a
30-second `sendDataExchange` timeout instead of a fast "peer unreachable"
flag.

### Fix sketch

`ping()` now `await`s `PilotBoot.shared.pingOnce()` (dials port 7,
PortEcho) and returns `lastPingOK && isReady`. `pingServer` gains a
`userInitiated: Bool = false` parameter — when true (Activity / Settings
taps) it records an event every time so the user sees their tap landed;
internal callers (launch, BG, settings save) keep the transition-only
logging.

---

## REFINEMENT-004 — No manual deep-backfill path

- **Surfaced by:** user request after first install: "How do we backfill the
  full history once after a reinstall?"
- **Status:** fixed (this commit).
- **Severity:** polish (workaround was "delete + reinstall the app and hope
  observers catch up").
- **Where:** `HealthSync/HealthSyncManager.swift:294-330` (`syncAll`).

### Description

Every sync — manual, observer-driven, BG-task — used the same 30-day rolling
cutoff, and the per-type HK anchor persisted across reinstalls (via
UserDefaults). After a server rebuild or a stale anchor situation, there
was no in-app path to re-walk a wider window: the anchor was already past
the new cutoff, so a wider predicate produced zero rows.

### Why it matters

The 30-day default is right for steady-state sync, but recovery cases
(server data lost, fresh device with same iCloud account, "I want last
year of HRV trends in this dashboard") had no in-app affordance. Pulling
through the Settings "Reset device ID" hatch worked by accident but reset
unrelated state.

### Fix sketch

`syncAll(reason:backfillDays:resetAnchors:)` overload takes a per-run
override of the cutoff and an opt-in anchor wipe. The Activity tab grows
a second button — **Full backfill** — under the existing Sync section,
gated by a confirmation dialog. The window stays at the canonical 30-day
horizon (anything wider exceeds the on-device models' modelled range);
the difference is purely "wipe anchors + re-walk", which covers the
"server lost data, resend everything we still hold locally" case.

