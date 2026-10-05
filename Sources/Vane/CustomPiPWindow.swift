import AppKit
import Combine
import QuartzCore

/// Owns placement and input while WebKit continues decoding the original video.
@MainActor final class CustomPiPWindow: NSPanel {
    let videoView: NSView
    let controlsView: NSView
    private var screenChanges: AnyCancellable?
    private var hasBeenShown = false
    private let sourceFrame: NSRect
    private var entryDestination: NSRect?
    private var entryLink: CADisplayLink?
    private var entryStarted: CFTimeInterval = 0
    private var applyingEntryFrame = false
    private var entryMinimumSize: NSSize?
    private var returnPlacement: NSRect?
    private var returnMinimumSize: NSSize?
    private var returnOrigin: NSRect = .zero
    private var returnDestination: NSRect = .zero
    private var returnStarted: CFTimeInterval = 0
    private var returnLink: CADisplayLink?
    private var returnCompletion: (@MainActor () -> Void)?
    static let placementKey = "customPiPFrame"

    init(frame: NSRect, sourceFrame: NSRect? = nil, videoView: NSView, controlsView: NSView) {
        self.videoView = videoView
        self.controlsView = controlsView
        self.sourceFrame = sourceFrame ?? frame
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
                    self.setFrame(Self.recoverFrame(self.entryDestination ?? self.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
                }
            }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        finishReturn()
        stopEntry(keepDestination: true)
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
        UserDefaults.vane.set(NSStringFromRect(returnPlacement ?? entryDestination ?? frame), forKey: Self.placementKey)
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
        stopEntry(keepDestination: false)
        let destination = frame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, sourceFrame != destination,
              let display = NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) }) else {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                animator().alphaValue = 1
            }
            return
        }
        entryDestination = destination
        entryMinimumSize = contentMinSize
        contentMinSize = .zero
        applyEntryFrame(sourceFrame)
        controlsView.alphaValue = 0
        alphaValue = 0.01
        orderFrontRegardless()
        entryStarted = CACurrentMediaTime()
        // A fixed display keeps ticking if a path crosses a gap between monitors.
        let link = display.displayLink(target: self, selector: #selector(advanceEntry(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        entryLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceEntry(_ link: CADisplayLink) {
        guard entryLink === link, let destination = entryDestination else { return }
        let time = min(1, max(0, (CACurrentMediaTime() - entryStarted) / 0.28))
        let progress = CGFloat(1 - pow(1 - time, 3))
        // Apply one rectangle per display refresh. Position and size share this
        // progress, so the panel cannot move vertically and then horizontally.
        applyEntryFrame(NSRect(
            x: sourceFrame.minX + (destination.minX - sourceFrame.minX) * progress,
            y: sourceFrame.minY + (destination.minY - sourceFrame.minY) * progress,
            width: sourceFrame.width + (destination.width - sourceFrame.width) * progress,
            height: sourceFrame.height + (destination.height - sourceFrame.height) * progress))
        alphaValue = min(1, time / 0.22)
        controlsView.alphaValue = max(0, (time - 0.7) / 0.3)
        if time >= 1 {
            applyEntryFrame(destination)
            stopEntry(keepDestination: false)
        }
    }

    private func applyEntryFrame(_ rect: NSRect) {
        applyingEntryFrame = true
        defer { applyingEntryFrame = false }
        super.setFrame(rect, display: true)
    }

    private func stopEntry(keepDestination: Bool) {
        guard entryLink != nil || entryDestination != nil else { return }
        entryLink?.invalidate()
        entryLink = nil
        controlsView.alphaValue = 1
        if let minimum = entryMinimumSize,
           !keepDestination || (frame.width >= minimum.width && frame.height >= minimum.height) {
            entryMinimumSize = nil
            applyingEntryFrame = true
            contentMinSize = minimum
            applyingEntryFrame = false
        }
        if !keepDestination {
            entryDestination = nil
            alphaValue = 1
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        // A drag, resize, or display recovery owns placement as soon as it begins.
        if !applyingEntryFrame {
            finishReturn()
            stopEntry(keepDestination: false)
        }
        super.setFrame(frameRect, display: flag)
    }

    func fadeOut(completion: @escaping @MainActor () -> Void) {
        stopEntry(keepDestination: true)
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

    /// Freeze the live host while WebKit obtains the current inline destination.
    func prepareReturn() {
        returnPlacement = entryDestination ?? frame
        stopEntry(keepDestination: true)
        rememberPlacement()
        ignoresMouseEvents = true
    }

    func animateReturn(to destination: NSRect?, completion: @escaping @MainActor () -> Void) {
        guard let destination,
              [destination.minX, destination.minY, destination.width, destination.height].allSatisfy(\.isFinite),
              destination.width > 0, destination.height > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let display = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              NSScreen.screens.contains(where: { $0.frame.intersects(destination) }) else {
            fadeOut(completion: completion)
            return
        }
        returnMinimumSize = entryMinimumSize ?? contentMinSize
        entryMinimumSize = nil
        entryDestination = nil
        contentMinSize = .zero
        returnOrigin = frame
        returnDestination = destination
        returnCompletion = completion
        returnStarted = CACurrentMediaTime()
        alphaValue = 1
        let link = display.displayLink(target: self, selector: #selector(advanceReturn(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        returnLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func advanceReturn(_ link: CADisplayLink) {
        guard returnLink === link else { return }
        let time = min(1, max(0, (CACurrentMediaTime() - returnStarted) / 0.28))
        let progress = CGFloat(1 - pow(1 - time, 3))
        applyEntryFrame(NSRect(
            x: returnOrigin.minX + (returnDestination.minX - returnOrigin.minX) * progress,
            y: returnOrigin.minY + (returnDestination.minY - returnOrigin.minY) * progress,
            width: returnOrigin.width + (returnDestination.width - returnOrigin.width) * progress,
            height: returnOrigin.height + (returnDestination.height - returnOrigin.height) * progress))
        controlsView.alphaValue = max(0, 1 - time / 0.3)
        // Keep the video visible throughout the flight, then hand it back inline.
        if time >= 1 { finishReturn() }
    }

    private func finishReturn() {
        returnLink?.invalidate()
        returnLink = nil
        let completion = returnCompletion
        returnCompletion = nil
        completion?()
    }

    func resumeAfterReturn() {
        finishReturn()
        if let returnPlacement { applyEntryFrame(returnPlacement) }
        if let returnMinimumSize { contentMinSize = returnMinimumSize }
        returnPlacement = nil
        returnMinimumSize = nil
        stopEntry(keepDestination: false)
        ignoresMouseEvents = false
        controlsView.alphaValue = 1
        alphaValue = 1
    }

    override func sendEvent(_ event: NSEvent) {
        var settleTinyInteraction = false
        defer {
            // Let the control receive its click at the original coordinates first.
            // A continuing interaction then needs the full usable player size.
            if settleTinyInteraction, isVisible, let destination = entryDestination {
                applyEntryFrame(destination)
                stopEntry(keepDestination: false)
            }
        }
        if event.type == .keyDown { (controlsView as? PiPPlaybackControls)?.showForKeyboard() }
        if event.type == .leftMouseDown, event.window === self, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            var target = contentView.hitTest(point)
            var interactive = false
            var exitControl = false
            while let view = target {
                if let control = view as? NSControl {
                    interactive = true
                    exitControl = ["vane.pip.restore", "vane.pip.minimize", "vane.pip.close"]
                        .contains(control.identifier?.rawValue ?? "")
                    break
                }
                target = view.superview
            }
            stopEntry(keepDestination: interactive)
            if interactive && !exitControl {
                alphaValue = 1
                settleTinyInteraction = entryMinimumSize != nil
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
