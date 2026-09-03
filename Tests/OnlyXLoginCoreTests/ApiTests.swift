import XCTest
@testable import OnlyXLoginCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fake server: records every request, answers from a script. The client's whole behaviour —
/// what it sends, what it makes of the answer — is proved here without a socket.
final class FakeTransport: Transport, @unchecked Sendable {
    struct Call { let request: URLRequest; let body: [String: Any]? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var answer: (URLRequest) throws -> (Int, String) = { _ in (200, "{}") }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        lock.lock(); _calls.append(Call(request: request, body: body)); lock.unlock()
        let (status, text) = try answer(request)
        let res = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(text.utf8), res)
    }
}

final class ApiTests: XCTestCase {
    private let openJson = """
    {"sessionToken":"tok-1","expiresAt":"2026-09-03T02:00:00Z",
     "account":{"id":"acct-1","username":"delfi.1","status":"connecting"},
     "identity":{"profile":"mac","source":"native","userAgent":"","acceptLanguage":null,"platform":null,
                 "userAgentMetadata":null,"initScript":null,"timezone":null},
     "tunnel":null}
    """

    func testOpenSendsTheClaimTheVersionThePlatformAndTheCaps() async throws {
        let fake = FakeTransport(); fake.answer = { _ in (200, self.openJson) }
        let api = OnlyxApi(base: "https://api.test/", transport: fake, appVersion: "1.0.0", platform: "ios-17.5")
        let opened = try await api.open(claim: "abcd1234abcd")
        XCTAssertEqual(opened.sessionToken, "tok-1")
        XCTAssertEqual(opened.account.username, "delfi.1")
        XCTAssertTrue(NativeIdentity.isNative(opened.identity))
        XCTAssertNil(opened.tunnel)
        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertEqual(call.request.url?.absoluteString, "https://api.test/connect-app/open")
        XCTAssertEqual(call.request.httpMethod, "POST")
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(call.request.value(forHTTPHeaderField: "authorization"), "open carries no bearer")
        XCTAssertEqual(call.body?["claim"] as? String, "abcd1234abcd")
        XCTAssertEqual(call.body?["appVersion"] as? String, "1.0.0")
        XCTAssertEqual(call.body?["platform"] as? String, "ios-17.5")
        XCTAssertEqual(call.body?["caps"] as? [String], ["nativeIdentity"])
    }

    func testTunnelNullDecodesAsNoTunnel() async throws {
        let fake = FakeTransport(); fake.answer = { _ in (200, self.openJson) }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        let opened = try await api.open(claim: "abcd1234abcd")
        XCTAssertEqual(ConnectFlow.disposition(for: opened),
                       .signIn(username: "delfi.1", expiresAt: "2026-09-03T02:00:00Z", native: true))
    }

    func testAServerErrorCarriesItsCode() async {
        let fake = FakeTransport(); fake.answer = { _ in (409, #"{"error":"invalid_or_spent"}"#) }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        do { _ = try await api.open(claim: "abcd1234abcd"); XCTFail("should throw") }
        catch let e as ApiError { XCTAssertEqual(e, ApiError(status: 409, code: "invalid_or_spent")) }
        catch { XCTFail("wrong error \(error)") }
    }

    func testAnUnparseableErrorBodyStillNamesTheStatus() async {
        let fake = FakeTransport(); fake.answer = { _ in (502, "<html>bad gateway</html>") }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        do { _ = try await api.status(token: "t"); XCTFail() }
        catch let e as ApiError { XCTAssertEqual(e.code, "http_502"); XCTAssertEqual(e.status, 502) }
        catch { XCTFail() }
    }

    func testTransportFailuresMapToTimeoutOrUnreachable() async {
        let fake = FakeTransport()
        fake.answer = { _ in throw URLError(.timedOut) }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        do { _ = try await api.status(token: "t"); XCTFail() }
        catch let e as ApiError { XCTAssertEqual(e.code, "timeout") } catch { XCTFail() }
        fake.answer = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await api.status(token: "t"); XCTFail() }
        catch let e as ApiError { XCTAssertEqual(e.code, "unreachable") } catch { XCTFail() }
    }

    func testImportSendsTheJarUnderTheBearer() async throws {
        let fake = FakeTransport()
        fake.answer = { _ in (200, #"{"ok":true,"importedAt":"2026-09-03T01:00:00Z","seat":{"workerId":"xof-worker-2-1","seatIndex":3}}"#) }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        let jar = SessionCapture.buildSessionPayload(
            cookies: [.init(name: "sess", value: "s", domain: ".onlyfans.com", path: "/", isSession: true, expires: nil, httpOnly: true, secure: true),
                      .init(name: "auth_id", value: "42", domain: ".onlyfans.com", path: "/", isSession: false, expires: 1e9, httpOnly: true, secure: true)],
            xbc: (key: "bcTokenSha", value: String(repeating: "f", count: 40)))
        let res = try await api.importSession(token: "tok-1", ImportRequest(session: jar, ofUserId: "42", username: "delfi.1"))
        XCTAssertEqual(res.seat, ImportSeat(workerId: "xof-worker-2-1", seatIndex: 3))
        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "authorization"), "Bearer tok-1")
        XCTAssertEqual(call.request.url?.path, "/connect-app/session")
        let session = try XCTUnwrap(call.body?["session"] as? [String: Any])
        XCTAssertEqual((session["cookies"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(session["xbc"] as? String, String(repeating: "f", count: 40))
        XCTAssertEqual(call.body?["ofUserId"] as? String, "42")
        // the session cookie's expires travels as -1, the seat's own shape for one
        let sess = (session["cookies"] as? [[String: Any]])?.first { ($0["name"] as? String) == "sess" }
        XCTAssertEqual(sess?["expires"] as? Double, -1)
    }

    func testStatusIsAGetUnderTheBearer() async throws {
        let fake = FakeTransport()
        fake.answer = { _ in (200, #"{"state":"connected","username":"delfi.1","accountStatus":"active","statusReason":null,"importedAt":"x","expiresAt":"y"}"#) }
        let api = OnlyxApi(base: "https://api.test", transport: fake, appVersion: nil, platform: nil)
        let s = try await api.status(token: "tok-1")
        XCTAssertEqual(s.state, "connected")
        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertEqual(call.request.httpMethod, "GET")
        XCTAssertNil(call.request.httpBody)
        XCTAssertEqual(call.request.value(forHTTPHeaderField: "authorization"), "Bearer tok-1")
    }
}

final class MeObserverTests: XCTestCase {
    func testTheScriptReportsOnlyUsersMe() {
        XCTAssertTrue(MeObserver.script.contains("/api2/v2/users/me"))
        XCTAssertTrue(MeObserver.script.contains("messageHandlers.onlyxMe"))
        XCTAssertTrue(MeObserver.script.contains("onlyfans\\.com$"), "the host check is anchored")
        XCTAssertEqual(MeObserver.handlerName, "onlyxMe")
    }
    func testDecodeAcceptsTheShapeWebKitPosts() {
        XCTAssertEqual(MeObserver.decode(["status": 200, "body": "{}"]), .init(status: 200, body: "{}"))
        XCTAssertEqual(MeObserver.decode(["status": NSNumber(value: 401), "body": ""]), .init(status: 401, body: ""))
        XCTAssertNil(MeObserver.decode("not a dict"))
        XCTAssertNil(MeObserver.decode(["body": "{}"]))
        XCTAssertNil(MeObserver.decode(["status": 200]))
    }
    func testJudgeNeedsA200ThatNamesAUser() {
        XCTAssertEqual(MeObserver.judge(.init(status: 200, body: #"{"id":7,"username":"a"}"#)), .init(id: "7", username: "a"))
        XCTAssertNil(MeObserver.judge(.init(status: 200, body: #"{"hasPassword":true}"#)), "the guest answer")
        XCTAssertNil(MeObserver.judge(.init(status: 401, body: #"{"id":7}"#)), "not a 200")
    }
}
