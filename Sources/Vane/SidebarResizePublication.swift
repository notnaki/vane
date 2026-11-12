import AppKit

/// A continuous drag publishes at native display boundaries; release is synchronous.
@MainActor final class SidebarResizePublication {
    typealias FrameDriver = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let isCurrent: @MainActor () -> Bool
    private let publish: @MainActor (CGFloat) -> Void
    private let afterFrame: @MainActor () -> Void
    private var usesNativeSizing: @MainActor () -> Bool = { false }
    private var stop: (@MainActor () -> Void)?
    private var pending: CGFloat?
    private var ending = false
    private var cancelled = false
    private var inFrame = false

    init(frameDriver: FrameDriver, isCurrent: @escaping @MainActor () -> Bool = { true },
         afterFrame: @escaping @MainActor () -> Void = {},
         publish: @escaping @MainActor (CGFloat) -> Void) {
        self.isCurrent = isCurrent
        self.publish = publish
        self.afterFrame = afterFrame
        stop = frameDriver { [weak self] in self?.advanceFrame() }
    }

    convenience init(buffer: LivePageResizeBuffer, frameDriver: FrameDriver,
                     afterFrame: @escaping @MainActor () -> Void = {},
                     publish: @escaping @MainActor (CGFloat) -> Void) {
        self.init(frameDriver: frameDriver,
            isCurrent: { [weak buffer] in buffer?.validateSidebarPublication() == true },
            afterFrame: afterFrame,
            publish: { [weak buffer] width in buffer?.publishSidebarWidth(width, publish) })
        buffer.trackSidebarPublicationLayout()
        usesNativeSizing = { [weak buffer] in buffer?.usesNativeSidebarSizing == true }
    }

    isolated deinit { stop?() }

    func enqueue(_ width: CGFloat) {
        guard !cancelled else { return }
        pending = width
        if usesNativeSizing() { finish() }
        else if ending { drain() }
    }

    /// The buffer's exact-layout phase must see the last covered publication.
    /// Subsequent covered callbacks during release no longer need a clock.
    func finish() {
        guard !cancelled else { return }
        ending = true
        stopFrames()
        drain()
    }

    func cancel() {
        cancelled = true
        pending = nil
        stopFrames()
    }

    private func stopFrames() {
        let stop = stop
        self.stop = nil
        stop?()
    }

    private func advanceFrame() {
        guard !inFrame, !ending, !cancelled else { return }
        inFrame = true
        defer { inFrame = false }
        guard drain(), !ending, !cancelled else { return }
        // Publishing can synchronously replace the root or retire this gesture.
        guard isCurrent() else { cancel(); return }
        afterFrame()
    }

    @discardableResult private func drain() -> Bool {
        guard !cancelled else { return false }
        guard isCurrent() else { cancel(); return false }
        guard let width = pending else { return false }
        pending = nil
        publish(width)
        return true
    }

    static func displayFrames(for window: NSWindow) -> FrameDriver {
        { [weak window] callback in
            guard let screen = window?.screen ?? NSScreen.main else { return {} }
            // The link retains this target, whose callback holds the publication
            // weakly. The cancellation closure owns the link, so there is no
            // link/target/owner cycle keeping an abandoned drag ticking.
            let target = SidebarResizeDisplayTarget(callback)
            let link = screen.displayLink(target: target, selector: #selector(SidebarResizeDisplayTarget.frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            return { link.invalidate() }
        }
    }
}

/// Reconcile the owned native tree once for a frame's changed presented width.
@MainActor final class SidebarResizeFrameLayout {
    private weak var window: NSWindow?
    private weak var root: NSView?
    private let isCurrent: @MainActor () -> Bool
    private var submittedWidth: CGFloat?

    init(window: NSWindow, root: NSView, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.window = window
        self.root = root
        self.isCurrent = isCurrent
    }

    func didPublishWidth(from previous: CGFloat, to next: CGFloat) {
        let available = root?.bounds.width ?? .infinity
        let before = SidebarWidth.fitting(previous, in: available)
        let after = SidebarWidth.fitting(next, in: available)
        submittedWidth = before == after ? nil : after
#if DEBUG
        if submittedWidth != nil { ResizeTimingDiagnostics.record("sidebar.width.submitted", height: after) }
#endif
    }

    func presentFrame() {
        let width = submittedWidth
        guard width != nil else { return }
        submittedWidth = nil
        guard let window, let root, window.contentView === root, isCurrent() else { return }
#if DEBUG
        ResizeTimingDiagnostics.record("sidebar.frame.layout.begin", width: window.frame.width, height: width)
#endif
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
#if DEBUG
        ResizeTimingDiagnostics.record("sidebar.frame.layout.end", width: window.frame.width, height: width)
#endif
        // Native layout can itself run callbacks that cancel or replace owners.
        guard window.contentView === root, isCurrent(), window.isVisible else { return }
#if DEBUG
        ResizeTimingDiagnostics.record("sidebar.frame.display.begin", width: window.frame.width, height: width)
#endif
        window.displayIfNeeded()
#if DEBUG
        ResizeTimingDiagnostics.record("sidebar.frame.display.end", width: window.frame.width, height: width)
#endif
    }
}

@MainActor private final class SidebarResizeDisplayTarget: NSObject {
    private let callback: @MainActor () -> Void
    init(_ callback: @escaping @MainActor () -> Void) { self.callback = callback }
    @objc func frame(_ link: CADisplayLink) { callback() }
}
