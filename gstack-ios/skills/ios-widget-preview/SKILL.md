---
name: ios-widget-preview
description: Render widget timeline entries to PNG headlessly across all supported families.
---

# /ios-widget-preview

## When to invoke

After any change to a `Widget`, `TimelineEntry`, or widget view code.
Catches widget-only regressions (overflows, family-specific layouts)
without a full host-app rebuild + reinstall + "add widget" gesture cycle.
Pairs with `/ios-visual-critique` to reason about the rendered output, and
with `/ios-screenshot-diff` to regression-test families.

Wrong call when the widget reads live data from an app group and the
group hasn't been seeded — the preview will show empty states regardless
of the widget's correctness. Run `/ios-healthkit-seed` (or app-group
seeding) first.

## Inputs

Required:
- `workspace` — Xcode workspace.
- `widget_scheme` — scheme that builds the widget extension. **The widget
  must have a standalone scheme** — without one, this skill can't target
  it. (Add a scheme entry to your `project.yml` or in Xcode's manage
  schemes dialog.)

Optional:
- `families` — list from `systemSmall`, `systemMedium`, `systemLarge`,
  `systemExtraLarge`, `accessoryCircular`, `accessoryRectangular`,
  `accessoryInline`. Default: all the widget declares support for.
- `timeline_entries` — JSON list of synthetic entry data. Default: ask
  the widget for its `Provider.placeholder` output.
- `device` — simulator for the host app group; default `iPhone 15`.

Assumes:
- The widget extension can be loaded standalone. iOS 17+ widgets
  generally can; older may require the host app installed first.

## Procedure

1. **Build the widget scheme** via `/ios-build`. Gate on `ok: true`.
2. **Install host app + widget** on the simulator (widgets ride along
   with the host app's `.app` bundle).
3. **Boot the simulator** and launch the host app once to register the
   widget bundle.
4. **For each family,** render via one of these paths in order of
   preference:
   - **SwiftUI #Preview macro** — if the widget's view exposes
     `#Preview(as: .systemSmall)` etc., use `xcrun swift package preview`
     (Xcode 16+) to render to PNG. This is the cleanest path when the
     project opts in.
   - **Snapshot test target** — if the project has a snapshot test
     target wired (e.g. via `swift-snapshot-testing`), invoke that test
     plan via `/ios-test` and pull the resulting reference images. The
     snapshot test is the closest thing iOS has to a first-party
     headless widget renderer.
   - **Manual simulator capture (fallback).** Boot the sim, add the
     widget to the home screen via UI scripting (`xcrun simctl ui ...`
     where available), screenshot the home screen, crop to the widget
     bounds. Document this path as fragile — touch coordinates change
     per device size.

   Capture the rendered PNG to
   `gstack-ios/.cache/widget-previews/<scheme>-<family>-<ts>.png`.
   Verify PNG dimensions match the family's expected size (e.g.
   `systemMedium` on iPhone 15 ≈ 338×158pt × scale).
5. **Compose report.** Flag the path used per family so callers know
   how reliable each rendered image is.

## Outputs

Report (`gstack-ios/.cache/ios-widget-preview-<scheme>-<ts>.json`):
```json
{
  "skill": "ios-widget-preview", "version": "0.1",
  "scheme": "AppWidget",
  "families_requested": ["systemSmall", "systemMedium"],
  "families_rendered": {
    "systemSmall": {"png": "gstack-ios/.cache/widget-previews/...",
                    "size": [170, 170], "ok": true},
    "systemMedium": {"png": "...", "size": [364, 170], "ok": true}
  },
  "failures": [],
  "ok": true
}
```

**Side effects:** PNGs written under `gstack-ios/.cache/widget-previews/`.

## Verification

- **Positive:** all requested families in `families_rendered`, each PNG
  exists and matches expected pixel size (±2%).
- **Negative:** `failures` lists each family that didn't render with the
  reason. Common: widget extension crashed on `placeholder()` — surface
  the crash log via `/ios-simctl log`.
- **Cross-check:** invoke `/ios-visual-critique` on the rendered PNGs with
  context `"<family> widget snapshot"`. If critique surfaces a finding,
  this skill's output is `ok: true` but with the critique IDs annotated.

## Composition

- **Upstream:** `/ios-build` (widget scheme), `/ios-simctl
  install/launch`, optionally `/ios-healthkit-seed` for data.
- **Downstream:** `/ios-visual-critique`, `/ios-screenshot-diff`.

## On failure → next step

- `Provider.placeholder()` crashed → fix the crash. The widget extension
  *must* be safe in the placeholder path; iOS calls it before any user
  interaction.
- Rendered PNG dimensions wrong → the widget container size doesn't
  match the family; check `supportedFamilies` and any
  `containerBackground` modifiers.
- Empty/black PNG → host app didn't register the widget bundle. Make
  sure step 3 (launch the host app once) actually completed.
- No widget scheme exists → add one in `project.yml`, regenerate via
  `/ios-xcodegen`, retry.

## Example

```
$ /ios-widget-preview widget_scheme=AppWidget

discovered: workspace=App.xcworkspace, families=[systemSmall, systemMedium]
build via /ios-build AppWidget... ok
install host app on iPhone 15... ok
launch host app to register widget bundle... ok

rendering systemSmall via SwiftUI #Preview path...
  ✓ gstack-ios/.cache/widget-previews/AppWidget-systemSmall-...png 170x170
rendering systemMedium via SwiftUI #Preview path...
  ✓ gstack-ios/.cache/widget-previews/AppWidget-systemMedium-...png 364x170

report: gstack-ios/.cache/ios-widget-preview-AppWidget-2026-05-16T13-05-00Z.json

# typical next: critique each rendered family:
$ /ios-visual-critique \
    screenshots=[<systemSmall png>, <systemMedium png>] \
    context="App widget snapshots — small + medium families, recent-sync data"
```

