# gstack-ios

A gstack extension that adds iOS / watchOS / WidgetKit refinement skills.

gstack ships a strong general-purpose sprint loop (Think → Plan → Build → Review
→ Test → Ship → Reflect). The iOS edges of that loop are where things get
rough: `xcodebuild` output is unparseable wall-of-text, simulators need
orchestration, HealthKit-shaped tests need synthetic data, paired-watch flows
need both sims booted, widget previews need their own dance, signing fails
silently. None of that is gstack's job — it's iOS's. gstack-ios fills the gap.

## What this actually is

A **framework for refinement** expressed as a set of skills. Each skill is a
reusable protocol with a canonical shape (see [`FRAMEWORK.md`](FRAMEWORK.md)):
when to invoke it, what it consumes, the procedure it runs, what it produces,
how the output is verified, and how it composes with other skills.

The skills are the durable artifact. The dogfood target —
[`../health-sync/`](../health-sync/) — is where each skill is proved against
real code. Every iteration of this directory's loop must produce both:

1. A sharpened skill spec.
2. A concrete change (or filed finding) in `health-sync/` that the skill surfaced.

If a skill can't earn its keep on health-sync, it doesn't ship.

## Planned skills

| # | Skill | Refines |
|---|---|---|
| 1 | `/ios-build` | xcodebuild noise → structured errors / warnings / timing |
| 2 | `/ios-xcodegen` | `project.yml` ↔ `.xcodeproj` drift |
| 3 | `/ios-test` | XCTest output → failures only, file:line |
| 4 | `/ios-simctl` | simulator boot / install / screenshot |
| 5 | `/ios-watch-pair` | paired iPhone + Watch sims running both targets |
| 6 | `/ios-healthkit-seed` | inject synthetic HK samples for deterministic tests |
| 7 | `/ios-widget-preview` | render widget timeline snapshots headlessly |
| 8 | `/ios-wiring-check` | finds defined-but-uncalled cross-target hooks |
| 9 | `/ios-signing-doctor` | provisioning / cert failure diagnosis |
| 10 | `/ios-screenshot-diff` | SwiftUI snapshot regression |
| 11 | `/ios-perf-trace` | Instruments trace + summary |
| 12 | `/ios-ship-testflight` | archive → IPA → upload |

Status of each tracked in [`BACKLOG.md`](BACKLOG.md).

## The loop

This directory runs as a self-development loop. Each iteration:

1. Reads `LOOP.md` for state, picks the next skill from `BACKLOG.md`.
2. Drafts or sharpens its `skills/<name>/SKILL.md` against the framework template.
3. Dogfoods the protocol on `health-sync/` and files findings to
   `../health-sync/REFINEMENTS.md`.
4. Optionally fixes one filed refinement (a separate, smaller act than
   defining the skill).
5. Commits, pushes, updates `LOOP.md` and `BACKLOG.md`.
6. Schedules the next iteration via `ScheduleWakeup`.

The loop stops when `BACKLOG.md` has no pending skills *and*
`health-sync/REFINEMENTS.md` has no pending findings.

## Install (deferred)

The skills are markdown specs. A future iteration will add an install hook into
`~/.claude/skills/gstack-ios/` so they become `/ios-build`-style slash commands.
Until then they're executed by reading the SKILL.md and following its procedure
verbatim — which is also how their reusability gets stress-tested.

## License

AGPL-3.0-or-later, matching the parent repo.
