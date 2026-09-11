import Foundation

/// Versioned capability: only advertise this when WebKit can enforce the route (iOS 17+).
/// The relay's long-lived upstream credentials never reach the app.
public enum ProxyRouting {
    public static let capability = "iosProxyTunnelV1"
    public static let probeURL = URL(string: "https://api.ipify.org?format=text")!

    public static func caps(supported: Bool) -> [String] {
        NativeIdentity.appCaps + (supported ? [capability] : [])
    }

    /// A server response cannot redirect our bearer to an arbitrary WebSocket host.
    public static func tunnelURL(_ raw: String, apiBase: String) -> URL? {
        guard let url = URL(string: raw), let base = URL(string: apiBase),
              url.scheme == "wss", base.scheme == "https", url.host == base.host,
              (url.port ?? 443) == (base.port ?? 443),
              url.path == "/connect-app/tunnel", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// Compare the measured exits, never an upstream proxy hostname or a guessed location.
    public static func sameExit(_ data: Data, expected: String) -> Bool {
        guard data.count <= 128, !expected.isEmpty,
              let actual = String(data: data, encoding: .utf8) else { return false }
        return actual.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}
