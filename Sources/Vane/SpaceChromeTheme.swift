import AppKit
import SwiftUI

/// Window-local surfaces and accents follow the large primary dot. Interaction
/// overlays stay neutral, so hovering lifts the surface without adding another hue.
struct SpaceChromeTheme: Equatable {
    var primary: ThemeColor?

    init(primary: ThemeColor? = nil) { self.primary = primary }
    init(space: Space?, fallback: String) {
        primary = space.flatMap { Spaces.palette(of: $0).first } ?? ThemeColor(hex: fallback)
    }

    private func tone(_ lightness: Double, saturation: Double = 1) -> Color {
        guard let primary else { return Color(white: lightness) }
        let hsl = primary.hsl
        return ThemeColor.hsl(h: hsl.h, s: hsl.s * saturation, l: lightness).color
    }

    var favoriteSelected: Color { Look.ink(0.32) }
    var pillFill: Color { Look.pillFill }
    var controlFill: Color { Look.controlFill }
    var cardFill: Color { Look.cardFill }
    var barFill: Color { primary == nil ? Look.barFill : bubble }
    var barSelected: Color { Look.barSelected }
    var barHovered: Color { Look.barHovered }
    var accentSelected: Color { primary == nil ? Look.accentSelected : tone(0.58).opacity(0.16) }
    var paneFrame: Color { primary == nil ? Look.paneFrame : tone(0.62).opacity(0.5) }
    var dropHalf: Color { primary == nil ? Look.dropHalf : tone(0.58).opacity(0.22) }
    /// Keep native tinted controls readable even when the primary dot is near black
    /// or white. Preserve its hue while bounding luminance for both pale and dark UI.
    var accent: Color {
        guard let primary else { return .accentColor }
        let luminance = Self.luminance(primary)
        guard luminance < 0.16 || luminance > 0.22 else { return primary.color }
        let target = luminance < 0.16 ? 0.16 : 0.22
        let hsl = primary.hsl
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if Self.luminance(.hsl(h: hsl.h, s: hsl.s, l: mid)) < target { low = mid }
            else { high = mid }
        }
        return ThemeColor.hsl(h: hsl.h, s: hsl.s, l: (low + high) / 2).color
    }

    private static func luminance(_ color: ThemeColor) -> Double {
        let rgb = color.nsColor.usingColorSpace(.sRGB)!
        func linear(_ value: Double) -> Double {
            let value = min(max(value, 0), 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
    var hovered: Color { Look.hovered }
    var selected: Color { Look.selected }
    var selectedEdge: Color { primary == nil ? Look.selectedEdge : tone(0.62).opacity(0.65) }
    // Floating hints keep a dark, opaque surface for predictable contrast over pages.
    var bubble: Color { tone(0.08, saturation: 0.65) }
    var bubbleHint: Color { tone(0.80, saturation: 0.35) }
    var bubbleHover: Color { Color.white.opacity(0.14) }
}

private struct SpaceChromeThemeKey: EnvironmentKey {
    static let defaultValue = SpaceChromeTheme()
}

extension EnvironmentValues {
    var spaceChromeTheme: SpaceChromeTheme {
        get { self[SpaceChromeThemeKey.self] }
        set { self[SpaceChromeThemeKey.self] = newValue }
    }
}

/// Native floating panels need the same window-local context as the main SwiftUI tree.
private struct SpaceChromeModifier: ViewModifier {
    @ObservedObject var store: TabStore
    @ObservedObject private var profiles = ProfileManager.shared

    func body(content: Content) -> some View {
        let theme = SpaceChromeTheme(space: store.currentSpace, fallback: store.profile.colorHex)
        content.environment(\.spaceChromeTheme, theme)
            .tint(theme.accent)
            .accentColor(theme.accent)
    }
}

extension View {
    func spaceChrome(_ store: TabStore) -> some View {
        modifier(SpaceChromeModifier(store: store))
    }
}
