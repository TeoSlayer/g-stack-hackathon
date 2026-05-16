# gstack-ios backlog

Ordered by impact for health-sync refinement. Top item is what the next
iteration picks up unless `LOOP.md` says otherwise.

| # | Skill | Status | Notes |
|---|---|---|---|
| 1 | `/ios-build` | sharpening (1 dogfood) | Foundation: nothing else is verifiable without a clean build signal. Full-build procedure exercised in iter 2+. |
| 2 | `/ios-xcodegen` | pending | health-sync uses xcodegen; project.yml drift is the most common silent regression. |
| 3 | `/ios-test` | pending | health-sync currently has no tests — this skill includes "where would the first test go" framing. |
| 4 | `/ios-simctl` | pending | Required before `/ios-watch-pair`, `/ios-healthkit-seed`, `/ios-widget-preview`. |
| 5 | `/ios-watch-pair` | pending | Paired sim orchestration. WatchConnectivity bugs are the #1 reason health-sync iter findings will stack up. |
| 6 | `/ios-healthkit-seed` | pending | Deterministic HK fixtures. Without this, every test depends on whatever the sim happens to have. |
| 7 | `/ios-widget-preview` | pending | Headless widget snapshot. Catches widget-only regressions without an Xcode round-trip. |
| 8 | `/ios-wiring-check` | pending | Greps for defined-but-uncalled cross-target hooks. The WCSessionBridge bug is the motivating example. |
| 9 | `/ios-signing-doctor` | pending | Provisioning / cert failure decoder. Defer until we hit it. |
| 10 | `/ios-screenshot-diff` | pending | SwiftUI snapshot regression. Pairs with `/ios-widget-preview`. |
| 11 | `/ios-perf-trace` | pending | Instruments trace summariser. Useful once health-sync has been profiled at least once. |
| 12 | `/ios-ship-testflight` | pending | Archive → IPA → upload. Final stage, depends on signing-doctor. |

## How to update this file

- When an iteration starts work on a skill, change `pending` → `draft (iter N)`.
- When dogfooded once, `draft` → `sharpening`.
- When dogfooded 3+ times and output shape stable, `sharpening` → `stable`.
- New skill ideas go at the bottom unless they unblock something higher up.

## Promoted from REFINEMENTS

Skills that emerged from a health-sync finding (rather than the original plan)
get added here with a note pointing at the finding. Keeps the framework
honest — if we never need a skill, we never write it.

*(none yet)*
