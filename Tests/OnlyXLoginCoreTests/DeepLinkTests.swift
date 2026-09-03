import XCTest
@testable import OnlyXLoginCore

final class DeepLinkTests: XCTestCase {
    func testAcceptsTheCanonicalLink() {
        XCTAssertEqual(DeepLink.parse("onlyx-connect://open?c=ubinfrk9fQINiOa_b0PAG9G5tBb5xXFLo0FSsq1Oooo"),
                       "ubinfrk9fQINiOa_b0PAG9G5tBb5xXFLo0FSsq1Oooo")
    }
    func testAcceptsTheSchemeColonForm() {
        XCTAssertEqual(DeepLink.parse("onlyx-connect:open?c=abcd1234abcd"), "abcd1234abcd")
    }
    func testStripsSurroundingQuotesTheShellAdds() {
        XCTAssertEqual(DeepLink.parse("\"onlyx-connect://open?c=abcd1234abcd\""), "abcd1234abcd")
        XCTAssertEqual(DeepLink.parse("  onlyx-connect://open?c=abcd1234abcd  "), "abcd1234abcd")
    }
    func testCaseInsensitiveScheme() {
        XCTAssertEqual(DeepLink.parse("ONLYX-CONNECT://OPEN?c=abcd1234abcd"), "abcd1234abcd")
    }
    func testRejectsAnotherScheme() {
        XCTAssertNil(DeepLink.parse("https://onlyx.ai/connect?c=abcd1234abcd"))
        XCTAssertNil(DeepLink.parse("onlyx-evil://open?c=abcd1234abcd"))
    }
    func testRejectsTheWrongAction() {
        XCTAssertNil(DeepLink.parse("onlyx-connect://import?c=abcd1234abcd"))
    }
    func testRejectsAMissingOrMalformedClaim() {
        XCTAssertNil(DeepLink.parse("onlyx-connect://open"))
        XCTAssertNil(DeepLink.parse("onlyx-connect://open?c="))
        XCTAssertNil(DeepLink.parse("onlyx-connect://open?c=short"))          // < 8
        XCTAssertNil(DeepLink.parse("onlyx-connect://open?c=has space here!")) // bad chars
    }
    func testAcceptsTheExactBoundaryLengths() {
        XCTAssertNotNil(DeepLink.parse("onlyx-connect://open?c=\(String(repeating: "a", count: 8))"))
        XCTAssertNotNil(DeepLink.parse("onlyx-connect://open?c=\(String(repeating: "a", count: 512))"))
        XCTAssertNil(DeepLink.parse("onlyx-connect://open?c=\(String(repeating: "a", count: 513))"))
    }
    func testConfigOverrideOnlyInDebugBuild() {
        XCTAssertEqual(Config.resolveApiBase(packaged: true, override: "https://evil.test"), Config.apiBase)
        XCTAssertEqual(Config.resolveApiBase(packaged: false, override: "https://dev.test/"), "https://dev.test")
        XCTAssertEqual(Config.resolveApiBase(packaged: false, override: nil), Config.apiBase)
    }
}
