import Foundation

/// What the creator reads when something goes wrong. Codes come from the API (connect-app.routes.ts)
/// and the tunnel close codes (tunnel.ts); the words live here so every surface stays in one voice
/// and none of them leaks what the estate looks like from the inside. A faithful port of
/// src/messages.js.
public struct UserMessage: Equatable, Sendable {
    public let title: String
    public let detail: String
}

public enum Messages {
    static let askForNewLink = "Ask your manager for a new link."

    static let openFailures: [String: UserMessage] = [
        "invalid_or_spent": .init(title: "This link has expired",
            detail: "Links work once and for 15 minutes. \(askForNewLink)"),
        "claim_required": .init(title: "This link is not complete", detail: askForNewLink),
        "account_unavailable": .init(title: "This account cannot be connected right now",
            detail: "Your manager needs to check the account in OnlyX before you sign in."),
        "no_egress": .init(title: "OnlyX is not ready for this account yet",
            detail: "Please try the link again in a minute. If it keeps happening, tell your manager."),
        "worker_not_ready": .init(title: "OnlyX is not ready for this account yet",
            detail: "Please try the link again in a minute. If it keeps happening, tell your manager."),
    ]

    static let importFailures: [String: UserMessage] = [
        "pass_invalid": .init(title: "This link has expired",
            detail: "Signing in took longer than the link allowed. \(askForNewLink)"),
        "session_unusable": .init(title: "The sign-in did not complete",
            detail: "OnlyFans did not finish signing you in. Sign out and sign in once more in this window."),
        "wrong_creator": .init(title: "That is a different OnlyFans account",
            detail: "You signed in to an account that is not the one this link is for. Sign out in this window and sign in with the right one."),
        "duplicate_account": .init(title: "That OnlyFans account is already connected elsewhere",
            detail: "Tell your manager which OnlyFans account you signed in with."),
        "proxy_changed": .init(title: "The connection changed while you were signing in",
            detail: "Please sign in again. \(askForNewLink)"),
        "account_unavailable": .init(title: "This account cannot be connected right now",
            detail: "Your manager needs to check the account in OnlyX before you sign in."),
        "already_imported": .init(title: "You are already signed in",
            detail: "This link was used to sign in already. If OnlyX still shows the account as disconnected, ask for a new link."),
    ]

    static let transport: [String: UserMessage] = [
        "unreachable": .init(title: "Cannot reach OnlyX",
            detail: "Check your internet connection and open the link again."),
        "timeout": .init(title: "OnlyX is not answering",
            detail: "Check your internet connection and open the link again."),
    ]

    /// Tunnel close codes, mirrored from the API's tunnel.ts. This app does not ride a tunnel yet;
    /// kept so the vocabulary matches the mac app if that changes.
    public static let tunnelClose: [Int: String] = [
        4403: "target_refused", 4429: "too_many_streams", 4413: "byte_budget", 4407: "proxy_auth",
        4409: "proxy_blocked", 4502: "proxy_error", 4504: "connect_timeout", 4408: "idle",
    ]

    static let tunnelFailures: [String: UserMessage] = [
        "proxy_auth": .init(title: "The secure connection was refused",
            detail: "OnlyX could not open the connection for this account. Tell your manager — nothing is wrong on your side."),
        "proxy_blocked": .init(title: "The secure connection was blocked",
            detail: "OnlyX could not open the connection for this account. Tell your manager — nothing is wrong on your side."),
        "proxy_error": .init(title: "The secure connection dropped",
            detail: "Please open the link again. If it keeps happening, tell your manager."),
        "connect_timeout": .init(title: "The secure connection timed out",
            detail: "Please open the link again. If it keeps happening, tell your manager."),
        "byte_budget": .init(title: "This sign-in used more data than expected",
            detail: "The link has been closed to protect the account. \(askForNewLink)"),
        "unauthorized": .init(title: "This link has expired",
            detail: "Signing in took longer than the link allowed. \(askForNewLink)"),
    ]

    static let generic = UserMessage(title: "Something went wrong",
        detail: "Please open the link again. If it keeps happening, tell your manager.")

    public static func forOpen(_ code: String) -> UserMessage {
        openFailures[code] ?? transport[code] ?? generic
    }
    public static func forImport(_ code: String) -> UserMessage {
        importFailures[code] ?? transport[code] ?? generic
    }
    public static func forTunnel(_ reason: String) -> UserMessage {
        tunnelFailures[reason] ?? generic
    }
    /// A seat that judged the import and refused it: the API's statusReason, made readable.
    public static func forFailedConnect(_ statusReason: String?) -> UserMessage {
        let detail: String
        if let r = statusReason, !r.isEmpty {
            detail = "OnlyFans did not accept the session on OnlyX (\(r)). Open a new link and sign in again."
        } else {
            detail = "OnlyFans did not accept the session on OnlyX. Open a new link and sign in again."
        }
        return UserMessage(title: "OnlyX could not use this sign-in", detail: detail)
    }

    /// The iPhone app cannot ride a proxy tunnel yet. When the server offers one, this is the honest
    /// dead-end rather than a silent half-sign-in. See README "What iOS cannot do".
    public static let tunnelUnsupported = UserMessage(
        title: "This account needs a computer to sign in",
        detail: "OnlyX is set to route this account's sign-in through its own connection, which the iPhone app cannot do yet. Ask your manager, or sign in on a Mac or Windows computer with the OnlyX Login app.")
}
