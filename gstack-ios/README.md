# gstack-ios

iOS / watchOS / WidgetKit skill pack for [gstack](https://github.com/garrytan/gstack).

gstack ships a strong general-purpose sprint loop (Think → Plan → Build →
Review → Test → Ship → Reflect). The iOS edges of that loop are where things
get rough: `xcodebuild` output is unparseable wall-of-text, simulators need
orchestration, HealthKit-shaped tests need synthetic data, paired-watch flows
need both sims booted, widget previews need their own dance, signing fails
silently. gstack-ios fills the gap as a peer skill pack.

## Skills

| Skill | Purpose |
|---|---|
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

Each skill is a single `SKILL.md` under `skills/<name>/` and conforms to the
same shape: **When to invoke**, **Inputs**, **Procedure**, **Outputs**,
**Verification**, **Composition**. The Outputs section pins a JSON schema
that downstream skills consume — so skills compose without negotiation.

## Install

```sh
git clone <this-repo>
ln -s "$(pwd)/gstack-ios" ~/.claude/skills/gstack-ios
```

Restart Claude Code. Skills are then invokable as `/ios-build`,
`/ios-test`, etc. The entry point is [`SKILL.md`](SKILL.md), which routes
to the relevant sub-skill based on the work in front of you.

## Requirements

- macOS with Xcode (any version ≥ 15).
- `xcodegen` for projects that use it (`brew install xcodegen`).
- `ripgrep` for `/ios-wiring-check` (`brew install ripgrep`).
- ImageMagick for `/ios-screenshot-diff` (`brew install imagemagick`) —
  falls back to Pillow if absent.
- App Store Connect API key for `/ios-ship-testflight`.

## Cache layout

All skill reports and artifacts live under `gstack-ios/.cache/`:

```
gstack-ios/.cache/
├── ios-build-<scheme>-<config>.json
├── ios-test-<scheme>.json + .xcresult/
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

## License

AGPL-3.0-or-later.
