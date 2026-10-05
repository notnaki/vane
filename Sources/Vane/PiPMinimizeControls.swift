import AppKit
import WebKit

/// Moves WebKit's live presentation view into a Vane-owned floating panel.
/// The native controls remain the fallback when that host cannot be identified safely.
///
/// PIPPanel and WebVideoViewContainer are WebKit/PIP implementation details. Discover
/// both defensively; an OS change must leave the ordinary native player intact.
@MainActor enum PiPMinimizeControls {
    @MainActor final class Attachment {
        weak var window: NSWindow?
        let panel: NSPanel
        private let originalParent: NSView?
        private let originalFrame: NSRect?
        private let videoView: NSView?
        private weak var tab: Tab?
        private weak var sourceWeb: WKWebView?
        private let sourceFrame: WKFrameInfo?
        private var querying = false
        private var ending = false
        fileprivate var returningToTab = false
        private var removed = false
        private var tracking: Task<Void, Never>?
        private var nativeSession: NativePiPHostBridge.Session?

        init(window: NSWindow?, tab: Tab, direct: NativePiPHostBridge.DirectCapture? = nil) {
            self.window = window
            self.tab = tab
            sourceWeb = tab.existingWeb
            sourceFrame = tab.pipFrame
            let controls = ControlsPanel(tab: tab)
            if let parent = direct?.parent ?? window?.contentView,
               let video = direct?.video ?? parent.subviews.first(where: {
                   NSStringFromClass(type(of: $0)) == "WebVideoViewContainer"
               }), video.layer != nil,
               let frame = direct?.frame ?? window?.frame, frame.width > 0, frame.height > 0,
               let session = direct?.session ?? NativePiPHostBridge.session(parent: parent) {
                originalParent = parent
                originalFrame = direct?.originalFrame ?? video.frame
                videoView = video
                let content = PiPPlaybackControls(tab: tab,
                    returnToTab: { [weak tab] in guard let tab else { return }; Self.perform(.back, tab: tab) },
                    minimize: { [weak tab] in guard let tab else { return }; Self.perform(.minimize, tab: tab) },
                    close: { [weak tab] in guard let tab else { return }; Self.perform(.close, tab: tab) })
                panel = CustomPiPWindow(frame: frame, sourceFrame: direct?.sourceFrame, videoView: video, controlsView: content)
                window?.orderOut(nil)
                (panel as? CustomPiPWindow)?.show()
                nativeSession = session
                controls.close()
            } else {
                originalParent = nil
                originalFrame = nil
                videoView = nil
                panel = controls
            }
            tracking = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.videoView != nil {
                        guard let tab = self.tab, tab.existingWeb === self.sourceWeb,
                              tab.pipFrame === self.sourceFrame, tab.pictureInPicture || self.returningToTab else {
                            self.remove()
                            return
                        }
                    }
                    guard self.videoView != nil || self.window?.isVisible == true else {
                        self.panel.orderOut(nil)
                        return
                    }
                    self.update(pointer: NSEvent.mouseLocation)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            nativeSession?.closeShell { [weak self] ok in
                guard let self, !self.removed else { return }
                if !ok { self.remove() }
            }
        }

        func update(pointer: NSPoint) {
            if let custom = panel as? CustomPiPWindow {
                // Let WindowServer move the live video without periodic JavaScript
                // replies, control redraws, or hover fades competing with the drag.
                custom.updateInteraction()
                guard !custom.isInteracting else { return }
                if let controls = custom.controlsView as? PiPPlaybackControls {
                    controls.updateVisibility(pointer: pointer)
                    if !querying, !ending, let tab {
                        querying = true
                        PictureInPicture.playback(tab) { [weak self, weak controls, weak custom] state in
                            guard let self else { return }
                            self.querying = false
                            if !self.removed, custom?.isInteracting == false, let state { controls?.update(state) }
                        }
                    }
                }
                return
            }
            guard let window, window.isVisible else {
                panel.orderOut(nil)
                return
            }
            // PIPPanel hosts a remotely rendered video; PIPAgent owns the visible window
            // and mouse events. A subview in that host is painted but cannot be clicked.
            let frame = window.frame
            let wanted = NSRect(x: frame.maxX - 84, y: frame.maxY - 40, width: 76, height: 34)
            if panel.frame != wanted { panel.setFrame(wanted, display: true) }
            if frame.contains(pointer) {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }

        func remove() {
            guard !removed else { return }
            removed = true
            tracking?.cancel()
            tracking = nil
            restoreVideo()
            nativeSession?.endPresentation()
            panel.orderOut(nil)
            panel.close()
        }

        func restoreVideo() {
            if let videoView, let originalParent, videoView.superview === panel.contentView {
                videoView.removeFromSuperview()
                if let originalFrame { videoView.frame = originalFrame }
                originalParent.addSubview(videoView)
            }
        }

        func resumeVideo() {
            guard !removed, let videoView, let custom = panel as? CustomPiPWindow,
                  let content = custom.contentView else { return }
            // A superseded page request cannot undo a native exit already in flight.
            if returningToTab && (tab?.pictureInPicture != true || nativeSession?.isExiting == true) { return }
            content.addSubview(videoView, positioned: .below, relativeTo: custom.controlsView)
            videoView.frame = content.bounds
            ending = false
            returningToTab = false
            nativeSession?.returnAnimation = nil
            custom.resumeAfterReturn()
            guard !removed else { return }
            custom.orderFrontRegardless()
        }

        private static func perform(_ action: ExitAction, tab: Tab) {
            attachments[tab.id]?.finish(action, tab: tab)
        }

        private func finish(_ action: ExitAction, tab: Tab) {
            guard !ending, !removed, tab.existingWeb === sourceWeb,
                  tab.pipFrame === sourceFrame, let custom = panel as? CustomPiPWindow else { return }
            ending = true
            let animatedBack = action == .back && nativeSession != nil
            let exit: @MainActor () -> Void = { [weak self, weak tab] in
                guard let self, let tab, !self.removed, tab.existingWeb === self.sourceWeb,
                      tab.pipFrame === self.sourceFrame else { return }
                if !self.returningToTab { self.restoreVideo() }
                let web = tab.existingWeb
                let frame = tab.pipFrame
                let completed: @MainActor (Bool) -> Void = { [weak self, weak tab] ok in
                    guard let tab, tab.existingWeb === web, tab.pipFrame === frame else { return }
                    if !ok {
                        self?.resumeVideo()
                        return
                    }
                    if action == .back && !animatedBack {
                        PictureInPicture.exitIfAuto(tab)
                        MediaState.shared.returned(to: tab)
                        PictureInPicture.returnToTab(tab)
                    }
                }
                switch action {
                case .back: PictureInPicture.minimize(tab, then: completed)
                case .minimize: MediaState.shared.minimize(tab, then: completed)
                case .close: MediaState.shared.dismiss(tab, then: completed)
                }
            }
            if animatedBack, let nativeSession {
                returningToTab = true
                custom.prepareReturn()
                nativeSession.returnAnimation = { [weak self] rect, window, finish in
                    guard let self, !self.removed else { finish(); return }
                    let valid = self.tab?.existingWeb === self.sourceWeb
                        && self.tab?.pipFrame === self.sourceFrame
                        && window != nil && window === self.sourceWeb?.window
                        && window?.isVisible == true && window?.isMiniaturized == false
                    let destination = valid ? rect.map { window!.convertToScreen($0) } : nil
                    custom.animateReturn(to: destination) { [weak self] in
                        self?.restoreVideo()
                        custom.orderOut(nil)
                        finish()
                        guard let self, !self.removed, let tab = self.tab,
                              tab.existingWeb === self.sourceWeb, tab.pipFrame === self.sourceFrame else { return }
                        self.returningToTab = false
                        PictureInPicture.exitIfAuto(tab)
                        MediaState.shared.returned(to: tab)
                        if !tab.pictureInPicture { PiPMinimizeControls.remove(tab.id) }
                    }
                }
                PictureInPicture.returnToTab(tab)
                exit()
            } else { custom.fadeOut(completion: exit) }
        }
    }
    private static var attachments: [UUID: Attachment] = [:]
    private static var before: [UUID: Set<ObjectIdentifier>] = [:]
    private static var pending: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private enum ExitAction { case back, minimize, close }

    private static var panels: [NSWindow] {
        NSApp.windows.filter {
            NSStringFromClass(type(of: $0)) == "PIPPanel" && $0.isVisible
                && $0.contentView?.subviews.contains {
                    NSStringFromClass(type(of: $0)) == "WebVideoViewContainer"
                } == true
        }
    }

    static func prepare(for tab: Tab) {
        if !tab.pictureInPicture {
            before[tab.id] = Set(panels.map(ObjectIdentifier.init))
        }
    }

    static func install(for tab: Tab) {
        if let attachment = attachments[tab.id], attachment.returningToTab {
            // A fresh entry owns the host now. Cancel only the old attachment;
            // remove(id) would also discard the newly captured native presentation.
            attachments.removeValue(forKey: tab.id)?.remove()
        }
        guard attachments[tab.id] == nil, pending[tab.id] == nil else { return }
        if let capture = NativePiPHostBridge.claim(for: tab) {
            attachments[tab.id] = Attachment(window: nil, tab: tab, direct: capture)
            before[tab.id] = nil
            return
        }
        let token = UUID()
        let task = Task { @MainActor [weak tab] in
            guard let tab else { return }
            defer {
                if pending[tab.id]?.token == token { pending[tab.id] = nil; before[tab.id] = nil }
            }
            for _ in 0..<20 {
                guard !Task.isCancelled, tab.pictureInPicture else { return }
                // The page's mode event can precede WebKit's native presentation call.
                // Retry direct discovery throughout entry, just like native discovery.
                if let capture = NativePiPHostBridge.claim(for: tab) {
                    attachments[tab.id] = Attachment(window: nil, tab: tab, direct: capture)
                    return
                }
                let used = Set(attachments.values.compactMap(\.window).map(ObjectIdentifier.init))
                let candidates = panels.filter {
                    !used.contains(ObjectIdentifier($0))
                        && !(before[tab.id]?.contains(ObjectIdentifier($0)) ?? false)
                }
                // Never guess which of two simultaneous PiP entries owns a panel.
                if candidates.count == 1, let window = candidates.first {
                    attachments[tab.id] = Attachment(window: window, tab: tab)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        pending[tab.id] = (token, task)
    }

    static func remove(_ id: UUID) {
        NativePiPHostBridge.cancel(for: id)
        pending.removeValue(forKey: id)?.task.cancel()
        before[id] = nil
        attachments.removeValue(forKey: id)?.remove()
    }

    static func returnedInline(_ tab: Tab) {
        // The page's inline event precedes the native exit rectangle. Keep the
        // original live view until its custom flight has actually landed.
        if !isReturningToTab(tab) { remove(tab.id) }
    }

    static func prepareToExit(_ tab: Tab) {
        guard let attachment = attachments[tab.id], !attachment.returningToTab else { return }
        attachment.restoreVideo()
    }

    static func isReturningToTab(_ tab: Tab) -> Bool { attachments[tab.id]?.returningToTab == true }

    static func resumeAfterFailedExit(_ tab: Tab) {
        attachments[tab.id]?.resumeVideo()
    }

    private final class ControlsPanel: NSPanel {
        init(tab: Tab) {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 76, height: 34),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            hidesOnDeactivate = false
            // The system PiP chrome is at the utility-window level, above floating panels.
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 34))
            contentView = content
            let minimize = ControlButton(symbol: "minus", identifier: "vane.pip.minimize",
                                         label: "Minimize Picture in Picture — keep playing") { [weak tab] in
                guard let tab else { return }
                MediaState.shared.minimize(tab)
            }
            let restore = ControlButton(symbol: "pip.exit", identifier: "vane.pip.restore",
                                        label: "Return Picture in Picture to Tab") { [weak tab] in
                guard let tab else { return }
                PictureInPicture.minimize(tab) { [weak tab] ok in
                    guard ok, let tab else { return }
                    // Minimize suppressed auto-PiP in the page. Returning to an already
                    // selected tab does not produce a selection change to clear it.
                    PictureInPicture.exitIfAuto(tab)
                    MediaState.shared.returned(to: tab)
                    PictureInPicture.returnToTab(tab)
                }
            }
            for (button, x) in [(minimize, CGFloat(0)), (restore, CGFloat(42))] {
                let glass = NSGlassEffectView(frame: NSRect(x: x, y: 0, width: 34, height: 34))
                glass.cornerRadius = 17
                glass.style = .regular
                glass.appearance = NSAppearance(named: .darkAqua)
                button.frame = glass.bounds
                glass.contentView = button
                content.addSubview(glass)
            }
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class ControlButton: NSButton {
        private let clickedAction: () -> Void

        init(symbol: String, identifier: String, label: String, action: @escaping () -> Void) {
            clickedAction = action
            super.init(frame: .zero)
            self.identifier = NSUserInterfaceItemIdentifier(identifier)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            imagePosition = .imageOnly
            isBordered = false
            contentTintColor = .white
            toolTip = label
            setAccessibilityLabel(label)
            target = self
            self.action = #selector(clicked)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func clicked() { clickedAction() }
    }
}
