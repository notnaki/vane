import AppKit
import SwiftUI

enum SpaceFooterPreferences {
    static let showIconsKey = "showSpaceIconsInFooter"
}

/// Density of the footer's Space targets, within the gap between Library and Create.
struct SpaceStripLayout: Equatable {
    let count: Int
    let itemWidth: CGFloat
    let dotSize: CGFloat
    let iconSize: CGFloat
    let showsButtonBackground: Bool
    let scrolls: Bool
    let showsAllIcons: Bool
    var buttonSize: CGFloat { min(itemWidth, Look.spaceDotHit) }

    init(count: Int, availableWidth: CGFloat, showIcons: Bool = true) {
        let count = max(0, count)
        self.count = count
        let width = max(0, availableWidth)
        showsButtonBackground = count <= 5
        // Keep ten slots once overflow begins, rather than shrinking indefinitely.
        let visibleCount = CGFloat(max(1, min(count, 10)))
        itemWidth = min(showsButtonBackground ? 34 : 28,
                        max(showsButtonBackground ? 16 : 13, width / visibleCount))
        let compression = CGFloat(min(5, max(0, count - 5))) / 5
        dotSize = 8 - compression * 4
        iconSize = showsButtonBackground ? 12 : 10
        // At the minimum sidebar width, preserve distinct targets even if that means
        // scrolling sooner. At the standard width, all ten Spaces fit without scrolling.
        scrolls = count > 10 || itemWidth * CGFloat(count) > width + 0.5
        // Overflow changes scrolling, never the user's chosen marker appearance.
        showsAllIcons = showIcons
    }
}

/// Measure the real footer viewport in window coordinates so both sidebar navigation
/// monitors leave its scroll gestures alone, including in the floating sidebar.
struct SpaceFooterScrollAnchor: NSViewRepresentable {
    let gesture: SpaceGesture
    let enabled: Bool

    final class Anchor: NSView {
        weak var gesture: SpaceGesture?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        if view.gesture !== gesture, view.gesture?.scrollingFooter === view {
            view.gesture?.scrollingFooter = nil
        }
        view.gesture = gesture
        if enabled { gesture.scrollingFooter = view }
        else if gesture.scrollingFooter === view { gesture.scrollingFooter = nil }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        if view.gesture?.scrollingFooter === view { view.gesture?.scrollingFooter = nil }
    }
}
