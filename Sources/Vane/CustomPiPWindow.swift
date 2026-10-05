import AppKit
import Combine

/// Owns placement and input while WebKit continues decoding the original video.
@MainActor final class CustomPiPWindow: NSPanel {
    let videoView: NSView
    let controlsView: NSView
    private var screenChanges: AnyCancellable?

    init(frame: NSRect, videoView: NSView, controlsView: NSView) {
        self.videoView = videoView
        self.controlsView = controlsView
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("vane.pip.window")
        title = "Picture in Picture"
        isExcludedFromWindowsMenu = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = frame.size
        let aspect = frame.width / frame.height
        contentMinSize = NSSize(width: max(280, 160 * aspect), height: max(160, 280 / aspect))
        isMovableByWindowBackground = true
        let content = VideoContent(frame: NSRect(origin: .zero, size: frame.size), video: videoView, controls: controlsView)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        contentView = content
        videoView.frame = content.bounds
        videoView.autoresizingMask = [.width, .height]
        content.addSubview(videoView)
        controlsView.frame = content.bounds
        controlsView.autoresizingMask = [.width, .height]
        content.addSubview(controlsView)
        NSApp.addWindowsItem(self, title: title, filename: false)
        screenChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setFrame(Self.recoverFrame(self.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
                }
            }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        NSApp.removeWindowsItem(self)
        screenChanges = nil
        super.close()
    }

    static func recoverFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let screen = screens.first, frame.width > 0, frame.height > 0 else { return frame }
        if screens.contains(where: {
            let visible = $0.intersection(frame)
            return visible.width >= 80 && visible.height >= 50
        }) { return frame }
        let scale = min(1, screen.width / frame.width, screen.height / frame.height)
        let size = NSSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    func fadeOut(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.orderOut(nil)
                completion()
            }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { (controlsView as? PiPPlaybackControls)?.showForKeyboard() }
        if event.type == .leftMouseDown, event.window === self, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            var target = contentView.hitTest(point)
            var interactive = false
            while let view = target {
                if view is NSControl { interactive = true; break }
                target = view.superview
            }
            // Keep the native resize border; all remaining video ground is a drag handle.
            if !interactive && contentView.bounds.insetBy(dx: 8, dy: 8).contains(point) {
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }

    private final class VideoContent: NSView {
        let video: NSView
        let controls: NSView

        init(frame: NSRect, video: NSView, controls: NSView) {
            self.video = video
            self.controls = controls
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { nil }
        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            video.frame = bounds
            controls.frame = bounds
        }
        override func layout() {
            video.frame = bounds
            controls.frame = bounds
            super.layout()
        }
    }
}
