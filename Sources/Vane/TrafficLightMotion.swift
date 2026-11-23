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
    /// View › Show Toolbar: the lights stay when the sidebar goes, stepping into the card's
    /// toolbar strip (as far in and down as the strip's own top row), or following a
    /// peeking panel's inset while it is out. A fraction, so the lights travel with the
    /// strip as it slides in or out rather than jumping ahead of it.
    var stay: CGFloat = 0

    private var stayingOffset: CGPoint {
        CGPoint(x: lightsInset + (1 - visibility) * MainToolbar.lightsShift.width,
                y: lightsInset + (1 - visibility) * MainToolbar.lightsShift.height)
    }

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                   AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(slide, inset), AnimatablePair(AnimatablePair(lightsInset, visibility), stay)) }
        set {
            slide = newValue.first.first; inset = newValue.first.second
            lightsInset = newValue.second.first.first; visibility = newValue.second.first.second
            stay = newValue.second.second
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
                    offset: libraryOpen ? .zero : CGPoint(x: slide + lightsInset, y: lightsInset),
                    visibility: libraryOpen ? 1 : visibility,
                    stay: libraryOpen ? 0 : stay, stayingOffset: stayingOffset, peeking: peeking)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct TrafficLightPlacement: NSViewRepresentable {
    let store: TabStore
    let offset: CGPoint
    let visibility: CGFloat
    let stay: CGFloat
    let stayingOffset: CGPoint
    let peeking: Bool

    func makeNSView(context: Context) -> TrafficLightPlacementView { TrafficLightPlacementView() }
    func updateNSView(_ view: TrafficLightPlacementView, context: Context) {
        view.store = store
        view.offset = offset
        view.visibility = visibility
        view.stay = stay
        view.stayingOffset = stayingOffset
        view.peeking = peeking
        view.place()
    }
}

final class TrafficLightPlacementView: NSView {
    weak var store: TabStore?
    var offset = CGPoint.zero
    var visibility: CGFloat = 1
    var stay: CGFloat = 0
    var stayingOffset = CGPoint.zero
    var peeking = false
    private var fullScreenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
            .map { NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            } }
        place()
    }

    /// Where the lights go, blending the sidebar's own placement into the toolbar's by
    /// `stay`. Full screen keeps the sidebar's: macOS owns the lights there, in its own
    /// titlebar over the menu bar, and the strip leaves them no spacer.
    static func resolve(offset: CGPoint, visibility: CGFloat, stay: CGFloat, staying: CGPoint,
                        fullScreen: Bool) -> (offset: CGPoint, visibility: CGFloat) {
        let s = fullScreen ? 0 : stay
        return (CGPoint(x: offset.x + (staying.x - offset.x) * s, y: offset.y + (staying.y - offset.y) * s),
                visibility + (1 - visibility) * s)
    }

    func place() {
        // Parked profile graphs can still update. Only the mounted owner may
        // position this window's controls.
        guard let store, store.profileVisible, let window = window as? VaneWindow,
              store.window === window else { return }
        let place = Self.resolve(offset: offset, visibility: visibility, stay: stay, staying: stayingOffset,
                                 fullScreen: window.styleMask.contains(.fullScreen))
        window.placeTrafficLights(offset: place.offset, visibility: place.visibility, peeking: peeking)
    }
}
