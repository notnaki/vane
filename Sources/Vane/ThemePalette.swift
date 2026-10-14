import AppKit
import SwiftUI

/// The editor works in Display P3, as Arc does. Keep the components alongside the legacy
/// hex fallback: rounding/clipping a P3 green into sRGB changes both the wheel and its wash.
struct ThemeColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    init?(hex: String) {
        guard let hsb = Look.hsb(hex: hex) else { return nil }
        let rgb = Look.rgb(h: hsb.h, s: hsb.s, b: hsb.b)
        let c = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            .usingColorSpace(.displayP3)!
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }

    var nsColor: NSColor {
        NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
    }
    var color: Color { Color(nsColor: nsColor) }
    var hex: String {
        let c = nsColor.usingColorSpace(.extendedSRGB)!
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let hi = max(red, green, blue), lo = min(red, green, blue)
        let l = (hi + lo) / 2, d = hi - lo
        guard d > 1e-9 else { return (0, 0, l) }
        var h: Double
        if hi == red { h = (green - blue) / d }
        else if hi == green { h = 2 + (blue - red) / d }
        else { h = 4 + (red - green) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return (h, d / (1 - abs(2 * l - 1)), l)
    }

    static func hsl(h: Double, s: Double, l: Double) -> ThemeColor {
        let hue = h - floor(h), light = min(max(l, 0), 1)
        let c = (1 - abs(2 * light - 1)) * min(max(s, 0), 1)
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let rgb: (Double, Double, Double)
        switch Int(hue * 6) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        let m = light - c / 2
        return ThemeColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }

    func ground(strength: Double) -> ThemeColor {
        let v = min(max(strength, 0), 1)
        return ThemeColor(red: 0.5 + (red - 0.5) * v,
                          green: 0.5 + (green - 0.5) * v,
                          blue: 0.5 + (blue - 0.5) * v)
    }
}

/// A pad is calibrated when opened or when a preset is chosen. Moving a dot must never
/// recalibrate its own range: that makes the colour under a stationary pointer drift.
struct ThemeWheel: Sendable {
    let saturation: Double
    let lower: Double
    let upper: Double
    let initialHue: Double

    init(_ color: ThemeColor) {
        let c = color.hsl
        saturation = c.s; initialHue = c.h
        lower = max(0, c.l - 0.25); upper = min(1, c.l + 0.25)
    }

    func point(_ color: ThemeColor) -> CGPoint {
        let c = color.hsl
        let p = Spaces.wheelPoint(r: min(max((c.l - lower) / (upper - lower), 0), 1), a: c.h * 2 * .pi)
        return CGPoint(x: p.x, y: p.y)
    }

    func color(at point: CGPoint, hueAtCenter: Double? = nil) -> ThemeColor {
        let w = Spaces.wheel(x: point.x, y: point.y)
        let h = w.r < 1e-8 ? (hueAtCenter ?? initialHue) : w.a / (2 * .pi)
        return .hsl(h: h, s: saturation, l: lower + w.r * (upper - lower))
    }

    static func positions(dragged point: CGPoint, index: Int, count: Int) -> [CGPoint] {
        let w = Spaces.wheel(x: point.x, y: point.y)
        let offsets: [Double] = count >= 3 ? [0, 5.0 / 12, -5.0 / 12] : count == 2 ? [0, 0.5] : [0]
        let angle = w.a - offsets[index] * 2 * .pi
        return offsets.map {
            let p = Spaces.wheelPoint(r: w.r, a: angle + $0 * 2 * .pi)
            return CGPoint(x: p.x, y: p.y)
        }
    }

    static func dragPoint(start: CGPoint, location: CGPoint, model: CGPoint, field: CGRect) -> CGPoint {
        CGPoint(x: model.x + (location.x - start.x) / field.width,
                y: model.y + (location.y - start.y) / field.height)
    }

    static func palette(_ primary: ThemeColor, count: Int) -> [ThemeColor] {
        let c = primary.hsl
        let offsets: [Double] = count >= 3 ? [0, 5.0 / 12, -5.0 / 12] : count == 2 ? [0, 0.5] : [0]
        return offsets.map { $0 == 0 ? primary : .hsl(h: c.h + $0, s: c.s, l: c.l) }
    }
}

/// Measured independently of the colour pad: fixed 8pt end insets, a whole-track wave,
/// and a thumb whose size follows intensity instead of changing the travel distance.
enum ThemeIntensity {
    static let width: CGFloat = 224
    static func value(x: Double, width: Double) -> Double {
        min(max((x - 8) / max(width - 16, 1), 0), 1)
    }
    static func x(value: Double, width: Double) -> Double { 8 + min(max(value, 0), 1) * max(width - 16, 1) }
    static func thumb(_ value: Double) -> CGSize {
        let v = min(max(value, 0), 1)
        return CGSize(width: 12 + 16 * v, height: 48 + 16 * v)
    }
}
