---
name: ios-healthkit-seed
description: Seed a simulator's HealthKit store with deterministic synthetic samples for repeatable tests.
status: draft
version: 0.1
---

# /ios-healthkit-seed

## When to invoke

When developing or testing any flow that reads from HealthKit and needs a
known input state — sync logic, time-series math, readiness/model computation,
anchored-query paging, calorie/distance aggregation. Also when reproducing a
user-reported bug that depends on specific sample shapes (e.g. "HRV reading
of exactly 17ms broke the readiness band classifier").

Wrong call against a real device (HK writes from a synthetic source aren't
attributable to a recognised app — won't show in Health). Simulator only.

## Inputs

Required:
- `device` — name or UDID of a booted simulator with HK available
  (iOS 16+ sim).
- `bundle_id` — the app whose HKHealthStore should see the samples.
- `samples` — list of `{type, value, unit, start_utc, end_utc, metadata?}`.

Or alternatively:
- `preset` — a named preset (e.g. `health-baseline-30d`,
  `hrv-recovery-stress-cycle`, `workout-week`) that expands to a sample list.

Assumes:
- The app has been launched once and granted HK read+write authorisation
  for the relevant types (HK won't accept writes before auth).
- The simulator is booted.

## Procedure

HealthKit on simulator has no first-party seeding API. There are three
viable paths; this skill tries them in order:

1. **App-driven write.** If the app exposes a debug URL scheme like
   `healthsync://debug/seed-hk?preset=baseline-30d`, invoke it via
   `xcrun simctl openurl`. The app handles the write under its own auth.
   *Most reliable; requires app cooperation.*
2. **Helper-app injection.** If the project includes a `HealthKitSeeder`
   debug-only app target, install + launch it with a JSON payload via a
   stdin-style URL (`healthkitseeder://seed?data=...`). The helper writes,
   then exits.
3. **Plist patch (last resort).** Locate
   `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/AppGroup/<...>/Health/healthdb.sqlite`
   and inject rows directly. Document as fragile — Apple's schema is
   undocumented and changes per iOS version. Surface as a `warning` in
   the report.

For each viable path, generate the samples deterministically: same `preset`
+ same seed → same output. Use a fixed PRNG seed (e.g. SHA256 of `preset`)
so reruns are byte-equivalent.

After write, **verify via anchored query** — the same query the app uses
should return the seeded samples. Do this by invoking the app's debug URL
`healthsync://debug/count-hk?type=hrv` or by reading the app's logs.

## Outputs

Report (`gstack-ios/.cache/ios-healthkit-seed-<ts>.json`):
```json
{
  "skill": "ios-healthkit-seed", "version": "0.1",
  "device": "...", "bundle_id": "...",
  "path_used": "app-driven|helper-app|plist-patch",
  "seeded": {"hrv": 30, "rhr": 30, "steps": 30, "sleep": 30, "workout": 4},
  "verified": {"hrv": 30, ...},
  "drift": [], "ok": true,
  "warnings": ["plist-patch is fragile; consider adding a debug URL scheme to the app"]
}
```

`drift` lists any `(type, requested, observed)` triples where the
post-seed query returned a different count than was inserted.

Side effects: writes to the simulator's HealthKit store. Persistent across
sim reboots; cleared by `xcrun simctl erase <UDID>`.

## Verification

- **Positive:** `drift: []` AND `verified` totals match `seeded`.
- **Negative:** non-empty `drift` — caller should not trust dependent
  test results until resolved.
- **Path-degraded warning:** `path_used == "plist-patch"` is `ok: true` but
  every subsequent invocation should re-check schema compatibility.

## Composition

- **Upstream:** `/ios-simctl boot`, `/ios-simctl install`, `/ios-simctl launch`
  (app must be running to grant HK auth on first invocation).
- **Downstream:** `/ios-test` (HK-dependent tests rely on this for
  determinism); `/ios-visual-critique` after a sync (so the screenshot has
  real-looking data not "no data yet" empty states).

## Dogfood log

*(none yet. First dogfood likely requires adding a debug URL scheme to
health-sync — file as a REFINEMENT under "dx" severity.)*
