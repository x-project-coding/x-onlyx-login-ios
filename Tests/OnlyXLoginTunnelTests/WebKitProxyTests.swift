#if canImport(WebKit) && canImport(Network)
import XCTest
import WebKit
import OnlyXLoginCore
@testable import OnlyXLoginTunnel

/// Opt-in public-network smoke: no creator, cookies, or production proxy is used. Both native
/// networking and the real WebKit network process must authenticate to the loopback proxy and
/// cross the real WebSocket bridge. Then stopping the proxy must make a fresh navigation fail.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class WebKitProxyTests: XCTestCase {
    func testWebKitAndURLSessionUseTheProxyAndNeverFailOver() async throws {
        guard ProcessInfo.processInfo.environment["ONLYX_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set ONLYX_RUN_NETWORK_TESTS=1 for the public-network WebKit smoke")
        }
        let peer = try RelayFixture(internet: true)
        let port = try await peer.start()
        defer { peer.close() }
        let tunnel = TunnelForwarder(url: URL(string: "ws://127.0.0.1:\(port)/connect-app/tunnel")!, token: "fixture-pass")
        let endpoint = try await tunnel.start()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.websiteDataStore.proxyConfigurations = [endpoint.configuration()]
        let view = WKWebView(frame: .zero, configuration: config)
        let navigation = NavigationProbe()
        view.navigationDelegate = navigation
        try await navigation.load(view, ProxyRouting.probeURL)
        let value = try await view.evaluateJavaScript("document.body.innerText") as? String
        let exit = try XCTUnwrap(value?.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(exit.contains(".") || exit.contains(":"), "IP echo, not an HTML error")
        let count = peer.acceptedCount
        XCTAssertGreaterThan(count, 0, "WebKit bypassed the bridge")
        try await endpoint.verifyExit(expected: exit)
        XCTAssertGreaterThan(peer.acceptedCount, count, "URLSession bypassed the bridge")
        await tunnel.close()

        // New store and URL rule out cached responses or a surviving keepalive connection.
        let deadConfig = WKWebViewConfiguration()
        deadConfig.websiteDataStore = .nonPersistent()
        deadConfig.websiteDataStore.proxyConfigurations = [endpoint.configuration()]
        let deadView = WKWebView(frame: .zero, configuration: deadConfig)
        let deadNavigation = NavigationProbe()
        deadView.navigationDelegate = deadNavigation
        do {
            try await deadNavigation.load(deadView, URL(string: "https://api.ipify.org?format=text&probe=\(UUID().uuidString)")!)
            XCTFail("WebKit used the direct network after its proxy stopped")
        } catch { /* expected: fail closed */ }
        do {
            try await endpoint.verifyExit(expected: exit)
            XCTFail("URLSession used the direct network after its proxy stopped")
        } catch { /* expected: fail closed */ }
    }
}

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    func load(_ view: WKWebView, _ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timer = Task {
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                view.stopLoading()
                complete(TunnelError("navigation_timeout"))
            }
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { complete(error) }
    private func complete(_ error: Error?) {
        guard let pending else { return }
        self.pending = nil
        timer?.cancel()
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
#endif
