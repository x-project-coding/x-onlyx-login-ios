import Foundation

/// How the app hears OnlyFans name the creator, without a DevTools protocol.
///
/// The mac app watches `/api2/v2/users/me` over CDP (`Network.responseReceived` +
/// `Network.getResponseBody`) — a read that touches nothing in the page. WebKit offers no such
/// hook: a WKWebView sees main-frame navigations, never a page's XHR/fetch bodies. So the iPhone
/// app runs a user script at document start that wraps `fetch` and `XMLHttpRequest` in the main
/// frame and posts ONLY the `/users/me` answer (status + body) to the native side through
/// `window.webkit.messageHandlers.onlyxMe`. Everything else passes through untouched.
///
/// THE HONEST COST: unlike the CDP watch, this is visible to the page — `window.fetch.toString()`
/// no longer reads `[native code]`. It is the same class of tell as the seat's own pins, and the
/// only page that could look is OnlyFans' own. A future de-injection: the `auth_id` cookie IS the
/// OnlyFans user id, so a cookie-store observer could supply `ofUserId` with no script at all; it
/// cannot supply the "OnlyFans itself said so" signal a `/users/me` 200 gives, which is why the
/// watch is kept for v1 (see README).
public enum MeObserver {
    /// The message-handler name the script posts to; the app registers it on the WKUserContentController.
    public static let handlerName = "onlyxMe"

    public static let script = """
    (() => {
      const ME = '/api2/v2/users/me';
      const report = (status, body) => {
        try { window.webkit.messageHandlers.onlyxMe.postMessage({ status: status, body: body }); } catch (e) {}
      };
      const isMe = (url) => {
        try {
          const u = new URL(url, location.href);
          return /(^|\\.)onlyfans\\.com$/i.test(u.hostname) && u.pathname === ME;
        } catch (e) { return false; }
      };
      const nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function (input, init) {
          const p = nativeFetch.apply(this, arguments);
          try {
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            if (isMe(url)) {
              p.then((res) => {
                try { res.clone().text().then((t) => report(res.status, t)).catch(() => {}); } catch (e) {}
              }).catch(() => {});
            }
          } catch (e) {}
          return p;
        };
      }
      const XO = XMLHttpRequest.prototype.open;
      const XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__onlyxMe = isMe(url); } catch (e) { this.__onlyxMe = false; }
        return XO.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        if (this.__onlyxMe) {
          this.addEventListener('load', () => { try { report(this.status, this.responseText); } catch (e) {} });
        }
        return XS.apply(this, arguments);
      };
    })();
    """

    /// The message the script posts, decoded from the WKScriptMessage body dictionary.
    public struct Report: Equatable, Sendable {
        public let status: Int
        public let body: String
        public init(status: Int, body: String) { self.status = status; self.body = body }
    }

    /// Decode a message body as WebKit hands it over (`[String: Any]`). Anything malformed is nil —
    /// a page cannot forge a sign-in by posting garbage, because `judgeMe` still has to name an id
    /// and the jar still has to carry the login cookies.
    public static func decode(_ any: Any) -> Report? {
        guard let dict = any as? [String: Any] else { return nil }
        let status: Int
        switch dict["status"] {
        case let n as Int: status = n
        case let n as NSNumber: status = n.intValue
        default: return nil
        }
        guard let body = dict["body"] as? String else { return nil }
        return Report(status: status, body: body)
    }

    /// The observation, judged: a 200 that names a user, or nil.
    public static func judge(_ report: Report) -> SessionCapture.Me? {
        guard report.status == 200 else { return nil }
        return SessionCapture.judgeMe(Data(report.body.utf8))
    }
}
