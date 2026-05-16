# gstack-ios

iOS / watchOS / WidgetKit skill pack for [gstack](https://github.com/garrytan/gstack).

gstack ships a strong general-purpose sprint loop (Think → Plan → Build →
Review → Test → Ship → Reflect). The iOS edges of that loop are where
things get rough: `xcodebuild` output is unparseable wall-of-text,
simulators need orchestration, HealthKit-shaped tests need synthetic
data, paired-watch flows need both sims booted, widget previews need
their own dance, signing fails silently. gstack-ios fills the gap as a
peer skill pack with **interactive + headless** modes.

## Install

```sh
git clone <this-repo>
cd gstack-ios
./install.sh
```

Symlinks the pack into `~/.claude/skills/gstack-ios/` and each
sub-skill into `~/.claude/skills/<sub-skill>/`. Restart Claude Code (or
just open a new session) — the slash commands appear in the picker.

## Two modes

### Interactive

Type a slash command in any Claude Code session:

```
/ios-build
/ios-simctl action=screenshot
/ios-visual-critique screenshots=[…] context="Status tab during sync"
/ios-loop goal="verify App"
```

Most skills auto-discover workspace / scheme / destination / device —
zero args is the common case.

### Headless (CI, scripts, agent loops)

```sh
gstack-ios/bin/headless "verify App"
gstack-ios/bin/headless "ship App to TestFlight"
gstack-ios/bin/headless "find dead wiring"
```

`bin/headless` wraps `/ios-loop` in `claude --print` and runs the chain
unattended. Exits `0` on `goal_achieved`, `1` on any other stop. Halts
cleanly when a finding needs human input — surfaces the next action so
the CI log says exactly what to do.

## Skills

| Skill | Purpose |
|---|---|
| `/ios-loop` | Goal-driven orchestrator. Plans the chain, executes it, follows recovery maps. |
| `/ios-build` | xcodebuild → structured errors / warnings / timing |
| `/ios-xcodegen` | regenerate `.xcodeproj` from `project.yml`, classify drift |
| `/ios-test` | XCTest → failures only with file:line |
| `/ios-simctl` | boot / install / launch / screenshot / push / url / log |
| `/ios-visual-critique` | structured critique over a screenshot — layout, contrast, truncation, empty states |
| `/ios-watch-pair` | paired iPhone + Watch sims, both apps, both screens |
| `/ios-healthkit-seed` | deterministic HK sample injection |
| `/ios-widget-preview` | headless widget rendering across families |
| `/ios-wiring-check` | dead / contract-broken declarations |
| `/ios-signing-doctor` | identity × profile × entitlement diagnosis |
| `/ios-screenshot-diff` | pixel diff with tolerance + region detection |
| `/ios-perf-trace` | Instruments trace + per-template summary |
| `/ios-ship-testflight` | archive → validate → upload → poll |

Each skill is a single `SKILL.md` under `skills/<name>/` and follows
the same shape: **When to invoke**, **Inputs**, **Procedure**,
**Outputs**, **Verification**, **Composition**, **On failure → next
step**, **Example**. JSON output schemas are stable so downstream
skills compose without negotiation.

## Requirements

- macOS with Xcode (any version ≥ 15).
- `xcodegen` for projects that use it (`brew install xcodegen`).
- `ripgrep` for `/ios-wiring-check` (`brew install ripgrep`).
- ImageMagick for `/ios-screenshot-diff` (`brew install imagemagick`).
- App Store Connect API key for `/ios-ship-testflight`.
- Claude Code itself (`claude` on PATH) for headless mode.

## Cache layout

All skill reports and artifacts live under `gstack-ios/.cache/`:

```
gstack-ios/.cache/
├── ios-build-<scheme>-<config>.json
├── ios-test-<scheme>.json + .xcresult/
├── ios-loop-<ts>.json
├── ios-simctl-<action>-<ts>.json
├── ios-visual-critique-<ts>.json + .md
├── ios-watch-pair-<ts>.json
├── ios-healthkit-seed-<ts>.json
├── ios-widget-preview-<scheme>-<ts>.json
├── ios-wiring-check-<ts>.json
├── ios-signing-doctor-<ts>.json
├── ios-screenshot-diff-<ts>.json
├── ios-perf-trace-<ts>.json + .trace/
├── ios-ship-testflight-<ts>.json + .xcarchive/ + .ipa
├── screenshots/
├── logs/
├── diffs/
├── widget-previews/
└── traces/
```

The cache is gitignored. Reports are overwritten by re-runs (stable
filename); timestamped artifacts accumulate until cleaned manually.

## Uninstall

```sh
rm ~/.claude/skills/gstack-ios
for s in build xcodegen test simctl visual-critique watch-pair \
         healthkit-seed widget-preview wiring-check signing-doctor \
         screenshot-diff perf-trace ship-testflight loop; do
  rm -f "$HOME/.claude/skills/ios-$s"
done
```

## License

AGPL-3.0-or-later.
