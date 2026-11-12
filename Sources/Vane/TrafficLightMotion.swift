import AppKit
import SwiftUI

/// One interpolation drives both the sidebar and the native titlebar buttons.
/// Separate animation branches can land a display pass apart during dismissal.
struct SidebarTrafficLightMotion: AnimatableModifier {
    let store: TabStore
    var slide: CGFloat
    var inset: CGFloat
    var visibility: CGFloat
    let libraryOpen: Bool
    let peeking: Bool

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(slide, inset), visibility) }
        set { slide = newValue.first.first; inset = newValue.first.second; visibility = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .offset(x: slide)
            .opacity(visibility)
            .background {
                TrafficLightPlacement(store: store,
                    offset: libraryOpen ? .zero : CGPoint(x: slide + inset, y: inset),
                    visibility: libraryOpen ? 1 : visibility, peeking: peeking)
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
