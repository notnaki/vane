import SwiftUI

/// Swipe progress blends brightness; selection owns a separate, quick size animation.
struct SpaceFooterMarker: View {
    let icon: String
    let layout: SpaceStripLayout
    var hovered = false
    var emphasis: Double
    var selected = false
    var reducedMotion = false

    var body: some View {
        let lit = min(1, max(0, emphasis))
        let minimumScale = layout.showsAllIcons ? 0.8 : Look.tileAppearScale
        ZStack {
            Circle().fill(hovered && !layout.showsButtonBackground ? Look.inkSecondary : Look.dotFill)
                .frame(width: layout.dotSize, height: layout.dotSize)
                .opacity(layout.showsAllIcons ? 0 : 1 - lit)
                .scaleEffect(Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - lit))
            SpaceFooterIcon(icon: icon, size: layout.iconSize, minimumScale: minimumScale,
                            selected: selected, reducedMotion: reducedMotion)
                .foregroundStyle(Look.inkPrimary)
                .opacity(layout.showsAllIcons ? (hovered ? 1 : 0.6 + 0.4 * lit) : lit)
        }
        .frame(width: layout.iconSize, height: layout.iconSize)
    }
}

private struct SpaceFooterIcon: View {
    let icon: String
    let size: CGFloat
    let minimumScale: CGFloat
    let selected: Bool
    let reducedMotion: Bool
    @State private var enlarged: Bool

    init(icon: String, size: CGFloat, minimumScale: CGFloat, selected: Bool, reducedMotion: Bool) {
        self.icon = icon
        self.size = size
        self.minimumScale = minimumScale
        self.selected = selected
        self.reducedMotion = reducedMotion
        _enlarged = State(initialValue: selected)
    }

    var body: some View {
        Image(systemName: icon == "cloud" ? "cloud.fill" : icon)
            .font(.system(size: size))
            .scaleEffect((reducedMotion ? selected : enlarged) ? 1 : minimumScale)
            .onChange(of: selected) { updateSize() }
            .onChange(of: reducedMotion) { if reducedMotion { updateSize() } }
    }

    private func updateSize() {
        // Page selection and native progress arrive in instant handoff transactions.
        // Only this local size change gets its own 150 ms animation; finger samples
        // never retarget it or stretch its duration to match the sidebar's travel.
        var transaction = Transaction(animation: reducedMotion ? nil : Look.quick)
        transaction.disablesAnimations = reducedMotion
        withTransaction(transaction) { enlarged = selected }
    }
}
