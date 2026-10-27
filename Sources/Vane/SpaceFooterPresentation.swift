import AppKit
import Combine
import SwiftUI

private struct SpaceFooterPresentationKey: EnvironmentKey {
    static let defaultValue: SpaceFooterPresentation? = nil
}

extension EnvironmentValues {
    var spaceFooterPresentation: SpaceFooterPresentation? {
        get { self[SpaceFooterPresentationKey.self] }
        set { self[SpaceFooterPresentationKey.self] = newValue }
    }
}

/// CA resolves a zero beginTime at commit. Its start callback provides a remaining-
/// duration estimate for hover retargets without counting pre-commit layout time.
@MainActor private final class SpaceFooterAnimationClock: NSObject, @preconcurrency CAAnimationDelegate {
    private(set) var beganAt: CFTimeInterval?
    func animationDidStart(_ anim: CAAnimation) {
        if beganAt == nil { beganAt = CACurrentMediaTime() }
    }
}

/// The window owns marker ink across profile hosting roots. Controls, menus and
/// accessibility remain in SwiftUI; a parked root cannot reclaim these layers.
@MainActor final class SpaceFooterPresentation {
    final class Marker {
        let layer = CALayer()
        let symbol = CALayer()
        let dot = CAShapeLayer()
        weak var view: NativeSpaceFooterMarkerView?
        var layout = SpaceStripLayout(count: 0, availableWidth: 0)
        var hovered = false
        var reduced = false
        var artwork: String?
        init() { layer.addSublayer(dot); layer.addSublayer(symbol) }
    }

    private weak var owner: TabStore?
    private final class Anchor {
        weak var view: NativeSpaceFooterMarkerView?
        init(_ view: NativeSpaceFooterMarkerView) { self.view = view }
    }
    private var anchors: [ObjectIdentifier: [UUID: Anchor]] = [:]
    private var selection: AnyCancellable?
    private var selectedID: UUID?
    private var markers: [UUID: Marker] = [:]
    private var progress: (origin: UUID, target: UUID, fraction: Double)?
    private var progressTiming: CABasicAnimation?
    private var progressClock: SpaceFooterAnimationClock?
    private var progressStart = 0.0
    private var reduced = false

    func activate(_ store: TabStore) {
        guard owner !== store else { return }
        owner = store
        // A parked root may still remember a previous Battery Saver policy.
        // Refresh before selection so that stale policy cannot suppress its motion.
        reduced = Motion.reduced
        for marker in markers.values { marker.reduced = reduced }
        retain(Set(store.swipeStrip.map(\.id)), owner: store)
        selection = store.$currentSpaceID.sink { [weak self] id in self?.select(id) }
        // Unhiding a cached hosting root need not update its representables.
        // Transfer its registered ink before BrowserWindowHost exposes that root.
        for view in anchors[ObjectIdentifier(store), default: [:]].values.compactMap(\.view) {
            guard view.owner === store, let config = view.configuration else { continue }
            mount(view, owner: store, id: config.id, icon: config.icon, layout: config.layout,
                  hovered: config.hovered, scheme: config.scheme, reduced: Motion.reduced)
        }
    }

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        let previous = selectedID
        selectedID = id
        if progress == nil {
            for (key, marker) in markers { resize(marker, selected: key == id) }
        } else if reduced || Motion.reduced { applyProgress() }
        if progress == nil {
            if let previous, id != nil {
                let timing = CABasicAnimation(keyPath: "opacity")
                timing.duration = 0.15
                timing.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (key, marker) in markers {
                    animateProgress(marker, id: key, from: key == previous ? 1 : 0, timing: timing)
                }
            } else { applyProgress() }
        }
    }

    func mount(_ view: NativeSpaceFooterMarkerView, owner: TabStore, id: UUID,
               icon: String, layout: SpaceStripLayout, hovered: Bool,
               scheme: ColorScheme, reduced: Bool) {
        view.owner = owner
        view.configuration = .init(id: id, icon: icon, layout: layout, hovered: hovered, scheme: scheme, reduced: reduced)
        anchors[ObjectIdentifier(owner), default: [:]][id] = Anchor(view)
        guard self.owner === owner else { return }
        let fresh = markers[id] == nil
        let marker = markers[id] ?? Marker()
        markers[id] = marker
        let changedMode = marker.layout.showsAllIcons != layout.showsAllIcons
        let changedEmphasis = !fresh && (marker.hovered != hovered || changedMode)
        marker.layout = layout
        marker.hovered = hovered
        marker.reduced = reduced
        if self.reduced != reduced || Motion.reduced {
            self.reduced = reduced || Motion.reduced
            if self.reduced {
                progressTiming = nil
                progressClock = nil
                for (key, existing) in markers {
                    resize(existing, selected: selectedID == key, animated: false)
                    removeProgressAnimations(existing)
                    applyProgress(to: existing, id: key)
                }
            }
        }
        if marker.view !== view {
            marker.view = view
            view.marker = marker
            view.layer?.addSublayer(marker.layer)
        }
        let scale = view.window?.backingScaleFactor ?? 2
        let artwork = "\(icon):\(layout.iconSize):\(scheme):\(scale)"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if marker.artwork != artwork {
            let renderer = ImageRenderer(content: Image(systemName: icon == "cloud" ? "cloud.fill" : icon)
                .font(.system(size: layout.iconSize)).foregroundStyle(Look.inkPrimary)
                // SF Symbols can overhang their point-size square (notably cloud).
                // Match the unclipped SwiftUI glyph inside the larger button target.
                .frame(width: layout.iconSize * 2, height: layout.iconSize * 2)
                .environment(\.colorScheme, scheme))
            renderer.scale = scale
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            appearance?.performAsCurrentDrawingAppearance { marker.symbol.contents = renderer.cgImage }
            marker.symbol.contentsScale = scale
            marker.artwork = artwork
        }
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            marker.dot.fillColor = Look.nsInk(hovered && !layout.showsButtonBackground ? 0.6 : 0.2).cgColor
        }
        CATransaction.commit()
        place(marker, in: view.bounds)
        if progress == nil { resize(marker, selected: selectedID == id, animated: !fresh) }
        if fresh, let timing = progressTiming {
            animateProgress(marker, id: id, from: weight(id, fraction: progressStart), timing: timing)
        } else if changedEmphasis {
            // Hover and compact/icon mode change the endpoints. Do not leave a
            // previous landing animation covering the updated ink until it jumps.
            let timing = CABasicAnimation(keyPath: "opacity")
            timing.duration = 0.15
            if let progressTiming {
                let remaining = progressClock?.beganAt.map {
                    max(0, $0 + progressTiming.duration - CACurrentMediaTime())
                } ?? progressTiming.duration
                // Hover-on responds promptly; leaving hover or changing marker
                // mode continues from visible ink until the sidebar lands.
                timing.duration = !changedMode && hovered && layout.showsAllIcons ? min(0.15, remaining) : remaining
                timing.timingFunction = progressTiming.timingFunction
            }
            if timing.timingFunction == nil { timing.timingFunction = CAMediaTimingFunction(name: .easeOut) }
            animateProgress(marker, id: id, from: weight(id), timing: timing, preservingGeometry: !changedMode)
        } else { applyProgress(to: marker, id: id) }
    }

    func detach(_ view: NativeSpaceFooterMarkerView) {
        if let owner = view.owner, let id = view.configuration?.id {
            let key = ObjectIdentifier(owner)
            if anchors[key]?[id]?.view === view { anchors[key]?[id] = nil }
            if anchors[key]?.isEmpty == true { anchors[key] = nil }
        }
        guard let marker = view.marker, marker.view === view else { return }
        marker.view = nil
        marker.layer.removeFromSuperlayer()
    }

    func retain(_ ids: Set<UUID>, owner: TabStore) {
        guard self.owner === owner else { return }
        for id in Set(markers.keys).subtracting(ids) {
            markers.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for key in Array(anchors.keys) {
            anchors[key] = anchors[key]?.filter { ids.contains($0.key) && $0.value.view != nil }
            if anchors[key]?.isEmpty == true { anchors[key] = nil }
        }
    }

    func place(_ marker: Marker, in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.layer.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        marker.symbol.bounds = CGRect(x: 0, y: 0, width: marker.layout.iconSize * 2, height: marker.layout.iconSize * 2)
        marker.symbol.position = center
        marker.dot.bounds = CGRect(x: 0, y: 0, width: marker.layout.dotSize, height: marker.layout.dotSize)
        marker.dot.position = center
        marker.dot.path = CGPath(ellipseIn: marker.dot.bounds, transform: nil)
        CATransaction.commit()
    }

    private func resize(_ marker: Marker, selected: Bool, animated: Bool = true) {
        let minimum = marker.layout.showsAllIcons ? 0.8 : Look.tileAppearScale
        let target = selected ? 1.0 : minimum
        let immediate = !animated || reduced || marker.reduced || Motion.reduced
        if !immediate, abs(marker.symbol.transform.m11 - target) < 0.0001 { return }
        let from = (marker.symbol.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue
            ?? marker.symbol.transform.m11
        marker.symbol.removeAnimation(forKey: "space-selection")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.symbol.transform = CATransform3DMakeScale(target, target, 1)
        CATransaction.commit()
        if !immediate, abs(from - target) > 0.0001 {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = from
            animation.toValue = target
            animation.duration = 0.15
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            setFrameRate(animation, for: marker)
            marker.symbol.add(animation, forKey: "space-selection")
        }
    }

    func track(origin: UUID, target: UUID, fraction: Double) {
        progressTiming = nil
        progressClock = nil
        progress = (origin, target, min(1, max(0, fraction)))
        for marker in markers.values {
            removeProgressAnimations(marker)
            marker.symbol.removeAnimation(forKey: "space-selection")
        }
        applyProgress()
    }

    func animate(origin: UUID, target: UUID, from: Double, to: Double, timing: CABasicAnimation) {
        progress = (origin, target, to)
        progressStart = from
        let clock = timing.copy() as! CABasicAnimation
        // Like the sidebar position animation, start when CA commits the tree.
        // An absolute wall-clock start can expire during expensive host layout.
        clock.beginTime = 0
        progressTiming = reduced || Motion.reduced ? nil : clock
        progressClock = progressTiming == nil ? nil : SpaceFooterAnimationClock()
        for (id, marker) in markers {
            animateProgress(marker, id: id, from: weight(id, fraction: from), timing: clock)
        }
    }

    func finishProgress() {
        progress = nil
        progressTiming = nil
        progressClock = nil
        for marker in markers.values { removeProgressAnimations(marker) }
        applyProgress()
    }

    private func weight(_ id: UUID) -> Double {
        guard let progress else { return selectedID == id ? 1 : 0 }
        return SpaceDotBlend.weights(current: progress.origin, target: progress.target,
                                     fraction: progress.fraction)[id] ?? 0
    }

    private func weight(_ id: UUID, fraction: Double) -> Double {
        guard let progress else { return selectedID == id ? 1 : 0 }
        return SpaceDotBlend.weights(current: progress.origin, target: progress.target, fraction: fraction)[id] ?? 0
    }

    private func animateProgress(_ marker: Marker, id: UUID, from: Double, timing: CABasicAnimation,
                                 preservingGeometry: Bool = false) {
        let icons = marker.layout.showsAllIcons
        let symbolFrom = marker.symbol.presentation()?.opacity
            ?? Float(icons ? (marker.hovered ? 1 : 0.6 + 0.4 * from) : from)
        let dotFrom = marker.dot.presentation()?.opacity ?? Float(icons ? 0 : 1 - from)
        let scaleFrom = (marker.dot.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue
            ?? (Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - from))
        let minimum = marker.layout.showsAllIcons ? 0.8 : Double(Look.tileAppearScale)
        let symbolScaleFrom = (marker.symbol.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue
            ?? (minimum + (1 - minimum) * from)
        if preservingGeometry {
            marker.symbol.removeAnimation(forKey: "space-emphasis")
            marker.dot.removeAnimation(forKey: "space-emphasis")
        } else { removeProgressAnimations(marker) }
        if progress != nil { marker.symbol.removeAnimation(forKey: "space-selection") }
        applyProgress(to: marker, id: id)
        guard !reduced, !marker.reduced, !Motion.reduced, timing.duration > 0 else { return }
        func add(_ layer: CALayer, path: String, key: String, from: Double, to: Double) {
            guard abs(from - to) > 0.0001 else { return }
            let animation = timing.copy() as! CABasicAnimation
            animation.keyPath = path
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = 0
            if timing === progressTiming { animation.delegate = progressClock }
            setFrameRate(animation, for: marker)
            layer.add(animation, forKey: key)
        }
        add(marker.symbol, path: "opacity", key: "space-emphasis", from: Double(symbolFrom), to: Double(marker.symbol.opacity))
        add(marker.dot, path: "opacity", key: "space-emphasis", from: Double(dotFrom), to: Double(marker.dot.opacity))
        if !preservingGeometry {
            add(marker.dot, path: "transform.scale", key: "space-dot-scale", from: scaleFrom, to: marker.dot.transform.m11)
        }
        if progress != nil && !preservingGeometry {
            add(marker.symbol, path: "transform.scale", key: "space-progress-scale", from: symbolScaleFrom,
                to: marker.symbol.transform.m11)
        }
    }

    private func setFrameRate(_ animation: CAPropertyAnimation, for marker: Marker) {
        let rate = Float(marker.view?.window?.screen?.maximumFramesPerSecond ?? 60)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    private func applyProgress() {
        for (id, marker) in markers { applyProgress(to: marker, id: id) }
    }

    private func applyProgress(to marker: Marker, id: UUID) {
        let lit = reduced || marker.reduced || Motion.reduced ? (selectedID == id ? 1.0 : 0.0) : weight(id)
        let icons = marker.layout.showsAllIcons
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marker.symbol.opacity = Float(icons ? (marker.hovered ? 1 : 0.6 + 0.4 * lit) : lit)
        let minimum = icons ? 0.8 : Double(Look.tileAppearScale)
        let symbolScale = minimum + (1 - minimum) * lit
        marker.symbol.transform = CATransform3DMakeScale(symbolScale, symbolScale, 1)
        marker.dot.opacity = Float(icons ? 0 : 1 - lit)
        let scale = Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - lit)
        marker.dot.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        if marker.reduced || Motion.reduced { removeProgressAnimations(marker) }
    }

    private func removeProgressAnimations(_ marker: Marker) {
        marker.symbol.removeAnimation(forKey: "space-emphasis")
        marker.symbol.removeAnimation(forKey: "space-progress-scale")
        marker.dot.removeAnimation(forKey: "space-emphasis")
        marker.dot.removeAnimation(forKey: "space-dot-scale")
    }
}

struct NativeSpaceFooterMarker: NSViewRepresentable {
    let presentation: SpaceFooterPresentation
    let owner: TabStore
    let id: UUID
    let icon: String
    let layout: SpaceStripLayout
    let hovered: Bool
    let reduced: Bool
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NativeSpaceFooterMarkerView { NativeSpaceFooterMarkerView() }
    func updateNSView(_ view: NativeSpaceFooterMarkerView, context: Context) {
        view.presentation = presentation
        presentation.mount(view, owner: owner, id: id, icon: icon, layout: layout,
                           hovered: hovered, scheme: scheme, reduced: reduced)
    }
    static func dismantleNSView(_ view: NativeSpaceFooterMarkerView, coordinator: ()) {
        view.presentation?.detach(view)
    }
}

@MainActor final class NativeSpaceFooterMarkerView: NSView {
    struct Configuration {
        let id: UUID
        let icon: String
        let layout: SpaceStripLayout
        let hovered: Bool
        let scheme: ColorScheme
        let reduced: Bool
    }
    weak var owner: TabStore?
    var configuration: Configuration?
    weak var presentation: SpaceFooterPresentation?
    weak var marker: SpaceFooterPresentation.Marker?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsDefaultClipping: Bool { false }
    override func layout() {
        super.layout()
        if let marker, marker.view === self { presentation?.place(marker, in: bounds) }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let owner, let config = configuration else { return }
        presentation?.mount(self, owner: owner, id: config.id, icon: config.icon, layout: config.layout,
                            hovered: config.hovered, scheme: config.scheme, reduced: config.reduced)
    }
}
