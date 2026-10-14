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

/// Window-sized colour interpolation belongs on the compositor, alongside sidebar travel.
/// Repeated updates with the same destination must leave an in-flight blend alone.
struct NativeThemeWash: NSViewRepresentable {
    let wash: ThemeWash
    let reduced: Bool
    let gesture: SpaceGesture
    let origin: ThemeWash
    let destination: ThemeWash

    func makeNSView(context: Context) -> ThemeWashSurface { ThemeWashSurface() }
    func updateNSView(_ view: ThemeWashSurface, context: Context) {
        let from = origin, to = destination
        gesture.trackGround = { [weak view] fraction in
            view?.apply(from.mixed(towards: to, fraction: fraction), duration: 0)
        }
        if reduced { view.finishAnimations() }
        view.apply(wash, duration: !reduced && context.transaction.animation != nil
            && !context.transaction.disablesAnimations ? gesture.colourDuration : 0)
    }
}

@MainActor final class ThemeWashSurface: NSView {
    let base = CAGradientLayer()
    private let overlay = CAGradientLayer()
    private let tint = CALayer()
    private let grain = ThemeGrainSurface()
    private var target: ThemeWash?
    override var isFlipped: Bool { true }

    init() {
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
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        base.frame = bounds
        overlay.frame = bounds
        grain.frame = bounds
        CATransaction.commit()
    }

    func finishAnimations() {
        for layer in [base, overlay, tint, grain.layer].compactMap({ $0 }) { layer.removeAllAnimations() }
    }

    func apply(_ wash: ThemeWash, duration: TimeInterval) {
        guard target != wash else { return }
        let animate = target != nil && duration > 0
        target = wash
        let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        func set(_ layer: CALayer, _ key: String, _ value: Any) {
            let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: key)
            layer.removeAnimation(forKey: key)
            if animate {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = value
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                layer.add(animation, forKey: key)
            }
            CATransaction.commit()
        }
        set(base, "colors", [wash.colors[0].nsColor.cgColor, wash.baseEnd.nsColor.cgColor])
        set(overlay, "colors", [NSColor.clear.cgColor, wash.colors[2].nsColor.cgColor])
        set(overlay, "opacity", Float(wash.overlay))
        set(tint, "opacity", Float(wash.opacity))
        if let layer = grain.layer { set(layer, "opacity", Float(wash.grain * Look.grainMax)) }
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
