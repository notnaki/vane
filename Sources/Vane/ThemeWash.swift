import SwiftUI

/// A stable two-colour base and optional third-colour overlay. Animating its components keeps the visible wash alive
/// through both gesture landing and an interrupted switch, without removing a gradient.
struct ThemeWash: VectorArithmetic {
    private var values: [Double]

    init(colors: [ThemeColor], strength: Double, opacity: Double, grain: Double, dark: Bool = false) {
        let colors = colors.isEmpty ? [ThemeColor(red: 0.5, green: 0.5, blue: 0.5)] : colors
        values = []
        // Preserve the same evenly spaced gradient for one, two, or three colours.
        for position in [0.0, 0.5, 1.0] {
            let index = position * Double(colors.count - 1)
            let low = Int(index), high = min(low + 1, colors.count - 1), f = index - Double(low)
            let a = colors[low].ground(strength: strength, dark: dark), b = colors[high].ground(strength: strength, dark: dark)
            values += [a.red + (b.red - a.red) * f, a.green + (b.green - a.green) * f,
                       a.blue + (b.blue - a.blue) * f]
        }
        values += [opacity, grain, colors.count == 3 ? 1 : 0]
    }

    /// Resolve gesture endpoints from their captured Spaces, even before SwiftUI has
    /// rendered the first input sample or the newly selected page.
    static func space(_ space: Space?, fallback: Profile, profiles: [Profile], systemDark: Bool) -> Self {
        // Incognito is an opaque black surface, independent of the desktop behind
        // the window and the neutral mixing used by ordinary Space themes.
        if fallback.id == Profile.incognito.id {
            return Self(colors: [ThemeColor(red: 0, green: 0, blue: 0)],
                        strength: 1, opacity: 1, grain: 0)
        }
        let dark = space?.appearance == "dark" ? true : space?.appearance == "light" ? false : systemDark
        var palette = space.map(Spaces.palette(of:)) ?? []
        if palette.isEmpty {
            let owner = space.flatMap { item in profiles.first { $0.id == item.profileID } } ?? fallback
            palette = [ThemeColor(hex: owner.colorHex)!]
        }
        let strength = space?.tint ?? Look.defaultTint
        return Self(colors: palette, strength: strength,
                    opacity: Look.groundOpacity(dark: dark, strength: strength),
                    grain: space?.grain ?? 0, dark: dark)
    }

    private init(values: [Double]) { self.values = values }
    static var zero: Self { Self(values: Array(repeating: 0, count: 12)) }
    static func + (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map(+)) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    var colors: [ThemeColor] {
        stride(from: 0, to: 9, by: 3).map { ThemeColor(red: values[$0], green: values[$0 + 1], blue: values[$0 + 2]) }
    }
    var opacity: Double { values[9] }
    var grain: Double { values[10] }
    var overlay: Double { values[11] }
    var baseEnd: ThemeColor {
        let a = colors[2], b = colors[1]
        return ThemeColor(red: a.red + (b.red - a.red) * overlay,
                          green: a.green + (b.green - a.green) * overlay,
                          blue: a.blue + (b.blue - a.blue) * overlay)
    }

    func mixed(towards target: Self, fraction: Double) -> Self {
        var delta = target - self
        delta.scale(by: min(max(fraction, 0), 1))
        return self + delta
    }
}

struct ThemeWashView: View, Animatable {
    nonisolated var wash: ThemeWash
    nonisolated var animatableData: ThemeWash {
        get { wash }
        set { wash = newValue }
    }

    var body: some View {
        ZStack {
            ZStack {
                LinearGradient(colors: [wash.colors[0].color, wash.baseEnd.color],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, wash.colors[2].color],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(wash.overlay)
            }
            .opacity(wash.opacity)
            Image(nsImage: Look.grain)
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .opacity(wash.grain * Look.grainMax)
        }
    }
}

/// Actual compositor values survive replacement even when the selected page is already
/// the previous destination. A new landing must not infer them from that model selection.
struct ThemeWashPresentation {
    fileprivate let values: [String: Any]
}

/// Window-sized colour interpolation belongs on the compositor, alongside sidebar travel.
/// Repeated updates with the same destination must leave an in-flight blend alone.
struct NativeThemeWash: NSViewRepresentable {
    let wash: ThemeWash
    let reduced: Bool
    let gesture: SpaceGesture
    let origin: ThemeWash
    let destination: ThemeWash
    let fallback: Profile
    let profiles: [Profile]
    let systemDark: Bool

    func makeNSView(context: Context) -> ThemeWashSurface { ThemeWashSurface() }
    func updateNSView(_ view: ThemeWashSurface, context: Context) {
        gesture.groundSurface = view
        let from = origin, to = destination
        let fallback = fallback, profiles = profiles, systemDark = systemDark
        let gesture = gesture
        gesture.trackGround = { [weak view, weak gesture] fraction in
            // A cached profile can arrive before SwiftUI updates this representable.
            // Its settled endpoints belong to the previous render; the new gesture
            // already carries the captured Spaces that must be painted on exposure.
            let origin = gesture?.outgoing.map {
                ThemeWash.space($0.space, fallback: fallback, profiles: profiles, systemDark: systemDark)
            } ?? from
            let destination = gesture?.neighbour.map {
                ThemeWash.space($0, fallback: fallback, profiles: profiles, systemDark: systemDark)
            } ?? to
            view?.apply(origin.mixed(towards: destination, fraction: fraction), duration: 0)
        }
        gesture.captureGround = { [weak view] in view?.capturePresentation() }
        gesture.animateGround = { [weak view] origin, destination, start, end, animation, presentedStart in
            let from = ThemeWash.space(origin, fallback: fallback, profiles: profiles, systemDark: systemDark)
            let to = ThemeWash.space(destination, fallback: fallback, profiles: profiles, systemDark: systemDark)
            let token = view?.animateNative(from: from.mixed(towards: to, fraction: start),
                                to: from.mixed(towards: to, fraction: end), animation: animation, presentedStart: presentedStart)
            return { [weak view] current in
                guard let view, let token else { return }
                let final = current.map { ThemeWash.space($0, fallback: fallback, profiles: profiles, systemDark: systemDark) }
                    ?? from.mixed(towards: to, fraction: end)
                view.finishNative(token: token, wash: final)
            }
        }
        if reduced { view.finishAnimations() }
        view.apply(wash, duration: !reduced && context.transaction.animation != nil
            && !context.transaction.disablesAnimations ? gesture.colourDuration : 0)
    }
}

/// Repaint the same wash over the page, with the window's gradient coordinates.
/// The original surface remains the sole owner of native Space transitions.
struct NativeThemeWashCopy: NSViewRepresentable {
    let gesture: SpaceGesture
    func makeNSView(context: Context) -> ThemeWashSurface {
        ThemeWashSurface(copyOrigin: CGPoint(x: -Look.floatingSidebarGap, y: -Look.floatingSidebarGap))
    }
    func updateNSView(_ view: ThemeWashSurface, context: Context) {
        gesture.groundCopies.add(view)
        gesture.groundSurface?.addCopy(view)
    }
}

@MainActor final class ThemeWashSurface: NSView {
    let base = CAGradientLayer()
    private let overlay = CAGradientLayer()
    private let tint = CALayer()
    private let grain = ThemeGrainSurface()
    private var target: ThemeWash?
    private var nativeToken: UUID?
    private let copies = NSHashTable<ThemeWashSurface>.weakObjects()
    private weak var copySource: ThemeWashSurface?
    private let copyOrigin: CGPoint
    var nativeAnimating: Bool { nativeToken != nil }
    override var isFlipped: Bool { true }

    init(copyOrigin: CGPoint = .zero) {
        self.copyOrigin = copyOrigin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(tint)
        tint.addSublayer(base)
        tint.addSublayer(overlay)
        base.startPoint = CGPoint(x: 0, y: 0.5)
        base.endPoint = CGPoint(x: 1, y: 0.5)
        overlay.startPoint = CGPoint(x: 0.5, y: 0)
        overlay.endPoint = CGPoint(x: 0.5, y: 1)
        grain.wantsLayer = true
        addSubview(grain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func addCopy(_ copy: ThemeWashSurface) {
        guard copy !== self, copy.copySource !== self else { return }
        copy.copySource?.copies.remove(copy)
        copy.copySource = self
        copies.add(copy)
        if let target { copy.apply(target, duration: 0) }
        // A newly mounted copy can join a transition already on the compositor.
        for (source, destination) in zip([base, overlay, tint, grain.layer],
                                         [copy.base, copy.overlay, copy.tint, copy.grain.layer]) {
            guard let source, let destination else { continue }
            for key in source.animationKeys() ?? [] {
                if let animation = source.animation(forKey: key) { destination.add(animation, forKey: key) }
            }
        }
        copy.needsLayout = true
    }

    override func layout() {
        super.layout()
        // Sample the resting panel's crop even while its retained host is parked
        // offscreen. A translation alone need not trigger an AppKit layout pass.
        let frame = copySource.map { CGRect(origin: copyOrigin, size: $0.bounds.size) } ?? bounds
        let canvas = CGRect(origin: .zero, size: frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = frame
        base.frame = canvas
        overlay.frame = canvas
        grain.frame = frame
        CATransaction.commit()
        for copy in copies.allObjects { copy.needsLayout = true }
    }

    func finishAnimations() {
        nativeToken = nil
        for layer in [base, overlay, tint, grain.layer].compactMap({ $0 }) { layer.removeAllAnimations() }
        for copy in copies.allObjects { copy.finishAnimations() }
    }

    func capturePresentation() -> ThemeWashPresentation {
        var values: [String: Any] = [:]
        for (layer, key, name) in [(base as CALayer, "colors", "base"), (overlay as CALayer, "colors", "overlay"),
                                   (overlay as CALayer, "opacity", "overlay"), (tint, "opacity", "tint")] {
            values["\(name).\(key)"] = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        }
        if let layer = grain.layer {
            values["grain.opacity"] = layer.presentation()?.opacity ?? layer.opacity
        }
        return ThemeWashPresentation(values: values)
    }

    @discardableResult func animateNative(from: ThemeWash, to: ThemeWash, animation: CABasicAnimation,
                                         presentedStart: ThemeWashPresentation? = nil) -> UUID {
        nativeToken = nil
        if presentedStart == nil { apply(from, duration: 0) }
        apply(to, duration: animation.duration, native: animation, start: from, presentedStart: presentedStart)
        let token = UUID()
        nativeToken = token
        return token
    }

    func finishNative(token: UUID, wash: ThemeWash) {
        guard nativeToken == token else { return }
        finishAnimations()
        apply(wash, duration: 0)
    }

    func apply(_ wash: ThemeWash, duration: TimeInterval, native: CABasicAnimation? = nil, start: ThemeWash? = nil, presentedStart: ThemeWashPresentation? = nil) {
        guard !nativeAnimating, target != wash || native != nil else { return }
        let animate = duration > 0 && (target != nil || native != nil)
        target = wash
        let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        func set(_ layer: CALayer, _ key: String, _ name: String, _ value: Any, _ initial: Any?) {
            let from = presentedStart?.values["\(name).\(key)"] ?? initial ?? layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: key)
            layer.removeAnimation(forKey: key)
            if animate {
                let animation = (native?.copy() as? CABasicAnimation) ?? CABasicAnimation(keyPath: key)
                animation.keyPath = key
                animation.fromValue = from
                animation.toValue = value
                animation.duration = duration
                if native == nil { animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                layer.add(animation, forKey: key)
            }
            CATransaction.commit()
        }
        set(base, "colors", "base", [wash.colors[0].nsColor.cgColor, wash.baseEnd.nsColor.cgColor],
            start.map { [$0.colors[0].nsColor.cgColor, $0.baseEnd.nsColor.cgColor] })
        set(overlay, "colors", "overlay", [NSColor.clear.cgColor, wash.colors[2].nsColor.cgColor],
            start.map { [NSColor.clear.cgColor, $0.colors[2].nsColor.cgColor] })
        set(overlay, "opacity", "overlay", Float(wash.overlay), start.map { Float($0.overlay) })
        set(tint, "opacity", "tint", Float(wash.opacity), start.map { Float($0.opacity) })
        if let layer = grain.layer { set(layer, "opacity", "grain", Float(wash.grain * Look.grainMax), start.map { Float($0.grain * Look.grainMax) }) }
        for copy in copies.allObjects {
            copy.apply(wash, duration: duration, native: native, start: start, presentedStart: presentedStart)
        }
    }
}

private final class ThemeGrainSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor(patternImage: Look.grain).setFill()
        dirtyRect.fill()
    }
}
