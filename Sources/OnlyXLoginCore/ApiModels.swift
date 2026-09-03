import Foundation

/// The wire shapes of the three calls the app makes to `of-api.onlyx.ai`, matched field for field
/// to the mac app (src/api.js) and the server (x-onlyfans apps/api/src/modules/connect-app). The
/// app holds exactly one secret: the pass's session token, returned by `open` and sent as a bearer
/// on the other two.

// MARK: open

/// The body of `POST /connect-app/open`. `caps` is what this build tells the server it can do; the
/// server gates the native identity on `nativeIdentity` (see NativeIdentity.appCaps).
public struct OpenRequest: Encodable, Sendable {
    public let claim: String
    public let appVersion: String?
    public let platform: String?
    public let caps: [String]
    public init(claim: String, appVersion: String?, platform: String?, caps: [String]) {
        self.claim = claim
        self.appVersion = appVersion
        self.platform = platform
        self.caps = caps
    }
}

public struct Account: Decodable, Sendable, Equatable {
    public let id: String
    public let username: String
    public let status: String
}

/// The identity the server tells the sign-in view to present. In native mode `source == "native"`
/// and every wire field is empty/absent: the app presents the machine it is running on (a real
/// iPhone Safari), which is the only coherent choice on WebKit — see NativeIdentity.
public struct Identity: Decodable, Sendable, Equatable {
    public let profile: String?
    public let source: String?          // "seat" | "native"
    public let userAgent: String?       // "" in native mode
    public let acceptLanguage: String?  // null in native mode
    public let platform: String?        // null in native mode
    public let initScript: String?      // the seat's in-page pins; null in native mode
    public let timezone: String?        // null unless the egress can justify a zone
    // userAgentMetadata is the seat's client-hint block. It is Decodable-ignored on purpose:
    // WKWebView cannot send client hints (no CDP), so the app can never apply it — recording that
    // we received it would only invite code that pretends to. See README "What iOS cannot do".
}

public struct Tunnel: Decodable, Sendable, Equatable {
    public let url: String?
}

/// The opened pass: token, expiry, account, identity, and the server's routing decision. `tunnel`
/// is `null` (its default on the estate) for a sign-in over the phone's own network; a non-null
/// `tunnel.url` is a WebSocket forwarder the mac app rides and this app does not yet support.
public struct OpenResponse: Decodable, Sendable, Equatable {
    public let sessionToken: String
    public let expiresAt: String
    public let account: Account
    public let identity: Identity
    public let tunnel: Tunnel?
}

// MARK: import

/// One cookie in the store's shape the seat resumes (x-onlyfans session-store cookieSchema). A
/// session cookie carries `expires: -1`, which is what the seat's own captures carry for one.
public struct SessionCookie: Codable, Sendable, Equatable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Double?
    public let httpOnly: Bool?
    public let secure: Bool?
    public init(name: String, value: String, domain: String, path: String,
                expires: Double?, httpOnly: Bool?, secure: Bool?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.expires = expires; self.httpOnly = httpOnly; self.secure = secure
    }
}

/// The jar handed to `POST /connect-app/session`, exactly the shape `buildSessionPayload` produces
/// in src/session-capture.js.
public struct SessionPayload: Codable, Sendable, Equatable {
    public let cookies: [SessionCookie]
    public let cookieHeader: String
    public let xbc: String?
    public let xbcKey: String?
    public let capturedAt: String
}

public struct ImportRequest: Encodable, Sendable {
    public let session: SessionPayload
    public let ofUserId: String
    public let username: String?
    public init(session: SessionPayload, ofUserId: String, username: String?) {
        self.session = session; self.ofUserId = ofUserId; self.username = username
    }
}

public struct ImportSeat: Decodable, Sendable, Equatable {
    public let workerId: String
    public let seatIndex: Int
}

public struct ImportResponse: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let importedAt: String
    public let seat: ImportSeat?
}

// MARK: status

/// What the seat made of the import, polled until it settles. `state` moves
/// awaiting_session -> verifying -> connected | failed (x-onlyfans ConnectState).
public struct StatusResponse: Decodable, Sendable, Equatable {
    public let state: String
    public let username: String?
    public let accountStatus: String?
    public let statusReason: String?
    public let importedAt: String?
    public let expiresAt: String?
}

/// Every failure the transport surfaces carries the server's `error` code, so the UI maps codes to
/// words in one place (Messages), the same contract as src/api.js's ApiError.
public struct ApiError: Error, Sendable, Equatable {
    public let status: Int          // HTTP status, or 0 for a transport failure
    public let code: String         // the server's `error`, or "timeout"/"unreachable"
    public init(status: Int, code: String) { self.status = status; self.code = code }
}

/// The body an error response carries: `{ "error": "<code>" }`.
struct ApiErrorBody: Decodable { let error: String? }

/// The absent body of a GET, typed so the generic `call` has something to be generic over.
struct NoBody: Encodable {}
