import AppKit

/// A continuous drag publishes at native display boundaries; release is synchronous.
@MainActor final class SidebarResizePublication {
    typealias FrameDriver = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let isCurrent: @MainActor () -> Bool
    private let publish: @MainActor (CGFloat) -> Void
    private var usesNativeSizing: @MainActor () -> Bool = { false }
    private var stop: (@MainActor () -> Void)?
    private var pending: CGFloat?
    private var ending = false
    private var cancelled = false

    init(frameDriver: FrameDriver, isCurrent: @escaping @MainActor () -> Bool = { true },
         publish: @escaping @MainActor (CGFloat) -> Void) {
        self.isCurrent = isCurrent
        self.publish = publish
        stop = frameDriver { [weak self] in self?.drain() }
    }

    convenience init(buffer: LivePageResizeBuffer, frameDriver: FrameDriver,
                     publish: @escaping @MainActor (CGFloat) -> Void) {
        self.init(frameDriver: frameDriver,
            isCurrent: { [weak buffer] in buffer?.validateSidebarPublication() == true },
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

    private func drain() {
        guard !cancelled else { return }
        guard isCurrent() else { cancel(); return }
        guard let width = pending else { return }
        pending = nil
        publish(width)
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

@MainActor private final class SidebarResizeDisplayTarget: NSObject {
    private let callback: @MainActor () -> Void
    init(_ callback: @escaping @MainActor () -> Void) { self.callback = callback }
    @objc func frame(_ link: CADisplayLink) { callback() }
}
