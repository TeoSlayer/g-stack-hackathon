# gstack-ios backlog

All 13 skill specs are drafted as of iter 2 (burst-draft turn). Status
column tracks dogfood maturity per `FRAMEWORK.md`:

- **draft** — protocol written, not yet dogfooded.
- **sharpening** — dogfooded 1–2 times, iterating on procedure.
- **stable** — dogfooded ≥3 times, output shape frozen.

## Skills

| # | Skill | Status | Dogfoods | Notes |
|---|---|---|---|---|
| 1 | `/ios-build` | sharpening | 1 | Foundation. Full-build path (steps 4–6) untested. |
| 2 | `/ios-xcodegen` | draft | 0 | Surfaced REFINEMENT-002 via design discussion. |
| 3 | `/ios-test` | draft | 0 | First dogfood will hit the no-tests meta-finding. |
| 4 | `/ios-simctl` | draft | 0 | Producer of screenshot/log artifacts. |
| 5 | `/ios-visual-critique` | draft | 0 | Reasons over screenshots — the "what looks fucked" skill. |
| 6 | `/ios-watch-pair` | draft | 0 | Verification harness for WCSession-class refinements. |
| 7 | `/ios-healthkit-seed` | draft | 0 | Deterministic HK fixtures. May surface "need app-side debug URL". |
| 8 | `/ios-widget-preview` | draft | 0 | Blocked on REFINEMENT-002 (widget needs a scheme). |
| 9 | `/ios-wiring-check` | draft | 0 | Should re-derive REFINEMENT-001 from scratch. |
| 10 | `/ios-signing-doctor` | draft | 0 | Diagnoses bg-delivery entitlement gap on free teams. |
| 11 | `/ios-screenshot-diff` | draft | 0 | Needs baselines; baselines emerge from human sign-off. |
| 12 | `/ios-perf-trace` | draft | 0 | First trace likely targets `syncAll` on launch. |
| 13 | `/ios-ship-testflight` | draft | 0 | Terminal skill. Gated on paid-team upgrade. |

## Composition graph (high-level)

```
/ios-xcodegen ──┐
                ▼
            /ios-build ──┬──► /ios-test ──┐
                         │                ├──► /ios-signing-doctor ──► /ios-ship-testflight
                         └──► /ios-simctl ┘
                                  │
                                  ├──► /ios-visual-critique
                                  ├──► /ios-screenshot-diff
                                  ├──► /ios-watch-pair ──► (verifies WCSession fixes)
                                  ├──► /ios-widget-preview
                                  ├──► /ios-perf-trace
                                  └──► /ios-healthkit-seed
                /ios-wiring-check ─── (independent; seeds REFINEMENTS)
```

## Dogfood priority order

The loop should dogfood in this order, oldest unblocked first:

1. `/ios-xcodegen` against health-sync (cheap, surfaces drift if any).
2. `/ios-wiring-check` against health-sync (cheap, re-derives REFINEMENT-001).
3. `/ios-build` full procedure (steps 4–6) against the HealthSync scheme.
4. `/ios-test` against health-sync (expected meta-finding: no tests).
5. `/ios-simctl boot + install + launch + screenshot` against health-sync.
6. `/ios-visual-critique` on the screenshot from #5.
7. `/ios-watch-pair` against health-sync (sets up WCSession verification).
8. `/ios-healthkit-seed` against health-sync (likely needs a REFINEMENT for
   app-side debug URL scheme first).
9. `/ios-perf-trace` on health-sync's `syncAll` on launch.
10. `/ios-signing-doctor` to re-derive bg-delivery entitlement diagnosis.
11. `/ios-widget-preview` once REFINEMENT-002 is fixed.
12. `/ios-screenshot-diff` after baselines emerge.
13. `/ios-ship-testflight` after paid-team upgrade.

## Promoted from REFINEMENTS

Skills that emerged from a health-sync finding rather than the original plan.

*(none yet)*
