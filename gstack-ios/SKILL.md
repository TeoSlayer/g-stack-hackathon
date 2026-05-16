---
name: gstack-ios
description: iOS / watchOS / WidgetKit skill pack for Claude Code — build, test, simulator orchestration, visual critique, signing, perf, ship. Interactive or headless.
---

# gstack-ios

iOS extension to gstack. Activates when work touches an Xcode project,
`.xcworkspace`, `project.yml`, Swift on Apple platforms, HealthKit,
WatchKit, WidgetKit, or any `xcrun simctl` flow. Each sub-skill is a
self-contained protocol — invokable on its own, composable with the
others, and runnable interactively from the prompt or headlessly via
`bin/headless`.

## Sub-skills

| Skill | When to reach for it |
|---|---|
| [`/ios-loop`](skills/ios-loop/SKILL.md) | Multi-step goal. Plans + executes a chain end-to-end. The headless entry point. |
| [`/ios-build`](skills/ios-build/SKILL.md) | Need a machine-checkable build signal. Gate before tests, ship, screenshots. |
| [`/ios-xcodegen`](skills/ios-xcodegen/SKILL.md) | `project.yml` was edited, or pbxproj drift is suspected. |
| [`/ios-test`](skills/ios-test/SKILL.md) | Run XCTest, get failures only with file:line. Surfaces a no-tests meta-finding when absent. |
| [`/ios-simctl`](skills/ios-simctl/SKILL.md) | Simulator lifecycle: boot, install, launch, screenshot, push, deep link, log capture. |
| [`/ios-visual-critique`](skills/ios-visual-critique/SKILL.md) | Structured critique of a captured screenshot — layout, contrast, truncation, empty states. |
| [`/ios-watch-pair`](skills/ios-watch-pair/SKILL.md) | Paired iPhone + Apple Watch simulators, both apps installed, both screens captured. |
| [`/ios-widget-preview`](skills/ios-widget-preview/SKILL.md) | Headless widget rendering across families. |
| [`/ios-wiring-check`](skills/ios-wiring-check/SKILL.md) | Find defined-but-uncalled symbols — cross-target hooks, delegate methods, doc-promised entry points. |
| [`/ios-signing-doctor`](skills/ios-signing-doctor/SKILL.md) | Decode code-signing / provisioning failures into a single actionable diagnosis. |
| [`/ios-screenshot-diff`](skills/ios-screenshot-diff/SKILL.md) | Pixel diff against a baseline, with tolerance and region detection. |
| [`/ios-perf-trace`](skills/ios-perf-trace/SKILL.md) | Capture an Instruments trace and summarise hotspots, allocations, energy. |
| [`/ios-ship-testflight`](skills/ios-ship-testflight/SKILL.md) | Archive → validate → upload to TestFlight, poll processing. |

## Two ways to run

### Interactive — from the Claude Code prompt

After `./install.sh`, every sub-skill is invokable as a slash command:

```
/ios-build
/ios-test
/ios-simctl action=screenshot
/ios-visual-critique screenshots=[…] context="Status tab during sync"
```

Most skills auto-discover workspace, scheme, destination, and device
from cwd — zero args is the common case. Override only when discovery
would pick the wrong thing.

### Headless — from a shell or CI

`bin/headless "<goal>"` wraps `/ios-loop` in `claude --print` and runs
the whole chain unattended:

```sh
gstack-ios/bin/headless "verify App"
gstack-ios/bin/headless "ship App to TestFlight"
gstack-ios/bin/headless "find dead wiring"
```

Exit `0` on `goal_achieved`, `1` on any other stop. The script halts on
findings that need human input (rotate a profile, fix code, add a test
target) and surfaces the next action — perfect for CI gates where
"halts cleanly for human" is the correct CI failure mode.

## Composition

Skills share a single cache directory — `gstack-ios/.cache/` — for
reports and artifacts. Downstream skills read upstream reports by
stable filename and refuse to run when the upstream signal is missing
or stale.

A typical sprint flow:

```
                    /ios-loop  ◄── headless entry point
                        │
   /ios-xcodegen  →  /ios-build  →  /ios-test  →  /ios-signing-doctor  →  /ios-ship-testflight
                        │
                        └─→  /ios-simctl  →  /ios-visual-critique
                                         →  /ios-screenshot-diff
                                         →  /ios-watch-pair
                                         →  /ios-widget-preview
                                         →  /ios-perf-trace

   /ios-wiring-check (independent — runs against the source tree directly)
```

Each skill ends its SKILL.md with an **On failure → next step** map.
`/ios-loop` reads those maps to traverse failures into recoveries
without needing a hand-written orchestrator.

## Report shape

Every skill writes a JSON report to `gstack-ios/.cache/` with a stable
filename. Reports always include:

- `skill` — the skill's name.
- `version` — major.minor.
- `ok` — boolean success flag.
- Skill-specific fields documented under each skill's **Outputs**
  section.

Reports are append-only over a run (stable filename means a re-run
overwrites the same file). The cache is gitignored.

## Install

```sh
./install.sh
```

Symlinks `gstack-ios/` to `~/.claude/skills/gstack-ios/` and each
sub-skill into `~/.claude/skills/<sub-skill>/` so they appear as
top-level slash commands. Editing this repo is reflected immediately —
no rebuild step.
