import AppKit
import Combine
import SwiftUI

/// Process-local, default-off spike. Independent opt-outs allow attribution in
/// the same binary; no preferences or persisted browser state are changed.
enum RenderPerformanceExperiment {
    private static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["VANE_RENDER_EXPERIMENT"] == "1"
    static let isolatedSignals = enabled && environment["VANE_RENDER_SIGNALS"] != "0"
    static let cachedTopology = enabled && environment["VANE_RENDER_TOPOLOGY"] != "0"
    static let layerDecoration = enabled && environment["VANE_RENDER_LAYERS"] != "0"
    static let rowSelection = enabled && environment["VANE_RENDER_SELECTION"] != "0"
    static let hostReuse = enabled && environment["VANE_RENDER_HOST_REUSE"] != "0"
    static let panelMotion = enabled && environment["VANE_RENDER_PANEL_MOTION"] != "0"
    static let deferredPageResize = enabled && environment["VANE_RENDER_VIEWPORT"] != "0"
    static let hiddenSurfaces = enabled && environment["VANE_RENDER_HIDDEN"] != "0"
}

/// High-frequency page signals have two small consumers. Legacy mode relays the
/// original synchronous will-change notification to Tab. Experimental mode keeps
/// those notifications here; real metadata and manual Tab notifications are intact.
@MainActor final class TabRenderSignals: ObservableObject {
    @Published var progress = 0.0
    @Published var hoveredLink: StatusBar.Hover?
    private var relay: AnyCancellable?
    let isolated: Bool

    init(owner: Tab, isolated: Bool = RenderPerformanceExperiment.isolatedSignals) {
        self.isolated = isolated
        if !isolated {
            relay = objectWillChange.sink { [weak owner] _ in owner?.objectWillChange.send() }
        }
    }
}

/// Only decorations cross this boundary. Editors, text, menus and accessibility
/// stay in the original SwiftUI tree. No full-document rasterization is used.
struct CompositedRowHighlight: NSViewRepresentable {
    let opacity: Double
    let color: Color
    let radius: CGFloat
    let reduced: Bool

    func makeNSView(context: Context) -> RowHighlightLayerView { RowHighlightLayerView() }
    func updateNSView(_ view: RowHighlightLayerView, context: Context) {
        view.apply(opacity: Float(opacity), color: NSColor(color), radius: radius,
                   reduced: reduced || context.transaction.disablesAnimations)
    }
    static func dismantleNSView(_ view: RowHighlightLayerView, coordinator: ()) {
        view.highlight.removeAllAnimations()
    }
}

@MainActor final class RowHighlightLayerView: NSView {
    let highlight = CALayer()
    private var initialized = false
    private var sourceColor = NSColor.clear
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlight)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        CATransaction.commit()
    }

    private func resolveColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { highlight.backgroundColor = sourceColor.cgColor }
        highlight.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resolveColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveColor() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resolveColor() }

    func apply(opacity: Float, color: NSColor, radius: CGFloat, reduced: Bool) {
        let old = highlight.opacity
        let from = highlight.presentation()?.opacity ?? old
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceColor = color
        resolveColor()
        highlight.cornerRadius = radius
        highlight.opacity = opacity
        // Repeated parent updates must not restart a fade. Policy changes end it.
        if reduced || old != opacity { highlight.removeAnimation(forKey: "opacity") }
        if initialized, !reduced, old != opacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = opacity
            animation.duration = opacity == 0 ? 0.08 : 0.12
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            highlight.add(animation, forKey: "opacity")
        }
        initialized = true
        CATransaction.commit()
    }
}

struct CompositedLoadingTrack: NSViewRepresentable {
    let progress: Double
    let reduced: Bool
    func makeNSView(context: Context) -> LoadingTrackLayerView { LoadingTrackLayerView() }
    func updateNSView(_ view: LoadingTrackLayerView, context: Context) {
        view.apply(progress: progress, reduced: reduced || context.transaction.disablesAnimations,
                   track: NSColor(Look.loadingTrack))
    }
    static func dismantleNSView(_ view: LoadingTrackLayerView, coordinator: ()) {
        view.fill.removeAllAnimations()
    }
}

@MainActor final class LoadingTrackLayerView: NSView {
    let track = CALayer()
    let fill = CALayer()
    private var progress = 0.0
    private var initialized = false
    private var sourceColor = NSColor.clear
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
    private func resolveColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { track.backgroundColor = sourceColor.cgColor }
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resolveColor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveColor() }
    func apply(progress requested: Double, reduced: Bool, track color: NSColor) {
        let next = requested.isFinite ? min(1, max(0, requested)) : 0
        let previous = progress
        let from = fill.presentation()?.bounds ?? fill.bounds
        progress = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceColor = color
        resolveColor()
        fill.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        layout()
        if reduced || previous != next { fill.removeAnimation(forKey: "bounds") }
        if initialized, !reduced, next > previous, bounds.width > 0 {
            let animation = CABasicAnimation(keyPath: "bounds")
            animation.fromValue = from
            animation.toValue = fill.bounds
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            fill.add(animation, forKey: "bounds")
        }
        initialized = true
        CATransaction.commit()
    }
}
