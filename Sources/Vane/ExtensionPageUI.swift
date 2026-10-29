import AppKit
import WebKit

/// Retained by the host while options or a popup is presented. Intercept file
/// selection and preserve the SDK's other UI/navigation delegate behavior.
@MainActor final class ExtensionPageUI: NSObject, WKUIDelegate, WKNavigationDelegate {
    weak var context: WKWebExtensionContext?
    // Objective-C capability queries can arrive outside actor isolation. These
    // immutable references are only queried for selectors there; callbacks run on main.
    nonisolated(unsafe) let originalUIDelegate: (any WKUIDelegate)?
    nonisolated(unsafe) let originalNavigationDelegate: (any WKNavigationDelegate)?
    private weak var web: WKWebView?
    var hasView: Bool { web != nil }
    private let requestID = UUID()
    private let isEnabled: () -> Bool
    private let didClose: (ExtensionPageUI) -> Void
    private var observers: [NSObjectProtocol] = []
    private weak var popover: NSPopover?
    private weak var window: NSWindow?

    init(web: WKWebView, context: WKWebExtensionContext, isEnabled: @escaping () -> Bool,
         didClose: @escaping (ExtensionPageUI) -> Void = { _ in }) {
        originalUIDelegate = web.uiDelegate
        originalNavigationDelegate = web.navigationDelegate
        self.web = web
        self.context = context
        self.isEnabled = isEnabled
        self.didClose = didClose
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalUIDelegate?.responds(to: selector) == true
            || originalNavigationDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalUIDelegate?.responds(to: selector) == true { return originalUIDelegate }
        if originalNavigationDelegate?.responds(to: selector) == true { return originalNavigationDelegate }
        return super.forwardingTarget(for: selector)
    }

    func observe(_ popup: NSPopover) {
        guard popover !== popup else { return }
        popover = popup
        observeClose(NSPopover.willCloseNotification, object: popup)
    }

    func observe(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        observeClose(NSWindow.willCloseNotification, object: window)
    }

    private func observeClose(_ name: NSNotification.Name, object: AnyObject) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.invalidate()
                self.didClose(self)
            }
        })
    }

    func cancel() { FileUploads.cancel(tabID: requestID) }

    func invalidate() {
        cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        popover = nil
        window = nil
        if web?.uiDelegate === self { web?.uiDelegate = originalUIDelegate }
        if web?.navigationDelegate === self { web?.navigationDelegate = originalNavigationDelegate }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard web === webView, isEnabled() else { completionHandler(nil); return }
        FileUploads.choose(parameters: parameters, id: requestID, web: webView,
            isCurrent: { [weak self, weak webView] in
                guard let self, let webView else { return false }
                return self.web === webView && self.isEnabled()
                    && (self.popover == nil || self.popover?.isShown == true)
            }, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true { cancel() }
        if let original = originalNavigationDelegate,
           original.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) {
            original.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // WebKit can defer starting navigation until the open-panel reply. Cancel at
        // policy admission and forward exactly one of the original policy variants.
        if action.targetFrame?.isMainFrame == true { cancel() }
        if let original = originalNavigationDelegate,
           original.responds(to: #selector(WKNavigationDelegate.webView(_:decidePolicyFor:preferences:decisionHandler:))) {
            original.webView?(webView, decidePolicyFor: action, preferences: preferences, decisionHandler: decisionHandler)
        } else if let original = originalNavigationDelegate,
                  original.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) {
            original.webView?(webView, decidePolicyFor: action) { decisionHandler($0, preferences) }
        } else { decisionHandler(.allow, preferences) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancel()
        originalNavigationDelegate?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        cancel()
        originalNavigationDelegate?.webView?(webView, didCommit: navigation)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancel()
        originalNavigationDelegate?.webViewWebContentProcessDidTerminate?(webView)
    }

    isolated deinit {
        cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
