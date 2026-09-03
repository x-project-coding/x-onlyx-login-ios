import Foundation
import OSLog
import SwiftUI
import WebKit
import OnlyXLoginCore

private let flowLog = Logger(subsystem: "ai.onlyx.login", category: "flow")

/// The run: one opened link, from claim to verdict. The effects (network, timers, the web view)
/// live here; every decision is asked of OnlyXLoginCore.ConnectFlow so the behaviour is the one the
/// Linux-run tests prove.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published var helpShowing = false
    /// The web view for the current run, created when a pass opens and dropped with the run.
    @Published private(set) var signIn: SignInController? = nil

    /// How long after OnlyFans names the creator before the jar is read: the sign-in's last
    /// cookies land in that window (SETTLE_MS on the desktop).
    static let settleSeconds: Double = 2
    static let statusPollSeconds: Double = 3

    private let api: OnlyxApi
    private var runSeq = 0
    private var run: Run? = nil

    /// One opened link. `id` is what makes a stale run (a second link arriving mid-flight)
    /// harmless: every await checks it is still the current one before acting.
    final class Run {
        let id: Int
        var done = false
        var token: String? = nil
        var account: Account? = nil
        var expiresAt: String? = nil
        var captured = false
        var capturing = false
        var refusedIds = Set<String>()
        var settleTask: Task<Void, Never>? = nil
        var pollTask: Task<Void, Never>? = nil
        init(id: Int) { self.id = id }
    }

    init() {
        #if DEBUG
        let packaged = false
        #else
        let packaged = true
        #endif
        let base = Config.resolveApiBase(packaged: packaged, override: ProcessInfo.processInfo.environment["ONLYX_API_BASE"])
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        api = OnlyxApi(base: base, transport: URLSessionTransport(),
                       appVersion: version,
                       platform: NativeIdentity.platformTag(systemVersion: UIDevice.current.systemVersion))
    }

    // MARK: entry points

    func handle(url: URL) {
        guard let claim = DeepLink.parse(url.absoluteString) else { return }
        Task { await start(claim: claim) }
    }

    /// The idle screen's "Paste your link": chat apps rarely make a custom-scheme link tappable, so
    /// the creator copies it and pastes it here. Returns false when the clipboard holds no link.
    @discardableResult
    func pasteLink() -> Bool {
        guard let text = UIPasteboard.general.string, let claim = DeepLink.parse(text) else { return false }
        Task { await start(claim: claim) }
        return true
    }

    /// The success/error screens' Done: back to idle. iOS apps do not exit themselves.
    func reset() {
        teardown()
        phase = .idle
    }

    // MARK: the run

    private func isStale(_ r: Run) -> Bool { r !== run || r.done }

    private func teardown() {
        let previous = run
        run = nil
        if let previous {
            previous.done = true
            previous.settleTask?.cancel()
            previous.pollTask?.cancel()
        }
        signIn?.close()
        signIn = nil
    }

    private func fail(_ r: Run, _ message: UserMessage) {
        guard !isStale(r) else { return }
        r.done = true
        r.settleTask?.cancel()
        r.pollTask?.cancel()
        flowLog.error("run \(r.id) failed: \(message.title, privacy: .public)")
        signIn?.close()
        signIn = nil
        phase = .error(message, username: r.account?.username)
    }

    private func start(claim: String) async {
        teardown()
        runSeq += 1
        let r = Run(id: runSeq)
        run = r
        phase = .opening

        let opened: OpenResponse
        do {
            opened = try await api.open(claim: claim)
        } catch let e as ApiError {
            return fail(r, Messages.forOpen(e.code))
        } catch {
            return fail(r, Messages.forOpen("unreachable"))
        }
        guard !isStale(r) else { return }
        r.token = opened.sessionToken
        r.account = opened.account
        r.expiresAt = opened.expiresAt
        flowLog.info("run \(r.id): pass opened (\(opened.identity.source ?? "seat", privacy: .public) identity, tunnel \(opened.tunnel?.url == nil ? "none" : "offered", privacy: .public))")

        switch ConnectFlow.disposition(for: opened) {
        case .tunnelUnsupported:
            // The server asked for the sign-in to ride the account's proxy. The mac app runs a
            // loopback forwarder for that; WKWebView cannot be given a per-view proxy, so the honest
            // answer is to stop here rather than sign in over the wrong network.
            return fail(r, Messages.tunnelUnsupported)
        case .signIn:
            break
        }

        let controller = SignInController(identity: opened.identity)
        controller.onMe = { [weak self] me in
            Task { @MainActor in self?.onMe(r, me) }
        }
        controller.onCrash = { [weak self] in
            Task { @MainActor in
                self?.fail(r, UserMessage(title: "The sign-in window stopped",
                                          detail: "Please open the link again."))
            }
        }
        controller.onCameraBlocked = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isStale(r) else { return }
                self.phase = .signin(username: r.account?.username, expiresAt: r.expiresAt, notice: UserMessage(
                    title: "Your iPhone is blocking the camera for this app",
                    detail: "Open Settings › OnlyX Login › Camera, switch it on, then open your link again."))
            }
        }
        signIn = controller
        phase = .signin(username: opened.account.username, expiresAt: opened.expiresAt, notice: nil)
        // Bare origin: a guest lands on the sign-in form; nobody is still signed in from a previous
        // run, because the data store is new and in memory.
        controller.load(URL(string: "https://onlyfans.com/")!)
    }

    /// OnlyFans answered `/users/me` naming a user. Capture once the last cookies land.
    private func onMe(_ r: Run, _ me: SessionCapture.Me) {
        guard !isStale(r) else { return }
        guard ConnectFlow.shouldCapture(me: me, alreadyCaptured: r.captured, capturing: r.capturing,
                                        refusedIds: r.refusedIds) else { return }
        guard r.settleTask == nil else { return }
        r.settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            r.settleTask = nil
            await self.capture(r, me)
        }
    }

    private func capture(_ r: Run, _ me: SessionCapture.Me) async {
        guard !isStale(r), let controller = signIn else { return }
        // Claimed before the first await: OnlyFans polls /users/me often enough that a second
        // answer during the cookie read or the import would import twice on a single-use token.
        if r.capturing { return }
        r.capturing = true
        defer { r.capturing = false }

        let cookies = await controller.readCookies()
        guard !isStale(r) else { return }
        guard SessionCapture.hasLoginCookies(cookies) else {
            // Named, but the jar is not there yet: the next /users/me tries again.
            flowLog.info("run \(r.id): named a user but the login cookies are not in the jar yet")
            return
        }
        // The device token, retried: OnlyFans writes bcTokenSha around sign-in rather than at it,
        // and the API refuses an import without one.
        var xbc: (key: String, value: String)? = nil
        for attempt in 0..<4 where xbc == nil {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !isStale(r) else { return }
            xbc = await controller.readXbc()
        }
        guard !isStale(r) else { return }
        guard let xbc else {
            // Left uncaptured so the next /users/me tries again, rather than spending the pass on
            // a jar the API will refuse.
            flowLog.info("run \(r.id): signed in but the device token is not in storage yet — waiting")
            return
        }

        let payload = SessionCapture.buildSessionPayload(cookies: cookies, xbc: xbc)
        r.captured = true
        flowLog.info("run \(r.id): captured \(payload.cookies.count) cookies + device token")
        phase = .captured(username: r.account?.username)

        guard let token = r.token else { return }
        let result: ImportResponse
        do {
            result = try await api.importSession(token: token, ImportRequest(session: payload, ofUserId: me.id, username: me.username))
        } catch let e as ApiError {
            guard !isStale(r) else { return }
            switch ConnectFlow.importOutcome(code: e.code) {
            case let .retrySignIn(notice, remember):
                r.captured = false
                if remember { r.refusedIds.insert(me.id) }
                flowLog.notice("run \(r.id): import refused (\(e.code, privacy: .public)) — waiting for another sign-in")
                phase = .signin(username: r.account?.username, expiresAt: r.expiresAt, notice: notice)
                return
            case let .fail(message):
                return fail(r, message)
            case .imported:
                break
            }
            return
        } catch {
            return fail(r, Messages.forImport("unreachable"))
        }
        guard !isStale(r) else { return }
        flowLog.info("run \(r.id): session imported at \(result.importedAt, privacy: .public); seat \(result.seat.map { "\($0.workerId)#\($0.seatIndex)" } ?? "pending", privacy: .public)")

        // The browser has done its job: close it, drop the jar, then watch the seat adopt it.
        signIn?.close()
        signIn = nil
        phase = .verifying(username: r.account?.username, seatState: nil)
        r.pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.poll(r, token: token)
                if r.done { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.statusPollSeconds * 1_000_000_000))
            }
        }
    }

    private func poll(_ r: Run, token: String) async {
        guard !isStale(r) else { return }
        let status: StatusResponse
        do {
            status = try await api.status(token: token)
        } catch let e as ApiError {
            guard !isStale(r) else { return }
            if let terminal = ConnectFlow.phaseForPollError(e, username: r.account?.username) {
                r.done = true
                r.pollTask?.cancel()
                phase = terminal
            }
            return
        } catch {
            return
        }
        guard !isStale(r) else { return }
        let next = ConnectFlow.phase(forStatus: status, fallbackUsername: r.account?.username)
        switch next {
        case .success, .error:
            r.done = true
            r.pollTask?.cancel()
        default:
            break
        }
        phase = next
    }
}
