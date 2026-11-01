import AppKit
import WebKit

/// Owns presentation, never extension identity or permissions. An action keeps its
/// exact WebKit popup view; a requested popup has a separate truthful window adapter.
@MainActor final class ExtensionWindowPresentation: NSObject, NSWindowDelegate {
    #if DEBUG
    static var actionResizeWillApplyForTesting: ((NSWindow, CGSize, Bool) -> Void)?
    #endif
    let context: WKWebExtensionContext
    let action: WKWebExtension.Action?
    let web: WKWebView
    let window: NSWindow
    private(set) weak var parentStore: TabStore?
    weak var parentTab: Tab?
    private let parentProfileID: UUID?
    private let parentWasPrivate: Bool
    private let didClose: (ExtensionWindowPresentation) -> Void
    private var delegateProxy: ExtensionPopupDelegate!
    private var parentCloseObserver: NSObjectProtocol?
    private weak var observedParentWindow: NSWindow?
    private var userResized = false
    private var actionFitTask: Task<Void, Never>?
    private var actionFitRequestedAgain = false
    private var actionFitTarget: CGSize?
    private(set) var isClosed = false
    var openExternal: ((URL) -> Void)?
    var focusChanged: (() -> Void)?

    init(web: WKWebView, context: WKWebExtensionContext, action: WKWebExtension.Action? = nil,
         parentStore: TabStore?, parentTab: Tab?, title: String, requestedFrame: CGRect? = nil,
         didClose: @escaping (ExtensionWindowPresentation) -> Void) {
        self.context = context
        self.action = action
        self.web = web
        self.parentStore = parentStore
        self.parentTab = parentTab
        parentProfileID = parentStore?.profileID
        parentWasPrivate = parentStore?.isPrivate ?? false
        self.didClose = didClose
        let size = Self.popupSize(web.intrinsicContentSize)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = title
        window.delegate = self
        delegateProxy = ExtensionPopupDelegate(owner: self, web: web)
        web.uiDelegate = delegateProxy
        web.navigationDelegate = delegateProxy
        let content = ExtensionPopupContentView(frame: CGRect(origin: .zero, size: size))
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        if let requestedFrame {
            let screen = parentStore?.window?.screen ?? NSScreen.main
            window.setFrame(Self.normalizedFrame(requestedFrame, fallback: window.frame,
                                                  screen: screen), display: false)
        } else {
            window.center()
            if let parent = parentStore?.window {
                var frame = window.frame
                frame.origin = CGPoint(x: parent.frame.midX - frame.width / 2,
                                       y: parent.frame.midY - frame.height / 2)
                window.setFrame(Self.contained(frame, in: parent.screen?.visibleFrame), display: false)
            }
            content.didLayout = { [weak self] in self?.scheduleActionContentFit() }
        }
        if action != nil, let parentStore { rebindParent(to: parentStore) }
    }

    /// A tab can move while its action stays open. The close observer must follow
    /// the same parent identity as focus queries, including a replaced NSWindow.
    /// Crossing the original profile/private boundary retires the presentation.
    func rebindParent(to store: TabStore) {
        guard !isClosed else { return }
        guard store.profileID == parentProfileID, store.isPrivate == parentWasPrivate,
              !store.isPrivate || context.hasAccessToPrivateData,
              parentTab.map({ $0.profileID == store.profileID && $0.isPrivate == store.isPrivate }) ?? true,
              let parent = store.window else { close(); return }
        guard parentStore !== store || observedParentWindow !== parent else { return }
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentStore = store
        observedParentWindow = parent
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: parent, queue: .main) { [weak self, weak parent] _ in
                MainActor.assumeIsolated {
                    guard let self, let parent, self.observedParentWindow === parent else { return }
                    self.close()
                }
            }
    }

    private static func popupSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite && size.width > 0 ? min(800, max(50, size.width)) : 400,
               height: size.height.isFinite && size.height > 0 ? min(600, max(50, size.height)) : 500)
    }

    /// Extension frame components are independently NaN when omitted. Never pass
    /// such a partial rectangle into AppKit or use it in coordinate conversion.
    static func normalizedFrame(_ requested: CGRect, fallback: CGRect, screen: NSScreen?) -> CGRect {
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        var frame = fallback
        frame.size.width = requested.width.isFinite && requested.width > 0 ? requested.width : frame.width
        frame.size.height = requested.height.isFinite && requested.height > 0 ? requested.height : frame.height
        frame.size.width = min(visible.width, max(100, frame.width))
        frame.size.height = min(visible.height, max(100, frame.height))
        frame.origin.x = requested.minX.isFinite ? requested.minX : visible.midX - frame.width / 2
        let screenTop = screen?.frame.maxY ?? visible.maxY
        frame.origin.y = requested.minY.isFinite ? screenTop - requested.minY - frame.height : visible.midY - frame.height / 2
        return contained(frame, in: visible)
    }

    private static func contained(_ frame: CGRect, in visible: CGRect?) -> CGRect {
        guard let visible else { return frame }
        var result = frame
        result.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        result.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return result
    }

    private func scheduleActionContentFit() {
        guard action != nil, !isClosed, !userResized else { return }
        guard actionFitTask == nil else { actionFitRequestedAgain = true; return }
        // Changing the owning window's frame from its content layout can feed
        // another constraint/layout pass into the pass currently in progress.
        actionFitTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.actionFitRequestedAgain = false
            self.fitActionContent()
            self.actionFitTask = nil
            if self.actionFitRequestedAgain { self.scheduleActionContentFit() }
        }
    }

    private func cancelActionContentFit() {
        actionFitTask?.cancel()
        actionFitTask = nil
        actionFitRequestedAgain = false
        actionFitTarget = nil
    }

    private func fitActionContent() {
        guard !isClosed, !userResized, context.isLoaded,
              action?.popupWebView === web, web.window === window else { return }
        let size = Self.popupSize(web.intrinsicContentSize)
        let old = window.contentLayoutRect.size
        guard abs(size.width - old.width) > 1 || abs(size.height - old.height) > 1 else {
            actionFitTarget = nil
            return
        }
        // Intermediate animation geometry must not restart the same request.
        guard actionFitTarget != size else { return }
        actionFitTarget = size
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame = Self.contained(frame, in: window.screen?.visibleFrame)
        #if DEBUG
        Self.actionResizeWillApplyForTesting?(window, size,
            (window.contentView as? ExtensionPopupContentView)?.layoutInProgressForTesting ?? false)
        #endif
        window.setFrame(frame, display: true, animate: window.isVisible && !Motion.reduced)
    }

    func show(focused: Bool = true) {
        guard !isClosed else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        if focused { window.makeKeyAndOrderFront(nil) }
        else { window.orderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) { retire(closeNativeWindow: false) }
    func windowWillStartLiveResize(_ notification: Notification) {
        userResized = true
        cancelActionContentFit()
    }
    func windowDidResize(_ notification: Notification) {
        guard let target = actionFitTarget else { return }
        let actual = window.contentLayoutRect.size
        if abs(target.width - actual.width) <= 1 && abs(target.height - actual.height) <= 1 {
            actionFitTarget = nil
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { focusChanged?() }
    func windowDidResignKey(_ notification: Notification) { focusChanged?() }

    func close() {
        retire(closeNativeWindow: true)
    }

    private func retire(closeNativeWindow: Bool) {
        guard !isClosed else { return }
        isClosed = true
        cancelActionContentFit()
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        observedParentWindow = nil
        focusChanged = nil
        (window.contentView as? ExtensionPopupContentView)?.didLayout = nil
        web.uiDelegate = delegateProxy.originalUI
        web.navigationDelegate = delegateProxy.originalNavigation
        web.removeFromSuperview()
        window.contentView = nil
        if let action { action.closePopup() }
        else { web.stopLoading() }
        if closeNativeWindow { window.close() }
        didClose(self)
    }

    func owns(_ url: URL) -> Bool {
        url.scheme == context.baseURL.scheme && url.host == context.baseURL.host
            && url.port == context.baseURL.port && url.user == nil && url.password == nil
    }
}

/// A browser.windows.create({type:'popup'}) result is a real API window/tab,
/// unlike an action's presentation-only native window. It is visible only to its owner.
@MainActor final class ExtensionRequestedWindow: NSObject, WKWebExtensionWindow {
    let presentation: ExtensionWindowPresentation
    lazy var tab = ExtensionRequestedTab(owner: self)
    private var observations: [NSKeyValueObservation] = []

    init(_ presentation: ExtensionWindowPresentation) {
        self.presentation = presentation
        super.init()
        presentation.focusChanged = { [weak self] in
            guard let self, !self.presentation.isClosed else { return }
            self.presentation.context.didFocusWindow(self.presentation.window.isKeyWindow ? self : nil)
        }
        observations = [
            presentation.web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed([.URL]) }
            },
            presentation.web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed([.title]) }
            },
            presentation.web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed([.loading]) }
            }
        ]
    }

    private func changed(_ properties: WKWebExtension.TabChangedProperties) {
        guard !presentation.isClosed, presentation.context.isLoaded else { return }
        presentation.context.didChangeTabProperties(properties, for: tab)
    }

    func accessible(_ context: WKWebExtensionContext) -> Bool {
        presentation.context === context && !presentation.isClosed && context.isLoaded
    }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { accessible(context) ? [tab] : [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { accessible(context) ? tab : nil }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if presentation.window.styleMask.contains(.fullScreen) { return .fullscreen }
        return presentation.window.isMiniaturized ? .minimized : presentation.window.isZoomed ? .maximized : .normal
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { accessible(context) ? presentation.window.frame : .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { presentation.window.screen?.frame ?? .null }
    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard accessible(context), frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            throw ExtensionHost.Failure("This extension popup is closed or its frame is invalid.")
        }
        presentation.window.setFrame(frame, display: true, animate: !Motion.reduced)
    }
    func focus(for context: WKWebExtensionContext) async throws {
        guard accessible(context) else { throw ExtensionHost.Failure("This extension popup is closed.") }
        presentation.show()
    }
    func close(for context: WKWebExtensionContext) async throws {
        guard accessible(context) else { throw ExtensionHost.Failure("This extension popup is closed.") }
        presentation.close()
    }
}

@MainActor final class ExtensionRequestedTab: NSObject, WKWebExtensionTab {
    private weak var owner: ExtensionRequestedWindow?
    init(owner: ExtensionRequestedWindow) { self.owner = owner }
    private func presentation(_ context: WKWebExtensionContext) -> ExtensionWindowPresentation? {
        guard let owner, owner.accessible(context) else { return nil }
        return owner.presentation
    }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { presentation(context) != nil ? owner : nil }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { presentation(context)?.web }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func isSelected(for context: WKWebExtensionContext) -> Bool { presentation(context) != nil }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { false }
    func url(for context: WKWebExtensionContext) -> URL? { presentation(context)?.web.url }
    func title(for context: WKWebExtensionContext) -> String? { presentation(context)?.web.title }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let presentation = presentation(context), presentation.owns(url) else {
            completionHandler(ExtensionHost.Failure("This popup can only load pages from its owning extension.")); return
        }
        presentation.web.load(URLRequest(url: url))
        completionHandler(nil)
    }
    func activate(for context: WKWebExtensionContext) async throws { try await owner?.focus(for: context) }
    func close(for context: WKWebExtensionContext) async throws { try await owner?.close(for: context) }
}

@MainActor private final class ExtensionPopupContentView: NSView {
    var didLayout: (() -> Void)?
    #if DEBUG
    private(set) var layoutInProgressForTesting = false
    #endif
    override func layout() {
        #if DEBUG
        layoutInProgressForTesting = true
        defer { layoutInProgressForTesting = false }
        #endif
        super.layout()
        didLayout?()
    }
}

/// Preserve all SDK behavior, including selectors added by a newer system WebKit.
/// Only public close/failure/navigation callbacks are intercepted. NSObject's public
/// forwarding mechanism sends every other callback to the original SDK delegates.
@MainActor private final class ExtensionPopupDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    weak var owner: ExtensionWindowPresentation?
    nonisolated(unsafe) let originalUI: (any WKUIDelegate)?
    nonisolated(unsafe) let originalNavigation: (any WKNavigationDelegate)?

    init(owner: ExtensionWindowPresentation, web: WKWebView) {
        self.owner = owner
        originalUI = web.uiDelegate
        originalNavigation = web.navigationDelegate
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalUI?.responds(to: selector) == true
            || originalNavigation?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalUI?.responds(to: selector) == true { return originalUI }
        if originalNavigation?.responds(to: selector) == true { return originalNavigation }
        return super.forwardingTarget(for: selector)
    }

    func webViewDidClose(_ webView: WKWebView) {
        originalUI?.webViewDidClose?(webView)
        owner?.close()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        originalNavigation?.webViewWebContentProcessDidTerminate?(webView)
        owner?.close()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        originalNavigation?.webView?(webView, didFail: navigation, withError: error)
        owner?.close()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        originalNavigation?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
        owner?.close()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let originalNavigation,
           originalNavigation.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) {
            originalNavigation.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
            return
        }
        guard let owner, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false || owner.owns(url) { decisionHandler(.allow) }
        else {
            if url.scheme == "https" || url.scheme == "http" { owner.openExternal?(url) }
            decisionHandler(.cancel)
        }
    }
}
