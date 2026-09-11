import XCTest
#if canImport(Network)
import Network
import OnlyXLoginCore
@testable import OnlyXLoginTunnel

final class TunnelTests: XCTestCase {
    func testAuthenticatedTunnelCarriesBinaryBytesBothWays() async throws {
        let peer = try RelayFixture()
        let port = try await peer.start()
        defer { peer.close() }
        let tunnel = TunnelForwarder(url: URL(string: "ws://127.0.0.1:\(port)/connect-app/tunnel")!, token: "fixture-pass")
        let endpoint = try await tunnel.start()
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        defer { client.cancel() }
        client.start(queue: DispatchQueue(label: "test.client"))
        try await send(client, Data([5, 1, 2]))
        let greeting = try await receive(client, count: 2)
        XCTAssertEqual(greeting, Data([5, 2]))
        let auth = Data([1, UInt8(endpoint.username.utf8.count)]) + Data(endpoint.username.utf8) +
            Data([UInt8(endpoint.password.utf8.count)]) + Data(endpoint.password.utf8)
        try await send(client, auth)
        let authenticated = try await receive(client, count: 2)
        XCTAssertEqual(authenticated, Data([1, 0]))
        let host = Data("onlyfans.com".utf8)
        try await send(client, Data([5, 1, 0, 3, UInt8(host.count)]) + host + Data([1, 187]))
        let connected = try await receive(client, count: 10)
        XCTAssertEqual(connected, SOCKS5Handshake.response(code: 0))
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 % 256) })
        try await send(client, payload)
        let echoed = try await receive(client, count: payload.count)
        XCTAssertEqual(echoed, payload)
        XCTAssertGreaterThan(peer.acceptedCount, 0)
        await tunnel.close()
    }

    func testRealListenerRefusesAnonymousLocalClients() async throws {
        let tunnel = TunnelForwarder(url: URL(string: "wss://example.com/connect-app/tunnel")!, token: "fixture")
        let endpoint = try await tunnel.start()
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        client.start(queue: DispatchQueue(label: "test.anonymous"))
        defer { client.cancel() }
        try await send(client, Data([5, 1, 0]))
        let refused = try await receive(client, count: 2)
        XCTAssertEqual(refused, Data([5, 255]))
        await tunnel.close()
    }

    func testStartsOnlyOnLoopbackAndStopsIdempotently() async throws {
        let tunnel = TunnelForwarder(url: URL(string: "wss://example.com/connect-app/tunnel")!, token: "fixture")
        let endpoint = try await tunnel.start()
        XCTAssertGreaterThan(endpoint.port, 0)
        XCTAssertFalse(endpoint.password.isEmpty)
        if #available(iOS 17, macOS 14, *) { XCTAssertFalse(endpoint.configuration().allowFailover) }
        await tunnel.close()
        await tunnel.close()
        do { _ = try await tunnel.start(); XCTFail("Restarted a closed pass") } catch {}
    }
}

func send(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
}

func receive(_ connection: NWConnection, count: Int) async throws -> Data {
    var result = Data()
    while result.count < count {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: TunnelError("eof")) }
            }
        }
        result.append(data)
    }
    return result
}

/// An actual WebSocket peer, not an injected transport. It checks the pass header, then either
/// echoes binary frames or relays TLS to the public IP echo for opt-in WebKit integration tests.
final class RelayFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.relay")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = 0
    private let internet: Bool
    var acceptedCount: Int { lock.withLock { accepted } }

    init(internet: Bool = false) throws {
        self.internet = internet
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { _, headers in
            let authenticated = headers.contains { $0.name.lowercased() == "authorization" && $0.value == "Bearer fixture-pass" }
            return .init(status: authenticated ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] ws in
            lock.withLock { connections.append(ws); accepted += 1 }
            let upstream = internet ? NWConnection(host: "api.ipify.org", port: 443, using: .tcp) : nil
            if let upstream { lock.withLock { connections.append(upstream) } }
            ws.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    if let upstream {
                        upstream.stateUpdateHandler = { state in
                            if case .ready = state {
                                self.frame(ws, Data(#"{"t":"ready"}"#.utf8), opcode: .text) { self.readUpstream(upstream, ws) }
                                self.readWebSocket(ws, upstream)
                            }
                        }
                        upstream.start(queue: queue)
                    } else {
                        frame(ws, Data(#"{"t":"ready"}"#.utf8), opcode: .text) { self.readWebSocket(ws, nil) }
                    }
                }
            }
            ws.start(queue: queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: queue)
        }
    }

    private func frame(_ ws: NWConnection, _ data: Data, opcode: NWProtocolWebSocket.Opcode = .binary,
                       then: @escaping @Sendable () -> Void) {
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        ws.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if error == nil { then() }
        })
    }

    private func readWebSocket(_ ws: NWConnection, _ upstream: NWConnection?) {
        ws.receiveMessage { [self] data, context, _, error in
            guard error == nil, let data,
                  (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode == .binary else {
                upstream?.cancel(); ws.cancel(); return
            }
            if let upstream {
                upstream.send(content: data, completion: .contentProcessed { error in
                    if error == nil { self.readWebSocket(ws, upstream) } else { ws.cancel() }
                })
            } else { frame(ws, data) { self.readWebSocket(ws, nil) } }
        }
    }

    private func readUpstream(_ upstream: NWConnection, _ ws: NWConnection) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { ws.cancel(); return }
            frame(ws, data) { self.readUpstream(upstream, ws) }
        }
    }

    func close() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
#endif
