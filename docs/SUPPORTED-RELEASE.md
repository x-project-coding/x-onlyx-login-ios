# Supported-host release for OnlyX Login

This is the reusable build, signing and upload procedure for bundle `ai.onlyx.login`, team `Y5NUN99S3X`, app/executable **OnlyX Login**. Run the examples from the repository root. Keep signing credentials, reviewer details and local upload records outside this public repository.

At the September 6, 2026 handoff, the existing runtime is **1.0 (3)**. The operator reported App Store **Invalid Binary** and a separate TestFlight build 3 **Waiting for Review**. The precise rejection cause is unconfirmed. [PR #4](https://github.com/x-project-coding/x-onlyx-login-ios/pull/4) is merged and its supported-host build 4 is running; build 4 has not yet been recorded here as built, uploaded or submitted. Older [handoff](HANDOFF-MAC.md) and [beta metadata](TESTFLIGHT-METADATA.md) are historical context, not current approval evidence.

## 1. Compile on the supported host

The [manual workflow](../.github/workflows/release-archive.yml) uses `macos-26` and `/Applications/Xcode_26.6.app/Contents/Developer`. Its shared guard requires public macOS **26.2–26.x**, Xcode **26.6 (17F113)** and iOS SDK **26.5**. A stable Xcode installation on macOS 27 beta does not satisfy that host requirement. Never change `BuildMachineOSBuild`, Xcode or SDK metadata to bypass it. [Apple requirements](https://developer.apple.com/xcode/system-requirements/)

After the reviewed workflow is available on the default branch, dispatch it against the reviewed branch or tag. Choose a positive build number unused in App Store Connect; **4** is the intended rebuild number at this handoff. Record the approved source commit independently before dispatching.

```sh
: "${ONLYX_SOURCE_REF:?Set the reviewed branch or tag}"
: "${ONLYX_BUILD_NUMBER:?Set an unused positive build number}"
gh workflow run release-archive.yml --repo x-project-coding/x-onlyx-login-ios \
  --ref "$ONLYX_SOURCE_REF" -f "build_number=$ONLYX_BUILD_NUMBER"
```

CI pins the actions and XcodeGen download, runs Release core tests and executes the actual configuration code to verify that packaged clients use `https://of-api.onlyx.ai` and ignore API overrides. It archives `OnlyXLogin.xcodeproj` / `OnlyXLogin` in `Release` for `generic/platform=iOS` with signing disabled. No real-account HTTP checks, Apple keys, profiles, review credentials or private notes are supplied to CI. The existing ordinary `ci.yml` remains separate.

## 2. Authenticate and preserve the artifact

Wait for completion. Confirm the authenticated GitHub run is the intended `workflow_dispatch`, has `conclusion: success`, and has the independently approved `headSha`. Download that run and attempt only into a new directory.

```sh
: "${ONLYX_CI_RUN:?Set the verified successful GitHub run ID}"
: "${ONLYX_CI_ATTEMPT:?Set the run attempt}"
gh run view "$ONLYX_CI_RUN" --repo x-project-coding/x-onlyx-login-ios \
  --json event,status,conclusion,headSha,url,workflowName
export ONLYX_ARTIFACT_DIR="$PWD/build/ci-download-$ONLYX_CI_RUN-$ONLYX_CI_ATTEMPT"
mkdir -p build
mkdir "$ONLYX_ARTIFACT_DIR"
gh run download "$ONLYX_CI_RUN" --repo x-project-coding/x-onlyx-login-ios \
  --name "OnlyXLogin-$ONLYX_BUILD_NUMBER-unsigned-$ONLYX_CI_RUN-$ONLYX_CI_ATTEMPT" \
  --dir "$ONLYX_ARTIFACT_DIR"
(cd "$ONLYX_ARTIFACT_DIR" && shasum -a 256 -c SHA256SUMS)
export ONLYX_EXTRACT_DIR="$PWD/build/ci-extracted-$ONLYX_CI_RUN-$ONLYX_CI_ATTEMPT"
mkdir "$ONLYX_EXTRACT_DIR"
ditto -x -k "$ONLYX_ARTIFACT_DIR/OnlyXLogin-$ONLYX_BUILD_NUMBER-unsigned.xcarchive.zip" \
  "$ONLYX_EXTRACT_DIR"
```

Match `provenance.json` to the approved source SHA, repository, run/attempt, requested build and archive hash. Its `environment` must agree with `build-environment.json`. These files are records, not independently signed attestations: authenticate their GitHub origin first. Preserve the original ZIP and JSON files. `ditto` retains symbolic links and executable modes; do not download the raw archive directory or rewrite its metadata.

## 3. Sign and export a separate local copy

Use an existing local Apple Distribution identity and matching current App Store profile. Set the private path/identity variables without adding their values to Git. The helper supports this main-app archive only; extensions or embedded libraries require a reviewed signing change.

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer
: "${ONLYX_PROFILE_PATH:?Set the local App Store mobileprovision file path}"
: "${ONLYX_SIGNING_IDENTITY:?Set the exact local Apple Distribution name or SHA-1}"
: "${ONLYX_PROVISIONING_PROFILE:?Set the name or UUID of that installed profile}"
export ONLYX_ENVIRONMENT_REPORT="$ONLYX_ARTIFACT_DIR/build-environment.json"
export ONLYX_ARCHIVE="$PWD/build/OnlyXLogin-$ONLYX_BUILD_NUMBER-supported-signed.xcarchive"
python3 scripts/prepare-unsigned-archive.py \
  --input "$ONLYX_EXTRACT_DIR/OnlyXLogin-$ONLYX_BUILD_NUMBER-unsigned.xcarchive" \
  --output "$ONLYX_ARCHIVE" \
  --profile "$ONLYX_PROFILE_PATH" \
  --signing-identity "$ONLYX_SIGNING_IDENTITY" \
  --environment-report "$ONLYX_ENVIRONMENT_REPORT"
export ONLYX_EXPORT_DIR="$PWD/build/OnlyXLogin-$ONLYX_BUILD_NUMBER-supported-export"
bash scripts/export-store.sh
```

Both output paths must be new. Preparation keeps the source archive unchanged and signs its copy with the existing app identifier, team, default Keychain group, disabled debugger access and distribution entitlement. **OnlyX Login has no Push Notifications or Sign in with Apple capability**; do not copy TalkGF entitlements. Export verifies the profile/certificate, strict signature, original app metadata/resources, and matching executable/dSYM UUID. Require successful exit plus `verified: true` in `verification.json`; keep that report and its IPA SHA-256.

The current local Mac is still macOS 27 beta, outside Xcode 26.6's supported host range. Selecting stable Xcode for local signing/export does not make that host supported. Prefer a supported Mac for export too when available. A local export result is separate from Apple processing and review; it must never be represented as approval. This procedure performs no local compilation and preserves the supported host's compiler metadata.

## 4. Validate and upload using the existing local Apple key

The exported IPA path is in `verification.json`. Use the existing authorized App Store Connect key; no new key or remote secret is required. The examples use Xcode 26.6's documented `altool` API-key flags with an issuer ID. The key must already be stored in its private local directory as `AuthKey_<key-id>.p8`; export only the directory variable, never key contents. Check `xcrun altool --help` if the existing key uses a different authentication type. [Apple upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

```sh
: "${ONLYX_IPA:?Set the exact IPA path from the successful verification report}"
: "${ONLYX_ASC_KEY_ID:?Set the existing authorized App Store Connect key identifier}"
: "${ONLYX_ASC_ISSUER_ID:?Set its issuer identifier}"
: "${API_PRIVATE_KEYS_DIR:?Set the existing private key directory outside Git}"
export API_PRIVATE_KEYS_DIR
umask 077
xcrun altool --validate-app "$ONLYX_IPA" \
  --api-key "$ONLYX_ASC_KEY_ID" --api-issuer "$ONLYX_ASC_ISSUER_ID" \
  --output-format json > "$ONLYX_EXPORT_DIR/apple-validation.json"
```

Inspect a successful validation result before performing the separately authorized upload:

```sh
xcrun altool --upload-package "$ONLYX_IPA" \
  --api-key "$ONLYX_ASC_KEY_ID" --api-issuer "$ONLYX_ASC_ISSUER_ID" \
  --output-format json > "$ONLYX_EXPORT_DIR/apple-upload.json"
```

Keep the delivery ID and final IPA hash privately. Then verify the bundle, version, build number and completed processing result in App Store Connect. A successful upload does not establish `VALID` processing, review submission or approval.

## 5. Hand off selection and submission

An app-scoped **Developer** can upload builds. Selecting a build for an App Store version and submitting it require **Account Holder, Admin or App Manager** access to that app. The authorized reviewer should select the exact processed replacement, save, submit, and record the resulting state separately from upload evidence. Do not treat an API permission failure as a binary failure. [Upload roles](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [Build selection roles](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit) · [Submission roles](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)

Preserve the pending **TestFlight build 3** review. Uploading the supported-host replacement for App Store review is not permission to expire build 3, withdraw its beta review, reset testers/groups or start a new beta submission. Make any necessary beta replacement only after explicit authorization. Record the exact Apple error if Invalid Binary recurs; do not infer its cause from the label alone.
