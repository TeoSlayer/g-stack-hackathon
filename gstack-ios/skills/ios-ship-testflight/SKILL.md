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

## On failure → next step

- Validation fails with privacy declaration errors → `Info.plist` is
  missing a `NSXxxUsageDescription` for a framework you link. Add it,
  re-archive.
- Upload rejected with `ITMS-90xxx` codes → look up the exact code;
  most common: ITMS-90683 (missing usage description), ITMS-90809
  (deprecated UIWebView usage), ITMS-90685 (CFBundleIdentifier
  collision with an existing build).
- Build stays in `PROCESSING` past `poll_timeout_s` → not necessarily
  failed; App Store Connect can take 10+ minutes for some payloads.
  Check `https://appstoreconnect.apple.com/apps/<id>/testflight` manually.
- `INVALID` final state → App Store Connect found a hard problem.
  Surface the message verbatim and stop — fixing requires a new build.
- `build_number conflict` → bump `CURRENT_PROJECT_VERSION`, regen via
  `/ios-xcodegen apply`, re-run with `bump_build_number: false` (you
  just bumped manually).

## Example

```
$ /ios-ship-testflight \
    scheme=App \
    api_key_id=ABC123 \
    api_issuer_id=01234567-89ab-cdef-0123-456789abcdef \
    api_key_path=~/Keys/AuthKey_ABC123.p8 \
    app_id=1234567890

preflight:
  ios-build (Release): ok=true ✓
  ios-test:            ok=true, failures=0 ✓
  ios-signing-doctor:  ok=true ✓

archive: xcodebuild archive ... → gstack-ios/.cache/archives/App-...xcarchive
export: → gstack-ios/.cache/exports/App.ipa (24.3 MB)
validate: xcrun altool --validate-app --file ... → ok
upload:   xcrun altool --upload-app --file ... → ok
poll: PROCESSING (30s)... PROCESSING (60s)... VALID (287s) ✓

✓ App 0.1.0 (build 42) is TestFlight-distributable.
report: gstack-ios/.cache/ios-ship-testflight-2026-05-16T13-30-00Z.json
```

