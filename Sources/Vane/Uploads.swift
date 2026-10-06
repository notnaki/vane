import AppKit
import WebKit

/// Native upload sheets belong to the requesting tab document and window. Returning
/// the panel's URLs lets WebKit grant its content process access to the selected files.
@MainActor enum FileUploads {
    @MainActor private final class Pending {
        let panel = NSOpenPanel()
        weak var window: NSWindow?
        let isCurrent: @MainActor () -> Bool
        let completion: @MainActor ([URL]?) -> Void
        var closeObserver: NSObjectProtocol?

        init(window: NSWindow, isCurrent: @escaping @MainActor () -> Bool,
             completion: @escaping @MainActor ([URL]?) -> Void) {
            self.window = window; self.isCurrent = isCurrent; self.completion = completion
        }

        func stopObserving() {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
    }
    private static var pending: [UUID: Pending] = [:]

    static func choose(parameters: WKOpenPanelParameters, tab: Tab, web: WKWebView,
                       completion: @escaping @MainActor ([URL]?) -> Void) {
        guard tab.existingWeb === web, let window = web.window, window.isVisible,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              pending[tab.id] == nil else { completion(nil); return }
        let id = tab.id
        let request = Pending(window: window, isCurrent: { [weak tab, weak web, weak window] in
            guard let tab, let web, let window else { return false }
            return tab.existingWeb === web && web.window === window && window.isVisible
                && !web.isHiddenOrHasHiddenAncestor
        }, completion: completion)
        let panel = request.panel
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.treatsFilePackagesAsDirectories = parameters.allowsDirectories
        panel.canCreateDirectories = false
        pending[id] = request
        request.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    if pending[id] === request { cancel(tabID: id) }
                }
            }
        panel.beginSheetModal(for: window) { response in
            guard pending[id] === request else { return }
            pending.removeValue(forKey: id)
            request.stopObserving()
            completion(response == .OK && request.isCurrent() ? panel.urls : nil)
        }
    }

    /// Resolve WebKit exactly once, including when AppKit's dismissal callback arrives
    /// after navigation, teardown, process termination, or a window-close notification.
    static func cancel(tabID: UUID) {
        guard let request = pending.removeValue(forKey: tabID) else { return }
        request.stopObserving()
        request.panel.cancel(nil)
        request.completion(nil)
    }
}

extension Tab {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        FileUploads.choose(parameters: parameters, tab: self, web: webView,
                           completion: completionHandler)
    }
}
