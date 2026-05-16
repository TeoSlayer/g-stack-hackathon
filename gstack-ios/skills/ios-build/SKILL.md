---
name: ios-build
description: Build an Xcode workspace/scheme and emit a structured report of errors, warnings, timing, and compiled-file count.
---

# /ios-build

## When to invoke

When you need a **machine-checkable build-status signal** — after any source
change, before any skill that assumes a buildable artifact (`/ios-test`,
`/ios-screenshot-diff`, `/ios-ship-testflight`), or as the first probe when
investigating an opaque "it doesn't work" report.

Wrong call when you only need a syntax check (`swift build` is lighter for
SPM-only sources), you're chasing a runtime crash (`/ios-perf-trace` or
`/ios-simctl` log capture), or the project hasn't been generated yet (run
`/ios-xcodegen` first).

## Inputs

All inputs are optional — the skill autodiscovers from cwd and falls back
on sensible defaults. Pass an arg only when discovery would pick the
wrong thing.

- `workspace` — path to `.xcworkspace`. Default: first `.xcworkspace`
  found at `find . -maxdepth 2 -name "*.xcworkspace"`. If none exists,
  falls back to the first `.xcodeproj` and switches to `-project` mode.
- `scheme` — Default: first scheme listed by `xcodebuild -list`
  (excluding Pods/dependency schemes). If only one scheme exists, no
  arg is needed.
- `destination` — Default: derived from the scheme's target platform.
  iOS → `generic/platform=iOS Simulator`; watchOS →
  `generic/platform=watchOS Simulator`; macOS →
  `generic/platform=macOS`.
- `configuration` — `Debug` (default) or `Release`.
- `derived_data` — Default: project-local `build/` (must be gitignored).
- `clean` — bool, default `false`. If true, runs `clean` before `build`.

Assumes:
- cwd is the project root or a subdirectory of it.
- `xcodebuild` on PATH.
- `xcbeautify` optional — used if present, raw output otherwise.

## Procedure

1. **Verify workspace.** `test -d "$workspace"` — fail fast if absent. If
   only `.xcodeproj` exists, downgrade to `-project` mode.
2. **Check generator drift.** If `project.yml` exists and its mtime is
   newer than `<scheme>.xcodeproj/project.pbxproj`, emit a warning. Recommend
   `/ios-xcodegen` but do not auto-invoke.
3. **List + validate schemes.**
   ```
   xcodebuild -list -workspace "$workspace"
   ```
   Parse the `Schemes:` block. If `$scheme` not in the list, fail with the
   list shown — most "build fails" are actually scheme typos.
4. **Build.**
   ```
   xcodebuild \
     -workspace "$workspace" \
     -scheme "$scheme" \
     -destination "$destination" \
     -configuration "$configuration" \
     -derivedDataPath "$derived_data" \
     build 2>&1 | tee "$derived_data/build.log"
   ```
   Capture exit code via `${PIPESTATUS[0]}`.
5. **Parse `build.log`.**
   - **Errors with location:** lines matching
     `^(.+):(\d+):(\d+): error: (.+)$` → `{file, line, column, message}`.
   - **Errors without location** (linker, signing, etc.): lines matching
     `^(error|ld|clang)(:| ): (.+)$` that didn't already match above →
     `{file: null, line: null, message}`. Don't drop these — they're the
     usual cause of "build failed but no clear error" reports.
   - **Warnings:** lines matching `^(.+):(\d+):(\d+): warning: (.+)$`,
     same shape as located errors. Categorise via message prefix:
     `deprecated` → `deprecation`, `implicit use of 'self'` →
     `implicit-self`, `Sendable` → `sendable`, `unused` → `unused`, else
     `other`.
   - **Compiled files:** count lines matching
     `^(SwiftCompile|CompileSwift|CompileC|CompileXIB|CompileStoryboard)\b`.
     Modern Xcode uses `SwiftCompile`; older verbose output uses
     `CompileSwift`. Both forms count.
   - **Duration:** parse the elapsed time from xcodebuild's trailer
     (`** BUILD SUCCEEDED **` / `** BUILD FAILED **` followed by a time);
     fallback to measured wall-clock.
6. **Emit report.** Write JSON to
   `gstack-ios/.cache/ios-build-<scheme>-<config>.json`. Echo a one-line
   summary to stdout:
   `✓ HealthSync (Debug, iOS sim): 51 files, 0 errors, 3 warnings, 42.1s`.

## Outputs

Report (`gstack-ios/.cache/ios-build-<scheme>-<config>.json`):

```json
{
  "skill": "ios-build",
  "version": "0.1",
  "timestamp_utc": "<ISO-8601>",
  "workspace": "<absolute path>",
  "scheme": "<string>",
  "destination": "<string>",
  "configuration": "Debug|Release",
  "ok": true,
  "duration_s": 42.1,
  "compiled_files": 51,
  "errors": [
    {"file": "<abs>", "line": 12, "column": 3, "message": "..."}
  ],
  "warnings": [
    {"file": "<abs>", "line": 24, "column": 5, "message": "...",
     "category": "deprecation"}
  ],
  "drift_warning": null,
  "log_path": "<abs to build.log>"
}
```

Field order is stable; new fields go at the end with sensible defaults.

**Side effects:**
- Writes `<derived_data>/build.log`.
- Writes the JSON report to `gstack-ios/.cache/`.
- Populates `<derived_data>/Build/` with build products.

## Verification

- **Positive:** `ok == true` AND `errors == []` AND exit code 0 AND
  `compiled_files > 0`. The last clause guards against no-op builds where
  Xcode short-circuits everything as up to date.
- **Negative:** `ok == false` AND `errors` non-empty AND the first error's
  `file` exists on disk. If `ok == false` and `errors == []`, the parser
  is broken — flag loudly.
- **Sanity:** `duration_s > 0` AND `log_path` readable.

## Composition

- **Upstream:** `/ios-xcodegen` — run first if step 2 raises a drift
  warning.
- **Downstream:** `/ios-test` (gates on `ok: true`), `/ios-screenshot-diff`,
  `/ios-ship-testflight` (also requires `configuration == "Release"`),
  `/ios-wiring-check` (reads warnings for `unused` entries).
- **Peers:** invoke once per scheme.

## On failure → next step

- If `ok: false` and `errors[].category == "code-signing"` or any error
  mentions provisioning / entitlements → `/ios-signing-doctor`.
- If `ok: false` and step 2 raised a drift warning → `/ios-xcodegen` to
  regenerate, then re-run.
- If `ok: false` and no errors are surfaced in the parser → the parser
  itself is wrong; read `log_path` directly and file a skill bug.
- If `ok: true` but `compiled_files == 0` → previous build is already
  up-to-date for the given config; run with `clean: true` to force.

## Example

Zero-arg invocation against a typical project:

```
$ /ios-build
discovered: workspace=App.xcworkspace, scheme=App,
            destination=generic/platform=iOS Simulator
building...
✓ App (Debug, iOS sim): 87 files, 0 errors, 3 warnings, 51.4s
report: gstack-ios/.cache/ios-build-App-Debug.json
```

A failing build:

```
$ /ios-build scheme=AppRelease configuration=Release
✗ AppRelease (Release, iOS sim): 12 files, 2 errors, 0 warnings, 8.1s
errors:
  App/HealthSync.swift:142:9: error: cannot find 'HealthStore' in scope
  App/SyncEndpoint.swift:24:14: error: extra argument 'metadata' in call
next: read the report at gstack-ios/.cache/ios-build-AppRelease-Release.json,
      then fix and re-run.
```

