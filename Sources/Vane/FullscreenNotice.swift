import AppKit
import WebKit

/// Identify the top-level browsing context and the way out. WKWebView's public
/// fullscreen state does not identify the requesting frame, so an embedded player's
/// pixels must never be attributed to its parent site's origin.
@MainActor enum FullscreenNotice {
    private static var panel: NSPanel?
    private static weak var owner: WKWebView?
    private static var dismissal: DispatchWorkItem?
    private static var observations: [NSObjectProtocol] = []

    static func show(pageURL: URL?, over web: WKWebView) {
        guard let window = web.window, let screen = window.screen else { return }
        hide(immediately: true)
        let context = origin(pageURL).map { " · Browsing \($0)" } ?? ""
        let label = NSTextField(wrappingLabelWithString: "Full screen\(context) · Press Esc to exit")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.setAccessibilityRole(.staticText)
        let width = min(label.fittingSize.width, max(1, min(640, screen.frame.width - 64) - 32))
        label.preferredMaxLayoutWidth = width
        let size = NSSize(width: width, height: label.fittingSize.height)
        let frame = NSRect(x: screen.frame.midX - (size.width + 32) / 2,
                           y: screen.frame.maxY - size.height - 16 - 48,
                           width: size.width + 32, height: size.height + 16)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.animationBehavior = .none
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = min(20, frame.height / 2)
        label.frame = NSRect(x: 16, y: 8, width: size.width, height: size.height)
        blur.addSubview(label)
        p.contentView = blur
        panel = p
        owner = web
        observations = [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak web] _ in
                MainActor.assumeIsolated {
                    if let web { hide(over: web, immediately: true) }
                }
            }
        }
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hide(immediately: true) }
            })
        let reduced = CustomPiPWindow.reducesMotion
        p.alphaValue = reduced ? 1 : 0
        p.orderFrontRegardless()
        if !reduced { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 } }
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let work = DispatchWorkItem { [weak p] in
            guard let p, panel === p else { return }
            hide()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// Omit credentials, paths and queries; keep scheme, complete ASCII hostname, and
    /// explicit port so distinct origins never collapse into an address-pill label.
    private static func origin(_ url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "a local file" }
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func hide(over web: WKWebView? = nil, immediately: Bool = false) {
        if let web, owner !== web { return }
        dismissal?.cancel(); dismissal = nil
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations = []
        owner = nil
        guard let p = panel else { return }
        panel = nil
        if immediately || CustomPiPWindow.reducesMotion { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }
}
