# Loop state

This file is the loop's only state. Each iteration reads it, acts, rewrites it.

## Current iteration

**N:** 2 (next to run)
**Working on:** `/ios-xcodegen` (skill #2 from BACKLOG.md)

## Iteration 1 outcome (2026-05-16)

**Did:**
- Scaffolded `gstack-ios/` with `README.md`, `FRAMEWORK.md`, `BACKLOG.md`,
  `LOOP.md`.
- Drafted `skills/ios-build/SKILL.md` to conform to `FRAMEWORK.md`.
- Dogfooded `/ios-build` step 3 (scheme discovery) against `health-sync/` —
  ran `xcodebuild -list -workspace HealthSync.xcworkspace`, surfaced two schemes
  vs. three targets.
- Seeded `health-sync/REFINEMENTS.md` with two findings:
  - **REFINEMENT-001:** `WCSessionBridge.publishStatus` is dead code (manual,
    motivates `/ios-wiring-check`).
  - **REFINEMENT-002:** `HealthSyncWidget` has no standalone scheme
    (`/ios-build`-surfaced, motivates `/ios-xcodegen` work and unblocks the
    future `/ios-widget-preview`).
- Marked `/ios-build` as `sharpening` (one dogfood entry).
- Added `gstack-ios/.cache/` to root `.gitignore`.

**Did not do** (intentional — next iteration):
- Run a full `xcodebuild build` (procedure steps 4–6). Deferred to keep iter 1
  focused on protocol definition; iter 2 of `/ios-build` (or iter 2 of the
  loop running `/ios-xcodegen`) can exercise the full procedure once the
  widget-scheme refinement is in.
- Fix any of the filed refinements. Fixes are separate, smaller commits — the
  skill that catches each finding should exist before the fix lands, so the
  fix-loop has a verifiable signal.

## Next iteration's mandate (iteration 2)

1. Read `BACKLOG.md`. `/ios-build` should be `sharpening`. `/ios-xcodegen`
   should be `pending` — promote to `draft (iter 2)`.
2. Create `gstack-ios/skills/ios-xcodegen/SKILL.md` conforming to
   `FRAMEWORK.md`. The protocol's core: regenerate from `project.yml`, diff
   the resulting `project.pbxproj` against the committed one, classify drift
   as "harmless" (whitespace, ordering) or "real" (added/removed targets,
   changed build settings).
3. Dogfood it on `health-sync/`:
   - Run `xcodegen generate` in `health-sync/`.
   - `git diff --stat HealthSync.xcodeproj/project.pbxproj` — capture the
     drift.
   - If drift is non-empty, file as `REFINEMENT-003` (note: drift, not bug —
     could legitimately be a generator-vs-edited-by-hand divergence the
     user chose to make).
   - If drift is empty, the skill still earns a dogfood entry: it proved
     "project is in sync with project.yml", which is non-trivial information.
4. Add a dogfood entry to `skills/ios-xcodegen/SKILL.md`.
5. **Do not** auto-commit the regenerated pbxproj — that's the user's call.
   Reset any drift from the working tree after recording the finding:
   `git checkout HealthSync.xcodeproj/project.pbxproj`.
6. Update `BACKLOG.md` (`/ios-xcodegen` → `sharpening`), this `LOOP.md`,
   commit, push, schedule iteration 3.

## Subsequent iterations

After iter 2: `/ios-test` (skill #3). The skill should also surface that
health-sync has *no* tests — so the first dogfood is a meta-finding ("nothing
to test") that motivates writing a first test as part of REFINEMENTS.

Iter 4: `/ios-simctl`. Iter 5: `/ios-watch-pair`. Each iteration produces one
sharpened skill + one finding (or fix) in health-sync. Iter 5 unblocks the
REFINEMENT-001 fix (because `/ios-watch-pair` lets us verify the WCSession
status push actually reaches the Watch).

## Stop conditions

- Every row in `BACKLOG.md` is `stable`, AND
- `../health-sync/REFINEMENTS.md` has no `status: open` entries.

Or: user explicitly halts the loop.

## Cadence

- Active iteration (just committed, picking up next skill immediately): 270s
  (stays in cache TTL).
- Waiting on a long-running build / sim boot: 1200s+.
- Idle: 1800s.

## Invariants

- One logical change per commit.
- Each iteration sharpens at least one skill spec AND produces at least one
  filed finding or fix. If only one of those happens, the iteration is
  incomplete and the next one finishes it before picking new work.
- Never break health-sync's main build. Revert and re-schedule if it happens.
- Never edit `~/.claude/` from inside the loop.
