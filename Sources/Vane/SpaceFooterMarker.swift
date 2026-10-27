import SwiftUI

/// Native windows animate marker ink independently of their profile hosting roots.
/// The fallback observes only this leaf, keeping menus and input handlers stable.
struct SpaceFooterEmphasis: View {
    let footer: SpaceFooterProgress
    @Environment(\.spaceFooterPresentation) private var presentation
    let icon: String
    let layout: SpaceStripLayout
    let hovered: Bool
    let selected: Bool
    let reducedMotion: Bool
    let spaceID: UUID
    let currentID: UUID?
    let targetID: UUID?
    let fallbackDrag: CGFloat
    let width: CGFloat
    let swiping: Bool
    let animation: Animation?
    var owner: TabStore? = nil

    @ViewBuilder var body: some View {
        if let presentation, let owner {
            NativeSpaceFooterMarker(presentation: presentation, owner: owner, id: spaceID,
                icon: icon, layout: layout, hovered: hovered, reduced: reducedMotion)
                .frame(width: layout.iconSize, height: layout.iconSize)
        } else {
            ObservedSpaceFooterEmphasis(marker: self, footer: footer)
        }
    }

    private func emphasis(drag: CGFloat?) -> Double {
        if reducedMotion { return selected ? 1 : 0 }
        guard let currentID else { return 0 }
        let drag = drag ?? fallbackDrag
        guard drag != 0, width > 0, let targetID else { return spaceID == currentID ? 1 : 0 }
        return SpaceDotBlend.weights(current: currentID, target: targetID,
            fraction: Double(min(1, abs(drag / width))))[spaceID] ?? 0
    }

    fileprivate func legacy(drag: CGFloat?) -> some View {
        let lit = emphasis(drag: drag)
        return SpaceFooterMarker(icon: icon, layout: layout, hovered: hovered,
                          emphasis: lit, selected: selected, reducedMotion: reducedMotion,
                          sizeEmphasis: swiping ? lit : nil)
            .transaction(value: lit) { transaction in
                if !swiping && !transaction.disablesAnimations { transaction.animation = animation }
            }
    }
}

private struct ObservedSpaceFooterEmphasis: View {
    let marker: SpaceFooterEmphasis
    @ObservedObject var footer: SpaceFooterProgress
    var body: some View { marker.legacy(drag: footer.drag) }
}

/// Finger progress blends brightness and size; uncovered selections keep a quick pulse.
struct SpaceFooterMarker: View {
    let icon: String
    let layout: SpaceStripLayout
    var hovered = false
    var emphasis: Double
    var selected = false
    var reducedMotion = false
    var sizeEmphasis: Double? = nil

    var body: some View {
        let lit = min(1, max(0, emphasis))
        let minimumScale = layout.showsAllIcons ? 0.8 : Look.tileAppearScale
        ZStack {
            Circle().fill(hovered && !layout.showsButtonBackground ? Look.inkSecondary : Look.dotFill)
                .frame(width: layout.dotSize, height: layout.dotSize)
                .opacity(layout.showsAllIcons ? 0 : 1 - lit)
                .scaleEffect(Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - lit))
            SpaceFooterIcon(icon: icon, size: layout.iconSize, minimumScale: minimumScale,
                            selected: selected, reducedMotion: reducedMotion, sizeEmphasis: sizeEmphasis)
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
    let sizeEmphasis: Double?
    @State private var enlarged: Bool

    init(icon: String, size: CGFloat, minimumScale: CGFloat, selected: Bool, reducedMotion: Bool,
         sizeEmphasis: Double?) {
        self.icon = icon
        self.size = size
        self.minimumScale = minimumScale
        self.selected = selected
        self.reducedMotion = reducedMotion
        self.sizeEmphasis = sizeEmphasis
        _enlarged = State(initialValue: selected)
    }

    var body: some View {
        Image(systemName: icon == "cloud" ? "cloud.fill" : icon)
            .font(.system(size: size))
            .scaleEffect(scale)
            // Replacing only the glyph cancels an in-flight presentation animation
            // even when its selected endpoint is already the current state value.
            .id(reducedMotion)
            .onChange(of: selected) { updateSize() }
            .onChange(of: reducedMotion) { if reducedMotion { updateSize() } }
    }

    private var scale: CGFloat {
        if reducedMotion { return selected ? 1 : minimumScale }
        if let sizeEmphasis {
            return minimumScale + (1 - minimumScale) * CGFloat(min(1, max(0, sizeEmphasis)))
        }
        return enlarged ? 1 : minimumScale
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
