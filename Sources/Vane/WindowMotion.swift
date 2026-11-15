import AppKit
import QuartzCore

/// Window frame and alpha animation paced by the screen's display link.
///
/// `NSWindow.animator()` steps window geometry and alpha from an AppKit timer, which
/// presents at 60 Hz on a 120 Hz display. This applies one value per display refresh
/// instead, like the Picture in Picture entry. A newer animation of the same window
/// takes over from its current values; the superseded completion still runs, as
/// AppKit's does for an interrupted group.
@MainActor final class WindowMotion: NSObject {
    private static var running: [ObjectIdentifier: WindowMotion] = [:]

    private weak var window: NSWindow?
    private let key: ObjectIdentifier
    private var link: CADisplayLink?
    private let fromFrame: NSRect, toFrame: NSRect?
    private let fromAlpha: CGFloat, toAlpha: CGFloat?
    private let duration: TimeInterval
    private let timing: CAMediaTimingFunction
    private var started: CFTimeInterval = 0
    private var completion: (() -> Void)?

    private init(_ window: NSWindow, frame: NSRect?, alpha: CGFloat?, duration: TimeInterval,
                 timing: CAMediaTimingFunction, completion: (() -> Void)?) {
        self.window = window
        key = ObjectIdentifier(window)
        fromFrame = window.frame; toFrame = frame
        fromAlpha = window.alphaValue; toAlpha = alpha
        self.duration = duration
        self.timing = timing
        self.completion = completion
    }

    static func animate(_ window: NSWindow, frame: NSRect? = nil, alpha: CGFloat? = nil,
                        duration: TimeInterval,
                        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .default),
                        completion: (() -> Void)? = nil) {
        cancel(window)
        let motion = WindowMotion(window, frame: frame, alpha: alpha, duration: duration,
                                  timing: timing, completion: completion)
        guard duration > 0, let screen = window.screen ?? NSScreen.main else {
            motion.apply(1); motion.finish(); return
        }
        running[motion.key] = motion
        motion.started = CACurrentMediaTime()
        // A screen link keeps ticking while the window is hidden or between displays.
        let link = screen.displayLink(target: motion, selector: #selector(WindowMotion.tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        motion.link = link
        link.add(to: .main, forMode: .common)
    }

    /// Stops at the current values. Call before setting the frame or alpha directly.
    /// The completion runs, matching an interrupted AppKit animation.
    static func cancel(_ window: NSWindow) {
        running[ObjectIdentifier(window)]?.finish()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard window != nil else { finish(); return }
        let time = min(1, (CACurrentMediaTime() - started) / duration)
        apply(time)
        if time >= 1 { finish() }
    }

    private func apply(_ time: Double) {
        guard let window else { return }
        let p = CGFloat(Self.progress(timing, time))
        if let toAlpha { window.alphaValue = fromAlpha + (toAlpha - fromAlpha) * p }
        if let toFrame {
            window.setFrame(NSRect(x: fromFrame.minX + (toFrame.minX - fromFrame.minX) * p,
                                   y: fromFrame.minY + (toFrame.minY - fromFrame.minY) * p,
                                   width: fromFrame.width + (toFrame.width - fromFrame.width) * p,
                                   height: fromFrame.height + (toFrame.height - fromFrame.height) * p),
                            display: true)
        }
    }

    private func finish() {
        link?.invalidate(); link = nil
        if Self.running[key] === self { Self.running[key] = nil }
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    /// Solves the timing function's cubic Bézier for `time`, as Core Animation does.
    nonisolated static func progress(_ timing: CAMediaTimingFunction, _ time: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        var a: [Float] = [0, 0], b: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &a)
        timing.getControlPoint(at: 2, values: &b)
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        // x(s) is monotonic for CA timing functions, so bisection always converges.
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if bezier(mid, Double(a[0]), Double(b[0])) < time { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, Double(a[1]), Double(b[1]))
    }
}

extension CAAnimation {
    /// Core Animation may present an unpinned animation below the display's refresh rate.
    func pinToDisplayRate(of screen: NSScreen?) {
        let rate = Float((screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
        preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }
}
