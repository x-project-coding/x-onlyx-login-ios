# OnlyX Login for iPhone

The iPhone counterpart of [OnlyX Login](https://github.com/x-project-coding/x-onlyx-login) (macOS /
Windows): a small app a creator opens **from a link** to sign in to OnlyFans for her OnlyX-managed
account, on the phone she actually has. Nothing to set up, no account to create: tap the link, sign
in, pass the selfie check with the phone's own camera, see **Connected**, close the app.

It speaks the **same server contract** as the mac app — `POST /connect-app/open`, `POST
/connect-app/session`, `GET /connect-app/status` on `of-api.onlyx.ai` — captures the **same jar**
by the same rules, and uses the same words. Where iOS differs, the difference is written down below.

**Status: v0 — the core is written and tested; the app target is written and compiles in CI; nobody
has yet signed in through it on a real iPhone.** See PLAN.md for what is left and what needs an
Apple account.

## For creators — installing it

Apps reach an iPhone only through Apple. This app is distributed with **TestFlight** (Apple's free
beta app): your manager sends an invitation link; it installs TestFlight first, then OnlyX Login
inside it. Open OnlyX Login once — after that your connect links open it by themselves.

Then, from the chat where your manager sent your connect link (it starts with `onlyx-connect://`):

- **tap it** — iOS asks whether to open OnlyX Login; choose Open; or
- **copy it** (press and hold → Copy), open OnlyX Login, tap **Paste your link**. Many chat apps
  do not make custom links tappable; pasting always works.

The app opens on the OnlyFans sign-in page. Sign in as usual — password, email code, and the
camera check if OnlyFans asks for one (allow the camera when your iPhone asks; use the front
camera) — and wait for the **Connected** screen. Links work **once** and for **15 minutes**.

Help is **inside the app** (the Help button), and it answers without a connection.

## What the app does, and does not do

- The sign-in happens in a private, in-memory browser inside the app (`WKWebView` on a
  non-persistent data store). Cookies, storage and cache are dropped with the run; nothing is
  written to the phone.
- **The browser presents the iPhone it is running on** — native identity, always. See below for
  why that is the only coherent option on iOS.
- The sign-in uses **the phone's own internet connection**. OnlyFans' identity check runs on the
  same device that signs in, so the desktop's "same network as the phone that scans the QR"
  problem cannot arise here — the phone IS the device.
- When OnlyFans confirms the sign-in (a `/users/me` answer naming her, with the login cookies in
  the jar), the app hands the session and the device token to OnlyX and closes the browser. OnlyX
  verifies it on its side; the app shows **Connected** when the seat says so, and nothing sooner.
- The app talks to exactly one server, fixed in the binary. A link carries a one-time code and
  nothing else — it cannot point the app anywhere.
- The camera is used only if OnlyFans asks for an identity check during sign-in.
- **Updates come through TestFlight / the App Store.** An iOS app cannot update itself; there is no
  in-app updater and no update screen.

## What iOS cannot do (and what the app does instead)

The mac app drives its browser over the Chrome DevTools Protocol. WebKit has no such protocol, and
every difference below follows from that.

| the mac app | the iPhone app |
| --- | --- |
| `Network.setUserAgentOverride` with client hints (seat mode) | **cannot** send `Sec-CH-UA-*`; can only set the UA string. So `seat` mode would be a Mac UA with blank hints over a WebKit TLS stack — the exact contradiction native mode exists to avoid. The app declares `nativeIdentity` and runs native: WKWebView's own iPhone-Safari identity, untouched. |
| `Network.responseReceived` watch on `/users/me` (touches nothing in the page) | a user script at document start wraps `fetch`/`XMLHttpRequest` in the main frame and posts **only** the `/users/me` answer to the native side. Visible to the page (`fetch.toString()`), same class of tell as the seat's own pins. See `MeObserver` for a script-free alternative via the `auth_id` cookie. |
| `session.cookies.get` | `WKHTTPCookieStore.getAllCookies` — HttpOnly included, which `document.cookie` would not be |
| `Runtime.evaluate` for `bcTokenSha` | `evaluateJavaScript` with the same expression |
| a loopback CONNECT forwarder when the server offers a tunnel | **not supported**: WKWebView takes no per-view proxy. The server's default is `tunnel: null`; if it ever offers one, the app stops with an honest message rather than sign in over the wrong network. (A NetworkExtension packet tunnel could do it later; it is a separate, entitlement-gated piece of work.) |
| popups: load in place / optional real popup | `createWebViewWith` returns nil and loads an https target in place |
| `render-process-gone` | `webViewWebContentProcessDidTerminate` |
| auto-update via electron-updater | TestFlight / App Store |

**The one thing this leaves for the server side.** The seat that resumes a desktop-app sign-in is
the `mac` profile (`APP_DEVICE_PROFILE` in x-onlyfans). An iPhone sign-in resumed by a Mac seat is
a larger declared-device delta (iOS → macOS) than the mac app's. The app sends `platform: ios-<ver>`
with every claim so the estate can see and measure iPhone sign-ins; closing the delta needs an
iPhone seat profile in x-onlyfans, which is a server change, not an app one.

## For developers

```
swift test                                  # the core, on Linux or macOS (43 tests, no simulator)
docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test    # the same, on a box without Swift
brew install xcodegen && xcodegen generate  # writes OnlyXLogin.xcodeproj (not committed)
open OnlyXLogin.xcodeproj                   # set your team under Signing & Capabilities, run on a device
```

A debug build honours `ONLYX_API_BASE` (scheme environment) to point at another API; a release build
ignores it.

| file | role |
| --- | --- |
| `Sources/OnlyXLoginCore/` | **Foundation-only, Linux-tested.** Deep link, API models + client (injectable transport), capture rules, the `/users/me` observer script, native identity, the messages, and the flow's decisions (`ConnectFlow`). |
| `Sources/OnlyXLoginApp/AppModel.swift` | the run: open → sign-in → capture → import → verify, with the timers and the stale-run guards |
| `Sources/OnlyXLoginApp/SignInWebView.swift` | the WKWebView: in-memory store, user scripts, cookie read, camera grant, https-only, popups |
| `Sources/OnlyXLoginApp/ContentView.swift` | the screens, in the mac app's words and colours; Help |
| `project.yml` | XcodeGen spec; `Info.plist` carries the URL scheme and the camera strings |
| `.github/workflows/ci.yml` | `swift test` on Linux; simulator build on macOS |

The server side lives in `x-onlyfans` (`apps/api/src/modules/connect-app/`); the connect page a
creator is sent lives in `x-onlyx-ui` (`app/pages/connect/[token].vue`).

## Releasing

Needs an Apple Developer account (the team), a bundle id (`ai.onlyx.login`), and a Mac with Xcode:

1. `xcodegen generate`, open the project, set the team, **Product → Archive**.
2. Distribute → **TestFlight** (external testing): Apple reviews the first build (usually a day),
   then the public TestFlight link is what managers send creators. Builds expire after 90 days;
   ship a new one before that.
3. The App Store is the long-term path and needs review of an app whose only job is signing in to
   OnlyFans — plan for questions. TestFlight is the realistic first channel.

Universal Links (`https://app.onlyx.ai/connect/...` opening the app directly, tappable in every
chat) need the team id in an `apple-app-site-association` file on app.onlyx.ai; until then the
custom scheme and **Paste your link** carry the flow.
