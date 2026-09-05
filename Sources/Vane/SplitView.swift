import AppKit
import SwiftUI

// MARK: - The model

/// A split view: two to four tabs shown side by side inside one page card, and *one* row in
/// the sidebar. Arc's split is not a window arrangement — it is a tab that happens to hold
/// several pages, which is why it moves, closes and comes back as one thing.
///
/// Pure and id-only: no `Tab`, no view, no store, so `selfcheck --pure` can prove every rule
/// below on a headless box. Everything that needs a live tab is in the `TabStore` extension
/// further down.
struct Split: Equatable, Sendable {
    /// Arc's ceiling, and a real one: a fifth pane on a 1280pt card is 250pt of page, which
    /// is under most sites' own minimum width.
    static let maxPanes = 4
    /// The smallest share of the card a pane can be dragged down to.
    static let minimumPane = 0.15

    /// The panes, in the order they are drawn. Never fewer than two — one pane is a plain
    /// tab, and `removing` says so by handing back nil.
    private(set) var tabs: [UUID]
    /// Top-and-bottom rather than side-by-side. Horizontal is Arc's default; a drop on the
    /// card's top or bottom edge is what asks for the other one.
    var vertical: Bool
    /// The pane ⌘L, the address pill and the keyboard act on, as an index. Kept here rather
    /// than read off `TabStore.current` alone so that leaving the split for another tab and
    /// coming back lands on the pane the user was last in.
    private(set) var active: Int
    /// Each pane's share of the card, in order, summing to 1.
    private(set) var weights: [Double]

    /// Nil for anything that is not a split: fewer than two distinct panes. Duplicates are
    /// dropped rather than rejected — the same tab cannot be two panes of one split.
    init?(tabs: [UUID], vertical: Bool = false) {
        var unique: [UUID] = []
        for id in tabs where !unique.contains(id) { unique.append(id) }
        guard unique.count >= 2 else { return nil }
        self.tabs = Array(unique.prefix(Split.maxPanes))
        self.vertical = vertical
        self.active = 0
        self.weights = Split.equal(self.tabs.count)
    }

    static func equal(_ n: Int) -> [Double] {
        guard n > 0 else { return [] }
        return Array(repeating: 1 / Double(n), count: n)
    }

    /// Weights that always sum to 1, whatever arithmetic produced them.
    static func normalised(_ w: [Double]) -> [Double] {
        let sum = w.reduce(0, +)
        guard sum > 0 else { return equal(w.count) }
        return w.map { $0 / sum }
    }

    var activeTab: UUID { tabs[min(max(active, 0), tabs.count - 1)] }
    var isFull: Bool { tabs.count >= Split.maxPanes }
    func contains(_ id: UUID) -> Bool { tabs.contains(id) }

    /// A pane joins beside `anchor` — the pane the user asked from — and takes focus, the
    /// way Arc slides the new page in next to the one it came from. A full split, or a tab
    /// that is already a pane, changes nothing.
    func adding(_ id: UUID, after anchor: UUID? = nil) -> Split {
        guard !isFull, !tabs.contains(id) else { return self }
        var out = self
        let at = anchor.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        out.tabs.insert(id, at: at)
        out.active = at
        out.weights = Split.equal(out.tabs.count)
        return out
    }

    /// A pane joins at one end, which is what a drop on an edge of the card asks for.
    func adding(_ id: UUID, at end: Zone) -> Split {
        guard !isFull, !tabs.contains(id) else { return self }
        var out = self
        let at = end.leads ? 0 : tabs.count
        out.tabs.insert(id, at: at)
        out.active = at
        out.weights = Split.equal(out.tabs.count)
        out.vertical = end.isVertical
        return out
    }

    /// One pane leaves. Nil when a single pane would be left: a split of one is a plain tab,
    /// and the caller is the one that has to make it one again.
    func removing(_ id: UUID) -> Split? {
        guard let i = tabs.firstIndex(of: id) else { return self }
        guard tabs.count > 2 else { return nil }
        var out = self
        out.tabs.remove(at: i)
        out.weights = Split.normalised(weights.enumerated().filter { $0.offset != i }.map(\.element))
        out.active = min(active > i ? active - 1 : active, out.tabs.count - 1)
        return out
    }

    func focusing(_ id: UUID) -> Split {
        guard let i = tabs.firstIndex(of: id) else { return self }
        var out = self
        out.active = i
        return out
    }

    /// ⌃⇧N: the next pane along, wrapping round the end.
    func next() -> Split {
        var out = self
        out.active = (active + 1) % tabs.count
        return out
    }

    /// "Swap": the panes change places. With more than two it is a flip, which is the only
    /// reading of "swap" that needs no second argument — and it is what Arc's own Swap does
    /// to a three-pane split.
    func swapped() -> Split {
        var out = self
        out.tabs.reverse()
        out.weights.reverse()
        out.active = tabs.count - 1 - active
        return out
    }

    /// Dragging the divider between panes `i` and `i + 1`. `base` is the weights the drag
    /// started from, so a live drag stays absolute rather than accumulating its own rounding,
    /// and neither neighbour can be pushed under `minimumPane`.
    static func resized(_ base: [Double], divider i: Int, by delta: Double) -> [Double] {
        guard base.indices.contains(i), base.indices.contains(i + 1) else { return base }
        let d = min(max(delta, minimumPane - base[i]), base[i + 1] - minimumPane)
        var out = base
        out[i] += d
        out[i + 1] -= d
        return out
    }

    func resized(divider i: Int, from base: [Double], by delta: Double) -> Split {
        var out = self
        out.weights = Split.resized(base, divider: i, by: delta)
        return out
    }

    // MARK: Drop zones

    /// Where a tab dropped on the page card lands. `centre` is deliberately not a drop: Arc
    /// has no gesture for "replace this page", and a whole-card target would swallow every
    /// miss of the sidebar.
    enum Zone: String, Sendable, CaseIterable {
        case leading, trailing, top, bottom, centre
        /// Top and bottom make a vertical split; the sides make the horizontal one.
        var isVertical: Bool { self == .top || self == .bottom }
        /// Whether the new pane goes in front of the ones already there.
        var leads: Bool { self == .leading || self == .top }
    }

    /// Which edge band of a card of `size` the point is in, in SwiftUI's coordinates (y down
    /// from the top). The nearest edge wins, so a corner resolves to something rather than to
    /// two things at once.
    static func zone(at p: CGPoint, in size: CGSize, band: CGFloat = 0.25) -> Zone {
        guard size.width > 0, size.height > 0 else { return .centre }
        let x = p.x / size.width, y = p.y / size.height
        let edges: [(Zone, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let near = edges.min(by: { $0.1 < $1.1 }), near.1 <= band, near.1 >= 0 else {
            return .centre
        }
        return near.0
    }

    // MARK: Session

    /// How a split is written into the session. By url, not by id: a tab's id is made fresh
    /// on every launch, and the session file already keys everything it knows about a tab by
    /// its url. Same ceiling as `Session.parked` — the same page open in two windows' panes
    /// comes back once per window, which nobody has ever noticed.
    struct Saved: Codable, Equatable, Sendable {
        var urls: [String]
        var vertical: Bool
        var active: Int
    }
}

// MARK: - The store's splits

/// The window's splits. Kept as ids so a split survives a tab moving section, being renamed
/// or being suspended; `TabStore.splits` is the storage and this is everything done to it.
///
/// ponytail: a flat array searched linearly. A window with more than a handful of splits is
/// not a thing, and a dictionary keyed by tab id would need two entries per pane kept honest.
@MainActor extension TabStore {

    func split(containing id: Tab.ID) -> Split? { splits.first { $0.contains(id) } }

    /// The split the user is in right now, if any: the one holding the selected tab.
    var activeSplit: Split? { current.flatMap { split(containing: $0) } }

    /// Which of a split's panes owns its sidebar row — the one that comes first in the strip,
    /// so the row stays where the user's eye already is when panes are added or swapped.
    func leadPane(_ split: Split) -> Tab.ID? {
        tabs.first { split.contains($0.id) }?.id
    }

    /// Splits are disjoint, so any pane that was in the old one names it. `key` is a tab the
    /// caller knows is in both — the anchor a pane joined beside, or the pane it started from
    /// — because a grown split's own active pane is by definition not in the old one.
    private func replace(_ split: Split, keyedOn key: Tab.ID) {
        guard let i = splits.firstIndex(where: { $0.contains(key) }) else { return }
        splits[i] = split
    }

    /// ⌃⇧= "Add Split View": a new pane beside the current tab, with the command bar up in
    /// `.address` so the next thing typed loads *into the new pane*.
    func addSplit() {
        guard let anchor = current else { return }
        guard split(containing: anchor)?.isFull != true else {
            axAnnounce("Split view already has \(Split.maxPanes) panes.")
            return
        }
        let fresh = newBlankTab()          // appends, and takes focus
        addPane(fresh.id, beside: anchor)
        palette = .address
    }

    /// The context menu's "Add Split View" / "Add to Split", ⌥-click on a row, and a drop on
    /// the page card: `id` becomes a pane beside the tab the user is looking at.
    func addPane(_ id: Tab.ID, beside anchor: Tab.ID? = nil, at end: Split.Zone? = nil) {
        let anchor = anchor ?? current
        guard let anchor, anchor != id else { return }
        if let existing = split(containing: anchor) {
            // Already a pane of this very split: the ask is only to look at it.
            guard !existing.contains(id) else { focusPane(id); return }
            guard !existing.isFull else {
                axAnnounce("Split view already has \(Split.maxPanes) panes.")
                return
            }
            // A pane that is already in *another* split leaves that one first.
            if split(containing: id) != nil { dropPane(id) }
            let grown = end.map { existing.adding(id, at: $0) } ?? existing.adding(id, after: anchor)
            replace(grown, keyedOn: anchor)
            current = grown.activeTab
        } else {
            if split(containing: id) != nil { dropPane(id) }
            guard var made = Split(tabs: end?.leads == true ? [id, anchor] : [anchor, id]) else { return }
            made.vertical = end?.isVertical ?? false
            made = made.focusing(id)
            splits.append(made)
            current = id
        }
        axAnnounce("Added to split view.")
    }

    /// A tab has gone — closed, or moved into another split. Its pane goes with it, and a
    /// split left holding one tab stops being a split at all. Returns the pane to focus when
    /// the tab that left was the one being shown, so `close` can prefer it to its own answer.
    @discardableResult
    func dropPane(_ id: Tab.ID) -> Tab.ID? {
        guard let i = splits.firstIndex(where: { $0.contains(id) }) else { return nil }
        if let shrunk = splits[i].removing(id) {
            splits[i] = shrunk
            return shrunk.activeTab
        }
        let survivor = splits[i].tabs.first { $0 != id }
        splits.remove(at: i)
        return survivor
    }

    /// ⌃⇧− "Remove Split": the pane you are in closes, exactly as ⌘W would close it.
    func removeSplitPane() {
        guard let split = activeSplit, let id = current, split.contains(id) else { return }
        archive(id)
    }

    /// ⌃⇧N: focus moves to the next pane, wrapping.
    func focusNextPane() {
        guard let split = activeSplit, let here = current else { return }
        let moved = split.focusing(here).next()
        replace(moved, keyedOn: here)
        current = moved.activeTab
        axAnnounce("Pane \(moved.active + 1) of \(moved.tabs.count).")
    }

    /// Clicking a pane, or the sidebar row coming back to the split it was last in. Cheap on
    /// purpose: the click monitor calls it on every mouse-down inside a pane, and setting
    /// `current` wakes a tab and re-syncs the extension host.
    func focusPane(_ id: Tab.ID) {
        if let split = split(containing: id), split.activeTab != id {
            replace(split.focusing(id), keyedOn: id)
        }
        guard current != id else { return }
        current = id
    }

    /// "Separate All Tabs": the split dissolves and its panes go back to being ordinary rows.
    /// Nothing closes — this is the opposite of Remove Split, not a tidier spelling of it.
    func separateSplit(_ split: Split) {
        splits.removeAll { $0.tabs == split.tabs }
        axAnnounce("Separated \(split.tabs.count) tabs.")
    }

    /// "Swap": the panes change places. Named rather than assumed, so the sidebar row's own
    /// menu can swap a split the keyboard is not currently in.
    func swapPanes(_ split: Split? = nil) {
        guard let split = split ?? activeSplit else { return }
        replace(split.swapped(), keyedOn: split.activeTab)
    }

    func resizeSplit(divider: Int, from base: [Double], by delta: Double) {
        guard let split = activeSplit, let here = current else { return }
        replace(split.resized(divider: divider, from: base, by: delta), keyedOn: here)
    }

    // MARK: Session

    /// The window's splits as the session file holds them. A pane with no url of its own —
    /// a blank tab that was never navigated — takes the whole split out: half a split is
    /// worse than none.
    var savedSplits: [Split.Saved] {
        splits.compactMap { split in
            let urls = split.tabs.compactMap { id in
                tabs.first { $0.id == id }?.currentURL?.absoluteString
            }
            guard urls.count == split.tabs.count else { return nil }
            return Split.Saved(urls: urls, vertical: split.vertical, active: split.active)
        }
    }

    /// Put the session's splits back, once the window's tabs exist. Panes are matched by url
    /// and each tab is used once, so two panes on the same page do not collapse into one.
    func applySplits(_ saved: [Split.Saved]) {
        var taken: Set<Tab.ID> = []
        for entry in saved {
            let ids = entry.urls.compactMap { url in
                tabs.first { $0.currentURL?.absoluteString == url && !taken.contains($0.id) }?.id
            }
            ids.forEach { taken.insert($0) }
            guard var split = Split(tabs: ids, vertical: entry.vertical) else { continue }
            if split.tabs.indices.contains(entry.active) {
                split = split.focusing(split.tabs[entry.active])
            }
            splits.append(split)
        }
    }
}

// MARK: - The page card

/// The panes, side by side inside the card. One `WebView` each, a draggable hairline between
/// them, and an accent frame round the one the keyboard is in.
struct SplitPanes: View {
    @EnvironmentObject var store: TabStore
    let split: Split

    var body: some View {
        GeometryReader { geo in
            let extent = (split.vertical ? geo.size.height : geo.size.width)
                - Look.splitGap * CGFloat(split.tabs.count - 1)
            // AnyLayout so both orientations are one expression: the alternative is the same
            // twenty lines written twice with HStack swapped for VStack.
            let layout = split.vertical
                ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.tabs.enumerated()), id: \.element) { i, id in
                    if i > 0 {
                        SplitDivider(index: i - 1, vertical: split.vertical, extent: extent,
                                     weights: split.weights)
                    }
                    pane(id, size: max(0, extent * weight(i)))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
        .accessibilityValue("\(split.tabs.count) panes")
    }

    private func weight(_ i: Int) -> CGFloat {
        split.weights.indices.contains(i) ? CGFloat(split.weights[i]) : 0
    }

    @ViewBuilder private func pane(_ id: Tab.ID, size: CGFloat) -> some View {
        if let tab = store.tabs.first(where: { $0.id == id }) {
            Pane(tab: tab, active: store.current == id) { store.focusPane(id) }
                .frame(width: split.vertical ? nil : size,
                       height: split.vertical ? size : nil)
        }
    }
}

/// One pane. The frame is the only thing that says which pane the address pill and ⌘L are
/// pointed at, so it is drawn inside the pane's own clip rather than around it.
private struct Pane: View {
    @ObservedObject var tab: Tab
    let active: Bool
    let focus: () -> Void

    var body: some View {
        WebView(web: tab.web).id(tab.id)
            .background(PaneFocus(focus: focus))
            .clipShape(.rect(cornerRadius: Look.paneRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Look.paneRadius)
                    .strokeBorder(active ? Look.paneFrame : .clear, lineWidth: Look.paneFrameWidth)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(TidyTitles.title(for: tab))
            .accessibilityValue(active ? "active pane" : "pane")
            .accessibilityAction(named: "Focus Pane", focus)
    }
}

/// Click-to-focus for a pane.
///
/// ponytail: a local mouse-down monitor rather than a tap gesture or a transparent overlay.
/// A WKWebView takes every click inside it before SwiftUI sees one, and anything that could
/// see the click would also have to swallow it from the page. The monitor watches, it does
/// not consume. Ceiling: it fires on the way *down*, so a click the page turns into a drag
/// still moves the focus — which is what Arc does too.
private struct PaneFocus: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.watch(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.focus = focus }
    func makeCoordinator() -> Coordinator { Coordinator(focus) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.stop() }
    }

    @MainActor final class Coordinator {
        var focus: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(_ focus: @escaping () -> Void) { self.focus = focus }

        func watch(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                else { return event }
                self.focus()
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The line between two panes, and the grab that moves it. `Look.splitGap` wide so there is
/// something to aim at: a 1pt target between two web views is not one.
private struct SplitDivider: View {
    @EnvironmentObject var store: TabStore
    let index: Int
    let vertical: Bool
    let extent: CGFloat
    let weights: [Double]
    /// The weights the drag started from, so every frame of it is measured from one place.
    @State private var base: [Double]?

    var body: some View {
        Rectangle()
            .fill(Look.hairline)
            .frame(width: vertical ? nil : Look.splitDivider,
                   height: vertical ? Look.splitDivider : nil)
            .frame(width: vertical ? nil : Look.splitGap,
                   height: vertical ? Look.splitGap : nil)
            .contentShape(.rect)
            .onHover { inside in
                if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let from = base ?? weights
                        if base == nil { base = from }
                        let moved = vertical ? value.translation.height : value.translation.width
                        store.resizeSplit(divider: index, from: from,
                                          by: Double(moved / max(extent, 1)))
                    }
                    .onEnded { _ in base = nil }
            )
            .accessibilityHidden(true)      // the panes' own actions are the accessible route
    }
}

// MARK: - Dropping a tab onto the page

/// The page card while a sidebar tab is in flight: its four edge bands take the tab as a new
/// pane, the middle takes nothing.
///
/// ponytail: a real NSView registered for the drag rather than SwiftUI's `.onDrop`. AppKit
/// hands a drag to the deepest registered view under the pointer and that is the WKWebView,
/// which has its own ideas about a dropped string. A view mounted after the page in the
/// ZStack sits above it and wins. It is only in the tree while a tab is being dragged, so it
/// never comes between the pointer and the page.
struct SplitDropWell: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var dragging = Dragging.shared
    @State private var zone: Split.Zone?

    var body: some View {
        if dragging.tab != nil {
            ZStack {
                band
                DropWell(zone: { zone = $0 }, drop: drop)
            }
            .accessibilityHidden(true)      // dragging is a pointer gesture; the menu is the rest
        }
    }

    /// Where the pane will land, shown as a band on that edge — the page's own version of
    /// the sidebar's drop line.
    @ViewBuilder private var band: some View {
        if let zone, zone != .centre {
            GeometryReader { geo in
                let across = zone.isVertical ? geo.size.height : geo.size.width
                Rectangle()
                    .fill(Look.paneFrame)
                    .frame(width: zone.isVertical ? nil : across * Look.splitDropBand,
                           height: zone.isVertical ? across * Look.splitDropBand : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(zone))
            }
        }
    }

    private func alignment(_ zone: Split.Zone) -> Alignment {
        switch zone {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom, .centre: .bottom
        }
    }

    private func drop(_ zone: Split.Zone) {
        guard let id = Dragging.shared.tab else { return }
        Dragging.shared.tab = nil
        store.addPane(id, at: zone)
    }
}

private struct DropWell: NSViewRepresentable {
    let zone: (Split.Zone?) -> Void
    let drop: (Split.Zone) -> Void

    func makeNSView(context: Context) -> DropWellView {
        let view = DropWellView()
        view.onZone = zone
        view.onDrop = drop
        return view
    }

    func updateNSView(_ view: DropWellView, context: Context) {
        view.onZone = zone
        view.onDrop = drop
    }
}

private final class DropWellView: NSView {
    var onZone: ((Split.Zone?) -> Void)?
    var onDrop: ((Split.Zone) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The sidebar's own drag carries the tab's id as a string; `Dragging.shared` is what
        // actually says which tab, so the type only has to be the one the drag advertises.
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// AppKit's y runs up from the bottom; `Split.zone` is written in SwiftUI's y-down space.
    private func zone(_ sender: any NSDraggingInfo) -> Split.Zone {
        let p = convert(sender.draggingLocation, from: nil)
        return Split.zone(at: CGPoint(x: p.x, y: bounds.height - p.y), in: bounds.size,
                          band: Look.splitDropBand)
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let where_ = zone(sender)
        onZone?(where_)
        return where_ == .centre ? [] : .move
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onZone?(nil) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let where_ = zone(sender)
        onZone?(nil)
        guard where_ != .centre else { return false }
        onDrop?(where_)
        return true
    }
}

// MARK: - check

extension Split {
    /// Every rule a split has, proved offline. The ids are made here rather than taken from
    /// live tabs, which is the whole reason the model holds ids and nothing else.
    nonisolated static func check() -> [(String, Bool)] {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        // Shares are arithmetic on doubles: 0.5 - 0.35 is not 0.15, and a screenshot could
        // not tell the difference if it were.
        func near(_ got: [Double], _ want: [Double]) -> Bool {
            got.count == want.count && zip(got, want).allSatisfy { abs($0 - $1) < 1e-9 }
        }
        guard let two = Split(tabs: [a, b]) else {
            return [("a pair of tabs makes a split", false)]
        }
        var out: [(String, Bool)] = [
            ("a pair of tabs makes a split", two.tabs == [a, b]),
            ("one tab is not a split", Split(tabs: [a]) == nil),
            ("no tabs are not a split", Split(tabs: []) == nil),
            ("the same tab twice is not two panes", Split(tabs: [a, a]) == nil),
            ("a split starts horizontal, the way Arc opens one", !two.vertical),
            ("the panes start on equal shares of the card",
             near(two.weights, [0.5, 0.5]) && two.weights.reduce(0, +) == 1),
            ("the first pane is the one the keyboard is in", two.activeTab == a),
        ]

        // Adding.
        let three = two.adding(c, after: a)
        out += [
            ("a pane joins beside the one it was asked from", three.tabs == [a, c, b]),
            ("…and takes the focus, because it is what was just asked for", three.activeTab == c),
            ("…and the shares even out again", near(three.weights, Split.equal(3))),
            ("a pane with no anchor joins at the end", two.adding(c).tabs == [a, b, c]),
            ("a tab that is already a pane joins nothing", three.adding(a) == three),
        ]
        let four = three.adding(d, after: b)
        let five = four.adding(e)
        out += [
            ("a fourth pane is allowed", four.tabs.count == 4),
            ("a fifth is not — four is Arc's ceiling", five == four && four.isFull),
            ("a full split says so before it is asked", !three.isFull && four.isFull),
        ]

        // Edge drops.
        out += [
            ("a drop on the leading edge puts the pane in front",
             two.adding(c, at: .leading).tabs == [c, a, b]),
            ("a drop on the trailing edge puts it at the end",
             two.adding(c, at: .trailing).tabs == [a, b, c]),
            ("a drop on the top edge stacks the panes instead",
             two.adding(c, at: .top).vertical && two.adding(c, at: .top).tabs == [c, a, b]),
            ("a drop on the bottom edge stacks them the other way up",
             two.adding(c, at: .bottom).vertical && two.adding(c, at: .bottom).tabs == [a, b, c]),
        ]

        // Removing.
        out += [
            ("a split of two loses a pane and stops being a split", two.removing(a) == nil),
            ("…whichever pane it was", two.removing(b) == nil),
            ("a split of three loses a pane and stays one",
             three.removing(c)?.tabs == [a, b]),
            ("the shares are shared out again", near(three.removing(c)?.weights ?? [], [0.5, 0.5])),
            ("removing a tab that is not a pane changes nothing", three.removing(d) == three),
            ("focus follows the pane that took the missing one's place",
             three.removing(c)?.activeTab == b),
            ("removing a pane before the focused one keeps the focus on it",
             four.focusing(b).removing(a)?.activeTab == b),
        ]

        // Focus.
        let walked = three.focusing(a).next().next().next()
        out += [
            ("focusing a pane moves the keyboard to it", three.focusing(b).activeTab == b),
            ("focusing something that is not a pane changes nothing",
             three.focusing(d) == three),
            ("the next pane wraps round the end", walked.activeTab == a),
            ("…one pane at a time", three.focusing(a).next().activeTab == c),
        ]

        // Swap.
        let flipped = three.focusing(a).swapped()
        out += [
            ("swap flips the panes", flipped.tabs == [b, c, a]),
            ("…and the focus rides with its own pane", flipped.activeTab == a),
            ("swapping twice is where you started", flipped.swapped() == three.focusing(a)),
            ("swap keeps a two-pane split's shares with their panes",
             near(two.resized(divider: 0, from: [0.5, 0.5], by: 0.2).swapped().weights, [0.3, 0.7])),
        ]

        // The divider.
        let dragged = Split.resized([0.5, 0.5], divider: 0, by: 0.2)
        out += [
            ("dragging the divider takes from one pane and gives to the other",
             near(dragged, [0.7, 0.3])),
            ("the shares still sum to 1", abs(dragged.reduce(0, +) - 1) < 1e-9),
            ("a pane cannot be dragged below its minimum",
             near(Split.resized([0.5, 0.5], divider: 0, by: -0.9), [minimumPane, 1 - minimumPane])),
            ("…from either side",
             near(Split.resized([0.5, 0.5], divider: 0, by: 0.9), [1 - minimumPane, minimumPane])),
            ("a divider that is not there moves nothing",
             near(Split.resized([0.5, 0.5], divider: 7, by: 0.2), [0.5, 0.5])),
            ("only the two panes either side of the divider move",
             near(Split.resized([0.4, 0.3, 0.3], divider: 1, by: 0.1), [0.4, 0.4, 0.2])),
        ]

        // Drop zones. SwiftUI's coordinates: x right, y down from the top.
        let card = CGSize(width: 1000, height: 800)
        out += [
            ("the middle of the card is not a drop target",
             zone(at: CGPoint(x: 500, y: 400), in: card) == .centre),
            ("the left edge adds a pane in front",
             zone(at: CGPoint(x: 40, y: 400), in: card) == .leading),
            ("the right edge adds one after",
             zone(at: CGPoint(x: 960, y: 400), in: card) == .trailing),
            ("the top edge stacks them", zone(at: CGPoint(x: 500, y: 20), in: card) == .top),
            ("the bottom edge stacks them the other way",
             zone(at: CGPoint(x: 500, y: 780), in: card) == .bottom),
            ("a corner resolves to its nearest edge, not to both",
             zone(at: CGPoint(x: 10, y: 30), in: card) == .leading),
            ("the band is a quarter of the card, so just inside it is still a drop",
             zone(at: CGPoint(x: 240, y: 400), in: card) == .leading
                && zone(at: CGPoint(x: 260, y: 400), in: card) == .centre),
            ("a card with no size has no zones",
             zone(at: .zero, in: .zero) == .centre),
            ("top and bottom are the vertical ones",
             Zone.top.isVertical && Zone.bottom.isVertical
                && !Zone.leading.isVertical && !Zone.trailing.isVertical),
            ("leading and top are the ones that go in front",
             Zone.leading.leads && Zone.top.leads && !Zone.trailing.leads && !Zone.bottom.leads),
        ]

        // Weights arithmetic.
        out += [
            ("equal shares of nothing is nothing", Split.equal(0).isEmpty),
            ("normalising shares that sum to something else fixes them",
             near(Split.normalised([1, 3]), [0.25, 0.75])),
            ("normalising nothing falls back to equal shares",
             near(Split.normalised([0, 0]), [0.5, 0.5])),
        ]

        // The session's shape.
        let saved = Split.Saved(urls: ["https://a.example", "https://b.example"],
                                vertical: true, active: 1)
        let round = (try? JSONEncoder().encode(saved))
            .flatMap { try? JSONDecoder().decode(Split.Saved.self, from: $0) }
        out.append(("a saved split round-trips through the session file", round == saved))
        return out
    }
}
