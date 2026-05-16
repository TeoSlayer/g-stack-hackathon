---
name: ios-perf-trace
description: Capture an Instruments trace and summarize hotspots, allocations, or energy events per template.
---

# /ios-perf-trace

## When to invoke

When a flow is slow, drains battery, hangs the main thread, or holds
onto memory. Specifically: build is green, tests pass, the screen looks
right, but the *experience* is bad. Also as a baseline-capture before a
performance-sensitive refactor, so the next run has a comparison point.

Wrong call as a first probe — most "slow" reports turn out to be "the
server is slow", "the network is slow", or "tests are slow because the
sim is cold". Run a quick targeted measurement first; only reach for
this skill when the bottleneck is plausibly on-device.

## Inputs

Required:
- `target` — one of:
  - `attach <bundle_id>` — attach to a running app.
  - `launch <bundle_id> <args...>` — launch fresh and trace from start.
- `template` — Instruments template name. Common: `Time Profiler`,
  `Allocations`, `Leaks`, `Energy Log`, `SwiftUI`, `Hangs`. Default:
  `Time Profiler`.
- `device` — name/UDID. Default: first booted simulator. Real devices
  supported via UDID.

Optional:
- `duration_s` — capture window. Default `30`.
- `out` — path for the `.trace` bundle. Default
  `gstack-ios/.cache/traces/<bundle_id>-<template>-<ts>.trace`.

Assumes:
- `xctrace` on PATH (`xcrun xctrace version`).
- For a real device target, the device is paired and trusted.

## Procedure

1. **Confirm template available.** `xcrun xctrace list templates` — fail
   fast if `$template` not listed.
2. **Capture.**
   ```
   xcrun xctrace record \
     --template "$template" \
     --device "$device" \
     --time-limit ${duration_s}s \
     --output "$out" \
     <attach_or_launch_args>
   ```
3. **Export structured data.** Discover the schemas available in this
   trace first — they vary per Instruments template and per Xcode
   version:
   ```
   xcrun xctrace export --input "$out" --toc
   ```
   then export the relevant tables:
   ```
   xcrun xctrace export \
     --input "$out" \
     --xpath '/trace-toc/run/data/table[@schema="<schema>"]' \
     --output /tmp/trace-export.xml
   ```
   Common schemas: `time-profile`, `time-sample`, `allocations`,
   `energy-usage`, `core-animation-fps`. If a requested schema isn't in
   the TOC, skip it gracefully — Xcode versions differ.

   Parse the XML by schema. Normalise into a common summary shape.
4. **Summarise per template:**
   - **Time Profiler:** top 10 symbols by self-time and inclusive-time;
     main-thread hangs > 250ms with stack; total CPU time.
   - **Allocations:** total allocs, peak heap, top 10 allocation sites,
     persistent allocations at end (candidate leaks).
   - **Energy Log:** wakeups/s, CPU active %, network bytes, location
     ticks. Anything > Apple's "thermal good" thresholds gets flagged.
   - **Hangs:** every hang ≥ 250ms with stack.
5. **Emit report.**

## Outputs

Report (`gstack-ios/.cache/ios-perf-trace-<ts>.json`):
```json
{
  "skill": "ios-perf-trace", "version": "0.1",
  "target": "com.example.app",
  "template": "Time Profiler",
  "duration_s": 30, "device": "iPhone 15 (UDID)",
  "trace_path": "<abs>",
  "summary": {
    "template_specific": {
      "top_symbols": [
        {"name": "HKAnchoredObjectQuery.execute", "self_ms": 4200,
         "inclusive_ms": 4800, "thread": "main"}
      ],
      "main_thread_hangs": [
        {"start_s": 12.4, "duration_ms": 380,
         "top_frame": "JSONSerialization.data"}
      ]
    }
  },
  "alerts": [
    {"severity": "major", "detail": "Main-thread JSON serialisation of
     ~60MB payload at 12.4s. Move encoding off the main actor."}
  ],
  "ok": true
}
```

`alerts` is the actionable distillation — caller files these as issues.

**Side effects:** `.trace` bundle (large, gigabytes possible) under
`gstack-ios/.cache/traces/`. Gitignored.

## Verification

- **Positive:** `ok: true` AND `summary.template_specific` non-empty AND
  `trace_path` is a readable `.trace` bundle.
- **Negative:** `xctrace` errors surface verbatim. Common: "could not
  attach: process not found" (bundle ID isn't running), "trace template
  not found".
- **Anti-noise:** alerts are gated on per-template thresholds; an
  empty-alerts report on a hot screen means the thresholds are too loose
  (skill bug, not project bug).

## Composition

- **Upstream:** `/ios-simctl boot/install/launch` (for the launchable
  target).
- **Downstream:** issues describing each alert. Pair with `/ios-test`
  if the perf issue can be regression-pinned.
- **Pairs with:** `/ios-visual-critique` — low FPS often shows up as
  visual artefacts in screenshots taken at the same moment.
