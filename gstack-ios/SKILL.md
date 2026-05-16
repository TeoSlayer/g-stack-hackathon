---
name: gstack-ios
description: iOS / watchOS / WidgetKit skill pack for gstack — build, test, simulator orchestration, visual critique, signing, perf, ship.
---

# gstack-ios

iOS extension to gstack. Activates when work touches an Xcode project,
`.xcworkspace`, `project.yml`, Swift on Apple platforms, HealthKit, WatchKit,
WidgetKit, or any `xcrun simctl` flow. Each sub-skill is a self-contained
protocol — invokable on its own and composable with the others.

## Sub-skills

| Skill | When to reach for it |
|---|---|
| [`/ios-build`](skills/ios-build/SKILL.md) | Need a machine-checkable build signal. The gate before tests, ship, screenshots. |
| [`/ios-xcodegen`](skills/ios-xcodegen/SKILL.md) | `project.yml` was edited, or `pbxproj` drift is suspected. |
| [`/ios-test`](skills/ios-test/SKILL.md) | Run XCTest, get failures only with file:line. Surfaces a no-tests meta-finding when absent. |
| [`/ios-simctl`](skills/ios-simctl/SKILL.md) | Simulator lifecycle: boot, install, launch, screenshot, push, deep link, log capture. |
| [`/ios-visual-critique`](skills/ios-visual-critique/SKILL.md) | Structured critique of a captured screenshot — layout, contrast, truncation, empty states. |
| [`/ios-watch-pair`](skills/ios-watch-pair/SKILL.md) | Paired iPhone + Apple Watch simulators, both apps installed, both screens captured. |
| [`/ios-healthkit-seed`](skills/ios-healthkit-seed/SKILL.md) | Inject deterministic HealthKit samples into a simulator for repeatable tests. |
| [`/ios-widget-preview`](skills/ios-widget-preview/SKILL.md) | Headless widget rendering across families. |
| [`/ios-wiring-check`](skills/ios-wiring-check/SKILL.md) | Find defined-but-uncalled symbols — cross-target hooks, delegate methods, doc-promised entry points. |
| [`/ios-signing-doctor`](skills/ios-signing-doctor/SKILL.md) | Decode code-signing / provisioning failures into a single actionable diagnosis. |
| [`/ios-screenshot-diff`](skills/ios-screenshot-diff/SKILL.md) | Pixel diff against a baseline, with tolerance and region detection. |
| [`/ios-perf-trace`](skills/ios-perf-trace/SKILL.md) | Capture an Instruments trace and summarise hotspots, allocations, energy. |
| [`/ios-ship-testflight`](skills/ios-ship-testflight/SKILL.md) | Archive → validate → upload to TestFlight, poll processing. |

## Composition

The skills share a single cache directory — `gstack-ios/.cache/` — for
reports and artifacts. Skills downstream of a producer (e.g. `/ios-test`
downstream of `/ios-build`) read the cached report by stable filename and
refuse to run if the upstream signal is missing or stale.

A typical sprint flow:

```
/ios-xcodegen  →  /ios-build  →  /ios-test  →  /ios-signing-doctor  →  /ios-ship-testflight
                       │
                       └─→  /ios-simctl  →  /ios-visual-critique
                                        →  /ios-screenshot-diff
                                        →  /ios-watch-pair
                                        →  /ios-widget-preview
                                        →  /ios-perf-trace

/ios-wiring-check (independent — runs against the source tree directly)
/ios-healthkit-seed (parameter to any test or visual flow that reads HK)
```

## Report shape

Every skill writes a JSON report to `gstack-ios/.cache/` with a stable
filename. Reports always include:

- `skill` — the skill's name.
- `version` — major.minor.
- `ok` — boolean success flag.
- Skill-specific fields documented under each skill's **Outputs** section.

Reports are append-only over a run (stable filename means a re-run
overwrites the same file). They are gitignored.

## Install

Symlink this directory into Claude Code's skills root:

```sh
ln -s "$(pwd)/gstack-ios" ~/.claude/skills/gstack-ios
```

Restart Claude Code to pick up the new skill. After install, each sub-skill
is invokable as `/ios-build`, `/ios-test`, etc. from the prompt.
