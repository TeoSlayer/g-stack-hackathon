---
name: ios-loop
description: Autonomous orchestrator — given a goal, plans and executes a chain of gstack-ios skills until done or human action is required.
---

# /ios-loop

## When to invoke

When you have a goal that requires multiple skills in sequence — "verify
this project", "ship to TestFlight", "find and fix dead wiring", "what
does the Status tab look like and is anything broken?". The loop figures
out which skills to chain, reads each one's JSON report, and decides
what comes next based on the per-skill "On failure → next step" maps.

Also the entry point for headless / CI runs. The same goal-driven chain
runs identically inside an interactive Claude Code session or under
`gstack-ios/bin/headless "<goal>"` outside it.

Wrong call for atomic operations — if you already know which one skill
you need, invoke it directly. The loop is for multi-step goals.

## Inputs

Required:
- `goal` — one-sentence statement of what done looks like.

Optional:
- `max_steps` — bound on chain length. Default `20`.
- `dry_run` — if true, plan but don't execute. Default `false`.
- `stop_on_human` — if true, halt when a skill returns a finding
  requiring human action (rotate profile, fix code, add test target).
  Default `true`. Set false in CI when you want a hard failure on
  human-action signals.
- `cache_max_age_s` — re-use cached skill reports younger than this.
  Default `300` (5 minutes). Set to 0 to force re-runs.

## Procedure

1. **Match the goal** against known patterns:

   | Goal pattern | Chain |
   |---|---|
   | "verify" / "health check" / "is X ready" | xcodegen → build → test → signing-doctor |
   | "ship" / "release" / "to testflight" | xcodegen → build (Release) → test → signing-doctor → ship-testflight |
   | "find dead wiring" / "audit unused" | wiring-check |
   | "screenshot X" / "what does X look like" | simctl screenshot → visual-critique |
   | "regression" / "did anything visually change" | build → simctl screenshot → screenshot-diff → visual-critique |
   | "trace perf" / "why is X slow" | simctl launch → perf-trace → visual-critique |
   | "set up watch" / "test wcsession" | build (×2) → watch-pair → simctl log |

   If the goal doesn't match a known pattern, fall back to:
   *"Read gstack-ios/SKILL.md's Composition section. Pick the skill
   whose 'When to invoke' best matches the goal. Run it. Follow its
   'On failure → next step' map. Repeat."*
2. **Execute each skill** in the planned chain. After each:
   - Read its JSON report from `gstack-ios/.cache/`.
   - If `ok: true` → continue to the next planned skill.
   - If `ok: false` → look up the failure category in the just-run
     skill's "On failure → next step" map and pivot to the named skill.
     Insert it into the chain.
   - If the report flags a `requires_human` condition and
     `stop_on_human: true` → halt and report.
3. **Stop conditions:**
   - The chain's terminal skill returned `ok: true`.
   - `stop_on_human` halt triggered.
   - `max_steps` reached.
   - **Loop detection:** if a skill has run twice in this chain and is
     about to run again with no inputs changed, halt — the recovery
     map is circular for this goal state, which is a skill bug to
     surface.
4. **Emit unified report.** One JSON file summarising the whole chain,
   each step's exit state, the artefacts produced, and the stop reason.

## Outputs

Report (`gstack-ios/.cache/ios-loop-<ts>.json`):
```json
{
  "skill": "ios-loop", "version": "0.1",
  "goal": "ship App to TestFlight",
  "plan": ["ios-xcodegen", "ios-build", "ios-test",
           "ios-signing-doctor", "ios-ship-testflight"],
  "steps": [
    {"skill": "ios-xcodegen",        "ok": true,  "elapsed_s": 1.2,
     "report": "gstack-ios/.cache/ios-xcodegen-App.json"},
    {"skill": "ios-build",           "ok": true,  "elapsed_s": 51.4,
     "report": "gstack-ios/.cache/ios-build-App-Release.json"},
    {"skill": "ios-test",            "ok": true,  "elapsed_s": 7.2,
     "report": "gstack-ios/.cache/ios-test-App.json"},
    {"skill": "ios-signing-doctor",  "ok": true,  "elapsed_s": 0.8,
     "report": "gstack-ios/.cache/ios-signing-doctor-...json"},
    {"skill": "ios-ship-testflight", "ok": true,  "elapsed_s": 295.1,
     "report": "gstack-ios/.cache/ios-ship-testflight-...json"}
  ],
  "stopped_because": "goal_achieved",
  "ok": true
}
```

`stopped_because` is one of: `goal_achieved`, `human_action_required`,
`max_steps`, `loop_detected`, `skill_unrecoverable`.

## On stop_reason → next step

- `goal_achieved` → nothing to do. Read the report for confirmation.
- `human_action_required` → read the last step's report for the exact
  action. Once done, re-run `/ios-loop` with the same goal; cached
  upstream reports mean only the failed step + downstream re-run.
- `max_steps` → the chain is longer than expected. Inspect the steps
  and either raise `max_steps` or split the goal into smaller goals.
- `loop_detected` → a recovery map points back to a skill that already
  failed the same way. File this as a skill bug — the recovery map
  needs a terminal exit, not a loop.

## Composition

- **Calls:** any of the other gstack-ios sub-skills, in any order, based
  on goal-matching and recovery-map traversal.
- **Read by:** humans (interactive mode); `bin/headless` (CI mode).
- **Pairs with:** every sub-skill — they're the executors; this is the
  planner.

## Example

**Interactive — one-call ship:**

```
$ /ios-loop goal="ship App to TestFlight"
matched plan: ios-xcodegen → ios-build (Release) → ios-test →
              ios-signing-doctor → ios-ship-testflight

step 1: ios-xcodegen        ✓ 1.2s   drift=harmless
step 2: ios-build (Release) ✓ 51.4s  87 files, 0 errors, 3 warnings
step 3: ios-test            ✓ 7.2s   14 passed, 0 failed
step 4: ios-signing-doctor  ✓ 0.8s   diagnosis empty
step 5: ios-ship-testflight ✓ 295.1s VALID

✓ goal achieved (5 steps, 355.7s total)
report: gstack-ios/.cache/ios-loop-2026-05-16T13-40-00Z.json
```

**Interactive — failure that requires human:**

```
$ /ios-loop goal="ship App to TestFlight"
step 1: ios-xcodegen        ✓
step 2: ios-build (Release) ✗ code-signing error
  → pivoting to ios-signing-doctor per failure map
step 3: ios-signing-doctor  finding: missing_entitlement
                            (HK background-delivery, paid-team-only)

⏸ stopped: human_action_required
read: gstack-ios/.cache/ios-signing-doctor-...json
once resolved, re-run `/ios-loop goal="ship App to TestFlight"`
```

**Headless from a shell:**

```sh
$ gstack-ios/bin/headless "verify App"
# wraps /ios-loop in `claude --print` and exits 0 on goal_achieved.
```
