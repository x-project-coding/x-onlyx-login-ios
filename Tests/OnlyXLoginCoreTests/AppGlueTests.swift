import XCTest
@testable import OnlyXLoginCore

/// The decisions that used to live in the app target, where no Linux test could reach them
/// (found in review: the JS could be broken outright and every test stayed green).
final class AppGlueTests: XCTestCase {
    func testPlatformCookieWithNoExpiryIsASessionCookieAndTravelsAsMinusOne() {
        let sess = SessionCapture.RawCookie(name: "sess", value: "s", domain: ".onlyfans.com", path: "/",
                                            expiresDate: nil, httpOnly: true, secure: true)
        XCTAssertTrue(sess.isSession); XCTAssertNil(sess.expires)
        let auth = SessionCapture.RawCookie(name: "auth_id", value: "42", domain: ".onlyfans.com", path: "/",
                                            expiresDate: Date(timeIntervalSince1970: 1_900_000_000), httpOnly: true, secure: true)
        XCTAssertFalse(auth.isSession); XCTAssertEqual(auth.expires, 1_900_000_000)
        let p = SessionCapture.buildSessionPayload(cookies: [sess, auth], xbc: nil)
        XCTAssertEqual(p.cookies.first { $0.name == "sess" }?.expires, -1)
        XCTAssertEqual(p.cookies.first { $0.name == "auth_id" }?.expires, 1_900_000_000)
    }
    func testParseXbcAcceptsOnlyTheJsonPairTheExpressionReturns() {
        let v = String(repeating: "a", count: 40)
        XCTAssertEqual(SessionCapture.parseXbc(#"{"key":"bcTokenSha","value":"\#(v)"}"#)?.value, v)
        XCTAssertEqual(SessionCapture.parseXbc(NSString(string: #"{"key":"k","value":"v"}"#))?.key, "k")
        XCTAssertNil(SessionCapture.parseXbc(nil))
        XCTAssertNil(SessionCapture.parseXbc(NSNull()))
        XCTAssertNil(SessionCapture.parseXbc("null"))
        XCTAssertNil(SessionCapture.parseXbc(#"{"key":"k"}"#))
        XCTAssertNil(SessionCapture.parseXbc(#"{"key":"","value":"v"}"#))
    }
    func testNavigationPolicyIsHttpsOnlyForTheMainFrameAndHandsOffSubframes() {
        XCTAssertTrue(SessionCapture.allowsNavigation(url: URL(string: "https://onlyfans.com/"), isMainFrame: true))
        XCTAssertTrue(SessionCapture.allowsNavigation(url: URL(string: "about:blank"), isMainFrame: true))
        XCTAssertFalse(SessionCapture.allowsNavigation(url: URL(string: "http://onlyfans.com/"), isMainFrame: true))
        XCTAssertFalse(SessionCapture.allowsNavigation(url: URL(string: "onlyfans://x"), isMainFrame: true))
        XCTAssertFalse(SessionCapture.allowsNavigation(url: URL(string: "about:srcdoc"), isMainFrame: true), "the main frame stays https")
        XCTAssertFalse(SessionCapture.allowsNavigation(url: nil, isMainFrame: true))
        XCTAssertTrue(SessionCapture.allowsNavigation(url: URL(string: "about:srcdoc"), isMainFrame: false))
        XCTAssertTrue(SessionCapture.allowsNavigation(url: URL(string: "blob:https://onlyfans.com/1"), isMainFrame: false))
        XCTAssertTrue(SessionCapture.allowsNavigation(url: URL(string: "data:text/html,x"), isMainFrame: false))
        XCTAssertFalse(SessionCapture.allowsNavigation(url: URL(string: "http://evil.test/"), isMainFrame: false))
    }
    func testAnOversizedReportIsRefused() {
        let big = String(repeating: "x", count: MeObserver.maxBodyBytes + 1)
        XCTAssertNil(MeObserver.decode(["status": 200, "body": big]))
        XCTAssertNotNil(MeObserver.decode(["status": 200, "body": String(repeating: "x", count: 100)]))
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

/// The observer script, EXECUTED — on macOS/iOS where JavaScriptCore is available (CI runs the
/// core suite on macOS). A substring test cannot fail on a broken script; this one does.
final class MeObserverScriptTests: XCTestCase {
    private func run(fetchStatus: Int, fetchBody: String, urls: [String], xhr: (url: String, responseType: String, text: String?, json: String?)? = nil) -> [[String: Any]] {
        let ctx = JSContext()!
        var errors: [String] = []
        ctx.exceptionHandler = { _, e in errors.append(e?.toString() ?? "?") }
        ctx.evaluateScript("""
        var reports = [];
        var window = this;
        window.location = { href: 'https://onlyfans.com/' };
        window.webkit = { messageHandlers: { onlyxMe: { postMessage: function (m) { reports.push(m); } } } };
        window.fetch = function (input, init) {
          var self = this;
          return Promise.resolve({ status: \(fetchStatus), clone: function () { return this; }, text: function () { return Promise.resolve(\(fetchBody.debugDescription)); } });
        };
        function XMLHttpRequest() { this.status = 200; this.responseType = ''; this._l = {}; }
        XMLHttpRequest.prototype.open = function (m, u) { this._url = u; };
        XMLHttpRequest.prototype.send = function () { var self = this; setTimeoutLike(function () { (self._l.load || function () {})(); }); };
        XMLHttpRequest.prototype.addEventListener = function (n, f) { this._l[n] = f; };
        var queued = []; function setTimeoutLike(f) { queued.push(f); }
        """)
        ctx.evaluateScript(MeObserver.script)
        for u in urls { ctx.evaluateScript("window.fetch('\(u)');") }
        if let xhr {
            let text = xhr.text.map { $0.debugDescription } ?? "undefined"
            let json = xhr.json ?? "undefined"
            ctx.evaluateScript("""
            (function () {
              var x = new XMLHttpRequest();
              x.open('GET', '\(xhr.url)');
              x.responseType = '\(xhr.responseType)';
              Object.defineProperty(x, 'responseText', { get: function () { if (x.responseType !== '' && x.responseType !== 'text') throw new Error('InvalidStateError'); return \(text); } });
              x.response = \(json);
              x.send();
            })();
            queued.forEach(function (f) { f(); });
            """)
        }
        // drain the promise queue
        ctx.evaluateScript("Promise.resolve().then(function(){}).then(function(){});")
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(errors, [], "the script threw")
        return ctx.objectForKeyedSubscript("reports").toArray() as? [[String: Any]] ?? []
    }

    func testFetchReportsOnlyUsersMeWithStatusAndBody() {
        let reports = run(fetchStatus: 200, fetchBody: #"{"id":7,"username":"a"}"#,
                          urls: ["https://onlyfans.com/api2/v2/users/me", "https://onlyfans.com/api2/v2/users/1", "/api2/v2/users/me"])
        XCTAssertEqual(reports.count, 2, "the absolute and the relative /users/me, not /users/1")
        XCTAssertEqual(reports.first?["status"] as? Int, 200)
        XCTAssertEqual(reports.first?["body"] as? String, #"{"id":7,"username":"a"}"#)
    }
    func testAForeignHostIsNotReported() {
        let reports = run(fetchStatus: 200, fetchBody: "{}", urls: ["https://x-onlyfans.com/api2/v2/users/me", "https://onlyfans.com.evil.test/api2/v2/users/me"])
        XCTAssertEqual(reports.count, 0)
    }
    func testXhrWithJsonResponseTypeStillReports() {
        let reports = run(fetchStatus: 200, fetchBody: "{}", urls: [],
                          xhr: (url: "/api2/v2/users/me", responseType: "json", text: nil, json: #"{"id":9}"#))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?["body"] as? String, #"{"id":9}"#)
    }
    func testXhrTextReports() {
        let reports = run(fetchStatus: 200, fetchBody: "{}", urls: [],
                          xhr: (url: "https://onlyfans.com/api2/v2/users/me", responseType: "", text: #"{"id":3}"#, json: nil))
        XCTAssertEqual(reports.first?["body"] as? String, #"{"id":3}"#)
    }
}
#endif
