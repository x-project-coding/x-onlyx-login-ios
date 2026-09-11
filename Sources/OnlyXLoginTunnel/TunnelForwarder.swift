#if canImport(Network)
import Foundation
import Network
import OnlyXLoginCore

public struct TunnelEndpoint: Sendable {
    public let port: UInt16
    public let username: String
    public let password: String

    @available(iOS 17.0, macOS 14.0, *)
    public func configuration() -> ProxyConfiguration {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.applyCredential(username: username, password: password)
        proxy.allowFailover = false
        return proxy
    }

    @available(iOS 17.0, macOS 14.0, *)
    public func verifyExit(expected: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [configuration()]
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: ProxyRouting.probeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TunnelError("proxy_error") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 else { throw TunnelError("proxy_error") }
            data.append(byte)
        }
        guard ProxyRouting.sameExit(data, expected: expected) else { throw TunnelError("proxy_changed") }
    }
}

public struct TunnelError: Error, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// SOCKS5 on loopback -> authenticated WSS -> the account's existing HTTP CONNECT proxy.
/// Each stream has bounded reads and waits for each write before reading more. Only encrypted
/// website bytes pass through the relay; no proxy password or website TLS key is held here.
public actor TunnelForwarder {
    private let url: URL
    private let token: String
    private let onFatal: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ai.onlyx.login.tunnel")
    private let username = "onlyx"
    private let password = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var startup: CheckedContinuation<TunnelEndpoint, Error>?
    private var deadline: Task<Void, Never>?
    private var streams: [UUID: TunnelStream] = [:]
    private var stopped = false
    private var fatalSent = false

    /// The caller validates the server-supplied URL against its configured API origin first.
    public init(url: URL, token: String, onFatal: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.token = token
        self.onFatal = onFatal
    }

    public func start() async throws -> TunnelEndpoint {
        guard !stopped, listener == nil else { throw TunnelError("proxy_error") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        listener.stateUpdateHandler = { state in Task { await self.stateChanged(state) } }
        deadline = Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            await self.stop(reason: "connect_timeout")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func stateChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            guard let startup, !stopped, let port = listener?.port else { return }
            self.startup = nil
            deadline?.cancel()
            startup.resume(returning: TunnelEndpoint(port: port.rawValue, username: username, password: password))
        case .failed:
            await stop(reason: "proxy_error")
        default: break
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped, streams.count < 64 else { connection.cancel(); return }
        let id = UUID()
        let stream = TunnelStream(connection: connection, url: url, token: token,
                                  username: username, password: password) { reason in
            Task { await self.finished(id, reason: reason) }
        }
        streams[id] = stream
        await stream.start(queue: queue)
    }

    private func finished(_ id: UUID, reason: String?) async {
        streams.removeValue(forKey: id)
        // Per-host/idle failures can be retried by WebKit. These pass-wide refusals cannot.
        if let reason, ["unauthorized", "proxy_auth", "proxy_blocked", "byte_budget"].contains(reason) {
            await stop(reason: reason)
        }
    }

    private func stop(reason: String) async {
        if !stopped && !fatalSent { fatalSent = true; onFatal(reason) }
        await close()
    }

    public func close() async {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel()
        listener?.cancel()
        startup?.resume(throwing: TunnelError("proxy_error"))
        startup = nil
        let existing = Array(streams.values)
        streams.removeAll()
        for stream in existing { await stream.close() }
    }
}

private actor TunnelStream {
    let connection: NWConnection
    let url: URL
    let token: String
    let username: String
    let password: String
    let finished: @Sendable (String?) -> Void
    var session: URLSession?
    var webSocket: URLSessionWebSocketTask?
    var work: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    var stopped = false

    init(connection: NWConnection, url: URL, token: String, username: String, password: String,
         finished: @escaping @Sendable (String?) -> Void) {
        self.connection = connection; self.url = url; self.token = token
        self.username = username; self.password = password; self.finished = finished
    }

    func start(queue: DispatchQueue) {
        guard !stopped else { return }
        connection.start(queue: queue)
        armTimeout(seconds: 25)
        work = Task { await run() }
    }

    func armTimeout(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task {
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            await close(reason: "connect_timeout")
        }
    }

    func run() async {
        do {
            var handshake = SOCKS5Handshake(username: username, password: password)
            while !stopped {
                let data = try await read()
                for event in handshake.receive(data) {
                    switch event {
                    case .reply(let response): try await write(response)
                    case .refused(let response):
                        try await write(response)
                        await close()
                        return
                    case let .connect(host, port, pending):
                        try await relay(host: host, port: port, pending: pending)
                        await close()
                        return
                    }
                }
            }
        } catch {
            await close(reason: reason(for: error))
        }
    }

    func relay(host: String, port: Int, pending: Data) async throws {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port))]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        webSocket = socket
        socket.resume()
        guard case .string(let control) = try await socket.receive(),
              let object = try JSONSerialization.jsonObject(with: Data(control.utf8)) as? [String: String] else {
            throw TunnelError("proxy_error")
        }
        guard object["t"] == "ready" else { throw TunnelError(object["reason"] ?? "proxy_error") }
        try await write(SOCKS5Handshake.response(code: 0))
        if !pending.isEmpty { try await socket.send(.data(pending)) }
        armTimeout(seconds: 300)
        // One frame/read in flight in each direction: slow consumers cannot accumulate a queue.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.upload(socket) }
            group.addTask { try await self.download(socket) }
            defer { group.cancelAll() }
            do {
                _ = try await group.next()
                await close()
            } catch {
                await close(reason: reason(for: error))
                throw error
            }
        }
    }

    func upload(_ socket: URLSessionWebSocketTask) async throws {
        while !stopped {
            let data = try await read()
            try await socket.send(.data(data))
            armTimeout(seconds: 300)
        }
    }

    func download(_ socket: URLSessionWebSocketTask) async throws {
        while !stopped {
            guard case .data(let data) = try await socket.receive() else { throw TunnelError("proxy_error") }
            try await write(data)
            armTimeout(seconds: 300)
        }
    }

    func read() async throws -> Data {
        guard !stopped else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: complete ? TunnelError("closed") : TunnelError("proxy_error")) }
            }
        }
    }

    func write(_ data: Data) async throws {
        guard !stopped else { throw CancellationError() }
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func close(reason: String? = nil) async {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        connection.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        finished(reason)
    }

    func reason(for error: Error) -> String? {
        let status = (webSocket?.response as? HTTPURLResponse)?.statusCode
        if status == 401 { return "unauthorized" }
        let code = webSocket.map { Int($0.closeCode.rawValue) } ?? 0
        return Messages.tunnelClose[code] ?? (error as? TunnelError)?.reason
    }
}

/// Never forward a pass bearer across a redirect, even if a reverse proxy is misconfigured.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
