---
name: ios-watch-pair
description: Boot paired iPhone + Apple Watch simulators, install both targets, screenshot both, drive cross-device interactions.
---

# /ios-watch-pair

## When to invoke

Whenever the work touches `WatchConnectivity`, paired-device flows, app
groups shared between phone + watch, or watchOS UI that depends on phone
state. Also the verification harness for any issue that involves WCSession
wiring — e.g. a status-push helper defined on the phone side that the
watch never receives.

Wrong call for watch-only flows that don't depend on the phone — boot a
watch simulator directly via `/ios-simctl` and save the pairing overhead.

## Inputs

Required:
- `phone_device` — name or UDID, default `iPhone 15`.
- `watch_device` — name or UDID, default `Apple Watch Series 10 (46mm)`.
- `phone_app_path` and `watch_app_path` — `.app` bundles to install.

Optional:
- `phone_bundle_id` / `watch_bundle_id` — for launch.
- `actions` — list of post-launch actions to run (e.g. `wait <secs>`,
  `nudge-sync`, `screenshot`).
- `screenshot_interval_s` — periodically capture both devices during the
  session. Default `0` (capture on demand only).

Assumes:
- Both simulator runtimes installed (`xcrun simctl list runtimes`).
- `/ios-build` already produced both `.app` bundles.

## Procedure

1. **List runtimes** to confirm both platforms available; abort with a
   message naming what's missing if not.
2. **Find pairing.**
   ```
   xcrun simctl list pairs
   ```
   If `$phone_device` + `$watch_device` already paired, reuse. Otherwise:
   ```
   xcrun simctl pair "$watch_device" "$phone_device"
   ```
   (order matters — watch first).
3. **Boot phone, then watch** in that order (watch needs phone running).
4. **Install both apps** via `/ios-simctl install` invocations.
5. **Activate pair:** `xcrun simctl pair_activate <pair-udid>`.
6. **Launch phone app** then **watch app**.
7. **Capture initial screenshots** (both devices) via `/ios-simctl
   screenshot`.
8. **For each action in `actions`:**
   - `wait <secs>` — sleep, then re-screenshot both.
   - `nudge-sync` — call `xcrun simctl openurl <watch>
     <app-scheme>://sync-now`. Skipped silently if the app doesn't declare
     the URL scheme.
   - `tap-X` — out of scope for v0.1 (would require Appium / private
     simctl). Document the gap.
9. **Compose report** referencing all screenshot artifacts.

## Outputs

Report (`gstack-ios/.cache/ios-watch-pair-<ts>.json`):
```json
{
  "skill": "ios-watch-pair", "version": "0.1",
  "phone": {"device": "iPhone 15 (UDID)", "state": "Booted",
            "bundle_id": "com.example.app",
            "screenshots": ["gstack-ios/.cache/screenshots/phone-1.png", "..."]},
  "watch": {"device": "Apple Watch Series 10 (46mm) (UDID)", "state": "Booted",
            "bundle_id": "com.example.app.watchkitapp",
            "screenshots": ["gstack-ios/.cache/screenshots/watch-1.png", "..."]},
  "pair_udid": "...",
  "actions_run": ["wait 5", "screenshot"],
  "ok": true
}
```

**Side effects:** simulator boot, install, pair-activate; screenshot
files under `gstack-ios/.cache/screenshots/`.

## Verification

- **Positive:** `pair_udid` present, both devices `Booted`, at least one
  screenshot per device, each ≥ 1 KB and not all-black.
- **Negative:** explicit failure naming which step broke (pair, boot,
  install, launch). Common: `pair` fails because the watch runtime
  mismatches the phone runtime — surface the version pair so caller can
  fix.
- **WCSession verification:** the skill does not verify activation on its
  own. Downstream check the captured `os_log` via `/ios-simctl log` with
  predicate `subsystem == "com.apple.WatchConnectivity"`.

## Composition

- **Upstream:** `/ios-build` (×2 schemes), `/ios-simctl`
  (boot/install/launch).
- **Downstream:** `/ios-visual-critique` (reasons over both screenshots);
  `/ios-simctl log` (captures WCSession traffic).

## On failure → next step

- `pair` fails with "version mismatch" → the watch runtime can't pair
  with that iPhone runtime. Boot a different combination
  (`xcrun simctl list runtimes` shows what's installed).
- `pair_activate` fails with "device not booted" → step 3 didn't fully
  succeed; re-check `xcrun simctl list devices` for `Booted` state.
- WCSession traffic absent in logs → the phone-side `WCSession.default
  .activate()` might not be wired. `/ios-wiring-check` against the
  source roots to catch dead activation calls.

## Example

```
$ /ios-watch-pair \
    phone_app_path=build/.../App.app \
    watch_app_path=build/.../AppWatch.app \
    actions=["wait 5", "nudge-sync", "wait 3"]

discovered: phone=iPhone 15 (boot needed), watch=Apple Watch Series 10 46mm
no existing pair → xcrun simctl pair Apple-Watch... iPhone-15
booting phone... booted (8.4s)
booting watch... booted (6.1s)
installing both apps... ok
pair_activate <pair-udid>... ok
launching phone (com.example.app)... ok
launching watch (com.example.app.watchkitapp)... ok
initial screenshots captured (phone + watch)
action: wait 5
action: nudge-sync — xcrun simctl openurl <watch> app://sync-now
action: wait 3
final screenshots captured (phone + watch)

✓ pair_udid=ABC-123, both Booted
artifacts:
  gstack-ios/.cache/screenshots/phone-2026-05-16T12-55-00Z.png
  gstack-ios/.cache/screenshots/watch-2026-05-16T12-55-00Z.png
  gstack-ios/.cache/screenshots/phone-2026-05-16T12-55-08Z.png
  gstack-ios/.cache/screenshots/watch-2026-05-16T12-55-08Z.png
report: gstack-ios/.cache/ios-watch-pair-2026-05-16T12-55-11Z.json

# typical next: critique the watch screen to verify it caught the sync:
$ /ios-visual-critique screenshots=[<final watch png>] \
    context="watch home glance, after phone sync nudge, expecting lastSyncAt to update"
```

