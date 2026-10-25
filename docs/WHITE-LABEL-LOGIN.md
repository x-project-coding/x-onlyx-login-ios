# Shared Login for white-label workspaces

The `WhiteLabelLogin` iOS target is the shared **Login** app for partners such as Plumify. It uses
`ai.onlyx.whitelabel.login`, version 1.0, and the `secure-connect://open?c=<claim>` URL scheme.
It shares the existing iOS 17+ proxy, camera, session capture and connection-verification code.
The API origin stays compiled as `https://of-api.onlyx.ai`; links cannot choose a server.

The app uses neutral copy and its own arrow icon. It sends creators to their manager for help.
OnlyX Login remains a separate target and URL scheme. Its supplied OnlyX artwork is copied
unchanged from the workspace's approved `brand/onlyx/` assets.

## Build and release

- Generate with `xcodegen generate`; build the `WhiteLabelLogin` scheme.
- Run the existing release workflow with `product=white-label` and an unused build number.
- Set `LOGIN_PRODUCT=white-label` for archive preparation, signature verification and export.
- Use a dedicated App Store profile for `ai.onlyx.whitelabel.login` with the existing distribution
  certificate. No VPN, push or Sign in with Apple capability is needed.
- The workflow artifact is `WhiteLabelLogin-<build>-unsigned-<run>-<attempt>`.
- Validate and upload the verified IPA using the existing Apple release process.

The partner desktop gateway wraps claims for its own authenticated browser. The iPhone app
requires the raw short-lived server claim behind a tenant-validated mobile handoff. Do not give
it a wrapped desktop-browser claim. The white-label connection page and TestFlight download
must be wired to that mobile handoff before customer rollout.

Build upload, Apple processing, external beta approval and a real-device creator sign-in are
separate checks. Record each accurately; none implies the others.

## TestFlight release, 2026-10-24

- Listing: **Login: Creator Connect** (Apple's plain `Login` name was unavailable).
- Home-screen name: **Login**. App Store Connect ID: `6826637909`.
- Version 1.0 (2), source `ec11fbb2cdee945fc4f5527bb976307d91d4646d`.
- Supported-host release workflow: [40119292586](https://github.com/x-project-coding/x-onlyx-login-ios/actions/runs/40119292586), passed.
- Apple package validation and upload succeeded; processing state `VALID`.
- `Login Internal`: build 1.0 (2), `Ready to Test`; no testers added yet.
- `Login Beta`: external group created; build submission is pending reviewer contact and designated demo access. No public installer link is active.
- A fresh physical-iPhone creator sign-in, identity check and session transfer remain unverified for this flavor.

The tenant API handoff is [API #1010](https://github.com/x-project-coding/x-onlyx-api/pull/1010);
the web handoff is [UI #537](https://github.com/x-project-coding/x-onlyx-ui/pull/537). Their customer rollout
remains disabled until an approved, joinable TestFlight URL is configured.

Beta description: Login connects a creator's own OnlyFans account to their authorized workspace.
Use the one-time sign-in link provided by your manager, sign in in the private browser, complete
any requested identity check, and wait for Connected. Local browser data is discarded at the end.
Feedback: support@onlyx.ai.

What to test: open or paste a designated one-time link, complete OnlyFans sign-in and any identity
check, and verify Connected. Check invalid/expired links and cancel/retry. Use only an authorized
demo creator account. Keep reviewer contact details and credentials in App Store Connect only.

Build 2 replaces the initially uploaded build 1 to correct a blank app icon. The exported IPA icon was decoded and visually checked before upload; app behavior is unchanged.

## Public-link setup, 2026-10-25

Public invitation: https://testflight.apple.com/join/9vJx65k6 (`Login Beta`, open to anyone,
no group-specific tester limit). The public link is enabled, but no external build is approved
and the public page currently says the beta is not accepting testers. Do not enable this URL in
production until Apple approval and a verified iPhone connection. The user chose to enter a new
review contact directly in Apple rather than reuse the OnlyX Login contact.
