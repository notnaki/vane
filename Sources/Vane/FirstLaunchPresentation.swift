import AppKit
import SwiftUI

/// Uses the browser's existing window without changing its frame or macOS presentation.
/// Retain the browser view so incoming links and its SwiftUI state survive setup.
@MainActor final class FirstLaunchPresentation: NSObject {
    private weak var host: NSWindow?
    private let welcome: NSHostingView<AnyView>
    private let onHostClose: () -> Void
    private var browser: NSView?
    private weak var previousResponder: NSResponder?

    init(host: NSWindow, content: AnyView, onHostClose: @escaping () -> Void = {}) {
        self.host = host
        self.onHostClose = onHostClose
        welcome = WelcomeHostingView(rootView: content)
        // Setup adapts to the saved browser size rather than imposing its ideal size.
        welcome.sizingOptions = []
        super.init()
    }

    func show() {
        guard browser == nil, let host, let content = host.contentView else { return }
        browser = content
        if let editor = host.firstResponder as? NSTextView, editor.isFieldEditor {
            previousResponder = editor.delegate as? NSResponder
        } else {
            previousResponder = host.firstResponder
        }
        host.makeFirstResponder(nil)
        host.contentView = welcome
        host.makeFirstResponder(welcome)
        NotificationCenter.default.addObserver(self, selector: #selector(hostWillClose),
                                               name: NSWindow.willCloseNotification, object: host)
    }

    func close() {
        guard let browser else { return }
        self.browser = nil
        NotificationCenter.default.removeObserver(self)
        defer { previousResponder = nil }
        guard let host, host.contentView === welcome else { return }
        host.contentView = browser
        if let view = previousResponder as? NSView, view.window === host {
            host.makeFirstResponder(view)
        }
    }

    /// Consent dialogs belong to the restored browser, after its dismissal event.
    func closeAndContinue(_ action: @escaping @MainActor () -> Void) {
        guard browser != nil else { return }
        close()
        Task { @MainActor in action() }
    }

    @objc private func hostWillClose() {
        close()
        onHostClose()
    }
}

/// Escape belongs to the guided screen, never to window/setup dismissal.
private final class WelcomeHostingView: NSHostingView<AnyView> {
    override func cancelOperation(_ sender: Any?) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return true }
        return super.performKeyEquivalent(with: event)
    }
}
