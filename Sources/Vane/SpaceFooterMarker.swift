import SwiftUI

/// Interpolate the symbol's point size and opacity from the same value. Redrawing the
/// symbol at that size avoids magnifying a tiny inactive glyph during Space changes.
struct SpaceFooterMarker: View, Animatable {
    let icon: String
    let layout: SpaceStripLayout
    var hovered = false
    nonisolated var emphasis: Double

    nonisolated var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    var body: some View {
        let lit = min(1, max(0, emphasis))
        let minimumScale = layout.showsAllIcons ? 0.8 : Look.tileAppearScale
        let iconScale = minimumScale + (1 - minimumScale) * lit
        ZStack {
            Circle().fill(hovered && !layout.showsButtonBackground ? Look.inkSecondary : Look.dotFill)
                .frame(width: layout.dotSize, height: layout.dotSize)
                .opacity(layout.showsAllIcons ? 0 : 1 - lit)
                .scaleEffect(Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - lit))
            Image(systemName: icon == "cloud" ? "cloud.fill" : icon)
                .font(.system(size: layout.iconSize * iconScale))
                .foregroundStyle(Look.inkPrimary)
                .opacity(layout.showsAllIcons ? (hovered ? 1 : 0.6 + 0.4 * lit) : lit)
        }
        .frame(width: layout.iconSize, height: layout.iconSize)
    }
}
