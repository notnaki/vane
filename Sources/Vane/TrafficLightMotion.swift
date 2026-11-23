import AppKit
import SwiftUI

/// One interpolation drives both the sidebar and the native titlebar buttons.
/// Separate animation branches can land a display pass apart during dismissal.
struct SidebarTrafficLightMotion: AnimatableModifier {
    let store: TabStore
    var slide: CGFloat
    var inset: CGFloat
    /// The lights' own inset, so they can settle on the row while the panel keeps its gap.
    var lightsInset: CGFloat
    var visibility: CGFloat
    let libraryOpen: Bool
    let peeking: Bool
    /// The toolbar's row holds the lights while the sidebar is away: they keep the
    /// sidebar's spot (following a peeking panel's inset) instead of leaving with it.
    var lightsStay = false

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(slide, inset), AnimatablePair(lightsInset, visibility)) }
        set {
            slide = newValue.first.first; inset = newValue.first.second
            lightsInset = newValue.second.first; visibility = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content
            .padding(inset)
            // Translate the resolved sidebar as one surface. Without this boundary,
            // each interpolated offset places its unchanged content again.
            .geometryGroup()
            .offset(x: slide)
            .opacity(visibility)
            .background {
                TrafficLightPlacement(store: store,
                    offset: libraryOpen ? .zero : CGPoint(x: (lightsStay ? 0 : slide) + lightsInset, y: lightsInset),
                    visibility: libraryOpen || lightsStay ? 1 : visibility, peeking: peeking)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct TrafficLightPlacement: NSViewRepresentable {
    let store: TabStore
    let offset: CGPoint
    let visibility: CGFloat
    let peeking: Bool

    func makeNSView(context: Context) -> TrafficLightPlacementView { TrafficLightPlacementView() }
    func updateNSView(_ view: TrafficLightPlacementView, context: Context) {
        view.store = store
        view.offset = offset
        view.visibility = visibility
        view.peeking = peeking
        view.place()
    }
}

private final class TrafficLightPlacementView: NSView {
    weak var store: TabStore?
    var offset = CGPoint.zero
    var visibility: CGFloat = 1
    var peeking = false

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); place() }

    func place() {
        // Parked profile graphs can still update. Only the mounted owner may
        // position this window's controls.
        guard let store, store.profileVisible, let window = window as? VaneWindow,
              store.window === window else { return }
        window.placeTrafficLights(offset: offset, visibility: visibility, peeking: peeking)
    }
}
