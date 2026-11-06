import AppKit
import WebKit

/// Transfers one live page between its browser host and a floating call window.
/// Never creates a second web view, navigates, or changes any media track.
@MainActor enum CallPopout {
    @MainActor private final class Session {
        weak var source: WebHost?
        weak var sourceWindow: NSWindow?
        let web: WKWebView
        let panel: CallPopoutWindow
        init(web: WKWebView, panel: CallPopoutWindow) {
            self.web = web; self.panel = panel
            source = web.superview as? WebHost
            sourceWindow = web.window
        }
    }
    private static var sessions: [UUID: Session] = [:]
    private static var suppressed: Set<UUID> = []
    private static var departures: Set<UUID> = []
    private final class WindowRef {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private static var minimizing: [UUID: WindowRef] = [:]

    static func window(for tab: Tab) -> NSPanel? { sessions[tab.id]?.panel }
    static func holds(_ web: WKWebView) -> Bool { sessions.values.contains { $0.web === web } }

    private static func visibleInBrowser(_ tab: Tab, excluding excluded: NSWindow? = nil) -> Bool {
        TabStore.all.contains { store in
            guard let window = store.window, window !== excluded, window.isVisible,
                  !window.isMiniaturized, store.profileVisible else { return false }
            return store.onScreenTabs.contains { $0 === tab }
        }
    }

    static func enterIfCalling(_ tab: Tab, minimizingWindow: NSWindow? = nil) {
        departures.insert(tab.id)
        minimizing[tab.id] = minimizingWindow.map(WindowRef.init)
        if tab.inMeetCall { callBecameActive(tab) }
        else { MeetCall.refresh(tab) }
    }

    static func callBecameActive(_ tab: Tab) {
        guard departures.contains(tab.id), PictureInPicture.autoEnabled,
              !suppressed.contains(tab.id), !visibleInBrowser(tab, excluding: minimizing[tab.id]?.window) else { return }
        present(tab)
    }

    /// Reconcile every affected Meet page after the browser has finalized its visible
    /// panes. The focused tab alone misses calls in another pane or a stashed Space.
    static func presentationChanged(_ tab: Tab) {
        guard !tab.tornDown, !tab.suspended, tab.existingWeb != nil,
              tab.inMeetCall || MeetCall.supports(tab.currentURL) else { return }
        if visibleInBrowser(tab) { returnInline(tab) }
        else if PictureInPicture.autoEnabled { enterIfCalling(tab) }
    }

    static func toggle(_ tab: Tab) {
        if sessions[tab.id] != nil { dismiss(tab, suppress: true) }
        else { suppressed.remove(tab.id); present(tab) }
    }

    private static func present(_ tab: Tab) {
        guard sessions[tab.id] == nil, tab.inMeetCall, !tab.tornDown, !tab.suspended,
              let web = tab.existingWeb, let sourceWindow = web.window else { return }
        let screen = sourceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: min(720, screen.width - 32), height: min(560, screen.height - 32))
        let frame = NSRect(x: screen.maxX - size.width - 16, y: screen.minY + 16, width: size.width, height: size.height)
        let panel = CallPopoutWindow(frame: frame, back: { [weak tab] in
            guard let tab else { return }
            returnInline(tab)
            PictureInPicture.returnToTab(tab)
        }, dismiss: { [weak tab] in
            guard let tab else { return }
            dismiss(tab, suppress: true)
        })
        let session = Session(web: web, panel: panel)
        sessions[tab.id] = session
        if let responder = sourceWindow.firstResponder as? NSView, responder.isDescendant(of: web) {
            sourceWindow.makeFirstResponder(nil)
        }
        if let source = session.source { Inspector.hideAttached(to: web, in: source) }
        panel.mount(web)
        // Moving a view does not clear WebHost's strong cache. Release the old host's
        // ownership after mounting, so closing this detached tab releases its page.
        session.source?.remove(web)
        tab.callPoppedOut = true
        panel.show()
    }

    static func returnInline(_ tab: Tab) {
        departures.remove(tab.id); minimizing.removeValue(forKey: tab.id); suppressed.remove(tab.id)
        dismiss(tab)
    }

    static func dismiss(_ tab: Tab, suppress: Bool = false) {
        if suppress { suppressed.insert(tab.id) }
        guard let session = sessions.removeValue(forKey: tab.id) else { return }
        tab.callPoppedOut = false
        // The browser host may now show another tab, or may have been replaced by a
        // Space/profile switch. Restore as a hidden cached page in those cases.
        if !tab.tornDown, tab.existingWeb === session.web {
            if let source = session.source, source.window != nil {
                source.restoreCallPage(session.web)
            } else if let root = session.sourceWindow?.contentView {
                session.web.isHidden = true
                root.addSubview(session.web, positioned: .below, relativeTo: nil)
            } else { session.web.removeFromSuperview() }
        } else { session.web.removeFromSuperview() }
        session.panel.orderOut(nil)
        session.panel.close()
        MediaState.shared.objectWillChange.send()
    }

    static func reset(_ tab: Tab) {
        returnInline(tab)
    }
}

@MainActor final class CallPopoutWindow: NSPanel {
    private let page = NSView()
    private let closeCallView: () -> Void

    init(frame: NSRect, back: @escaping () -> Void, dismiss: @escaping () -> Void) {
        closeCallView = dismiss
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("vane.call.window")
        title = "meet.google.com"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 420, height: 320)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(type)?.isHidden = true }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = root
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 12
        let backButton = NSButton(title: "Back to Tab", image: NSImage(systemSymbolName: "arrow.up.left", accessibilityDescription: nil)!, target: nil, action: nil)
        backButton.identifier = .init("vane.call.restore")
        let closeButton = NSButton(title: "Close", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: nil, action: nil)
        closeButton.identifier = .init("vane.call.close")
        closeButton.toolTip = "Hide call window — stay in the call"
        closeButton.setAccessibilityLabel("Hide call window, stay in the call")
        let site = NSTextField(labelWithString: "meet.google.com")
        site.font = .systemFont(ofSize: 12, weight: .semibold)
        site.alignment = .center
        site.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(backButton)
        header.addArrangedSubview(site)
        header.addArrangedSubview(closeButton)
        root.addSubview(header); root.addSubview(page)
        header.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 48),
            page.topAnchor.constraint(equalTo: header.bottomAnchor), page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        backButton.target = self; backButton.action = #selector(restoreTab)
        closeButton.target = self; closeButton.action = #selector(hideCall)
        backAction = back
    }

    private var backAction: (() -> Void)?
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { closeCallView() }
    @objc private func restoreTab() { backAction?() }
    @objc private func hideCall() { closeCallView() }

    func mount(_ web: WKWebView) {
        contentView?.layoutSubtreeIfNeeded()
        web.isHidden = false
        web.frame = page.bounds
        web.autoresizingMask = [.width, .height]
        page.addSubview(web)
    }

    func show() {
        alphaValue = CustomPiPWindow.reducesMotion ? 1 : 0
        orderFrontRegardless()
        guard !CustomPiPWindow.reducesMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}
