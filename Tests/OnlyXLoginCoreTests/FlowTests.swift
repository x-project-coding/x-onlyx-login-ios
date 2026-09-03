import XCTest
@testable import OnlyXLoginCore

final class FlowTests: XCTestCase {
    private func identity(source: String) -> Identity {
        Identity(profile: "mac", source: source, userAgent: source == "native" ? "" : "Mozilla/5.0 Mac",
                 acceptLanguage: source == "native" ? nil : "en-US,en", platform: source == "native" ? nil : "MacIntel",
                 initScript: nil, timezone: nil)
    }
    private func open(tunnel: String?, source: String = "native") -> OpenResponse {
        OpenResponse(sessionToken: "tok", expiresAt: "2026-09-03T02:00:00Z",
                     account: .init(id: "acct-1", username: "delfi.1", status: "connecting"),
                     identity: identity(source: source), tunnel: tunnel.map { Tunnel(url: $0) })
    }

    func testNoTunnelIsTheSignInPath() {
        let d = ConnectFlow.disposition(for: open(tunnel: nil))
        XCTAssertEqual(d, .signIn(username: "delfi.1", expiresAt: "2026-09-03T02:00:00Z", native: true))
    }
    func testAnExplicitNullTunnelStillSignsIn() {
        // tunnel: null decodes to Tunnel? = nil OR Tunnel(url: nil); both are the sign-in path.
        XCTAssertEqual(ConnectFlow.disposition(for: open(tunnel: nil)),
                       .signIn(username: "delfi.1", expiresAt: "2026-09-03T02:00:00Z", native: true))
        let withNullUrl = OpenResponse(sessionToken: "t", expiresAt: "e",
            account: .init(id: "a", username: "u", status: "connecting"),
            identity: identity(source: "native"), tunnel: Tunnel(url: nil))
        if case .signIn = ConnectFlow.disposition(for: withNullUrl) {} else { XCTFail("null url must sign in") }
    }
    func testAnOfferedTunnelIsRefusedAsUnsupported() {
        XCTAssertEqual(ConnectFlow.disposition(for: open(tunnel: "wss://of-api.onlyx.ai/connect-app/tunnel")),
                       .tunnelUnsupported)
    }
    func testCaptureGuards() {
        let me = SessionCapture.Me(id: "123", username: "delfi.1")
        XCTAssertTrue(ConnectFlow.shouldCapture(me: me, alreadyCaptured: false, capturing: false, refusedIds: []))
        XCTAssertFalse(ConnectFlow.shouldCapture(me: me, alreadyCaptured: true, capturing: false, refusedIds: []))
        XCTAssertFalse(ConnectFlow.shouldCapture(me: me, alreadyCaptured: false, capturing: true, refusedIds: []))
        XCTAssertFalse(ConnectFlow.shouldCapture(me: me, alreadyCaptured: false, capturing: false, refusedIds: ["123"]))
    }
    func testImportOutcomes() {
        XCTAssertEqual(ConnectFlow.importOutcome(code: nil), .imported)
        // wrong account / duplicate: recoverable, and the id is remembered
        if case let .retrySignIn(_, remember) = ConnectFlow.importOutcome(code: "wrong_creator") {
            XCTAssertTrue(remember)
        } else { XCTFail() }
        if case let .retrySignIn(_, remember) = ConnectFlow.importOutcome(code: "duplicate_account") {
            XCTAssertTrue(remember)
        } else { XCTFail() }
        // session_unusable: recoverable but NOT tied to an id
        if case let .retrySignIn(_, remember) = ConnectFlow.importOutcome(code: "session_unusable") {
            XCTAssertFalse(remember)
        } else { XCTFail() }
        // anything else is terminal
        if case .fail = ConnectFlow.importOutcome(code: "proxy_changed") {} else { XCTFail() }
    }
    func testStatusVerdicts() {
        func status(_ s: String, reason: String? = nil) -> StatusResponse {
            .init(state: s, username: "delfi.1", accountStatus: nil, statusReason: reason,
                  importedAt: nil, expiresAt: nil)
        }
        XCTAssertEqual(ConnectFlow.phase(forStatus: status("connected"), fallbackUsername: nil),
                       .success(username: "delfi.1"))
        if case let .error(msg, _) = ConnectFlow.phase(forStatus: status("failed", reason: "sess_rejected"), fallbackUsername: nil) {
            XCTAssertTrue(msg.detail.contains("sess_rejected"))
        } else { XCTFail() }
        if case let .verifying(_, seat) = ConnectFlow.phase(forStatus: status("verifying"), fallbackUsername: nil) {
            XCTAssertEqual(seat, "verifying")
        } else { XCTFail() }
    }
    func testPollErrorOnAnExpiredPassIsReassuring() {
        let p = ConnectFlow.phaseForPollError(ApiError(status: 401, code: "pass_invalid"), username: "delfi.1")
        if case let .error(msg, _)? = p { XCTAssertEqual(msg.title, "Still connecting") } else { XCTFail() }
        // a transient transport error keeps polling (nil = no phase change)
        XCTAssertNil(ConnectFlow.phaseForPollError(ApiError(status: 0, code: "timeout"), username: "delfi.1"))
    }
}

final class NativeIdentityTests: XCTestCase {
    private func identity(_ source: String, ua: String? = nil) -> Identity {
        Identity(profile: "mac", source: source, userAgent: ua, acceptLanguage: nil,
                 platform: nil, initScript: nil, timezone: nil)
    }
    func testNativeLeavesTheEngineUserAgentAlone() {
        XCTAssertTrue(NativeIdentity.isNative(identity("native")))
        XCTAssertNil(NativeIdentity.customUserAgent(for: identity("native", ua: "")))
    }
    func testSeatModeSetsTheUAStringOnlyBestEffort() {
        XCTAssertFalse(NativeIdentity.isNative(identity("seat")))
        XCTAssertEqual(NativeIdentity.customUserAgent(for: identity("seat", ua: "Mozilla/5.0 Mac")), "Mozilla/5.0 Mac")
    }
    func testTheAppDeclaresTheNativeCap() {
        XCTAssertEqual(NativeIdentity.appCaps, ["nativeIdentity"])
    }
    func testPlatformTagIsBoundedAndNamesIOS() {
        XCTAssertEqual(NativeIdentity.platformTag(systemVersion: "17.5"), "ios-17.5")
        XCTAssertLessThanOrEqual(NativeIdentity.platformTag(systemVersion: String(repeating: "9", count: 60)).count, 32)
    }
}

final class MessagesTests: XCTestCase {
    func testKnownCodesMapToWords() {
        XCTAssertEqual(Messages.forOpen("invalid_or_spent").title, "This link has expired")
        XCTAssertEqual(Messages.forImport("wrong_creator").title, "That is a different OnlyFans account")
        XCTAssertEqual(Messages.forTunnel("proxy_blocked").title, "The secure connection was blocked")
    }
    func testUnknownCodeFallsBackToGeneric() {
        XCTAssertEqual(Messages.forOpen("something_new"), Messages.generic)
    }
    func testTransportCodesAreSharedAcrossOpenAndImport() {
        XCTAssertEqual(Messages.forOpen("timeout"), Messages.transport["timeout"])
        XCTAssertEqual(Messages.forImport("unreachable"), Messages.transport["unreachable"])
    }
    func testFailedConnectNamesTheReasonWhenPresent() {
        XCTAssertTrue(Messages.forFailedConnect("sess_rejected").detail.contains("sess_rejected"))
        XCTAssertFalse(Messages.forFailedConnect(nil).detail.contains("("))
    }
}
