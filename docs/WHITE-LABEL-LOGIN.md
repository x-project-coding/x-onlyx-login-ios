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
