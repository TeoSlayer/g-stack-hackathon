# Loop state

This file is the loop's only state. Each iteration reads it, acts, rewrites it.

## Current iteration

**N:** 3 (next to run)
**Mode:** dogfooding (all 13 skill specs drafted; next phase is exercising them)

## Iteration 2 outcome (2026-05-16, burst-draft turn)

**Pivot:** the loop's original cadence was one-skill-per-iteration with
immediate dogfood. User redirected: build ALL skill specs first, dogfood
second. Burst-drafted 12 new skills in a single turn:

- `/ios-xcodegen`, `/ios-test`, `/ios-simctl`, `/ios-visual-critique` (new
  skill — reasons over screenshots to surface UI problems),
  `/ios-watch-pair`, `/ios-healthkit-seed`, `/ios-widget-preview`,
  `/ios-wiring-check`, `/ios-signing-doctor`, `/ios-screenshot-diff`,
  `/ios-perf-trace`, `/ios-ship-testflight`.

All conform to `FRAMEWORK.md` (When / Inputs / Procedure / Outputs /
Verification / Composition / Dogfood log).

`/ios-visual-critique` is the user-requested addition: take screenshots
during sim progression, structured critique of UI problems. Producer
skills (`/ios-simctl`, `/ios-watch-pair`, `/ios-widget-preview`,
`/ios-screenshot-diff`) emit the screenshots; this skill consumes them.

No new health-sync REFINEMENTS this iter — the skill specs themselves
*are* the deliverable. Existing REFINEMENT-001 and REFINEMENT-002 carry
forward.

## Next iteration's mandate (iteration 3)

Mode is **dogfooding**. Pick the top unblocked item from
`BACKLOG.md`'s "Dogfood priority order" — `/ios-xcodegen` against
`../health-sync/`. Steps:

1. Read `gstack-ios/skills/ios-xcodegen/SKILL.md`.
2. Execute its Procedure verbatim against `../health-sync/`:
   - `cp health-sync/HealthSync.xcodeproj/project.pbxproj /tmp/pbxproj.before`
   - `cd health-sync && xcodegen generate --spec project.yml`
   - `diff -u /tmp/pbxproj.before health-sync/HealthSync.xcodeproj/project.pbxproj`
   - Classify drift per the skill's category list.
3. Write report JSON to `gstack-ios/.cache/ios-xcodegen-health-sync.json`.
4. If `drift == "real"`, file REFINEMENT-003 in `health-sync/REFINEMENTS.md`
   describing the drift. If `drift == "harmless"` or `"none"`, the dogfood
   entry is still valuable — proves the project is in sync.
5. `git checkout health-sync/HealthSync.xcodeproj/project.pbxproj` to leave
   the working tree clean (skill defaults to `validate` mode).
6. Add a dogfood entry to `skills/ios-xcodegen/SKILL.md` (replace the
   "none yet" placeholder).
7. Update `BACKLOG.md`: `/ios-xcodegen` → `sharpening`, increment dogfoods
   to 1.
8. Rewrite this file (LOOP.md) for iteration 4.
9. Commit (one logical change), push.
10. Schedule iteration 4 via `ScheduleWakeup`. Delay: 270s.

## Subsequent iterations

Iter 4: `/ios-wiring-check` against health-sync — should re-derive
REFINEMENT-001 from scratch. If it doesn't, the skill's false-positive
filters are too aggressive — sharpen.

Iter 5: `/ios-build` full procedure (steps 4–6). Likely 5–10 minutes wall
time for a cold build. Schedule with 1200s delay to absorb the build wait
in one cache miss instead of N small ones.

Iter 6: `/ios-test` against health-sync. Expected outcome: `no_tests:
true` meta-finding. File REFINEMENT-004 ("add first XCTest target") in
response.

Iter 7: `/ios-simctl boot + install + launch + screenshot` → produces
the first artifact for iter 8.

Iter 8: `/ios-visual-critique` on iter 7's screenshot. First real test of
the critique skill — context will be "Status tab on cold launch, expecting
[X]". Findings get filed.

Iter 9+: continue down BACKLOG dogfood priority order.

## Stop conditions

- Every row in `BACKLOG.md` is `stable` (≥3 dogfoods each) AND
- `../health-sync/REFINEMENTS.md` has no `status: open` entries.

Or: user explicitly halts the loop.

## Cadence

- Active iteration (next skill is cheap to dogfood): 270s (in-cache).
- Waiting on a full build / Instruments trace / TestFlight upload:
  1200s+.
- Idle / no immediate work: 1800s.

## Invariants

- One logical change per commit.
- Each iteration sharpens at least one skill AND produces at least one
  filed finding OR fix. If only one happens, next iteration finishes it
  before picking new work.
- Never break health-sync's main build. Revert and re-schedule if it
  happens.
- Never edit `~/.claude/` from inside the loop.
- Don't touch `pilot-swift/` — someone else's working tree state lives
  there.

## Open framework questions

*(file meta-issues here so the loop doesn't stall on doc churn)*

- **Baseline-promotion skill missing.** `/ios-screenshot-diff` assumes
  baselines exist but there's no skill to promote a current screenshot
  to baseline status. Likely future addition: `/ios-baseline-promote`.
  Not blocking — first few dogfoods of `/ios-screenshot-diff` can use
  manually committed baselines.
- **`/ios-healthkit-seed` plist-patch fragility.** The third fallback path
  (direct SQLite injection) is documented but discouraged. If the first
  two paths fail repeatedly, this is the skill that needs sharpening, not
  health-sync.
- **Install hook for skills.** Currently SKILL.md files are executed by
  an agent reading them. A future iteration may install them under
  `~/.claude/skills/gstack-ios/` so they become real `/slash-commands`.
  Deferred until skills are mostly `stable`, per the LOOP invariant
  "Never edit `~/.claude/` from inside the loop" — that install would
  be a user-confirmed step, not a loop action.
