import Foundation

/// Where the app talks to, and the link scheme it answers — fixed in the binary, exactly as the
/// mac app fixes them (src/config.js, src/deep-link.js).
///
/// Nothing the creator receives can move the API base: the deep link carries a one-time claim and
/// nothing else, so a forged link cannot make the app hand a session to somebody else's server. The
/// one override is for development and tests and is honoured ONLY in a debug build — a release build
/// ignores the environment entirely, the way `app.isPackaged` gates it on the desktop.
public enum Config {
    /// The single server this app speaks to. Compiled in.
    public static let apiBase = "https://of-api.onlyx.ai"

    /// The custom URL scheme a connect link uses: `onlyx-connect://open?c=<claim>`.
    public static let scheme = "onlyx-connect"

    /// Help lives inside the app, never behind a link — `onlyx.ai/connect-app` 404s, so a stuck
    /// creator with no connection still needs an answer she can read.
    public static let supportEmail = "support@onlyx.ai"

    /// Resolve the API base. `packaged` is false only in a debug build; an override is honoured
    /// solely then, so a shipped app can never be pointed elsewhere.
    public static func resolveApiBase(packaged: Bool, override: String?) -> String {
        if !packaged, let override, !override.isEmpty {
            return trimTrailingSlashes(override)
        }
        return apiBase
    }

    static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
