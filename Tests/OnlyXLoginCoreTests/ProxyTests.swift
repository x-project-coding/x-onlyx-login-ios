import XCTest
@testable import OnlyXLoginCore

final class ProxyTests: XCTestCase {
    func testCapabilityIsOnlySentBySupportedDevices() {
        XCTAssertEqual(ProxyRouting.caps(supported: false), NativeIdentity.appCaps)
        XCTAssertTrue(ProxyRouting.caps(supported: true).contains("iosProxyTunnelV1"))
    }

    func testBearerNeverLeavesTheConfiguredOrigin() {
        let base = "https://of-api.onlyx.ai"
        XCTAssertNotNil(ProxyRouting.tunnelURL("wss://of-api.onlyx.ai/connect-app/tunnel", apiBase: base))
        for bad in ["ws://of-api.onlyx.ai/connect-app/tunnel", "wss://evil.example/connect-app/tunnel",
                    "wss://of-api.onlyx.ai:444/connect-app/tunnel", "wss://of-api.onlyx.ai/other",
                    "wss://user@of-api.onlyx.ai/connect-app/tunnel", "wss://of-api.onlyx.ai/connect-app/tunnel?x=1"] {
            XCTAssertNil(ProxyRouting.tunnelURL(bad, apiBase: base), bad)
        }
    }

    func testExitProofRequiresTheMeasuredAddress() {
        XCTAssertTrue(ProxyRouting.sameExit(Data("192.0.2.1\n".utf8), expected: "192.0.2.1"))
        XCTAssertFalse(ProxyRouting.sameExit(Data("192.0.2.2".utf8), expected: "192.0.2.1"))
        XCTAssertFalse(ProxyRouting.sameExit(Data(), expected: ""))
    }

    private var authentication: Data { Data([1, 1, 117, 1, 112]) }
    private func request(_ host: String = "onlyfans.com", port: Int = 443) -> Data {
        Data([5, 1, 0, 3, UInt8(host.utf8.count)]) + Data(host.utf8) + Data([UInt8(port / 256), UInt8(port % 256)])
    }

    func testFragmentedAndPipelinedHandshakePreservesTLSBytes() {
        let wire = Data([5, 1, 2]) + authentication + request() + Data([22, 3, 1])
        var pipelined = SOCKS5Handshake(username: "u", password: "p")
        XCTAssertEqual(pipelined.receive(wire), [.reply(Data([5, 2])), .reply(Data([1, 0])),
                       .connect(host: "onlyfans.com", port: 443, pending: Data([22, 3, 1]))])
        var fragmented = SOCKS5Handshake(username: "u", password: "p")
        let events = wire.dropLast(3).flatMap { fragmented.receive(Data([$0])) }
        XCTAssertEqual(events, [.reply(Data([5, 2])), .reply(Data([1, 0])),
                       .connect(host: "onlyfans.com", port: 443, pending: Data())])
    }

    func testAnonymousAndWrongPasswordAreRefused() {
        var anonymous = SOCKS5Handshake(username: "u", password: "p")
        XCTAssertEqual(anonymous.receive(Data([5, 1, 0])), [.refused(Data([5, 255]))])
        var wrong = SOCKS5Handshake(username: "u", password: "different")
        XCTAssertEqual(wrong.receive(Data([5, 1, 2]) + authentication), [.reply(Data([5, 2])), .refused(Data([1, 1]))])
    }

    func testOnlyDomainHTTPSConnectsAreAccepted() {
        for target in [request(port: 80), request("127.0.0.1"), request("localhost"), request("x..com"),
                       Data([5, 1, 0, 1, 127, 0, 0, 1, 1, 187]), Data([5, 3, 0, 3, 0])] {
            var parser = SOCKS5Handshake(username: "u", password: "p")
            let events = parser.receive(Data([5, 1, 2]) + authentication + target)
            guard case .refused = events.last else { return XCTFail("Accepted invalid target") }
        }
    }

    func testUnboundedLocalInputIsRefused() {
        var parser = SOCKS5Handshake(username: "u", password: "p")
        XCTAssertEqual(parser.receive(Data(repeating: 0, count: 65_537)), [.refused(Data())])
    }
}
