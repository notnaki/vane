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
        var explanation: NSAlert?

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

    // Confirmed on 27.0.1, kept for the 27.0 release family pending a verified
    // engine fix. WKUIDelegate grants selected roots, but WebKit's form policy
    // rejects enumerated children before our navigation delegate is called.
    static func directoryUploadsUnavailable(on version: OperatingSystemVersion =
        ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        version.majorVersion == 27 && version.minorVersion == 0
    }

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
        if parameters.allowsDirectories && directoryUploadsUnavailable() {
            let alert = NSAlert()
            alert.messageText = "Folder uploads unavailable"
            alert.informativeText = "This version of macOS WebKit can stop the page before a folder upload reaches the website. Vane has cancelled this folder selection. Use the website’s individual-file upload option, or try a different browser."
            alert.addButton(withTitle: "OK")
            request.explanation = alert
            alert.beginSheetModal(for: window) { _ in
                guard pending[id] === request else { return }
                pending.removeValue(forKey: id)
                request.stopObserving()
                completion(nil)
            }
            return
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
        if let alert = request.explanation {
            request.window?.endSheet(alert.window, returnCode: .abort)
            alert.window.orderOut(nil)
        } else { request.panel.cancel(nil) }
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
