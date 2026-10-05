import AppKit
import Combine

/// Owns placement and input while WebKit continues decoding the original video.
@MainActor final class CustomPiPWindow: NSPanel {
    let videoView: NSView
    let controlsView: NSView
    private var screenChanges: AnyCancellable?
    private var hasBeenShown = false
    static let placementKey = "customPiPFrame"

    init(frame: NSRect, videoView: NSView, controlsView: NSView) {
        self.videoView = videoView
        self.controlsView = controlsView
        let saved = UserDefaults.vane.string(forKey: Self.placementKey).map(NSRectFromString)
        let initialFrame = Self.initialFrame(frame, saved: saved, screens: NSScreen.screens.map(\.visibleFrame))
        super.init(contentRect: initialFrame, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        animationBehavior = .none
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
        contentMinSize = NSSize(width: min(initialFrame.width, max(280, 160 * aspect)),
                                height: min(initialFrame.height, max(160, 280 / aspect)))
        isMovableByWindowBackground = true
        let content = VideoContent(frame: NSRect(origin: .zero, size: initialFrame.size), video: videoView, controls: controlsView)
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
        rememberPlacement()
        NSApp.removeWindowsItem(self)
        screenChanges = nil
        super.close()
    }

    static func initialFrame(_ proposed: NSRect, saved: NSRect?, screens: [NSRect]) -> NSRect {
        guard proposed.width > 0, proposed.height > 0 else { return proposed }
        let validSaved = saved.flatMap { rect -> NSRect? in
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        let placement = validSaved ?? proposed
        let aspect = proposed.width / proposed.height
        let width = max(placement.width, 280, 160 * aspect)
        let height = width / aspect
        let wanted = NSRect(x: placement.minX, y: placement.maxY - height, width: width, height: height)
        return recoverFrame(wanted, screens: screens)
    }

    private func rememberPlacement() {
        guard hasBeenShown else { return }
        UserDefaults.vane.set(NSStringFromRect(frame), forKey: Self.placementKey)
    }

    static func recoverFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let first = screens.first, frame.width > 0, frame.height > 0 else { return frame }
        let visible = screens.filter {
            let intersection = $0.intersection(frame)
            return intersection.width >= 80 && intersection.height >= 50
        }
        let screen = visible.max {
            let left = $0.intersection(frame), right = $1.intersection(frame)
            return left.width * left.height < right.width * right.height
        } ?? first
        let scale = min(1, screen.width / frame.width, screen.height / frame.height)
        if scale < 1 {
            // A remembered landscape width can otherwise put portrait controls below
            // the display. Fit size before accepting any partial-screen placement.
            let size = NSSize(width: frame.width * scale, height: frame.height * scale)
            return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                          y: min(max(frame.maxY - size.height, screen.minY), screen.maxY - size.height),
                          width: size.width, height: size.height)
        }
        if !visible.isEmpty { return frame }
        return NSRect(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2,
                      width: frame.width, height: frame.height)
    }

    func show() {
        hasBeenShown = true
        // Use only opacity, so AppKit cannot zoom the panel out of a source window.
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = 1
        }
    }

    func fadeOut(completion: @escaping @MainActor () -> Void) {
        rememberPlacement()
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
