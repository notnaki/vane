import AppKit
import SwiftUI

/// Arc's Recent Tab Switcher. ⌃⇥ lays the window's five most recently used tabs out in a
/// row over the page, the showing tab first and the one before it highlighted. Every ⇥ while
/// ⌃ is still down moves the highlight along, ⇧⇥ moves it back, ⌃W closes it, letting go of
/// ⌃ switches to it and Escape leaves everything as it was. A quick tap — down and up before
/// the row has had time to draw — is the classic "back to the tab I was just on".
///
/// The state is a plain value so `check()` can drive it without a window; `TabSwitching`
/// holds one while ⌃ is down and does the AppKit part.
struct TabSwitcher: Equatable {
    /// Most recently used first: `ids[0]` is the tab that was showing when ⌃⇥ was pressed.
    private(set) var ids: [UUID]
    /// The highlighted slot.
    private(set) var index: Int

    /// nil when there is nothing to move to: a lone tab is not a choice. `startAt` is the
    /// slot the first press lands on — 1 for ⌃⇥, the last for ⌃⇧⇥, 0 when no tab is showing.
    init?(recent ids: [UUID], startAt: Int) {
        guard ids.indices.contains(startAt) else { return nil }
        self.ids = ids
        index = startAt
    }

    var highlighted: UUID { ids[index] }

    /// Wraps at both ends, the way ⌃⇥ in Arc comes back round to the current tab.
    mutating func advance(by delta: Int) { index = (index + delta % ids.count + ids.count) % ids.count }

    /// The highlighted tab is going (⌃W). The highlight keeps its slot, so the next card
    /// slides under it; off the end it steps back one. False when the row is now empty.
    mutating func removeHighlighted() -> Bool {
        ids.remove(at: index)
        guard !ids.isEmpty else { return false }
        index = min(index, ids.count - 1)
        return true
    }

    /// The window's tabs in MRU order: the showing tab first, then by `lastActive`, newest
    /// first, capped. The showing tab is placed by hand rather than sorted into place because
    /// selecting a tab stamps both it *and* the one it replaced `.now`, and the replaced one is
    /// stamped a hair later — by the clock alone the previous tab would come first.
    nonisolated static func recent(_ tabs: [(id: UUID, lastActive: Date)], current: UUID?,
                                   limit: Int = 5) -> [UUID] {
        let rest = tabs.filter { $0.id != current }.sorted { $0.lastActive > $1.lastActive }.map(\.id)
        return Array(([current].compactMap { $0 } + rest).prefix(limit))
    }
}

/// One session at a time, app-wide — there is one ⌃ key. Holds the value above from the
/// first ⌃⇥ until ⌃ comes up, and owns the two event monitors that make that work: a
/// `.flagsChanged` one to see ⌃ let go, and a `.keyDown` one for Escape and ⌃W. ⌃⇥ itself
/// keeps arriving through the ordinary keybinding route (`Menu.swift` → `step`).
@MainActor final class TabSwitching: ObservableObject {
    static let shared = TabSwitching()

    @Published private(set) var state: TabSwitcher?
    /// The row is drawn only once ⌃ has been held past `Look.switcherDelay`. A tap that is
    /// over before then still switches — that *is* the two-tab toggle — but nothing flashes.
    @Published private(set) var shown = false
    /// The window the session belongs to; its `WebCard` is the one that draws the row.
    private(set) weak var store: TabStore?
    private var monitors: [Any] = []
    private var reveal: Task<Void, Never>?

    /// ⌃⇥ (+1) and ⌃⇧⇥ (−1): open on the first press, move on every one after.
    func step(_ delta: Int) {
        if state != nil { state?.advance(by: delta); return }
        guard let s = Windows.current else { return }
        let ids = TabSwitcher.recent(s.tabs.map { ($0.id, $0.lastActive) }, current: s.current)
        let start = s.current == nil ? 0 : (delta > 0 ? 1 : ids.count - 1)
        guard let fresh = TabSwitcher(recent: ids, startAt: start) else { return }
        store = s
        state = fresh
        reveal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Look.switcherDelay))
            if !Task.isCancelled { self?.shown = true }
        }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                if !event.modifierFlags.contains(.control) { self?.commit() }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, state != nil else { return event }
                if event.keyCode == 53 { cancel(); return nil }                       // Escape
                if event.modifierFlags.contains(.control),
                   event.charactersIgnoringModifiers == "w" { closeHighlighted(); return nil }
                return event
            },
        ].compactMap { $0 }
    }

    /// ⌃ came up: go to the highlighted tab.
    func commit() {
        if let id = state?.highlighted, let store, store.tabs.contains(where: { $0.id == id }) {
            store.current = id
        }
        end()
    }

    func cancel() { end() }

    /// ⌃W with the row up: Arc's way of clearing out the tabs you were just in without
    /// leaving the switcher. Same rule as ⌘W — a Today tab is archived, a kept one parked.
    func closeHighlighted() {
        guard let id = state?.highlighted, let store else { return }
        store.archive(id)
        if state?.removeHighlighted() != true { end() }
    }

    private func end() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        reveal?.cancel()
        state = nil
        shown = false
        store = nil
    }
}

// MARK: - The row

/// The cards over the page. Sits in `WebCard`'s overlay, so it is centred on the page and
/// not on the window; drawn only for the window the session was started in.
struct TabSwitcherOverlay: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var switching = TabSwitching.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if switching.shown, switching.store === store, let state = switching.state {
            HStack(spacing: Look.inset) {
                ForEach(state.ids, id: \.self) { id in
                    if let tab = store.tabs.first(where: { $0.id == id }) {
                        SwitcherCard(tab: tab, highlighted: id == state.highlighted)
                    }
                }
            }
            .padding(Look.inset)
            .background(Look.barFill, in: .rect(cornerRadius: Look.barRadius))
            .background(Look.barMaterial, in: .rect(cornerRadius: Look.barRadius))
            .hairline(radius: Look.barRadius, Look.barStroke)
            .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
            .transition(.opacity.combined(with: .scale(scale: Look.appearScale)))
            .animation(reduceMotion ? nil : Look.appear, value: switching.shown)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recent tabs")
            .accessibilityHint("Keep holding Control and press Tab to move. Release Control to switch.")
        }
    }
}

private struct SwitcherCard: View {
    @ObservedObject var tab: Tab
    let highlighted: Bool

    var body: some View {
        VStack(spacing: Look.inset) {
            SiteIcon(icon: tab.favicon, size: Look.switcherIcon)
            Text(TidyTitles.title(for: tab))
                .font(Look.small)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(highlighted ? Look.barSelectedText : Look.barText)
        }
        .padding(.horizontal, Look.inset)
        .frame(width: Look.switcherCard, height: Look.switcherCardHeight)
        .background(highlighted ? Look.barSelected : .clear, in: .rect(cornerRadius: Look.pillRadius))
        .animation(Look.quick, value: highlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TidyTitles.title(for: tab))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

// MARK: - check

extension TabSwitcher {
    nonisolated static func check() -> [(String, Bool)] {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()
        let t = { (t: Double) in Date(timeIntervalSince1970: t) }
        let tabs = [(a, t(5)), (b, t(9)), (c, t(1)), (d, t(7)), (e, t(3)), (f, t(8))]
        let mru = recent(tabs, current: c)
        var out: [(String, Bool)] = [
            ("the showing tab comes first even when its clock says otherwise", mru.first == c),
            ("the rest follow by last use, newest first", Array(mru.dropFirst()) == [b, f, d, a]),
            ("five cards, never more", mru.count == 5 && !mru.contains(e)),
            ("no showing tab: plain MRU", recent(tabs, current: nil).first == b),
            ("a lone tab is not a choice", TabSwitcher(recent: [a], startAt: 1) == nil),
            ("no tabs at all is not a choice", TabSwitcher(recent: [], startAt: 0) == nil),
        ]
        guard var s = TabSwitcher(recent: [a, b, c], startAt: 1) else {
            return out + [("a session opens on the previous tab", false)]
        }
        out.append(("a session opens on the previous tab: the two-tab toggle", s.highlighted == b))
        s.advance(by: 1)
        out.append(("⇥ moves along", s.highlighted == c))
        s.advance(by: 1)
        out.append(("⇥ wraps back round to the current tab", s.highlighted == a))
        s.advance(by: -1)
        out.append(("⇧⇥ goes back, wrapping the other way", s.highlighted == c))
        s.advance(by: -7)
        out.append(("any stride wraps", s.highlighted == b))
        out.append(("⌃⇧⇥ first press lands on the oldest",
                    TabSwitcher(recent: [a, b, c], startAt: 2)?.highlighted == c))
        // ⌃W: [a, b, c] with b highlighted → [a, c], c under the highlight.
        s = TabSwitcher(recent: [a, b, c], startAt: 1)!
        out.append(("closing the highlighted tab keeps the slot, so the next card slides under",
                    s.removeHighlighted() && s.highlighted == c && s.ids == [a, c]))
        out.append(("closing the last card steps the highlight back",
                    s.removeHighlighted() && s.highlighted == a))
        out.append(("closing the only card ends the session", !s.removeHighlighted()))
        return out
    }
}
