import Foundation

/// Which identity the sign-in view presents, and why the iPhone app can only present its own.
///
/// On the desktop the server chooses between `seat` (wear the Linux container's Mac profile) and
/// `native` (present the real machine). It applies the seat's client hints over the Chrome DevTools
/// Protocol. WebKit exposes NO such protocol: WKWebView can set the User-Agent STRING
/// (`customUserAgent`) but cannot send `Sec-CH-UA-*` client hints or override `navigator.platform`.
///
/// That makes `seat` mode incoherent on iOS in exactly the way `native` mode exists to avoid: a Mac
/// User-Agent with no client hints beside it is the "all blank" tell x-onlyfans' device-profile.js
/// names, and iOS Safari's TLS is WebKit, not Chromium, so a Chrome UA over it is a fresh
/// contradiction. So the iPhone app runs NATIVE mode: it declares the capability, the server sends
/// an empty wire story, and the app leaves WKWebView's own honest iPhone-Safari identity untouched.
/// A real iPhone Safari is already a coherent device — and, unlike Chromium, it sends no client
/// hints, so there is nothing missing.
///
/// The one thing this leaves for the server side, flagged in the README: the seat that resumes an
/// iPhone sign-in is still the `mac` profile (x-onlyfans APP_DEVICE_PROFILE), so the resume presents
/// macOS where the sign-in was iOS — a larger declared-device delta than the mac app's. `platform`
/// below is sent so the estate can measure it; closing it needs an iPhone seat profile, which is a
/// server change, not an app one.
public enum NativeIdentity {
    /// What this build tells the server it can do. The server gates the native wire story on it.
    public static let nativeIdentityCap = "nativeIdentity"
    public static let appCaps = [nativeIdentityCap]

    /// The server's instruction. Anything but `native` means "wear what you were sent" — which this
    /// app can only partially honour (the UA string, never the client hints).
    public static func isNative(_ identity: Identity) -> Bool {
        identity.source == "native"
    }

    /// The platform string sent with the claim, e.g. `ios-17.5`. Recorded in ConnectAppPass.platform
    /// so iPhone sign-ins are distinguishable in the estate. Bounded at the server's 32 chars.
    public static func platformTag(systemVersion: String) -> String {
        let tag = "ios-\(systemVersion)"
        return String(tag.prefix(32))
    }

    /// In native mode the app applies NOTHING to WKWebView's own User-Agent — WebKit's iPhone Safari
    /// string is already the honest one, and it needs no cleaning (there is no Electron/app token to
    /// remove, unlike the desktop). Returns the customUserAgent to set, or nil to leave the engine's
    /// own — which is what native mode always does on iOS.
    ///
    /// For a `seat`-mode response the server sends a Mac UA string; the app can set that string but
    /// cannot send the client hints that would make it coherent, so this returns it while the caller
    /// records that the wire story is only half-applied. Native is the estate default, so this is
    /// the exceptional branch.
    public static func customUserAgent(for identity: Identity) -> String? {
        if isNative(identity) { return nil }
        // seat mode: best-effort UA string only (degraded — see doc above).
        if let ua = identity.userAgent, !ua.isEmpty { return ua }
        return nil
    }
}
