---
name: ios-simctl
description: Simulator lifecycle — boot, install, launch, screenshot, push, deep-link, terminate, log capture.
---

# /ios-simctl

## When to invoke

Whenever you need to drive a simulator from outside Xcode — install an app
into a known state, capture a screenshot for visual review, deliver a test
push, open a deep link, scrape `os_log` output. Also the producer for the
screenshot artifacts that `/ios-visual-critique` and `/ios-screenshot-diff`
consume.

Wrong call when the simulator is already running an interactive Xcode
debug session — driving it from outside will fight the debugger. Wait
until the debugger is paused or detached.

## Inputs

Required:
- `action` — one of: `boot`, `shutdown`, `install`, `uninstall`, `launch`,
  `terminate`, `screenshot`, `push`, `url`, `log`, `state`.

Action-dependent:
- `device` — name or UDID. Default: first available `iPhone 15` for iOS
  actions, `Apple Watch Series 10 (46mm)` for watchOS actions. Resolved
  via `xcrun simctl list devices`.
- `app_path` — `.app` bundle path for `install`.
- `bundle_id` — `com.example.app` for `launch`, `terminate`, `push`, `url`.
- `payload` — APNs JSON payload for `push`.
- `link` — URL for `url`.
- `log_predicate` — `os_log` predicate string for `log`, e.g.
  `subsystem == "com.example.app"`.
- `out` — output path for `screenshot` or `log`. Default:
  `gstack-ios/.cache/screenshots/<device>-<timestamp>.png` or
  `gstack-ios/.cache/logs/<device>-<timestamp>.log`.

Assumes:
- `xcrun simctl` on PATH.
- Sufficient disk under `~/Library/Developer/CoreSimulator/`.

## Procedure

Each action maps to one or two `xcrun simctl` invocations:

1. `boot`:
   ```
   xcrun simctl boot "$device"
   open -a Simulator    # surfaces UI; safe to omit for headless
   ```
   Wait until `xcrun simctl list devices | grep "$device" | grep -q
   "Booted"`.
2. `install`: `xcrun simctl install "$device" "$app_path"`.
3. `launch`:
   ```
   xcrun simctl launch --console-pty "$device" "$bundle_id"
   ```
   Capture PID from stderr for later screenshot/log gating.
4. `screenshot`:
   ```
   mkdir -p gstack-ios/.cache/screenshots
   xcrun simctl io "$device" screenshot --type=png "$out"
   ```
   Verify file > 1 KB (small files indicate Black Screen Of Boot).
5. `push`:
   ```
   echo "$payload" > /tmp/push.json
   xcrun simctl push "$device" "$bundle_id" /tmp/push.json
   ```
6. `url`: `xcrun simctl openurl "$device" "$link"`.
7. `log`:
   ```
   xcrun simctl spawn "$device" log show --last 5m \
     --predicate "$log_predicate" --style ndjson > "$out"
   ```
8. `state`: `xcrun simctl list devices --json` filtered for `$device`.

After every state-changing action, capture a screenshot to
`gstack-ios/.cache/screenshots/` and reference it in the report — so
`/ios-visual-critique` can pick up the trail without a separate
invocation.

## Outputs

Report (`gstack-ios/.cache/ios-simctl-<action>-<timestamp>.json`):
```json
{
  "skill": "ios-simctl",
  "version": "0.1",
  "action": "launch",
  "device": "<name> (<UDID>)",
  "device_state": "Booted",
  "ok": true,
  "artifacts": {
    "screenshot": "gstack-ios/.cache/screenshots/...",
    "log": "gstack-ios/.cache/logs/...",
    "pid": 12345
  },
  "elapsed_s": 1.4
}
```

**Side effects:**
- Simulator state changes (boot, install, etc.). Enumerated under `action`.
- Files written: screenshot PNG, log NDJSON. All under
  `gstack-ios/.cache/`.

## Verification

- **Positive:** `ok: true`, expected artifact exists, device state
  reflects the action.
- **Negative:** explicit error from simctl bubbled up verbatim. Common
  failures: `device not booted` (run `boot` first), `Operation timed out`
  (simulator wedged — `xcrun simctl shutdown all && xcrun simctl erase
  all` as last resort, with explicit user confirmation).
- **Screenshot sanity:** PNG > 1 KB AND not all-black (compare first/last
  pixel — all-black indicates boot in progress).

## Composition

- **Upstream:** `/ios-build` (need a built `.app` to install).
- **Downstream:** `/ios-visual-critique` (consumes screenshots);
  `/ios-screenshot-diff` (consumes screenshots vs baseline).
- **Used by:** `/ios-watch-pair` invokes this twice (phone + watch);
  `/ios-widget-preview` invokes this with a widget-specific URL scheme.

## On failure → next step

- `Operation timed out` → simulator is wedged. Try `xcrun simctl
  shutdown all && xcrun simctl erase <UDID>` (ask before erasing —
  destroys all installed apps and their data).
- `Unable to find a device matching` → spelled the device wrong;
  `xcrun simctl list devices available` shows what's actually installed.
- `Failed to install: invalid bundle` → bundle was built for the wrong
  architecture/destination; re-run `/ios-build` with the matching
  destination.
- Screenshot is all-black → device finished `boot` but the app isn't
  drawing yet. `wait 2` and re-screenshot.

## Example

```
$ /ios-simctl action=screenshot bundle_id=com.example.app
discovered: device=iPhone 15 (booted)
xcrun simctl io <UDID> screenshot --type=png \
  gstack-ios/.cache/screenshots/iPhone-15-2026-05-16T12-50-00Z.png
✓ screenshot captured: 1179x2556, 412 KB
```

Full boot → install → launch → screenshot sequence:

```
$ /ios-simctl action=boot device="iPhone 15"
$ /ios-simctl action=install app_path=build/.../App.app
$ /ios-simctl action=launch bundle_id=com.example.app
✓ launched: PID 14872
$ /ios-simctl action=screenshot
✓ gstack-ios/.cache/screenshots/iPhone-15-...png

# pipe to visual critique:
$ /ios-visual-critique screenshots=[<that path>] context="App home tab"
```

