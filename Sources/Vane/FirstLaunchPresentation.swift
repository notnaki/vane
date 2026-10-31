import AppKit
import SwiftUI

/// Covers the host's display without creating a macOS Space or animating the user
/// away from their desktop. The browser retains every incoming link underneath.
@MainActor final class FirstLaunchPresentation: NSWindowController {
    private weak var host: NSWindow?
    private var savedOptions: NSApplication.PresentationOptions?

    init(host: NSWindow, content: AnyView) {
        self.host = host
        let frame = host.screen?.frame ?? NSScreen.main?.frame ?? host.frame
        let welcome = WelcomeWindow(contentRect: frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        welcome.title = "Welcome to Vane"
        welcome.isReleasedWhenClosed = false
        welcome.isMovable = false
        welcome.hasShadow = false
        welcome.animationBehavior = .none
        welcome.collectionBehavior = [.fullScreenAuxiliary]
        welcome.contentView = NSHostingView(rootView: content)
        super.init(window: welcome)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard savedOptions == nil, let window, let host else { return }
        savedOptions = NSApp.presentationOptions
        var options = NSApp.presentationOptions
        options.subtract([.hideDock, .hideMenuBar])
        options.formUnion([.autoHideDock, .autoHideMenuBar])
        NSApp.presentationOptions = options
        fitScreen()
        NotificationCenter.default.addObserver(self, selector: #selector(fitScreen),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        host.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func fitScreen() {
        guard let frame = (host?.screen ?? window?.screen ?? NSScreen.main)?.frame else { return }
        window?.setFrame(frame, display: true)
    }

    override func close() {
        guard let options = savedOptions else { return }
        savedOptions = nil
        NotificationCenter.default.removeObserver(self)
        if let window {
            host?.removeChildWindow(window)
            window.orderOut(nil)
        }
        NSApp.presentationOptions = options
        super.close()
    }
}

@MainActor private final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
