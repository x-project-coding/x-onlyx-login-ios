# iPhone account-proxy release candidate

Version 1.1 (proposed build 5), minimum iOS 17. The previous shipped builds remain unchanged.
This file describes the candidate, not Apple approval or a completed creator connection.

## Route and boundaries

The app advertises `iosProxyTunnelV1`. The server's independent `XOF_CONNECT_APP_IOS_TUNNEL`
switch negotiates a tunnel only with that capability and iOS 17+. Do **not** enable the desktop
`XOF_CONNECT_APP_TUNNEL` switch for this release: a desktop handing the selfie to a different
phone has different routing requirements.

WebKit uses `WKWebsiteDataStore.proxyConfigurations` before constructing its private web view.
Its authenticated loopback SOCKS5 listener forwards each domain-name HTTPS connection over WSS
to the existing OnlyX relay. The relay owns the upstream proxy credentials. The app only holds a
short-lived, per-account pass and random local credentials, all in memory. TLS to the website
remains end-to-end. The relay origin must match the compiled API origin; redirects cannot carry
the bearer elsewhere. Local clients without the run's password are refused.

The backend records the assigned proxy and its measured exit IP at open. The app verifies that
exit through its proxy before showing sign-in and again before import. The backend remeasures
before saving. A route change, missing route, failed measurement or dead proxy is an error;
`allowFailover` is false. Disabling rollout cannot waive a previously negotiated import's pin.
Expired, revoked, consumed and reassigned passes cannot keep using the relay. Established
streams are reauthorized every 30 seconds and closed at expiry.

This is an **in-app web proxy**, not a device-wide VPN. External Safari, other apps, a different
phone and non-web transports must not be assumed to inherit it. `window.open` stays in the same
web view; the camera still uses Apple's permission flow. The vendor's actual selfie flow and
network transitions require device testing, not an assumption based on HTTPS tests.

## Repeatable checks

```sh
swift test
ONLYX_RUN_NETWORK_TESTS=1 swift test
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodegen generate
xcodebuild -project OnlyXLogin.xcodeproj -scheme OnlyXLogin \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/proxy-tests CODE_SIGNING_ALLOWED=NO test
```

Use an appropriate installed Xcode via `DEVELOPER_DIR`. The optional network test uses only the
public IP echo and a local fixture, never a real creator or production proxy. It exercises the
actual WebKit network process and URLSession through real sockets, checks the relay was used,
then closes the proxy and requires both paths to fail. Socket tests also cover local credentials,
binary integrity and teardown. Core tests cover fragmentation, invalid targets, URL-origin
validation, capability negotiation and missing-route refusal. Server tests cover pass lifecycle,
unchanged legacy behavior, exit rotation and atomic session import.

## Release gates

1. Deploy the reviewed additive server schema (`ConnectAppPass.iosTunnel`, `tunnelExitIp`) and
   code with the new switch **off**. Do not change existing workers or desktop routing.
2. Build on the supported host using [SUPPORTED-RELEASE.md](SUPPORTED-RELEASE.md). Verify the
   current unused build number in App Store Connect before uploading. Preserve original compiler
   metadata; simulator success on a beta Mac is not a supported App Store archive.
3. Test a limited candidate with the iOS switch enabled. Old app builds lack the capability and
   stay on their old route; this new build refuses an unmeasured/direct response.
4. On a real iPhone, complete a fresh creator sign-in and any selfie check, verify server-side
   `/users/me` identifies the expected creator and the UI reaches Connected, then verify a
   subsequent read and a worker session restore still work. Record only IDs, statuses and
   redacted diagnostics—never cookies, passwords, pass tokens or the selfie.
5. Test Wi-Fi/cellular transition, expired link, app background/foreground, denied camera and
   proxy loss. Proxy failures must not open a direct route.
6. Only then widen TestFlight distribution. A public invite, upload, successful proxy probe or
   API import acceptance alone is not proof that OnlyFans accepted the session on the worker.

The native-to-worker browser identity mismatch is separate from exit consistency. This build
adds the exact observed User-Agent to the import body for the corresponding server work; it
does not pretend that WebKit and Chromium become the same browser by sharing an IP or UA.

## Apple API references

- [WKWebsiteDataStore.proxyConfigurations](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-cdc1)
- [ProxyConfiguration](https://developer.apple.com/documentation/network/proxyconfiguration)
- [Apple's WebKit proxy example](https://developer.apple.com/videos/play/wwdc2023/10002/)
