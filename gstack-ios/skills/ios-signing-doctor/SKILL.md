---
name: ios-signing-doctor
description: Diagnose code-signing failures — read the build log, list installed identities/profiles, identify the mismatch.
status: draft
version: 0.1
---

# /ios-signing-doctor

## When to invoke

When `/ios-build` fails with `Code Signing Error`, `No profiles for ... found`,
`The executable was signed with invalid entitlements`, or an `xcrun altool`
upload is rejected for signing reasons. Also as a preflight before an
unfamiliar archive build (e.g. switching from sim to device, or a new team
member's machine).

Wrong call when the build error is *unrelated* to signing — the procedure
will produce an "everything looks fine" report and waste machine time.

## Inputs

Required:
- `project_root` — the directory containing the `.xcodeproj` or workspace.

Optional:
- `build_log` — path to a recent build.log (from `/ios-build`). If absent,
  the skill runs a quick build with `-showBuildSettings` only — much faster
  than a full build.
- `bundle_id` — expected bundle identifier to validate against installed
  profiles.
- `team_id` — expected `DEVELOPMENT_TEAM`.

Assumes:
- `security` CLI on PATH (system tool, always present on macOS).
- The user's keychain is unlocked (or `security` will fail with a clear
  error — surface it).

## Procedure

1. **Parse the build log** (if provided) for signing-specific patterns:
   - `Code Signing Error:` lines and their surrounding context.
   - `error: No profiles for '<bundle_id>' were found`.
   - `error: '<file>' requires a provisioning profile`.
   - `error: Provisioning profile "<name>" doesn't include signing
     certificate "<cert>"`.
   - `error: The executable was signed with invalid entitlements`.
   Bucket findings by category.
2. **List installed code-signing identities:**
   ```
   security find-identity -v -p codesigning
   ```
   Parse each line into `{sha1, type ("Apple Development" | "Apple Distribution"),
   team_name, team_id}`.
3. **List installed provisioning profiles:**
   ```
   ls ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision \
     | while read p; do
         security cms -D -i "$p" > /tmp/profile.plist
         /usr/libexec/PlistBuddy -c "Print" /tmp/profile.plist
       done
   ```
   Extract `{name, uuid, app_id, team_id, expiration, devices?, entitlements}`
   for each.
4. **Read project signing settings** via
   `xcodebuild -showBuildSettings -workspace ... -scheme ...` filtered for
   `CODE_SIGN_*`, `DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE*`,
   `PRODUCT_BUNDLE_IDENTIFIER`.
5. **Diagnose by cross-referencing:**
   - Project's `PRODUCT_BUNDLE_IDENTIFIER` ↔ profile `app_id` (wildcards OK).
   - Project's `DEVELOPMENT_TEAM` ↔ identity `team_id`.
   - Profile expiration vs `Date()`.
   - Profile entitlements ⊇ project entitlements file.
6. **Compose diagnosis.** Each finding is one of:
   - `no_matching_profile` — no installed profile matches the bundle ID.
   - `expired_profile` — matching profile but past expiration.
   - `team_mismatch` — profile's team ≠ project's team.
   - `missing_entitlement` — entitlements file requests a capability not in
     the profile (e.g. `aps-environment` for push).
   - `no_identity_for_profile` — profile names a cert that's not in the
     keychain.
   - `keychain_locked` — `security` returned an "interaction not allowed"
     error.

## Outputs

Report (`gstack-ios/.cache/ios-signing-doctor-<ts>.json`):
```json
{
  "skill": "ios-signing-doctor", "version": "0.1",
  "project_root": "<abs>",
  "expected": {"bundle_id": "io.vulturelabs.healthsyncs", "team_id": "ABCD123"},
  "identities": [{"team_id": "ABCD123", "type": "Apple Development",
                  "sha1": "..."}],
  "profiles": [{"name": "iOS Team Provisioning", "app_id": "io.vulturelabs.*",
                "team_id": "ABCD123",
                "expires": "2026-08-12T00:00:00Z", "ok": true}],
  "diagnosis": [
    {"category": "missing_entitlement",
     "detail": "Project requests com.apple.developer.healthkit.background-delivery
                but installed profile doesn't include it.",
     "suggested_fix": "Either remove the entitlement (paid-team-only) or
                       use a profile from a paid Apple Developer team."}
  ],
  "ok": false
}
```

If the procedure runs cleanly with no diagnosis, `diagnosis: []` and
`ok: true`.

Side effects: writes a transient `/tmp/profile.plist` per profile (cleaned
up at the end of the run).

## Verification

- **Positive:** `ok: true` AND `diagnosis: []` AND a downstream build
  actually succeeds (caller's responsibility to re-run `/ios-build`).
- **Negative:** `ok: false` AND each diagnosis has a `suggested_fix` the
  caller can act on. "Vague" diagnoses are a skill bug — every category
  must produce a concrete next step.

## Composition

- **Upstream:** `/ios-build` (provides the build log).
- **Downstream:** human action (rotating profiles, switching teams, etc.).
  After acting, re-run `/ios-build` to confirm.
- **Pairs with:** `/ios-ship-testflight` (signing failures at upload time
  often surface here too).

## Dogfood log

*(none yet. The motivating real-world signal is in
`HealthSync/HealthSyncManager.swift:17–23`, which documents that the
`com.apple.developer.healthkit.background-delivery` entitlement is
paid-team-only — the skill should re-derive this finding from a fresh
build attempt on a free team.)*
