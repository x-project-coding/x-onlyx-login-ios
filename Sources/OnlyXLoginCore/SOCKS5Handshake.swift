import Foundation

/// Incremental RFC 1928/1929 handshake for the app's authenticated, loopback-only bridge.
/// No DNS is resolved on the phone: only domain-name CONNECTs to HTTPS may reach the relay.
public struct SOCKS5Handshake {
    public enum Event: Equatable {
        case reply(Data)
        case connect(host: String, port: Int, pending: Data)
        case refused(Data)
    }
    private enum Stage { case greeting, authentication, request, finished }
    private var stage = Stage.greeting
    private var buffer = Data()
    private let username: Data
    private let password: Data

    public init(username: String, password: String) {
        self.username = Data(username.utf8)
        self.password = Data(password.utf8)
    }

    public mutating func receive(_ data: Data) -> [Event] {
        guard stage != .finished else { return [] }
        guard buffer.count + data.count <= 65_536 else {
            stage = .finished
            buffer.removeAll()
            return [.refused(Data())]
        }
        buffer.append(data)
        var events: [Event] = []
        func bytes(_ range: Range<Int>) -> Data { buffer.subdata(in: range) }
        while true {
            switch stage {
            case .greeting:
                guard buffer.count >= 2 else { return events }
                let count = Int(buffer[1])
                guard buffer.count >= 2 + count else { return events }
                guard buffer[0] == 5, bytes(2..<(2 + count)).contains(2) else {
                    stage = .finished
                    return events + [.refused(Data([5, 255]))]
                }
                buffer = Data(buffer.dropFirst(2 + count))
                stage = .authentication
                events.append(.reply(Data([5, 2])))
            case .authentication:
                guard buffer.count >= 2 else { return events }
                let userLength = Int(buffer[1])
                guard buffer.count >= 3 + userLength else { return events }
                let passwordLength = Int(buffer[2 + userLength])
                let end = 3 + userLength + passwordLength
                guard buffer.count >= end else { return events }
                guard buffer[0] == 1, userLength > 0, passwordLength > 0,
                      bytes(2..<(2 + userLength)) == username,
                      bytes((3 + userLength)..<end) == password else {
                    stage = .finished
                    return events + [.refused(Data([1, 1]))]
                }
                buffer = Data(buffer.dropFirst(end))
                stage = .request
                events.append(.reply(Data([1, 0])))
            case .request:
                guard buffer.count >= 5 else { return events }
                guard buffer[0] == 5, buffer[1] == 1, buffer[2] == 0, buffer[3] == 3 else {
                    stage = .finished
                    return events + [.refused(Self.response(code: 7))]
                }
                let length = Int(buffer[4])
                let end = 7 + length
                guard buffer.count >= end else { return events }
                let port = Int(buffer[5 + length]) * 256 + Int(buffer[6 + length])
                let host = String(data: bytes(5..<(5 + length)), encoding: .utf8)?.lowercased() ?? ""
                stage = .finished
                guard port == 443, Self.publicHostname(host) else {
                    return events + [.refused(Self.response(code: 2))]
                }
                let pending = Data(buffer.dropFirst(end))
                buffer.removeAll()
                return events + [.connect(host: host, port: port, pending: pending)]
            case .finished:
                return events
            }
        }
    }

    public static func response(code: UInt8) -> Data { Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]) }

    private static func publicHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host.contains("."),
              host.range(of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil,
              !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }
}
