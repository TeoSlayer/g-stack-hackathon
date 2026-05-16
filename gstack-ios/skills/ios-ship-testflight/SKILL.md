---
name: ios-ship-testflight
description: Archive → validate → upload to TestFlight, then poll App Store Connect for processing state.
---

# /ios-ship-testflight

## When to invoke

When a Release build is ready to go to internal testers via TestFlight.
The skill is intentionally narrow: archive, validate, upload, confirm. It
does not promote builds to external testers, manage versioning, or write
release notes — those are human decisions that belong upstream.

Wrong call before `/ios-build` (Release), `/ios-test`, and
`/ios-signing-doctor` have all passed. The upload step takes minutes and
fails late if signing is wrong.

## Inputs

Required:
- `workspace` — `.xcworkspace` path.
- `scheme` — scheme to archive.
- `api_key_id`, `api_issuer_id`, `api_key_path` — App Store Connect API
  credentials. Path to a `.p8` file.
- `app_id` — the app's App Store Connect ID (for status polling).

Optional:
- `archive_path` — default
  `gstack-ios/.cache/archives/<scheme>-<ts>.xcarchive`.
- `export_method` — `app-store-connect` (default) or `validation`.
- `poll_timeout_s` — how long to wait for processing. Default `600`.
- `bump_build_number` — if `true`, increment `CURRENT_PROJECT_VERSION`
  before archiving and write it back into `project.yml` (regen pbxproj
  via `/ios-xcodegen apply`). Default `false` — version bumps should be
  deliberate.

Assumes:
- All preflight skills passed: `/ios-build (Release)`, `/ios-test`,
  `/ios-signing-doctor`.
- The App Store Connect API key has the required role (Developer or
  App Manager).

## Procedure

1. **Preflight gates.** Verify:
   - `gstack-ios/.cache/ios-build-<scheme>-Release.json` exists,
     `ok: true`.
   - `gstack-ios/.cache/ios-test-<scheme>.json` exists,
     `failures: []` OR `no_tests: true`.
   - `gstack-ios/.cache/ios-signing-doctor-<ts>.json` (most recent) has
     `ok: true`.
   If any gate fails, abort with the failing report cited.
2. **Archive:**
   ```
   xcodebuild archive \
     -workspace "$workspace" -scheme "$scheme" \
     -configuration Release \
     -destination 'generic/platform=iOS' \
     -archivePath "$archive_path" 2>&1 | tee archive.log
   ```
3. **Export.** Write an `ExportOptions.plist` declaring the method and
   signing style:
   ```
   xcodebuild -exportArchive \
     -archivePath "$archive_path" \
     -exportOptionsPlist /tmp/ExportOptions.plist \
     -exportPath gstack-ios/.cache/exports/ 2>&1 | tee export.log
   ```
   Yields an `.ipa`.
4. **Validate (preflight):**
   ```
   xcrun altool --validate-app \
     --file <ipa> --type ios \
     --apiKey $api_key_id --apiIssuer $api_issuer_id
   ```
   Surface every error verbatim. If validation fails, do **not** proceed
   to upload — file findings instead.
5. **Upload:**
   ```
   xcrun altool --upload-app \
     --file <ipa> --type ios \
     --apiKey $api_key_id --apiIssuer $api_issuer_id
   ```
   Capture `Bundle Short Version String` and `Bundle Version` from the
   archive's `Info.plist`.
6. **Poll processing.** App Store Connect API:
   `GET /v1/builds?filter[app]=<app_id>&filter[version]=<build>` — repeat
   every 30s up to `poll_timeout_s`. State transitions:
   `PROCESSING` → (`VALID` | `INVALID` | `FAILED` | `EXPIRED`).
7. **Emit final report** when state stabilises or timeout hits.

## Outputs

Report (`gstack-ios/.cache/ios-ship-testflight-<ts>.json`):
```json
{
  "skill": "ios-ship-testflight", "version": "0.1",
  "scheme": "App",
  "archive_path": "<abs>",
  "ipa_path": "<abs>",
  "marketing_version": "0.1.0",
  "build_number": "42",
  "validation": {"ok": true, "errors": []},
  "upload": {"ok": true, "bundle_id": "com.example.app"},
  "processing": {"final_state": "VALID", "elapsed_s": 287},
  "ok": true
}
```

If anything fails, `ok: false` and the report includes the failing stage
+ full error output. The skill is intentionally noisy on failure —
silent failures here cost a real release window.

**Side effects:**
- `.xcarchive` and `.ipa` written under `gstack-ios/.cache/`.
- A TestFlight build is published to App Store Connect on success.
  This is the one skill in gstack-ios with a side effect *visible to
  external testers* — treat invocation as "publish".

## Verification

- **Positive:** `processing.final_state == "VALID"`. Build is
  TestFlight-distributable.
- **Negative:** any non-`VALID` final state surfaces the App Store
  Connect message verbatim. Common: `INVALID` due to missing privacy
  declarations (`Info.plist` keys); `FAILED` due to processing crash
  (re-upload usually works).
- **Idempotency check:** uploading the same `marketing_version` +
  `build_number` twice is rejected by App Store Connect. The skill
  detects this and surfaces "build_number conflict — bump and retry"
  rather than failing opaquely.

## Composition

- **Upstream gates:** `/ios-build (Release)`, `/ios-test`,
  `/ios-signing-doctor`.
- **Upstream optional:** `/ios-perf-trace` (if a perf gate is required
  by the project — not enforced by this skill).
- **Downstream:** none. Terminal skill. TestFlight notifies testers
  asynchronously.
