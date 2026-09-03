import Foundation
import SwiftUI
import WebKit
import OnlyXLoginCore

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
/// Identity: NATIVE, always in practice. The app leaves WKWebView's own iPhone-Safari User-Agent
/// alone (NativeIdentity). In the exceptional `seat` answer it sets the UA string only.
@MainActor
final class SignInController: NSObject, ObservableObject {
    let webView: WKWebView
    var onMe: ((SessionCapture.Me) -> Void)? = nil
    var onCrash: (() -> Void)? = nil
    private var closed = false

    init(identity: Identity) {
        let config = WKWebViewConfiguration()
        // Nothing outlives the run: cookies, storage and cache live as long as this store object.
        config.websiteDataStore = .nonPersistent()
        // The selfie check: OnlyFans' vendor uses getUserMedia in the page. Inline playback and no
        // user-gesture gate are what let its <video> preview run inside the page.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
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
                    SessionCapture.RawCookie(
                        name: c.name, value: c.value, domain: c.domain, path: c.path,
                        isSession: c.expiresDate == nil,
                        expires: c.expiresDate?.timeIntervalSince1970,
                        httpOnly: c.isHTTPOnly, secure: c.isSecure)
                })
            }
        }
    }

    /// `(key, value)` of the device token in the page's local storage, or nil.
    func readXbc() async -> (key: String, value: String)? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(SessionCapture.readXbcExpression) { result, _ in
                guard let json = result as? String, let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let key = dict["key"], let value = dict["value"] else {
                    return cont.resume(returning: nil)
                }
                cont.resume(returning: (key: key, value: value))
            }
        }
    }
}

// MARK: the observer's messages

/// WKUserContentController retains its handlers; this breaks the cycle so a run's controller is
/// released with the run.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: SignInController?
    init(_ target: SignInController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

extension SignInController {
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.name == MeObserver.handlerName,
              let report = MeObserver.decode(message.body),
              let me = MeObserver.judge(report) else { return }
        onMe?(me)
    }
}

// MARK: guards

extension SignInController: WKNavigationDelegate {
    /// https only, plus about:blank. Everything else — a custom scheme, plain http, a file — is
    /// refused, the same rule the mac app's will-navigate guard applies.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased()
        if scheme == "https" || url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
        decisionHandler(origin.protocol == "https" ? .grant : .deny)
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
