import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP round trip. The app hands in URLSession; tests hand in a fake, so the client's
/// behaviour — headers, bearer, JSON, timeouts, error mapping — is proved without a network.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The three calls the app makes, and the one thing it holds: the pass's session token. Same
/// contract as src/api.js — every failure is an ApiError carrying the server's `error` code.
public struct OnlyxApi: Sendable {
    public let base: String
    let transport: Transport
    let appVersion: String?
    let platform: String?
    let caps: [String]
    public static let timeout: TimeInterval = 20

    public init(base: String, transport: Transport, appVersion: String?, platform: String?,
                caps: [String] = NativeIdentity.appCaps) {
        self.base = Config.trimTrailingSlashes(base)
        self.transport = transport
        self.appVersion = appVersion
        self.platform = platform
        self.caps = caps
    }

    /// A request with no body (the status poll).
    func call<T: Decodable>(_ method: String, _ path: String, token: String? = nil) async throws -> T {
        try await call(method, path, token: token, body: Optional<NoBody>.none)
    }

    func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, token: String? = nil,
                                          body: B?) async throws -> T {
        guard let url = URL(string: base + path) else { throw ApiError(status: 0, code: "unreachable") }
        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let res: HTTPURLResponse
        do {
            (data, res) = try await transport.send(req)
        } catch let e as URLError where e.code == .timedOut {
            throw ApiError(status: 0, code: "timeout")
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError(status: 0, code: "unreachable")
        }
        guard (200..<300).contains(res.statusCode) else {
            let code = (try? JSONDecoder().decode(ApiErrorBody.self, from: data))?.error
            throw ApiError(status: res.statusCode, code: code ?? "http_\(res.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError(status: res.statusCode, code: "bad_response")
        }
    }

    /// Spend a claim. Returns the opened pass: token, expiry, account, identity, tunnel (or null).
    public func open(claim: String) async throws -> OpenResponse {
        try await call("POST", "/connect-app/open",
                       body: OpenRequest(claim: claim, appVersion: appVersion, platform: platform, caps: caps))
    }

    public func importSession(token: String, _ body: ImportRequest) async throws -> ImportResponse {
        try await call("POST", "/connect-app/session", token: token, body: body)
    }

    public func status(token: String) async throws -> StatusResponse {
        try await call("GET", "/connect-app/status", token: token)
    }
}

/// URLSession as a Transport. On iOS this is what the app uses; it is here (Foundation-only) so
/// the same type serves any host.
public struct URLSessionTransport: Transport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiError(status: 0, code: "unreachable") }
        return (data, http)
    }
}
