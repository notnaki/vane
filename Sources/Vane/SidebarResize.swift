import AppKit
import SwiftUI

private struct SidebarWindowWidth: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var sidebarWindowWidth: CGFloat {
        get { self[SidebarWindowWidth.self] }
        set { self[SidebarWindowWidth.self] = newValue }
    }
}

/// Observe the shared preference, but fit its presentation independently in each window.
@MainActor @propertyWrapper struct WindowSidebarWidth: DynamicProperty {
    @ObservedObject private var sidebar = SidebarWidth.shared
    @Environment(\.sidebarWindowWidth) private var available
    var wrappedValue: CGFloat { SidebarWidth.fitting(sidebar.width, in: available) }
}

/// Keep full-size header targets until they touch, then move secondary actions into a menu.
struct SidebarChromeLayout {
    let width: CGFloat
    // The address pill has its own compact presentation, independent of header overflow.
    var compact: Bool { width < Look.sidebarWidth }
    private var fullTargetsWidth: CGFloat { Look.inset * 2 + Look.trafficLights + Look.control * 4 }
    var usesOverflow: Bool { width < fullTargetsWidth }

    /// Close gaps continuously; never shrink the glyphs or their 24pt hit areas.
    /// Header gaps are twice the navigation gaps, matching the normal 12pt / 6pt rhythm.
    var navigationSpacing: CGFloat {
        let targets = usesOverflow ? fullTargetsWidth - Look.control : fullTargetsWidth
        let gapUnits: CGFloat = usesOverflow ? 6 : 8
        return min(6, max(0, (width - targets) / gapUnits))
    }
    var headerSpacing: CGFloat { navigationSpacing * 2 }
    var headerHeight: CGFloat { Look.topRow }
    var addressTop: CGFloat { Look.topInset + headerHeight + Look.inset }
}

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

    /// Measured from the installed Arc for macOS resize handlers: 164–500pt,
    /// a 228pt reset width, and collapse when the pointer passes 82pt.
    /// At the minimum, Back and Forward remain visible beside the navigation menu.
    nonisolated static let minimum: CGFloat = 164
    nonisolated static let maximum: CGFloat = 500
    nonisolated static let collapseThreshold: CGFloat = 82
    nonisolated static var standard: CGFloat { Look.sidebarWidth }

    nonisolated static func shouldCollapse(_ proposed: CGFloat) -> Bool {
        proposed.isFinite && proposed < collapseThreshold
    }

    /// The width the handle is allowed to hand back. Pure, so `selfcheck --pure` can prove
    /// the clamp without a window server. NaN — which is what a drag against a collapsing
    /// window can produce — resolves to the default rather than propagating.
    nonisolated static func clamp(_ w: CGFloat) -> CGFloat {
        guard w.isFinite else { return standard }
        return Swift.min(Swift.max(w, minimum), maximum)
    }

    /// Leave a usable page column when the browser is narrower than a saved sidebar.
    nonisolated static func fitting(_ proposed: CGFloat, in windowWidth: CGFloat) -> CGFloat {
        guard windowWidth.isFinite, windowWidth > 0 else { return clamp(proposed) }
        return min(clamp(proposed), max(minimum, windowWidth - 200))
    }

    static func inWindow(_ store: TabStore) -> CGFloat {
        fitting(shared.width, in: store.window?.contentView?.bounds.width ?? .infinity)
    }

    /// A width read back off disk. An unset key reads as 0, which clamps up to the minimum
    /// rather than to the default, so "never set" is checked before clamping.
    nonisolated static func load(_ defaults: UserDefaults = .vane) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return standard }
        return clamp(defaults.double(forKey: key))
    }

    /// Only on the way out of a drag, not on every frame of it: a drag is ~60 writes a
    /// second and none of the intermediate ones is worth remembering.
    func save(_ defaults: UserDefaults = .vane) {
        defaults.set(Double(width), forKey: SidebarWidth.key)
    }

    /// Pointer movement must follow the hand, even inside a window reveal transaction.
    /// At a clamp boundary repeated events should not publish identical widths.
    func setLiveWidth(_ proposed: CGFloat, available: CGFloat? = nil) {
        let next = available.map { Self.fitting(proposed, in: $0) } ?? Self.clamp(proposed)
        guard next != width else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { width = next }
    }

    func reset() {
        Motion.animate(Look.quick) { width = SidebarWidth.standard }
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

/// A small magnetic catch at the default width. A wider release band prevents jitter
/// while the pointer moves around the catch; widths outside it still follow the hand.
struct SidebarResizeDetent {
    private var engaged = false

    mutating func width(for proposed: CGFloat) -> CGFloat {
        let distance = abs(proposed - SidebarWidth.standard)
        engaged = distance <= (engaged ? 12 : 6)
        return engaged ? SidebarWidth.standard : SidebarWidth.clamp(proposed)
    }
}

/// Keep the fade on its own layer: live-width transactions deliberately disable SwiftUI
/// animation and must not cut short the resize affordance's entrance or exit.
private struct SidebarResizeHighlight: NSViewRepresentable {
    var active: Bool
    var dragging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    func makeNSView(context: Context) -> SidebarResizeHighlightView {
        SidebarResizeHighlightView()
    }

    func updateNSView(_ view: SidebarResizeHighlightView, context: Context) {
        view.setActive(active, animated: !reduceMotion && !batterySaver.isActive,
                       delay: dragging ? 0 : 0.25)
    }

    static func dismantleNSView(_ view: SidebarResizeHighlightView, coordinator: ()) {
        view.setActive(false, animated: false)
    }
}

final class SidebarResizeHighlightView: NSView {
    static let fadeKey = "resize-highlight-opacity"
    private var revealTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Arc's 4pt rule has elongated oval caps, not 2pt circular corners.
        (layer as? CAShapeLayer)?.fillColor = NSColor.white.withAlphaComponent(0.4).cgColor
        layer?.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { CAShapeLayer() }

    override func layout() {
        super.layout()
        guard let shape = layer as? CAShapeLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = CGPath(roundedRect: bounds, cornerWidth: bounds.width / 2,
                            cornerHeight: min(5, bounds.height / 2), transform: nil)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setActive(_ active: Bool, animated: Bool, delay: TimeInterval = 0) {
        guard active && animated && delay > 0 else {
            revealTask?.cancel()
            revealTask = nil
            applyActive(active, animated: animated)
            return
        }
        // Repeated layout updates must not restart an already pending hover dwell.
        guard layer?.opacity == 0, revealTask == nil else { return }
        let wait = UIAnimation.feedback.duration(delay)
        revealTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.revealTask = nil
            self.applyActive(true, animated: true)
        }
    }

    private func applyActive(_ active: Bool, animated: Bool) {
        guard let layer else { return }
        let target: Float = active ? 1 : 0
        let changed = layer.opacity != target
        let presented = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        guard animated else {
            layer.removeAnimation(forKey: Self.fadeKey)
            return
        }
        // Width updates must keep an in-flight fade's original clock.
        guard changed else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presented
        fade.toValue = target
        fade.duration = UIAnimation.feedback.duration(0.2)
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(fade, forKey: Self.fadeKey)
    }
}

/// The seam between the sidebar and the page card, as a thing you can grab.
/// Its rule appears only while hovering or dragging. The forgiving hit area stays wider
/// than the rule, centred on the seam like AppKit's split-view divider.
struct SidebarHandle: View {
    @EnvironmentObject private var store: TabStore
    @ObservedObject private var sidebar = SidebarWidth.shared
    @WindowSidebarWidth private var presentedWidth
    /// The gap between the pointer and the seam, taken on the drag's first frame and held
    /// for the rest of it, so the seam does not jump to the pointer when the grab was a few
    /// points off centre.
    @State private var start: CGFloat?
    @State private var hovered = false
    @State private var detent = SidebarResizeDetent()

    /// Wide enough to hit without aiming, narrow enough that the first sidebar row's close
    /// button is still clickable.
    static let hitTestWidth: CGFloat = 8

    var body: some View {
        Color.clear
            .frame(width: Self.hitTestWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                SidebarResizeHighlight(active: hovered || start != nil, dragging: start != nil)
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .onHover { inside in
                hovered = inside
            }
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
                        let grab = start ?? (presentedWidth - value.startLocation.x)
                        if start == nil {
                            detent = SidebarResizeDetent()
                            start = grab
                        }
                        sidebar.setLiveWidth(detent.width(for: value.location.x + grab),
                                             available: store.window?.contentView?.bounds.width)
                    }
                    .onEnded { value in
                        let proposed = value.location.x + (start ?? 0)
                        sidebar.setLiveWidth(detent.width(for: proposed),
                                             available: store.window?.contentView?.bounds.width)
                        start = nil
                        detent = SidebarResizeDetent()
                        sidebar.save()
                        if SidebarWidth.shouldCollapse(proposed) {
                            if store.sidebarShown { store.toggleSidebar() }
                            axAnnounce("Sidebar hidden.")
                        } else {
                            axAnnounce("Sidebar \(Int(sidebar.width)) points wide.")
                        }
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
            .accessibilityValue("\(Int(presentedWidth)) points")
            .accessibilityHint("Drag to resize the sidebar. Double-click to reset it.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Widen Sidebar") { step(20) }
            .accessibilityAction(named: "Narrow Sidebar") { step(-20) }
            .accessibilityAction(named: "Reset Sidebar Width") { sidebar.reset() }
    }

    private func step(_ delta: CGFloat) {
        let proposed = presentedWidth + delta
        let next = store.window?.contentView.map {
            SidebarWidth.fitting(proposed, in: $0.bounds.width)
        } ?? SidebarWidth.clamp(proposed)
        Motion.animate(Look.quick) {
            sidebar.width = next
        }
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
            ("Arc-sized narrow sidebars remain usable",
             clamp(164) == 164 && clamp(180) == 180 && clamp(200) == 200),
            ("reset uses the installed Arc default", standard == 228),
            ("a drag past Arc's collapse threshold hides the sidebar",
             shouldCollapse(81) && !shouldCollapse(82) && !shouldCollapse(164)),
            ("a nonsense drag does not hide the sidebar", !shouldCollapse(.nan)),
        ]

        let suite = "vane.check.sidebar.\(ProcessInfo.processInfo.processIdentifier)"
        if let scratch = UserDefaults(suiteName: suite) {
            defer { UserDefaults.dropScratchSuite(suite) }
            out.append(("an unset width reads back as the default", load(scratch) == standard))
            scratch.set(Double(999), forKey: key)
            out.append(("a stored width is clamped on the way back in", load(scratch) == maximum))
            scratch.set(Double(180), forKey: key)
            out.append(("a stored narrow width round-trips", load(scratch) == 180))
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
