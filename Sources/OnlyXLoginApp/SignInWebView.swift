import AVFoundation
import Foundation
import OSLog
import SwiftUI
import WebKit
import OnlyXLoginCore

let log = Logger(subsystem: "ai.onlyx.login", category: "signin")

/// The sign-in browser: one WKWebView per run, in memory, hardened, listening for OnlyFans to
/// name the creator. The WebKit stand-in for the mac app's WebContentsView + CDP debugger, with
/// each Electron guard mapped to its WebKit equivalent:
///
///   in-memory partition           WKWebsiteDataStore.nonPersistent()
///   Page.addScriptToEvaluateOnNewDocument   WKUserScript at .atDocumentStart (harden + observer)
///   Network.responseReceived watch          the observer script -> WKScriptMessageHandler
///   Runtime.evaluate (device token)         evaluateJavaScript
///   session.cookies.get                     WKHTTPCookieStore.getAllCookies (HttpOnly included)
///   will-navigate https-only guard          WKNavigationDelegate decidePolicyFor
///   window.open -> load in place            WKUIDelegate createWebViewWith (returns nil, loads)
///   media permission (the selfie)           WKUIDelegate requestMediaCapturePermissionFor -> .grant
///   render-process-gone                     webViewWebContentProcessDidTerminate
///
/// Identity: NATIVE, always in practice — this iPhone, as SAFARI presents it. A bare WKWebView's
/// User-Agent lacks Safari's `Version/x Mobile/15E148 Safari/604.1` tokens, which is the exact
/// signature every "is this an in-app browser" check keys on, and identity vendors treat an in-app
/// view as a different device class. `applicationNameForUserAgent` adds precisely those tokens,
/// so the string is what her own Safari sends: same engine, same device, no invented claim — the
/// same move the mac app makes when it strips its Electron token (native-identity.js). In the
/// exceptional `seat` answer the served UA string is set instead (NativeIdentity).
@MainActor
final class SignInController: NSObject, ObservableObject {
    let webView: WKWebView
    var onMe: ((SessionCapture.Me) -> Void)? = nil
    var onCrash: (() -> Void)? = nil
    /// The camera is refused at the SYSTEM level (Settings › OnlyX Login › Camera off). Raised once
    /// so the sign-in screen can say how to recover; the vendor's iframe only says "unavailable".
    var onCameraBlocked: (() -> Void)? = nil
    private var closed = false
    private var cameraWarned = false

    init(identity: Identity) {
        let config = WKWebViewConfiguration()
        // Nothing outlives the run: cookies, storage and cache live as long as this store object.
        config.websiteDataStore = .nonPersistent()
        // The selfie check: OnlyFans' vendor uses getUserMedia in the page. Inline playback and no
        // user-gesture gate are what let its <video> preview run inside the page.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if NativeIdentity.isNative(identity) {
            config.applicationNameForUserAgent = NativeIdentity.safariApplicationName(systemVersion: UIDevice.current.systemVersion)
        }
        let content = WKUserContentController()
        // Before any page script, main frame: the WebAuthn refusal and the /users/me observer.
        content.addUserScript(WKUserScript(source: SessionCapture.hardenScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: MeObserver.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        content.add(WeakScriptMessageHandler(self), name: MeObserver.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if let ua = NativeIdentity.customUserAgent(for: identity) {
            // seat mode only — a UA string with no client hints beside it; see NativeIdentity.
            webView.customUserAgent = ua
        }
        if let script = identity.initScript, !NativeIdentity.isNative(identity) {
            content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Stop everything and drop the store. The web view is released with this object.
    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: MeObserver.handlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The whole jar, HttpOnly cookies included — which is why it is read from the cookie store and
    /// never from document.cookie (sess and auth_id are HttpOnly).
    func readCookies() async -> [SessionCapture.RawCookie] {
        await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.map { c in
                    SessionCapture.RawCookie(name: c.name, value: c.value, domain: c.domain, path: c.path,
                                             expiresDate: c.expiresDate, httpOnly: c.isHTTPOnly, secure: c.isSecure)
                })
            }
        }
    }

    /// `(key, value)` of the device token in the page's local storage, or nil.
    func readXbc() async -> (key: String, value: String)? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(SessionCapture.readXbcExpression) { result, _ in
                cont.resume(returning: SessionCapture.parseXbc(result))
            }
        }
    }
}

// MARK: the observer's messages

/// WKUserContentController retains its handlers; this breaks the cycle so a run's controller is
/// released with the run. `@MainActor` because WebKit delivers on the main thread and the iOS 17
/// SDK does not say so (the annotation landed in WebKit after Xcode 15.4); under the iOS 18+ SDK
/// the protocol is main-actor itself and this is simply consistent with it.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: SignInController?
    init(_ target: SignInController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

extension SignInController {
    /// Only the MAIN frame on an OnlyFans origin is listened to: the handler name is visible in
    /// every frame, the vendor's iframe included, and a report from anywhere else is noise at
    /// best. The body is size-capped in `decode`.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == MeObserver.handlerName,
              message.frameInfo.isMainFrame,
              SessionCapture.isOnlyFansHost(message.frameInfo.securityOrigin.host),
              let report = MeObserver.decode(message.body) else { return }
        guard let me = MeObserver.judge(report) else {
            log.info("users/me answered \(report.status) without naming a user (guest answer)")
            return
        }
        log.info("OnlyFans named user \(me.id, privacy: .private)")
        onMe?(me)
    }
}

// MARK: guards

extension SignInController: WKNavigationDelegate {
    /// https only, plus about:blank. Everything else — a custom scheme, plain http, a file — is
    /// refused, the same rule the mac app's will-navigate guard applies.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = SessionCapture.allowsNavigation(url: navigationAction.request.url, isMainFrame: isMain)
        if !allowed {
            // Blocking is silent to the page, so it is loud here: a guard of ours and a vendor
            // outage look identical from the outside otherwise.
            log.notice("blocked navigation (\(isMain ? "main" : "sub") frame): \(navigationAction.request.url?.scheme ?? "?", privacy: .public)")
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("the sign-in web content process terminated")
        onCrash?()
    }
}

extension SignInController: WKUIDelegate {
    /// `window.open` / target=_blank: the mac app's default is to load an https target in place
    /// rather than deny it outright (a denied popup returns null to a vendor about to use it).
    /// Same here: nil = no new web view; the request is loaded in this one when it is https.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// The selfie check. iOS asks the person once, system-wide, for the camera (the Info.plist
    /// usage string); this answers the PAGE's request on a secure origin. A denial at the system
    /// level surfaces as the vendor's own "camera unavailable", which the Help screen explains.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let secure = origin.protocol == "https"
        // A standing SYSTEM denial: iOS asks once, and a reflexive "Don't Allow" earlier means the
        // vendor's check fails inside its iframe with no way to say why. Detected and surfaced,
        // as the mac app does for macOS; the grant below still goes through so the page sees the
        // same answer it would from Safari.
        if secure, !cameraWarned, AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            cameraWarned = true
            log.notice("camera is denied for this app at the system level")
            onCameraBlocked?()
        }
        log.info("media capture requested (type \(type.rawValue)) on \(secure ? "https" : "insecure", privacy: .public) origin — \(secure ? "grant" : "deny", privacy: .public)")
        decisionHandler(secure ? .grant : .deny)
    }

    /// No JavaScript dialogs: a sign-in page has no business blocking on alert(), and an
    /// unanswered one hangs the page. Dismissed, like the mac app's absence of a dialog handler.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }
}

/// The SwiftUI wrapper. The web view is owned by the controller (so the run can read it after the
/// view goes away); this only mounts it.
struct SignInWebView: UIViewRepresentable {
    let controller: SignInController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
