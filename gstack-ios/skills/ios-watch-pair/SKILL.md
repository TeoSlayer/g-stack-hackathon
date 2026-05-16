---
name: ios-watch-pair
description: Boot paired iPhone + Apple Watch simulators, install both targets, screenshot both, drive cross-device interactions.
status: draft
version: 0.1
---

# /ios-watch-pair

## When to invoke

Whenever the work touches `WatchConnectivity`, paired-device flows, app
groups shared between phone + watch, or watchOS UI that depends on phone
state. Also the verification harness for any REFINEMENT that involves
WCSession (REFINEMENT-001 in health-sync is the motivating case).

Wrong call for watch-only flows that don't depend on the phone — boot a
watch simulator directly via `/ios-simctl` and save the pairing overhead.

## Inputs

Required:
- `phone_device` — name or UDID, default `iPhone 15`.
- `watch_device` — name or UDID, default `Apple Watch Series 10 (46mm)`.
- `phone_app_path` and `watch_app_path` — `.app` bundles to install.

Optional:
- `phone_bundle_id` / `watch_bundle_id` — for launch.
- `actions` — list of post-launch actions to run (e.g. `tap-sync-now`,
  `wait`, `screenshot`).
- `screenshot_interval_s` — periodically capture both devices during the
  session (default 0 = capture on demand only).

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
7. **Capture initial screenshots** (both devices) → `/ios-simctl screenshot`.
8. **For each action in `actions`:**
   - `tap-X` — out of scope for this skill (would require Appium / private
     `simctl`). Document the gap; for now, action `wait <secs>` is the only
     interaction primitive.
   - `wait <secs>` — sleep, then re-screenshot both.
   - `nudge-sync` — call `xcrun simctl openurl <watch> healthsync://sync-now`
     (assumes the app handles that URL scheme; if not, file a REFINEMENT).
9. **Compose report** referencing all screenshot artifacts.

## Outputs

Report (`gstack-ios/.cache/ios-watch-pair-<ts>.json`):
```json
{
  "skill": "ios-watch-pair", "version": "0.1",
  "phone": {"device": "iPhone 15 (UDID)", "state": "Booted",
            "bundle_id": "io.vulturelabs.healthsyncs",
            "screenshots": ["gstack-ios/.cache/screenshots/phone-1.png", ...]},
  "watch": {"device": "Apple Watch Series 10 (46mm) (UDID)", "state": "Booted",
            "bundle_id": "io.vulturelabs.healthsyncs.watchkitapp",
            "screenshots": ["gstack-ios/.cache/screenshots/watch-1.png", ...]},
  "pair_udid": "...",
  "actions_run": ["wait 5", "screenshot"],
  "ok": true
}
```

Side effects: simulator boot, install, pair-activate; screenshot files
under `gstack-ios/.cache/screenshots/`.

## Verification

- **Positive:** `pair_udid` present, both devices `Booted`, at least one
  screenshot per device, each screenshot ≥ 1 KB and not all-black.
- **Negative:** explicit failure naming which step broke (pair, boot, install,
  launch). Common: `pair` fails because the watch runtime mismatches the
  phone runtime — surface the version pair so caller can fix.
- **WCSession verification:** the skill does not verify activation by
  itself — instead, downstream check the captured os_log via `/ios-simctl log`
  with predicate `subsystem == "com.apple.WatchConnectivity"`.

## Composition

- **Upstream:** `/ios-build` (×2 schemes), `/ios-simctl boot/install/launch`.
- **Downstream:** `/ios-visual-critique` (reasons over both screenshots);
  `/ios-simctl log` (capture WCSession traffic).
- **Verifies:** REFINEMENT-001 fix in health-sync once landed.

## Dogfood log

*(none yet.)*
