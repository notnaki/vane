import SwiftUI
import WebKit

/// Live views are opt-in and ephemeral. Reopening a board displays its saved capture.
/// Use the owner's cookie store and content rules, without registering a browser tab,
/// history visit, password handler, or extension context for this preview.
struct EaselLiveView: NSViewRepresentable {
    let url: URL
    let profileID: UUID
    func makeCoordinator() -> Delegate { Delegate(profileID: profileID) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ProfileManager.dataStore(for: profileID)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        Blocker.apply(to: configuration, profileID: profileID)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        context.coordinator.source = url
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { Self.update(web, source: url, delegate: context.coordinator) }
    static func update(_ web: WKWebView, source: URL, delegate: Delegate) {
        guard delegate.source != source else { return }
        delegate.source = source
        delegate.upgradedHosts.removeAll()
        web.load(URLRequest(url: source))
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Delegate) {
        web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
        web.loadHTMLString("", baseURL: nil)
    }
    @MainActor final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        let profileID: UUID
        var source: URL?
        var upgradedHosts: Set<String> = []
        init(profileID: UUID) { self.profileID = profileID }
        enum Policy: Equatable { case allow, cancel, upgrade(URL) }
        func policy(url: URL, mainFrame: Bool) -> Policy {
            guard EaselItem.webURL(url.absoluteString) != nil else { return .cancel }
            // Preview-local retry state avoids granting an interstitial's one-shot HTTP
            // allowance to a browser tab. The owner's explicit host exceptions still apply.
            if mainFrame, HTTPSOnly.enabled, let upgraded = HTTPSOnly.upgrade(url, profileID: profileID) {
                guard upgradedHosts.insert(url.host ?? "").inserted else { return .cancel }
                return .upgrade(upgraded)
            }
            return .allow
        }

        func finished(url: URL?) {
            if url?.scheme?.lowercased() == "https" { upgradedHosts.removeAll() }
        }
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { finished(url: web.url) }
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, EaselItem.webURL(url.absoluteString) != nil else {
                decisionHandler(.cancel); return
            }
            guard action.targetFrame != nil, !action.shouldPerformDownload else { decisionHandler(.cancel); return }
            switch policy(url: url, mainFrame: action.targetFrame?.isMainFrame == true) {
            case .allow: decisionHandler(.allow)
            case .cancel: decisionHandler(.cancel)
            case .upgrade(let target):
                decisionHandler(.cancel)
                web.load(URLRequest(url: target))
            }
        }
        func webView(_ web: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
            decisionHandler(response.canShowMIMEType && !attachment ? .allow : .cancel)
        }
        func webView(_ web: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Let the system validate ordinary TLS. A preview never supplies passwords
            // or grants the browser's explicit certificate exceptions.
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
        func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ web: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ web: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
        func webView(_ web: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
        func webView(_ web: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    }
}
