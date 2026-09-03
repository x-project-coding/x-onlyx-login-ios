import XCTest
@testable import OnlyXLoginCore

final class SessionCaptureTests: XCTestCase {
    private func raw(_ name: String, _ value: String, domain: String = ".onlyfans.com",
                     session: Bool = true, expires: Double? = nil,
                     httpOnly: Bool? = nil, secure: Bool? = nil) -> SessionCapture.RawCookie {
        .init(name: name, value: value, domain: domain, path: "/", isSession: session,
              expires: expires, httpOnly: httpOnly, secure: secure)
    }

    func testJudgeMeNamesTheUser() {
        let me = SessionCapture.judgeMe(Data(#"{"id":123456,"username":"delfi.1"}"#.utf8))
        XCTAssertEqual(me, .init(id: "123456", username: "delfi.1"))
    }
    func testJudgeMeStringifiesANumericId() {
        XCTAssertEqual(SessionCapture.judgeMe(Data(#"{"id":42}"#.utf8))?.id, "42")
    }
    func testJudgeMeRefusesTheGuestAnswer() {
        // A 200 with no id is the guest body, not a sign-in.
        XCTAssertNil(SessionCapture.judgeMe(Data(#"{"hasPassword":true}"#.utf8)))
        XCTAssertNil(SessionCapture.judgeMe(Data(#"not json"#.utf8)))
        XCTAssertNil(SessionCapture.judgeMe(Data(#"{"id":0}"#.utf8)))
    }
    func testIsMeUrlIsAnchoredToTheRealHost() {
        XCTAssertTrue(SessionCapture.isMeUrl("https://onlyfans.com/api2/v2/users/me"))
        XCTAssertTrue(SessionCapture.isMeUrl("https://www.onlyfans.com/api2/v2/users/me?x=1"))
        XCTAssertFalse(SessionCapture.isMeUrl("https://x-onlyfans.com/api2/v2/users/me"))
        XCTAssertFalse(SessionCapture.isMeUrl("https://onlyfans.com.evil.test/api2/v2/users/me"))
        XCTAssertFalse(SessionCapture.isMeUrl("https://onlyfans.com/api2/v2/users/1"))
    }
    func testHasLoginCookiesNeedsBothWithValues() {
        XCTAssertTrue(SessionCapture.hasLoginCookies([raw("sess", "s"), raw("auth_id", "42")]))
        XCTAssertFalse(SessionCapture.hasLoginCookies([raw("sess", "s")]))
        XCTAssertFalse(SessionCapture.hasLoginCookies([raw("sess", "s"), raw("auth_id", "")]))
        // A login cookie on a foreign domain does not count.
        XCTAssertFalse(SessionCapture.hasLoginCookies([raw("sess", "s"),
            raw("auth_id", "42", domain: "evil.test")]))
    }
    func testBuildPayloadKeepsOnlyOnlyFansCookiesWithValues() {
        let cookies = [
            raw("sess", "abc", session: true),
            raw("auth_id", "42", session: false, expires: 1_900_000_000),
            raw("__cf_bm", "drop", domain: ".onlyfans.com"),   // NEVER-restored
            raw("empty", "", domain: ".onlyfans.com"),          // valueless
            raw("other", "x", domain: "google.com"),            // foreign
        ]
        let p = SessionCapture.buildSessionPayload(cookies: cookies,
            xbc: (key: "bcTokenSha", value: String(repeating: "a", count: 40)))
        XCTAssertEqual(p.cookies.map(\.name).sorted(), ["auth_id", "sess"])
        XCTAssertEqual(p.cookies.first(where: { $0.name == "sess" })?.expires, -1)      // session -> -1
        XCTAssertEqual(p.cookies.first(where: { $0.name == "auth_id" })?.expires, 1_900_000_000)
        XCTAssertEqual(p.cookieHeader, "sess=abc; auth_id=42")
        XCTAssertEqual(p.xbc, String(repeating: "a", count: 40))
        XCTAssertEqual(p.xbcKey, "bcTokenSha")
        XCTAssertTrue(p.capturedAt.contains("T"))
    }
    func testBuildPayloadWithoutADeviceToken() {
        let p = SessionCapture.buildSessionPayload(cookies: [raw("sess", "s")], xbc: nil)
        XCTAssertNil(p.xbc); XCTAssertNil(p.xbcKey)
    }
    func testTheXbcExpressionMatchesTheSeat() {
        XCTAssertTrue(SessionCapture.readXbcExpression.contains("localStorage"))
        XCTAssertTrue(SessionCapture.readXbcExpression.contains("[0-9a-f]{40}"))
    }
    func testTheHardenScriptNeutralisesWebAuthn() {
        XCTAssertTrue(SessionCapture.hardenScript.contains("navigator.credentials"))
        XCTAssertTrue(SessionCapture.hardenScript.contains("PublicKeyCredential"))
    }
}
