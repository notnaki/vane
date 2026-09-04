import AppKit
import SwiftUI

/// The sidebar's width, and the grab handle on its right edge.
///
/// Arc's sidebar is dragged by its own trailing edge: the pointer turns into a column-resize
/// cursor a few points either side of the seam, the page card reflows live under the drag,
/// and a double-click puts it back to the default. The width is one app-wide setting that
/// outlives the window — not per window, because a sidebar that is 200 in one window and 380
/// in the next reads as a bug rather than as a preference.
///
/// ponytail: an `ObservableObject` singleton rather than a value on `TabStore`. Every window
/// shows the same width, so one publisher is one source of truth; putting it on the store
/// would mean writing it into every store on every drag and would still not survive a new
/// window opening mid-drag.
@MainActor final class SidebarWidth: ObservableObject {
    static let shared = SidebarWidth()

    /// Published, so the sidebar, the page card and the favourites grid all reflow on the
    /// same frame the drag moves.
    @Published var width: CGFloat = SidebarWidth.load()

    nonisolated fileprivate static let key = "sidebarWidth"

    /// Arc's range, floored at the width the top row actually needs. Arc drags down to
    /// ~200; Vane's own chrome — the 62pt the traffic lights reserve, the sidebar toggle and
    /// the three navigation glyphs at `Look.icon` — measures ~210 with its padding, and a
    /// frame narrower than its content does not clip it, it lets it slide under the page
    /// card. 220 is the first width where nothing in the top row is cut off.
    /// ponytail: a measured constant rather than a live measurement. Upgrade path if the top
    /// row ever changes: read its fitting size instead of trusting this number.
    nonisolated static let minimum: CGFloat = 220
    nonisolated static let maximum: CGFloat = 400
    /// What a double-click on the handle goes back to — the same number the design is drawn
    /// against, so "reset" means "what the screenshots show".
    nonisolated static var standard: CGFloat { 250 }

    /// The width the handle is allowed to hand back. Pure, so `selfcheck --pure` can prove
    /// the clamp without a window server. NaN — which is what a drag against a collapsing
    /// window can produce — resolves to the default rather than propagating.
    nonisolated static func clamp(_ w: CGFloat) -> CGFloat {
        guard w.isFinite else { return standard }
        return Swift.min(Swift.max(w, minimum), maximum)
    }

    /// A width read back off disk. An unset key reads as 0, which clamps up to the minimum
    /// rather than to the default, so "never set" is checked before clamping.
    nonisolated static func load(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return standard }
        return clamp(defaults.double(forKey: key))
    }

    /// Only on the way out of a drag, not on every frame of it: a drag is ~60 writes a
    /// second and none of the intermediate ones is worth remembering.
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(Double(width), forKey: SidebarWidth.key)
    }

    func reset() {
        width = SidebarWidth.standard
        save()
    }

    /// How many tiles across the favourites grid runs at this width. `TabStore` picks the
    /// column count from how many favourites there are; a narrow sidebar has to be able to
    /// veto that, or four tiles in 200pt are four 40pt slivers.
    /// Pure, and deliberately separate from `TabStore.favouriteColumns` so that function —
    /// which the existing checks pin — keeps meaning exactly what it did.
    static func favouriteColumns(_ count: Int, width: CGFloat,
                                 minTile: CGFloat = 56, gap: CGFloat = Look.inset,
                                 margin: CGFloat = Look.inset * 2) -> Int {
        let wanted = TabStore.favouriteColumns(count)
        guard wanted > 1 else { return Swift.max(wanted, 1) }
        let usable = width - margin
        // n tiles need n*minTile plus (n-1) gaps.
        let fits = Int((usable + gap) / (minTile + gap))
        return Swift.max(1, Swift.min(wanted, fits))
    }
}

/// The seam between the sidebar and the page card, as a thing you can grab.
///
/// It draws nothing: Arc's divider is the gap that is already there, and a visible rule would
/// be one more line in a window whose whole point is that it has none. It is `hitTestWidth`
/// wide, centred on the seam, which is the same forgiveness AppKit gives a split view.
struct SidebarHandle: View {
    @ObservedObject private var sidebar = SidebarWidth.shared
    /// The gap between the pointer and the seam, taken on the drag's first frame and held
    /// for the rest of it, so the seam does not jump to the pointer when the grab was a few
    /// points off centre.
    @State private var start: CGFloat?

    /// Wide enough to hit without aiming, narrow enough that the first sidebar row's close
    /// button is still clickable.
    static let hitTestWidth: CGFloat = 8

    var body: some View {
        Color.clear
            .frame(width: Self.hitTestWidth)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            // macOS's own column-resize pointer, so the affordance is the system's rather
            // than a cursor we drew.
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // The live pointer, not `translation`. The handle sits at an offset
                        // that the drag itself changes, so the view moves out from under the
                        // gesture and SwiftUI re-records its start — measured, the sidebar
                        // then ran about four times the distance the mouse did. `location`
                        // is in the window's own space and cannot drift, so the drag is
                        // "the seam is wherever the pointer is", plus the grab offset taken
                        // on the first frame.
                        let grab = start ?? (sidebar.width - value.location.x)
                        if start == nil { start = grab }
                        sidebar.width = SidebarWidth.clamp(value.location.x + grab)
                    }
                    .onEnded { _ in
                        start = nil
                        sidebar.save()
                        axAnnounce("Sidebar \(Int(sidebar.width)) points wide.")
                    }
            )
            // Arc's double-click on the divider. Simultaneous rather than stacked or
            // exclusive, and both spellings were tried: `.onTapGesture` on top of the drag
            // never fires, and `exclusively(before:)` fires the tap but then never lets the
            // drag start. Simultaneous works because the two can't both be true — the drag
            // needs a point of movement, and a double-click has none.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    sidebar.reset()
                    axAnnounce("Sidebar width reset.")
                }
            )
            // A pointer target, not an element: the accessible route is the two actions
            // below, which VoiceOver can reach without a drag.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidebar Width")
            .accessibilityValue("\(Int(sidebar.width)) points")
            .accessibilityHint("Drag to resize the sidebar. Double-click to reset it.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Widen Sidebar") { step(20) }
            .accessibilityAction(named: "Narrow Sidebar") { step(-20) }
            .accessibilityAction(named: "Reset Sidebar Width") { sidebar.reset() }
    }

    private func step(_ delta: CGFloat) {
        sidebar.width = SidebarWidth.clamp(sidebar.width + delta)
        sidebar.save()
        axAnnounce("Sidebar \(Int(sidebar.width)) points wide.")
    }
}

extension SidebarWidth {
    /// Offline proof of the clamp, the persistence and the column arithmetic. Nothing here
    /// touches the user's defaults — the suite is thrown away at the end.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = [
            ("the default width is the one the design is drawn against", standard == Look.sidebarWidth),
            ("a width inside the range is left alone", clamp(310) == 310),
            ("a narrow drag stops at the minimum", clamp(40) == minimum),
            ("a wide drag stops at the maximum", clamp(4000) == maximum),
            ("the ends of the range are themselves allowed",
             clamp(minimum) == minimum && clamp(maximum) == maximum),
            ("a nonsense width resolves to the default", clamp(.nan) == standard),
            ("the range is Arc's, floored at the width the top row needs",
             minimum == 220 && maximum == 400),
        ]

        let suite = "vane.check.sidebar.\(ProcessInfo.processInfo.processIdentifier)"
        if let scratch = UserDefaults(suiteName: suite) {
            defer { scratch.removePersistentDomain(forName: suite) }
            out.append(("an unset width reads back as the default", load(scratch) == standard))
            scratch.set(Double(999), forKey: key)
            out.append(("a stored width is clamped on the way back in", load(scratch) == maximum))
            scratch.set(Double(280), forKey: key)
            out.append(("a stored width round-trips", load(scratch) == 280))
        } else {
            out.append(("scratch defaults suite is available", false))
        }

        out += [
            ("one favourite is one full-width tile", favouriteColumns(1, width: 250) == 1),
            ("a wide sidebar keeps the count-based columns",
             favouriteColumns(7, width: 400) == TabStore.favouriteColumns(7)),
            ("a narrow sidebar drops a column rather than shrinking the tiles",
             favouriteColumns(7, width: 200) < TabStore.favouriteColumns(7)),
            ("…and never drops below one", favouriteColumns(7, width: 20) == 1),
            ("the column count never exceeds what the count itself asks for",
             (0...12).allSatisfy { favouriteColumns($0, width: 400) <= max(TabStore.favouriteColumns($0), 1) }),
        ]
        return out
    }
}
