import Foundation

/// What "signed in" means, and what gets handed back — the same rules the seat uses so the jar this
/// app captures is one the seat can resume (x-onlyfans worker/runtime/src/session.js). A faithful
/// port of src/session-capture.js.
///
/// Signed in = OnlyFans itself said so: a 200 from `/api2/v2/users/me` naming an `id`, AND the two
/// login cookies (`sess`, `auth_id`) present in the jar at that moment. A cookie alone can be dead;
/// a `/users/me` alone can be the guest answer (a 200 with no `id`).
public enum SessionCapture {
    public static let mePath = "/api2/v2/users/me"
    /// Cookies the seat never restores; captured here they would only be dropped there.
    static let never: Set<String> = ["__cf_bm", "_cfuvid"]

    /// Is this the `/users/me` request whose body names the creator? Anchored to the real host so
    /// `x-onlyfans.com` and `onlyfans.com.evil.test` do not match.
    public static func isMeUrl(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url), let host = comps.host else { return false }
        return isOnlyFansHost(host) && comps.path == mePath
    }

    /// A host that is onlyfans.com or a subdomain of it — the same anchored check the cookie filter
    /// uses, so the URL filter and the jar filter cannot disagree about what OnlyFans is.
    static func isOnlyFansHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "onlyfans.com" || h.hasSuffix(".onlyfans.com")
    }

    /// A cookie domain, which may carry a leading dot (`.onlyfans.com`).
    static func isOnlyFansCookieDomain(_ domain: String?) -> Bool {
        guard let domain, !domain.isEmpty else { return false }
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return isOnlyFansHost(d)
    }

    public struct Me: Equatable, Sendable {
        public let id: String
        public let username: String?
    }

    /// `id` and `username` from a `/users/me` body, or nil for a guest answer or anything
    /// unparseable. The id is stringified because OnlyFans sends it as a number.
    public static func judgeMe(_ body: Data) -> Me? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let idValue = obj["id"]
        let id: String
        switch idValue {
        case let n as NSNumber: id = n.stringValue
        case let s as String where !s.isEmpty: id = s
        default: return nil
        }
        guard id != "0", !id.isEmpty else { return nil }
        let username = obj["username"] as? String
        return Me(id: id, username: username)
    }

    /// A minimal cookie as read from the platform's cookie store, before it is shaped for the wire.
    public struct RawCookie: Sendable, Equatable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String?
        /// A session cookie (no expiry). Maps to `expires: -1`, the seat's shape for one.
        public let isSession: Bool
        public let expires: Double?
        public let httpOnly: Bool?
        public let secure: Bool?
        public init(name: String, value: String, domain: String, path: String?,
                    isSession: Bool, expires: Double?, httpOnly: Bool?, secure: Bool?) {
            self.name = name; self.value = value; self.domain = domain; self.path = path
            self.isSession = isSession; self.expires = expires; self.httpOnly = httpOnly; self.secure = secure
        }
    }

    /// Both login cookies present with a value — the jar half of "signed in".
    public static func hasLoginCookies(_ cookies: [RawCookie]) -> Bool {
        var named = Set<String>()
        for c in cookies where isOnlyFansCookieDomain(c.domain) && !c.value.isEmpty {
            named.insert(c.name)
        }
        return named.contains("sess") && named.contains("auth_id")
    }

    static func normalize(_ c: RawCookie) -> SessionCookie {
        let path = (c.path?.isEmpty == false) ? c.path! : "/"
        let expires: Double? = c.isSession ? -1 : c.expires
        return SessionCookie(name: c.name, value: c.value, domain: c.domain, path: path,
                             expires: expires, httpOnly: c.httpOnly, secure: c.secure)
    }

    /// The import body for `POST /connect-app/session`. `xbc` is `(key, value)` of the device token
    /// or nil. Keeps only OnlyFans cookies with a value, drops the two the seat never restores.
    public static func buildSessionPayload(cookies: [RawCookie],
                                           xbc: (key: String, value: String)?,
                                           now: Date = Date()) -> SessionPayload {
        let kept = cookies
            .filter { isOnlyFansCookieDomain($0.domain) && !never.contains($0.name)
                        && !$0.name.isEmpty && !$0.value.isEmpty }
            .map(normalize)
        let header = kept.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let iso = ISO8601DateFormatter.onlyxMillis.string(from: now)
        return SessionPayload(cookies: kept, cookieHeader: header,
                              xbc: xbc?.value, xbcKey: xbc?.key, capturedAt: iso)
    }

    /// The in-page expression that finds the device token, verbatim from the seat and the mac app:
    /// any localStorage key naming `bc` whose value is 40 hex characters. Read via
    /// `evaluateJavaScript` on WKWebView, the WebKit stand-in for the mac app's CDP Runtime.evaluate.
    public static let readXbcExpression = """
    (() => {
      try {
        for (const key of Object.keys(localStorage)) {
          if (key.toLowerCase().includes('bc')) {
            const value = localStorage.getItem(key);
            if (value && /^[0-9a-f]{40}$/i.test(value)) return JSON.stringify({ key, value });
          }
        }
      } catch (e) {}
      return null;
    })()
    """

    /// The seat's WebAuthn hardening, applied here for the same reason: OnlyFans probes WebAuthn on
    /// the login form, and a passkey the seat cannot replay is a dead end for the session it must
    /// resume. Injected as a WKUserScript at document start.
    public static let hardenScript = """
    try {
      if (navigator.credentials) {
        navigator.credentials.get = () => Promise.reject(new DOMException('Not supported', 'NotAllowedError'));
        navigator.credentials.create = () => Promise.reject(new DOMException('Not supported', 'NotAllowedError'));
      }
      if (window.PublicKeyCredential) {
        window.PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
        window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
      }
    } catch (e) {}
    """
}

extension ISO8601DateFormatter {
    /// `capturedAt` carries milliseconds, matching `new Date().toISOString()` on the desktop.
    static let onlyxMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
