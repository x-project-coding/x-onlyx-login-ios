# Plan — OnlyX Login for iPhone

**Why.** 90% of the creators OnlyX onboards in Argentina have no laptop. The mac/Windows app exists
because a creator has to sign in herself — OnlyFans asks for her face — and an agency owner cannot
do that for her. On a phone, the streamed browser is a poor sign-in (VNC typing, and the identity
check compares networks between the seat's proxy and her phone). A native iPhone app signs her in on
her own device, with her own camera, on her own connection.

## What "the same functionality as the mac app" means here

| capability | mac app | iPhone app | status |
| --- | --- | --- | --- |
| open from a link (`onlyx-connect://open?c=`) | protocol handler | URL scheme + **Paste your link** (chat apps rarely linkify custom schemes) | written |
| spend the claim, hold the pass token | `POST /open` | same call, same fields, `platform: ios-<ver>`, `caps: [nativeIdentity]` | written, tested |
| a private browser that presents a coherent device | in-memory partition, native identity | non-persistent WKWebView, native identity (forced — see README) | written |
| hear OnlyFans name her | CDP watch on `/users/me` | user-script observer → message handler | written, script tested |
| capture the jar + device token | `session.cookies.get`, `Runtime.evaluate` | `WKHTTPCookieStore`, `evaluateJavaScript` | written, rules tested |
| import, handle refusals in place | `POST /session`; wrong account → stay signed-in | same, via `ConnectFlow.importOutcome` | written, tested |
| verify with the seat, success only when it says so | `GET /status` poll | same, via `ConnectFlow.phase(forStatus:)` | written, tested |
| the selfie check | macOS camera permission dance | iOS system prompt + `requestMediaCapturePermissionFor → .grant` | written |
| tunnel through the account's proxy | loopback CONNECT forwarder | **not in v1** — honest refusal; server default is off | decided |
| help inside the app, offline | yes | yes, iPhone-specific entries | written |
| auto-update | electron-updater | TestFlight / App Store | n/a |

## Milestones

1. **v0 (this repo, now):** core written and tested on Linux (43 tests); app target written; CI
   compiles it for the simulator on a macOS runner. No human has signed in through it.
2. **v0.1 — first device run.** Needs a Mac + Apple team: archive, TestFlight internal build, sign
   in with a test creator, watch the seat adopt the session (`connect-app/status` → `connected`).
   Expect to tune: the observer's timing vs OnlyFans' SPA (the first `/users/me` may be the guest
   answer), the settle delay, the camera inline-video behaviour in the vendor's iframe.
3. **v0.2 — the connect page offers it.** `x-onlyx-ui` `connect-desktop.ts` currently returns the
   streamed browser for every phone. Add an `ios` platform: on an iPhone, show "Open in OnlyX Login"
   (the same deep link) + the TestFlight install link + the paste instruction, and keep the streamed
   browser as the fallback. `x-onlyx-api` gains `connect_app_download_ios_url` (empty = not offered,
   like the mac/win URLs) and `downloadIosUrl` in `PublicConnectDesktopOut`.
4. **v0.3 — measure the resume.** Every iPhone pass is recorded with `platform: ios-…`. Compare
   sign-out rates of iPhone-made sessions resumed by `mac` seats against desktop-made ones. If they
   are worse, that is the case for an `iphone` seat profile in x-onlyfans (`buildProfiles`).
5. **Later:** Universal Links (tappable https links in every chat; needs the team id on
   app.onlyx.ai), a NetworkExtension tunnel if the server ever needs the sign-in on the account's
   egress, App Store submission.

## What needs George

- An Apple Developer account (or access to one): team id, the `ai.onlyx.login` bundle id, a TestFlight
  external-testing group. Without it there is no device build at all.
- A Mac with Xcode for the archive (CI can build for the simulator; a signed archive for TestFlight
  can also be automated in CI once the signing certificate and provisioning profile are secrets).
- A decision on the App Store vs TestFlight-only distribution.

## Risks, named

- **Review.** An app whose sole purpose is signing into OnlyFans may draw questions in App Store
  review. TestFlight review is lighter; still, be ready to explain what it is (a login helper that
  stores nothing).
- **The observer is visible.** `fetch.toString()` is not `[native code]` on the sign-in page. If
  OnlyFans ever keys on that, the `auth_id`-cookie path (no script) is the fallback for the user id.
- **The resume delta.** iOS sign-in → Mac seat. Measured, not assumed (milestone 4).
- **WKWebView vs OnlyFans' vendor.** Ondato's mobile-web selfie flow under an in-app WKWebView is
  untested here; the first device run is what settles it.
