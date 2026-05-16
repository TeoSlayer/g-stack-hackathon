---
name: ios-visual-critique
description: Structured critique of a simulator screenshot — surfaces layout, contrast, truncation, missing assets, empty states, accessibility issues.
---

# /ios-visual-critique

## When to invoke

Right after `/ios-simctl screenshot` (or `/ios-widget-preview`, or
`/ios-watch-pair`) when you want a structured, machine-and-human-readable
critique of what's wrong on the captured frame. Catches the things that
build-clean and tests-pass don't surface — text clipped at the edge,
contrast too low, an empty state where data should be, an icon that
didn't load, a widget that overflowed its background.

This is **not** pixel diffing. Use `/ios-screenshot-diff` for regression
checks against a known-good baseline. This is open-ended critique: given
this screen, what's wrong?

Wrong call when there's no baseline AND the surface is totally unfamiliar
(no design intent) — without *any* expectation, the critique becomes
vibes. Provide at least a one-line context like "Status hero on the
iOS app's Status tab during a sync".

## Inputs

Required:
- `screenshots` — list of one or more PNG paths. The skill reads each as
  an image input via the `Read` tool.

Optional but strongly recommended:
- `context` — string describing what the screen should show. E.g. "Trends
  tab showing 30-day HRV with a 7-day forecast tail". Without it, the
  critique falls back to generic "is this a reasonable iOS screen?".
- `design_intent` — path to a reference image / mock the screen is meant
  to match. Enables comparative critique.
- `severity_filter` — drop issues below `critical | major | minor | nit`.
  Default: report all.

Assumes:
- Vision-capable LLM access (the current Claude session). The skill is
  executed by reading the image via the `Read` tool and reasoning.

## Procedure

1. **Verify inputs.** Each screenshot path exists, is a readable PNG
   ≥ 1 KB, dimensions plausibly matching a known device (iPhone 15:
   1179×2556, Apple Watch 46mm: 416×496, etc.). Flag unexpected dimensions
   as a `meta_finding`.
2. **Read each image** with the `Read` tool — the runtime renders it
   visually for the agent.
3. **Run the critique checklist** per image. For each item, decide
   present/absent and (if a problem) severity:
   - **Truncation:** text cut off at the right or bottom edge of a
     container.
   - **Overlap:** elements visually colliding.
   - **Contrast:** body text on background failing roughly WCAG AA
     (4.5:1). Estimate, don't measure.
   - **Off-screen content:** scrollable indicator showing but no scroll
     position, OR critical info below the fold without a hint.
   - **Empty state:** a section blank where data was expected (informed
     by `context`).
   - **Loading state:** spinners visible after expected work should have
     completed.
   - **Missing/broken assets:** placeholder icons, blank image rects,
     "image-not-found" glyphs.
   - **Typography:** mixed weights/sizes in a single label, suspicious
     line-breaks.
   - **Layout:** misaligned baselines, inconsistent padding between
     similar elements.
   - **Locale:** hardcoded strings in non-target locale, RTL misalignment.
   - **Accessibility hints:** small touch targets (< ~44pt), missing
     label for an icon-only button.
4. **For each finding,** record:
   - `id` — stable within this invocation, e.g. `F-1`.
   - `severity` — `critical | major | minor | nit`.
   - `category` — one of the checklist categories above.
   - `where` — described location.
   - `problem` — one sentence.
   - `evidence` — what visually triggered the finding.
   - `suggested_fix` — one sentence, optional.
5. **Apply severity filter** if given.
6. **Compose the report.** Include a one-line headline:
   `"7 findings: 1 critical, 3 major, 3 minor"`.

## Outputs

Report (`gstack-ios/.cache/ios-visual-critique-<timestamp>.json`):
```json
{
  "skill": "ios-visual-critique",
  "version": "0.1",
  "screenshots": ["gstack-ios/.cache/screenshots/..."],
  "context": "Status tab during sync",
  "headline": "3 findings: 1 critical, 2 minor",
  "findings": [
    {"id": "F-1", "severity": "critical", "category": "missing_assets",
     "where": "Status hero, leading icon",
     "problem": "App icon is the generic SwiftUI placeholder.",
     "evidence": "Light-grey square with 'system' glyph in the icon position.",
     "suggested_fix": "Wire AppIcon asset catalogue."}
  ],
  "ok": true
}
```

Also emits a human-readable Markdown sibling
(`gstack-ios/.cache/ios-visual-critique-<timestamp>.md`) so the report is
readable without `jq`.

**Side effects:** the two report files only.

## Verification

- **Positive:** `ok: true`, every finding has all required fields, every
  `where` references an element plausibly visible in the screenshot.
- **"Looks clean" case:** `findings: []` with an explanatory note in
  `headline` ("no issues at this severity threshold"). Don't fabricate
  findings to pad the list.
- **Negative:** `ok: false` only when input verification failed (bad path,
  unreadable file). A critique that surfaces 0 findings is still
  `ok: true`.
- **Anti-vibes guard:** every finding must cite specific visual
  `evidence`. Findings without evidence are dropped in step 4.

## Composition

- **Upstream:** `/ios-simctl screenshot`, `/ios-watch-pair` (phone +
  watch), `/ios-widget-preview` (N families), `/ios-screenshot-diff` (the
  diff visualisation itself can be critiqued).
- **Downstream:** humans, and `/ios-screenshot-diff` — a critique can
  promote a "regression" diff into a "regression with context".
- **Pairs with:** `/ios-test` — XCTest catches logic; this catches the
  layer XCTest can't see.
