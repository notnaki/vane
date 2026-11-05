import AppKit
import WebKit

/// What a tab remembers about page dialogs. Sheets block their window, so a page that
/// keeps calling alert() could otherwise lock the user out of it.
///
/// ponytail: suppression lasts until the tab closes, rather than ending on navigation, so
/// a page can't escape it by reloading. Ceiling: a site stays silenced in that tab.
struct PageDialogPolicy {
    private static let repeatInterval: Duration = .seconds(10)
    private var suppressed: Set<String> = []
    private var lastDismissed: [String: ContinuousClock.Instant] = [:]

    func isSuppressed(_ site: String) -> Bool { suppressed.contains(site) }

    func offersSuppression(_ site: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard let last = lastDismissed[site] else { return false }
        return now - last < Self.repeatInterval
    }

    mutating func dismissed(_ site: String, suppress: Bool, now: ContinuousClock.Instant = .now) {
        lastDismissed[site] = now
        if suppress { suppressed.insert(site) }
    }
}

/// alert(), confirm() and prompt() as sheets on the requesting tab's window. WebKit answers
/// all three on its own when a delegate doesn't, so confirm() would silently be false.
@MainActor enum PageDialogs {
    private static let maxMessageCharacters = 1024
    private static let maxMessageLines = 24
    private static let promptFieldSize = CGSize(width: 280, height: 24)

    @MainActor private final class Pending {
        let alert = NSAlert()
        weak var window: NSWindow?
        let completion: @MainActor (Bool) -> Void
        var closeObserver: NSObjectProtocol?

        init(window: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
            self.window = window; self.completion = completion
        }

        func stopObserving() {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
    }
    private static var pending: [UUID: Pending] = [:]

    /// Long enough to read, but short enough that a page can't push the buttons off screen.
    static func clipped(_ message: String) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.prefix(maxMessageLines).joined(separator: "\n")
        let clipped = String(kept.prefix(maxMessageCharacters))
        return clipped.count < message.count ? clipped + "…" : clipped
    }

    /// Calls back exactly once. It answers false without a sheet when the tab can't show
    /// one, such as a tab in the background or a window already showing a sheet.
    static func present(message: String, frame: WKFrameInfo, tab: Tab, web: WKWebView,
                        cancellable: Bool, field: NSTextField? = nil,
                        completion: @escaping @MainActor (Bool) -> Void) {
        let site = frame.securityOrigin.host
        guard tab.existingWeb === web, let window = web.window, window.isVisible,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              pending[tab.id] == nil, !tab.dialogPolicy.isSuppressed(site) else {
            completion(false); return
        }
        let request = Pending(window: window, completion: completion)
        let alert = request.alert
        // Names the frame's own site, so an embedded frame can't pass as the page around it.
        alert.messageText = site.isEmpty ? "This page says" : "\(site) says"
        alert.informativeText = clipped(message)
        alert.addButton(withTitle: "OK")
        if cancellable { alert.addButton(withTitle: "Cancel") }
        if let field {
            field.frame = CGRect(origin: .zero, size: promptFieldSize)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        if tab.dialogPolicy.offersSuppression(site) {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t let this site show more dialogs in this tab"
        }
        pending[tab.id] = request
        let id = tab.id
        request.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    if pending[id] === request { cancel(tabID: id) }
                }
            }
        alert.beginSheetModal(for: window) { [weak tab] response in
            guard pending[id] === request else { return }
            pending.removeValue(forKey: id)
            request.stopObserving()
            tab?.dialogPolicy.dismissed(site, suppress: alert.suppressionButton?.state == .on)
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// Resolves WebKit once when navigation, teardown or a closing window ends the dialog.
    static func cancel(tabID: UUID) {
        guard let request = pending.removeValue(forKey: tabID) else { return }
        request.stopObserving()
        request.window?.endSheet(request.alert.window, returnCode: .abort)
        request.alert.window.orderOut(nil)
        request.completion(false)
    }
}

extension Tab {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        PageDialogs.present(message: message, frame: frame, tab: self, web: webView,
                            cancellable: false) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        PageDialogs.present(message: message, frame: frame, tab: self, web: webView,
                            cancellable: true, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        PageDialogs.present(message: prompt, frame: frame, tab: self, web: webView,
                            cancellable: true, field: field) { accepted in
            completionHandler(accepted ? field.stringValue : nil)
        }
    }
}
