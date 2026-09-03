import Foundation

/// The flow a single opened link runs, as a set of PURE decisions — the transitions main.js makes
/// between `open`, the sign-in, capture, import and status polling, with none of Electron's timers,
/// windows or networking. The app owns the effects (fetches, the WKWebView, timers) and asks this
/// type what to do; keeping the decisions here is what lets them be tested on Linux.

/// What the creator is looking at. Mirrors the phases ui.js renders. There are deliberately no
/// auto-update phases: iOS apps update through the App Store / TestFlight, never in-process.
public enum Phase: Equatable, Sendable {
    case idle
    case opening
    case signin(username: String?, expiresAt: String?, notice: UserMessage?)
    case captured(username: String?)
    case verifying(username: String?, seatState: String?)
    case success(username: String?)
    case error(UserMessage, username: String?)
}

/// What `open` decided, reduced to what the flow acts on.
public enum OpenDisposition: Equatable, Sendable {
    /// Ready to sign in over the phone's own network — the estate default (`tunnel: null`).
    case signIn(username: String, expiresAt: String, native: Bool)
    /// The server offered a proxy tunnel this app cannot ride yet. An honest dead end.
    case tunnelUnsupported
}

/// What to do after `POST /connect-app/session` returns.
public enum ImportOutcome: Equatable, Sendable {
    /// The pass is still open: she can sign out and sign in with the right account. The refused
    /// OnlyFans id is remembered so the same answer does not re-capture on every page.
    case retrySignIn(notice: UserMessage, rememberRefusedId: Bool)
    /// A terminal failure — show the error and end the run.
    case fail(UserMessage)
    /// The import took; move to verifying.
    case imported
}

public enum ConnectFlow {
    /// Reduce an `open` response to the flow's disposition. A non-null tunnel URL is refused up
    /// front, because the whole sign-in would otherwise run without the proxy the server asked for.
    public static func disposition(for open: OpenResponse) -> OpenDisposition {
        if let url = open.tunnel?.url, !url.isEmpty {
            return .tunnelUnsupported
        }
        return .signIn(username: open.account.username,
                       expiresAt: open.expiresAt,
                       native: NativeIdentity.isNative(open.identity))
    }

    /// Should this `/users/me` observation start a capture? The guards from `onMe`/`capture`:
    /// only when signed-in state is live, nothing captured yet, no capture already running, and this
    /// OnlyFans id has not already been refused by the server.
    public static func shouldCapture(me: SessionCapture.Me,
                                     alreadyCaptured: Bool,
                                     capturing: Bool,
                                     refusedIds: Set<String>) -> Bool {
        if alreadyCaptured || capturing { return false }
        if refusedIds.contains(me.id) { return false }
        return true
    }

    /// Map an import result code to the next move. `nil` code means the import succeeded.
    public static func importOutcome(code: String?) -> ImportOutcome {
        guard let code else { return .imported }
        switch code {
        case "wrong_creator", "duplicate_account", "session_unusable":
            // Still recoverable in the same window. `session_unusable` is not tied to one identity,
            // so its id is not remembered (a retry of the same account can succeed once the jar
            // settles); the other two are about which account she chose.
            return .retrySignIn(notice: Messages.forImport(code),
                                rememberRefusedId: code != "session_unusable")
        default:
            return .fail(Messages.forImport(code))
        }
    }

    /// The next phase from a status poll, mirroring `poll`. `connected` -> success, `failed` ->
    /// error, anything else -> keep verifying with the seat's state shown.
    public static func phase(forStatus status: StatusResponse, fallbackUsername: String?) -> Phase {
        switch status.state {
        case "connected":
            return .success(username: status.username ?? fallbackUsername)
        case "failed":
            return .error(Messages.forFailedConnect(status.statusReason), username: status.username ?? fallbackUsername)
        default:
            return .verifying(username: status.username ?? fallbackUsername, seatState: status.state)
        }
    }

    /// A status-poll transport error. A 401 / `pass_invalid` means the pass ran out while the seat
    /// was still verifying — the import is safe on the server, so she is told it is finishing in the
    /// background rather than shown a failure. Any other transport error is transient: keep polling.
    public static func phaseForPollError(_ error: ApiError, username: String?) -> Phase? {
        if error.status == 401 || error.code == "pass_invalid" {
            return .error(UserMessage(
                title: "Still connecting",
                detail: "Your sign-in was received. OnlyX is finishing the connection in the background — your manager will see the result."),
                username: username)
        }
        return nil
    }
}
