---
name: ios-test
description: Run XCTest, return failures only with file:line, surface a meta-finding when no tests exist.
---

# /ios-test

## When to invoke

After `/ios-build` reports `ok: true`, whenever code that has tests has
changed, and as the gate before `/ios-ship-testflight`. Also when a build
*succeeds* but behaviour is suspected to have regressed — passing tests
pin down what you're not regressing.

Wrong call when no tests exist for the target (the skill will emit a
meta-finding, not a failure — useful information, but you don't need to
discover it twice). Wrong when you need an interactive debug session —
use Xcode directly.

## Inputs

Required:
- `workspace` — `.xcworkspace` path.
- `scheme` — scheme with a configured Test action.

Optional:
- `destination` — Xcode destination (defaults to scheme's primary
  simulator).
- `only_testing` — list of `TestTarget/TestClass/testMethod` strings to
  filter.
- `skip_testing` — inverse of above.
- `test_plan` — `.xctestplan` name to use instead of the scheme's default.

Assumes:
- `/ios-build` has been run recently (within minutes) for the same scheme
  + destination. If the cached report is missing or > 10 min old, invoke
  `/ios-build` first.

## Procedure

1. **Gate on build state.** Check
   `gstack-ios/.cache/ios-build-<scheme>-Debug.json`. If absent or stale,
   run `/ios-build` first; if that fails, abort with the build failure
   cited.
2. **Build for testing first** — this also discovers whether any test
   targets exist:
   ```
   xcodebuild build-for-testing \
     -workspace "$workspace" -scheme "$scheme" \
     -destination "$destination" \
     -derivedDataPath gstack-ios/.cache/derived-data/ 2>&1
   ```
   After this completes, look for `.xctestrun` files under
   `gstack-ios/.cache/derived-data/Build/Products/`. If none exist, the
   scheme has no test targets — emit the **no-tests meta-finding** and
   stop.

   The `.xctestrun` file is a plist listing every test bundle and the
   tests inside; `plutil -convert json -o - <file>` gives a parseable
   view of what would run.
3. **Run tests.**
   ```
   xcodebuild test -workspace ... -scheme ... -destination ... \
     -resultBundlePath gstack-ios/.cache/ios-test-<scheme>.xcresult \
     2>&1 | tee build.log
   ```
4. **Parse.** Prefer the `.xcresult` bundle
   (`xcrun xcresulttool get --format json`) over log scraping — the bundle
   has structured failure metadata. Extract:
   - Total / passed / failed / skipped counts.
   - For each failure: test name, file path, line number, message.
   - Wall-clock duration.
5. **Emit report.**

## Outputs

Report (`gstack-ios/.cache/ios-test-<scheme>.json`):
```json
{
  "skill": "ios-test",
  "version": "0.1",
  "workspace": "<abs>",
  "scheme": "<str>",
  "ok": true,
  "no_tests": false,
  "totals": {"total": 12, "passed": 11, "failed": 1, "skipped": 0},
  "duration_s": 4.7,
  "failures": [
    {"test": "AppTests.testReadinessUnknownPath",
     "file": "<abs>", "line": 24,
     "message": "XCTAssertEqual failed: expected .unknown, got .green"}
  ],
  "result_bundle": "<path to .xcresult>"
}
```

**No-tests meta-finding** — when no tests exist:
```json
{"skill": "ios-test", "no_tests": true,
 "meta_finding": "Scheme has no XCTest targets configured. Add a test
                  target and at least one test before /ios-test can
                  produce a real signal."}
```

**Side effects:**
- `.xcresult` bundle written to `gstack-ios/.cache/`.
- Simulator boots if not already running.

## Verification

- **Positive:** `ok: true` AND `failures: []` AND `totals.total > 0`.
- **Negative:** `ok: false` AND `failures` non-empty AND every failure
  has a real file:line.
- **Sanity:** `totals.passed + totals.failed + totals.skipped ==
  totals.total`.
- **Meta:** `no_tests: true` is a successful invocation that surfaces a
  project gap, not a tool failure.

## Composition

- **Upstream:** `/ios-build` (gate).
- **Downstream:** `/ios-ship-testflight` (refuses to ship with failures).
- **Pairs with:** `/ios-screenshot-diff` (visual regression is a kind of
  test that doesn't fit XCTest's text-mode failure model).
