# Hand-off: first device run and TestFlight, from a Mac

This is the brief for a Claude Code session running on a Mac with Xcode. It picks up where the
Linux-side work stopped: the app is written, its core is tested, CI compiles it for the simulator —
and nobody has yet signed in through it on a real iPhone. Read README.md and PLAN.md first.

**Working rules.** Work on a branch (`lane/first-device-run`), never commit to `main` directly, open
a PR for any code change and let CI run. Commit as `Claude Code <noreply@anthropic.com>`. Never
commit a Team ID, a certificate, a pass token, a cookie or a screenshot with a session in it. Test
only with a creator the operator names as a test account — never a live, earning one.

## 0. What the operator (George) does himself, once

- Be enrolled in the Apple Developer Program (or have access to a team), and sign that Apple ID
  in to Xcode: Xcode › Settings › Accounts. Note the **Team ID** (10 characters, in
  developer.apple.com › Membership).
- Have Xcode 16 or newer installed (`xcode-select -p` should point at it) and Homebrew.
- Pick the **test creator** in the OnlyX console and send himself its connect link
  (`https://app.onlyx.ai/connect/<token>`). That link is what mints the app's one-time pass.

## 1. Clone, generate, prove the core

```bash
git clone https://github.com/x-project-coding/x-onlyx-login-ios.git && cd x-onlyx-login-ios
brew install xcodegen
xcodegen generate                 # writes OnlyXLogin.xcodeproj (gitignored)
swift test                        # the core: 47 tests + 4 executed-script tests under JavaScriptCore
sudo xcodebuild -license accept   # only if xcodebuild asks
```

If `swift test` fails here but passes in CI, say so and stop: the Mac's toolchain differs from
CI's and that is worth knowing before anything else.

## 2. Simulator build and a full flow without a camera

```bash
xcodebuild -project OnlyXLogin.xcodeproj -scheme OnlyXLogin \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
APP=$(xcodebuild -project OnlyXLogin.xcodeproj -scheme OnlyXLogin -sdk iphonesimulator -showBuildSettings \
      | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/"OnlyX Login.app"
xcrun simctl boot "iPhone 16" 2>/dev/null; open -a Simulator
xcrun simctl install booted "$APP"
xcrun simctl launch booted ai.onlyx.login
```

Get a pass. The connect page's own endpoint mints one; `<token>` is the last path segment of the
connect link George sent himself. A pass is single-use and lives 15 minutes; minting again
supersedes the previous one.

```bash
curl -s -X POST "https://app.onlyx.ai/api/connect/<token>/desktop" | python3 -m json.tool
# -> { "deepLink": "onlyx-connect://open?c=…", "expiresAt": …, "downloadMacUrl": …, … }
xcrun simctl openurl booted "onlyx-connect://open?c=<the claim>"
```

Watch the app's own log while it runs — every decision is logged:

```bash
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "ai.onlyx.login"'
```

Expected sequence: `pass opened (native identity, tunnel none)` → the OnlyFans sign-in page →
after sign-in `OnlyFans named user …` → `captured N cookies + device token` → `session imported
at …; seat …` → the Connecting screen → **Connected** when `status` says `connected`. The
simulator has no camera, so if OnlyFans asks for a selfie the run stops there; that step is what
the device run is for. Lines worth reading if it stalls: `guest answer` (the first `/users/me`
before sign-in — harmless), `login cookies are not in the jar yet`, `device token is not in storage
yet — waiting`, `import refused (<code>)`, `blocked navigation`, `media capture requested`.

## 3. The device run

Plug in the iPhone, trust the Mac on it, select it as the run destination in Xcode. Set the team
WITHOUT committing it — either in Xcode (target OnlyXLogin › Signing & Capabilities › Team, which
edits the gitignored project) or on the command line:

```bash
xcodebuild -project OnlyXLogin.xcodeproj -scheme OnlyXLogin -destination 'generic/platform=iOS' \
  -configuration Debug -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAMID> build
```

If `ai.onlyx.login` is already taken on the team, change `PRODUCT_BUNDLE_IDENTIFIER` in
`project.yml`, regenerate, and say so in the PR — the plan names that id.

Run it from Xcode (⌘R). On a personal/free team the phone asks to trust the developer profile
(Settings › General › VPN & Device Management). Then mint a fresh pass as above and get the link
onto the phone: paste it into Safari's address bar (iOS asks "Open in OnlyX Login?"), or copy it
and use **Paste your link** on the app's idle screen. Sign in as the test creator; allow the camera
when iOS asks; follow OnlyFans' selfie check if it appears. Watch the log in Console.app with the
same subsystem filter.

## 4. What to report back (this is the deliverable)

- Device and iOS version; whether the deep link opened the app from Safari and from a chat app.
- Each screen reached, in order, and what OnlyFans showed: email code, captcha, selfie/video
  check, anything unexpected. Whether the selfie vendor's page worked inside the app (camera
  preview visible, check completed).
- The log excerpt from `pass opened` to the terminal line, with cookies/tokens redacted.
- The seat's verdict: the Connected screen, or the error shown, and the `statusReason` if any.
- Anything you changed: on the branch, as a PR, with `swift test` and the simulator build green.
  Likely tuning: the 2-second settle before the jar is read, the `/users/me` observer if it never
  fires (check `guest answer` lines), the sub-frame navigation rule if the vendor's iframe blanks.

## 5. TestFlight

Only after a device run has reached Connected at least once.

1. In App Store Connect create the app record: name **OnlyX Login**, bundle id `ai.onlyx.login`,
   primary language English. Export compliance is already answered in Info.plist
   (`ITSAppUsesNonExemptEncryption = NO`).
2. Xcode: Product › Archive with "Any iOS Device (arm64)" selected, then Distribute App › App Store
   Connect › Upload, automatic signing.
3. App Store Connect › TestFlight: add the build to an **external** group, fill the Beta App Review
   notes plainly — "A sign-in helper: a creator opens it from a link her agency sends, signs in to
   her own OnlyFans account inside the app, and the app hands the session to OnlyX. It stores
   nothing." — and submit. Enable the **public link** on the group.
4. Send the public link back. On the server it becomes `CONNECT_APP_DOWNLOAD_IOS_URL` for the OnlyX
   API, which is what makes the connect page offer the app to iPhones (PRs x-onlyx-api #276 and
   x-onlyx-ui #258, once merged and deployed). Builds expire after 90 days; a new archive is a
   new build in the same group.

## Reference, so you do not have to rediscover it

- The mac app this mirrors: https://github.com/x-project-coding/x-onlyx-login (`src/main.js` is the
  flow; `src/session-capture.js` the capture rules). The server side is x-onlyfans
  `apps/api/src/modules/connect-app/`.
- The API base is compiled in (`Config.apiBase`). A Debug build honours `ONLYX_API_BASE` from the
  scheme's environment for pointing at a test server; a Release build ignores it.
- The three things iOS forces (native identity, the user-script observer, no tunnel) are explained
  in README.md "What iOS cannot do". Do not "fix" them into the mac app's shape.
