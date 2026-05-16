---
name: ios-xcodegen
description: Regenerate Xcode project from project.yml and classify pbxproj drift as harmless or real.
---

# /ios-xcodegen

## When to invoke

Before `/ios-build` whenever `project.yml` has been edited, or when a build
gives "file not found" / "no such scheme" errors that smell like generator
drift. Also as a standalone sanity check: a project should regenerate to
a byte-equivalent (or only trivially different) pbxproj. If it doesn't,
something is being edited by hand that shouldn't be — and the next regen
silently destroys it.

Wrong call when there's no `project.yml` (this is a CocoaPods or
hand-maintained project — different tool). Also wrong in CI without human
review of the diff — auto-committing regenerated pbxproj on every push is
how you erase deliberate manual edits.

## Inputs

Required:
- `project_root` — directory containing `project.yml`. Auto-detected if cwd
  contains one.

Optional:
- `mode` — `validate` (default; regen + diff + reset) or `apply` (regen +
  diff + leave changes in working tree for human review).
- `acceptable_drift_categories` — list of drift kinds tolerated without
  flagging. Default: `["whitespace", "ordering"]`. Add `"file_uuid_churn"`
  if the generator is known to renumber on every run.

Assumes:
- `xcodegen` on PATH.
- `project.yml` is the source of truth.
- The repo is git-tracked.

## Procedure

1. **Locate `project.yml`.** Fail fast if absent.
2. **Snapshot.** `cp project.pbxproj project.pbxproj.before`.
3. **Regenerate.** `xcodegen generate --spec project.yml` from
   `$project_root`. Capture stdout/stderr — generator warnings frequently
   flag misconfigurations.
4. **Diff.**
   ```
   diff -u project.pbxproj.before *.xcodeproj/project.pbxproj
   ```
5. **Classify each hunk** by inspecting the changed lines:
   - `whitespace` — every changed line is blank or whitespace-only when
     stripped.
   - `ordering` — every removed line appears verbatim as an added line
     elsewhere in the diff and vice versa (i.e. the multiset of changed
     lines is unchanged). Detect by `sort` of removed lines ==
     `sort` of added lines.
   - `file_uuid_churn` — every difference is in a 24-hex-char token
     (pbxproj's object identifiers); the surrounding structure is
     identical when UUIDs are normalised. Detect by substituting
     `[A-F0-9]{24}` → `UUID` on both sides and re-diffing.
   - `target_change` — a `PBXNativeTarget` or `PBXAggregateTarget` block
     changed.
   - `build_setting_change` — a `buildSettings` dict changed.
   - `source_change` — a `PBXFileReference` or `PBXBuildFile` added /
     removed.
   - `scheme_change` — `xcshareddata/xcschemes/*.xcscheme` changed.
   - `other` — anything else.
6. **Report.** If all hunks are in `acceptable_drift_categories`, drift is
   `harmless`. Otherwise `real`. Either way emit the full classification.
7. **Reset (validate) or leave (apply).** In `validate`,
   `git checkout -- *.xcodeproj/project.pbxproj` and remove the `.before`
   snapshot. In `apply`, leave the regenerated file for human review.

## Outputs

Report (`gstack-ios/.cache/ios-xcodegen-<project>.json`):
```json
{
  "skill": "ios-xcodegen",
  "version": "0.1",
  "project_root": "<abs>",
  "mode": "validate|apply",
  "drift": "none|harmless|real",
  "hunks": [
    {"category": "build_setting_change", "lines_added": 3,
     "lines_removed": 1, "sample": "<first 5 lines of hunk>"}
  ],
  "generator_warnings": ["<line>"],
  "ok": true
}
```

**Side effects:**
- `validate` mode: none after reset.
- `apply` mode: `*.xcodeproj/project.pbxproj` overwritten; possibly
  schemes added/removed under `xcshareddata/xcschemes/`.

## Verification

- **Positive:** `drift == "none"` or `drift == "harmless"`. `ok: true`.
- **Negative:** `drift == "real"` AND the `hunks` list explains *why* in a
  way a human can act on.
- **Pathological:** `xcodegen generate` itself fails (`ok: false`) —
  usually a malformed `project.yml`. Surface generator stderr verbatim.

## Composition

- **Upstream:** none. Starting point for build-related work.
- **Downstream:** `/ios-build` — if drift is `real`, downstream callers
  decide whether to apply or revert before building.
- **Pairs with:** `/ios-wiring-check` — both surface "something defined
  that isn't being used"; this at the project level, that at the source
  level.

## On failure → next step

- If `xcodegen generate` itself fails → fix `project.yml` per the
  generator stderr, then re-run.
- If `drift == "real"` and the diff looks like the generator's choice
  → re-run with `mode: apply`, review the diff manually, commit if
  intentional.
- If `drift == "real"` and the diff looks like manual edits to pbxproj
  → either fold those edits into `project.yml` (the source of truth),
  or accept the drift category in `acceptable_drift_categories`.

## Example

```
$ /ios-xcodegen
discovered: project_root=.
xcodegen generate --spec project.yml
diff: 14 hunks, classified as ordering (12), file_uuid_churn (2)
drift: harmless
✓ project in sync with project.yml
report: gstack-ios/.cache/ios-xcodegen-App.json
```

Real drift detected:

```
$ /ios-xcodegen
xcodegen generate --spec project.yml
diff: 3 hunks, classified as build_setting_change (1), source_change (2)
drift: real
- SWIFT_VERSION changed from 5.9 → 5.10 in HealthSync target
- Added: HealthSync/NewModelsView.swift
- Removed: HealthSync/CalendarView.swift
working tree reset; re-run with mode=apply to keep these changes.
```

