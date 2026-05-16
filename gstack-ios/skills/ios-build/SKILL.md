---
name: ios-build
description: Build an Xcode workspace/scheme and emit a structured report of errors, warnings, timing, and compiled-file count.
status: draft
version: 0.1
---

# /ios-build

## When to invoke

The right call when you need a **machine-checkable build-status signal** that
another skill or human can consume. Specifically: after any source change
that hasn't been verified, before any skill that assumes a buildable artifact
(`/ios-test`, `/ios-screenshot-diff`, `/ios-ship-testflight`), and as the
first probe when investigating an opaque "it doesn't work" report.

Wrong call when: you only need a syntax check (use SourceKit / `swift build`
for SPM-only sources), you're chasing a runtime crash (use `/ios-perf-trace`
or `/ios-simctl` for logs), or the project doesn't have a workspace yet
(invoke `/ios-xcodegen` first).

## Inputs

Required:
- `workspace` — path to `.xcworkspace`. If only a `.xcodeproj` exists, the
  skill switches to `-project` and notes it in the report.
- `scheme` — one of the schemes returned by `xcodebuild -list`. The skill
  validates this before building.

Optional:
- `destination` — Xcode destination string. Default: `generic/platform=iOS Simulator`
  for iOS schemes, `generic/platform=watchOS Simulator` for watchOS schemes.
  Detect by reading the scheme's primary target platform.
- `configuration` — `Debug` (default) or `Release`.
- `derived_data` — explicit path. Default: project-local `build/` (must already
  be in `.gitignore`).
- `clean` — bool, default `false`. If true, runs `clean` before `build`.

Assumes:
- cwd is the project root containing the workspace/project.
- `xcodebuild` on PATH (verified via `which xcodebuild`).
- `xcbeautify` optional — used if present, raw output otherwise.

## Procedure

1. **Verify workspace.** `test -d "$workspace"` — fail fast with a clear
   message if absent. If only `.xcodeproj` exists at the same root, downgrade
   to `-project` mode and note it.

2. **Check generator drift.** If `project.yml` exists and its mtime is newer
   than `<scheme>.xcodeproj/project.pbxproj`, emit a warning that the project
   may be stale. Recommend `/ios-xcodegen` but don't auto-invoke (composition
   stays explicit).

3. **List + validate schemes.**
   ```
   xcodebuild -list -workspace "$workspace"
   ```
   Parse the `Schemes:` block. If `$scheme` not in the list, fail with the
   list shown — most "build fails" are actually "scheme typo".

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
   - **Errors:** lines matching `^(.+):(\d+):(\d+): error: (.+)$` → `{file, line, column, message}`.
   - **Warnings:** lines matching `^(.+):(\d+):(\d+): warning: (.+)$` →
     `{file, line, column, message, category}`. Categorise via message prefix:
     `deprecated` → `deprecation`, `implicit use of 'self'` → `implicit-self`,
     `Sendable` → `sendable`, `unused` → `unused`, else `other`.
   - **Compiled files:** count occurrences of `^CompileSwift ` and `^CompileC `.
   - **Duration:** parse the trailer (`** BUILD SUCCEEDED **` / `** BUILD FAILED **`)
     and the elapsed time printed by xcodebuild, falling back to wall-clock if absent.

6. **Emit report** (see Outputs). Write JSON to
   `gstack-ios/.cache/ios-build-<scheme>-<config>.json` (path is stable so
   consumers can find it without a search). Also echo a 1-line human summary
   to stdout: `✓ HealthSync (Debug, iOS sim): 51 files, 0 errors, 3 warnings, 42.1s`.

## Outputs

**Report** (`gstack-ios/.cache/ios-build-<scheme>-<config>.json`):

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
    {"file": "<abs path>", "line": 12, "column": 3, "message": "..."}
  ],
  "warnings": [
    {"file": "<abs path>", "line": 24, "column": 5, "message": "...",
     "category": "deprecation"}
  ],
  "drift_warning": null,
  "log_path": "<absolute path to build.log>"
}
```

Field order is stable. New fields go at the end with sensible defaults so
downstream skills can ignore them. Never remove a field within a major version.

**Side effects:**
- Writes `<derived_data>/build.log` (raw xcodebuild output).
- Writes JSON report to `gstack-ios/.cache/`.
- Populates `<derived_data>/Build/` with the actual build products.
- Touches Xcode's user-level DerivedData if `derived_data` is not set
  (default tries to keep everything project-local).

Nothing outside the project directory (and DerivedData) is touched.

## Verification

- **Positive:** `ok == true` AND `errors == []` AND exit code 0 AND
  `compiled_files > 0`. The last clause guards against no-op builds where
  Xcode short-circuits (every file already up to date — useful in a tight
  iteration loop, but unsatisfying as a *refinement* signal).
- **Negative:** `ok == false` AND `errors` non-empty AND the first error's
  `file` exists on disk (catches log-parser regressions that fabricate file
  paths). If `ok == false` and `errors == []`, the parser is broken — flag
  loudly, don't fail silently.
- **Sanity:** `duration_s > 0` AND `log_path` is readable. A `duration_s == 0`
  result on a non-incremental build means the parser missed the timing line.

## Composition

**Upstream** (run before):
- `/ios-xcodegen` — regenerates the project from `project.yml`. Run if step 2
  raises a drift warning.

**Downstream** (consume the report):
- `/ios-test` — refuses to run unless `ok: true`.
- `/ios-screenshot-diff` — same gating.
- `/ios-ship-testflight` — same gating, and additionally requires
  `configuration == "Release"`.
- `/ios-wiring-check` — reads `warnings` for `unused` / `unreachable` entries
  as a starting set.

**Peers:**
- `/ios-build` itself is run once per scheme. For health-sync that's three
  invocations: `HealthSync`, `HealthSyncWatch`, and (once the project.yml gains
  one) `HealthSyncWidget`.

## Dogfood log

- **2026-05-16, iteration 1.** Applied `/ios-build`'s scheme-discovery step
  (procedure step 3) to `health-sync/`. Discovered the workspace exposes
  `HealthSync` and `HealthSyncWatch` schemes only — `HealthSyncWidget` is a
  target but has no scheme, so the protocol's "fail-fast on bad scheme" branch
  was the right design. Filed REFINEMENT-002 against health-sync to add a
  widget scheme to `project.yml`. Full build deferred to iteration 2 — running
  it inside the protocol-definition iteration would have bloated the commit.
  Commit: TBD-after-commit.
