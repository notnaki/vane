import SwiftUI

/// Window-local interaction colours come from the large primary dot, never the
/// complementary wash stops. Nil retains the standard look outside browser windows.
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

    var favoriteSelected: Color { primary == nil ? Look.ink(0.32) : tone(0.66).opacity(0.48) }
    var pillFill: Color { primary == nil ? Look.pillFill : tone(0.58).opacity(0.12) }
    var controlFill: Color { primary == nil ? Look.controlFill : tone(0.58).opacity(0.14) }
    var cardFill: Color { primary == nil ? Look.cardFill : tone(0.58).opacity(0.06) }
    var barFill: Color { primary == nil ? Look.barFill : bubble }
    var barSelected: Color { primary == nil ? Look.barSelected : bubbleHover }
    var barHovered: Color { primary == nil ? Look.barHovered : bubbleHover.opacity(0.6) }
    var accentSelected: Color { primary == nil ? Look.accentSelected : tone(0.58).opacity(0.16) }
    var paneFrame: Color { primary == nil ? Look.paneFrame : tone(0.62).opacity(0.5) }
    var dropHalf: Color { primary == nil ? Look.dropHalf : tone(0.58).opacity(0.22) }
    var accent: Color { primary?.color ?? .accentColor }
    var hovered: Color { primary == nil ? Look.hovered : tone(0.58).opacity(0.22) }
    var selected: Color { primary == nil ? Look.selected : tone(0.58).opacity(0.34) }
    var selectedEdge: Color { primary == nil ? Look.selectedEdge : tone(0.62).opacity(0.65) }
    // Floating hints keep a dark, opaque surface for predictable contrast over pages.
    var bubble: Color { tone(0.12, saturation: 0.65) }
    var bubbleHint: Color { tone(0.80, saturation: 0.35) }
    var bubbleHover: Color { tone(0.65, saturation: 0.6).opacity(0.24) }
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
