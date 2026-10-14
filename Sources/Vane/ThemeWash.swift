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
