import AppKit
import SwiftUI
import WebKit

// MARK: - The value

/// Arc's multi-select: ⌘-click adds a row to the selection, ⇧-click takes the run between
/// the last row clicked and this one, and everything the sidebar can do to one tab it can
/// then do to all of them at once.
///
/// A pure value with no reference to the store, so `selfcheck --pure` can prove the range
/// arithmetic and the section confinement without a window. `TabStore` holds one of these
/// and is the only thing that knows which tabs are real.
///
/// ponytail: a `Set` plus an anchor, not an ordered collection. The *order* a bulk action
/// applies in is the order the sidebar draws the rows in, which the store already knows
/// (`TabStore.section`) — storing a second order here would be a copy that can drift from
/// the one on screen. Ceiling: a selection spanning two sections is impossible by
/// construction; Arc's is too, so there is nothing above this ceiling to reach for.
struct Selection: Equatable, Sendable {
    /// One section of the sidebar in the order it is drawn. A ⇧-click's range and ⌘A are
    /// confined to one of these — a run of rows that spans Pinned *and* Today is not a run
    /// the user can see, so it is not one they can make.
    struct Section: Equatable, Sendable {
        let kind: TabKind
        /// The rows, top to bottom. For Pinned this is `Pins.visible` — a tab inside a
        /// folded-up folder is not on screen and so is not in a range that crosses it.
        let ids: [Tab.ID]

        init(kind: TabKind, ids: [Tab.ID]) {
            self.kind = kind
            self.ids = ids
        }
    }

    private(set) var ids: Set<Tab.ID> = []
    /// Which section the selection lives in. nil exactly when it is empty.
    private(set) var section: TabKind?
    /// The last row clicked, which is what a ⇧-click ranges *from*. Kept still by a
    /// ⇧-click so a second one grows or shrinks the same run rather than walking away.
    private(set) var anchor: Tab.ID?

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: Tab.ID) -> Bool { ids.contains(id) }

    /// ⌘-click: this row joins the selection, or leaves it. A row in another section starts
    /// a new selection rather than joining across the divide.
    mutating func toggle(_ id: Tab.ID, in section: Section) {
        guard section.ids.contains(id) else { return }
        if self.section != section.kind { ids = [] }
        self.section = section.kind
        anchor = id
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if ids.isEmpty { clear() }
    }

    /// ⇧-click: everything between the anchor and this row, in the order they are drawn.
    /// `anchor` is what to range from when there is no selection yet — the current tab, at
    /// the call site — and is ignored once one exists.
    mutating func range(anchor from: Tab.ID?, to id: Tab.ID, in section: Section) {
        guard let to = section.ids.firstIndex(of: id) else { return }
        // The remembered anchor wins, but only while it is still in this section: a
        // ⇧-click after the anchor's row was archived, or in the other section, has to
        // range from somewhere that is on screen.
        let start = [self.section == section.kind ? self.anchor : nil, from]
            .compactMap { $0 }
            .compactMap { section.ids.firstIndex(of: $0) }
            .first ?? to
        ids = Set(section.ids[min(start, to)...max(start, to)])
        self.section = section.kind
        self.anchor = section.ids[start]
    }

    /// ⌘A: every row of the section, which is the section the current tab is in.
    mutating func selectAll(in section: Section) {
        guard !section.ids.isEmpty else { return }
        ids = Set(section.ids)
        self.section = section.kind
        if anchor.map(section.ids.contains) != true { anchor = section.ids.first }
    }

    /// Escape, and a plain click on any row.
    mutating func clear() {
        ids = []
        section = nil
        anchor = nil
    }

    /// The tabs are still selected, they are just somewhere else now — what a bulk Pin or
    /// Unpin leaves behind. Without this the selection would name a section its own rows
    /// are no longer in, and the next ⇧-click would find none of them.
    mutating func moved(to kind: TabKind) {
        guard !ids.isEmpty else { return }
        section = kind
    }

    /// Ids that have left the store — a tab archived, closed, or moved to another Space —
    /// are dropped, so nothing selected is a tab that no longer exists.
    mutating func keep(_ live: Set<Tab.ID>) {
        guard !ids.isEmpty else { return }
        ids.formIntersection(live)
        if let a = anchor, !live.contains(a) { anchor = ids.first }
        if ids.isEmpty { clear() }
    }

    /// What VoiceOver is told when the selection changes, and what the bulk menu counts.
    var announcement: String {
        count == 0 ? "Selection cleared." : "\(count) tab\(count == 1 ? "" : "s") selected."
    }
}

// MARK: - The store's side

extension TabStore {
    /// One section's rows in the order the sidebar draws them. Pinned is `pins.visible` —
    /// folders and folded-away tabs included in the shape, excluded from the ids — and the
    /// other two are simply the strip filtered, since the strip *is* their order.
    func section(_ kind: TabKind) -> Selection.Section {
        guard kind == .pinned else {
            return .init(kind: kind, ids: tabs.filter { $0.kind == kind }.map(\.id))
        }
        let live = Dictionary(tabs.map { ($0.id.uuidString, $0.id) }, uniquingKeysWith: { a, _ in a })
        return .init(kind: .pinned, ids: pins.visible.compactMap { $0.entry.tab.flatMap { live[$0] } })
    }

    /// The section a tab's row is in — the one its ⌘-click and ⇧-click are confined to.
    func section(of id: Tab.ID) -> Selection.Section {
        section(tabs.first { $0.id == id }?.kind ?? .today)
    }

    /// The selection in the order it is drawn, which is the order every bulk action applies
    /// in: archiving from the top down is what the sidebar's own sweep looks like.
    var selectedTabs: [Tab] {
        guard let kind = selection.section else { return [] }
        return section(kind).ids
            .filter(selection.contains)
            .compactMap { id in tabs.first { $0.id == id } }
    }

    /// A row was clicked with ⌘ down. The tab on screen is already selected in every sense
    /// the sidebar shows, so the first ⌘-click adds to it rather than starting from nothing —
    /// the way ⌘-clicking a second icon in Finder gives you two, not one.
    func toggleSelection(_ id: Tab.ID) {
        let rows = section(of: id)
        if selection.isEmpty, let here = current, here != id, rows.ids.contains(here) {
            selection.toggle(here, in: rows)
        }
        selection.toggle(id, in: rows)
        axAnnounce(selection.announcement)
    }

    /// A row was clicked with ⇧ down. With nothing selected yet the run starts at the tab
    /// the user is looking at, which is the row Arc ranges from too.
    func extendSelection(to id: Tab.ID) {
        selection.range(anchor: current, to: id, in: section(of: id))
        axAnnounce(selection.announcement)
    }

    /// ⌘A on the sidebar: every tab in the current tab's section.
    func selectAllTabs() {
        guard let here = current else { return }
        selection.selectAll(in: section(of: here))
        axAnnounce(selection.announcement)
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        axAnnounce(selection.announcement)
    }

    // MARK: Bulk actions

    /// ⌘W with a selection, and "Archive N Tabs". The existing archive path, one tab at a
    /// time, so a pinned tab parks and a Today tab is written down — the section's own
    /// rules, not a second set of them.
    func archiveSelection() {
        let ids = selectedTabs.map(\.id)
        guard !ids.isEmpty else { return }
        selection.clear()
        ids.forEach { archive($0) }
        axAnnounce("Archived \(ids.count) tab\(ids.count == 1 ? "" : "s").")
    }

    /// "Pin N Tabs" / "Unpin N Tabs", and "Add N to Favourites": one `move` each, so the
    /// clamping, the folder bookkeeping and the saved rows all happen exactly as they do
    /// for one tab.
    func moveSelection(to kind: TabKind) {
        let ids = selectedTabs.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach { move($0, to: kind) }
        // ponytail: Favourites are tiles, and a tile does not draw the row fill — a selection
        // that lands there is one the user can neither see nor click their way out of, so it
        // ends at the grid's edge. Upgrade path: give the tile the same ticked/edge treatment
        // `SidebarRow` has and this becomes `moved(to: .favourite)` like the other two.
        if kind == .favourite { selection.clear() } else { selection.moved(to: kind) }
        axAnnounce("Moved \(ids.count) tab\(ids.count == 1 ? "" : "s") to \(TabMenu.name(kind)).")
    }

    /// "Move to Folder ▸". Pinned only: a folder holds pinned rows and nothing else.
    func moveSelection(into folder: UUID) {
        let ids = selectedTabs.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach { move($0, into: folder) }
        selection.moved(to: .pinned)
        axAnnounce("Moved \(ids.count) tab\(ids.count == 1 ? "" : "s") into the folder.")
    }

    /// "Move N Tabs to Space ▸". The tabs leave this window, so the selection goes with them.
    func moveSelection(toSpace space: UUID, as kind: TabKind) {
        let ids = selectedTabs.map(\.id)
        guard !ids.isEmpty else { return }
        selection.clear()
        ids.forEach { Spaces.move($0, to: space, as: kind, from: self) }
    }

    /// "Copy N Links": one url per line, in the order the rows are drawn — which is what
    /// makes the clipboard paste as a list rather than as a set.
    func copySelectionLinks() {
        let urls = selectedTabs.compactMap(\.currentURL).map(\.absoluteString)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        axAnnounce("Copied \(urls.count) link\(urls.count == 1 ? "" : "s").")
    }

    /// "Add to Split View": the selected tabs become one split, in their drawn order. Each
    /// pane is added beside the one before it, so the panes read left to right the way the
    /// rows read top to bottom.
    func splitSelection() {
        let ids = selectedTabs.map(\.id)
        guard (2...Split.maxPanes).contains(ids.count) else { return }
        selection.clear()
        var anchor = ids[0]
        for id in ids.dropFirst() {
            addPane(id, beside: anchor)
            anchor = id
        }
    }

    /// Whether a selection is big enough for a split and small enough to fit in one.
    var selectionFitsSplit: Bool { (2...Split.maxPanes).contains(selection.count) }
}

// MARK: - ⌘A

extension Selection {
    /// ⌘A belongs to whatever is typing — a url field, a rename field, a text box on the
    /// page — and only falls through to the sidebar when nothing is. Called from
    /// `VaneWindow.sendEvent`; true means the sidebar took it.
    ///
    /// ponytail: "the sidebar has focus" is read as "nothing that types has focus". The
    /// sidebar is a pile of SwiftUI rows with no focus ring and nothing to make first
    /// responder, so there is no state to ask; this is the same question from the other
    /// end. Ceiling: ⌘A anywhere on the chrome selects the section. Upgrade path: give the
    /// row list a real `@FocusState` and ask that instead.
    /// Escape on a window with a selection. Called from `VaneWindow.sendEvent` ahead of
    /// everything else Escape can mean; true means the selection took it.
    @MainActor static func clear(in window: NSWindow) -> Bool {
        guard let store = TabStore.all.first(where: { $0.window === window }),
              !store.selection.isEmpty else { return false }
        store.clearSelection()
        return true
    }

    @MainActor static func selectAll(in window: NSWindow) -> Bool {
        guard !typing(window.firstResponder),
              let store = TabStore.all.first(where: { $0.window === window }),
              !store.isLittle, store.current != nil else { return false }
        store.selectAllTabs()
        return true
    }

    @MainActor private static func typing(_ responder: NSResponder?) -> Bool {
        if responder is NSText || responder is NSTextView { return true }
        // A focused page's first responder is a private WebKit view *inside* the WKWebView,
        // so the ancestry is the only reliable way to ask.
        var view = responder as? NSView
        while let here = view {
            if here is WKWebView { return true }
            view = here.superview
        }
        return false
    }
}

// MARK: - The bulk menu

/// The right-click menu on a row that is part of a selection: everything `TabMenu` offers
/// one tab, said once for all of them. Arc's own wording, with the count in it, so the item
/// says how much it is about to do.
///
/// ponytail: `store` is passed in rather than read from the environment, as `TabMenu` and
/// `SpaceMenu` do — a context menu is hosted in its own window, and a missing
/// `@EnvironmentObject` there is a crash rather than a blank menu.
struct BulkMenu: View {
    let store: TabStore
    /// Read once when the menu opens: the menu is a snapshot, and a count that changed
    /// under it would label an item with a number it is not going to act on.
    let count: Int
    let kind: TabKind

    var body: some View {
        Button("Copy \(count) Links") { store.copySelectionLinks() }
        Button("Add to Split View") { store.splitSelection() }
            .disabled(!store.selectionFitsSplit)
        Divider()
        if kind != .favourite {
            // ponytail: no capacity test. Vane's grid has no cap — `favouriteColumns` grows
            // the rows instead — so "if there is space" is always true. The day the grid
            // gets a ceiling, this is where it is checked.
            Button("Add \(count) to Favourites") { store.moveSelection(to: .favourite) }
        }
        Button(kind == .pinned ? "Unpin \(count) Tabs" : "Pin \(count) Tabs") {
            store.moveSelection(to: kind == .pinned ? .today : .pinned)
        }
        if kind == .pinned {
            let folders = store.pins.entries.compactMap(\.folder)
            if !folders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(folders) { folder in
                        Button(folder.name) { store.moveSelection(into: folder.id) }
                    }
                }
            }
        }
        MoveSelectionToSpaceMenu(store: store, count: count)
        Divider()
        Button(kind == .today ? "Archive \(count) Tabs" : "Close \(count) Tabs") {
            store.archiveSelection()
        }
    }
}

/// `MoveToSpaceMenu` for a whole selection. Its own view rather than a parameter on that
/// one: the single-tab menu disables itself on a tab with no web url, and a selection is
/// disabled only when *none* of its tabs has one.
private struct MoveSelectionToSpaceMenu: View {
    let store: TabStore
    let count: Int

    var body: some View {
        let others = store.spaces.filter { $0.id != store.currentSpaceID }
        if !others.isEmpty {
            Menu("Move \(count) Tabs to Space") {
                ForEach(others) { space in
                    Menu(space.name) {
                        Button("Pinned") { store.moveSelection(toSpace: space.id, as: .pinned) }
                        Button("Today") { store.moveSelection(toSpace: space.id, as: .today) }
                    }
                }
            }
            .disabled(!store.selectedTabs.contains {
                $0.currentURL?.scheme?.hasPrefix("http") == true
            })
        }
    }
}

// MARK: - Checks

extension Selection {
    /// `vane selfcheck` — the range arithmetic and the section confinement, offline.
    nonisolated static func check() -> [(String, Bool)] {
        let ids = (0..<5).map { _ in UUID() }
        let today = Section(kind: .today, ids: ids)
        let pinned = Section(kind: .pinned, ids: [ids[0], ids[1]])
        var out: [(String, Bool)] = []

        var s = Selection()
        out.append(("a fresh selection is empty and belongs to no section",
                    s.isEmpty && s.section == nil && s.anchor == nil))
        s.toggle(ids[1], in: today)
        out.append(("⌘-click takes the row and the section with it",
                    s.ids == [ids[1]] && s.section == .today && s.anchor == ids[1]))
        s.toggle(ids[3], in: today)
        out.append(("a second ⌘-click adds rather than replaces", s.ids == [ids[1], ids[3]]))
        s.toggle(ids[3], in: today)
        out.append(("⌘-clicking a selected row takes it back out", s.ids == [ids[1]]))
        s.toggle(ids[1], in: today)
        out.append(("⌘-clicking the last one left empties the selection",
                    s.isEmpty && s.section == nil))

        s = Selection()
        s.toggle(ids[1], in: today)
        s.range(anchor: nil, to: ids[3], in: today)
        out.append(("⇧-click takes the run from the anchor down",
                    s.ids == Set(ids[1...3]) && s.anchor == ids[1]))
        s.range(anchor: nil, to: ids[2], in: today)
        out.append(("a second ⇧-click shrinks the same run instead of walking the anchor",
                    s.ids == Set(ids[1...2]) && s.anchor == ids[1]))
        s.range(anchor: nil, to: ids[0], in: today)
        out.append(("⇧-click upwards ranges the other way", s.ids == Set(ids[0...1])))
        s.range(anchor: nil, to: ids[1], in: today)
        out.append(("⇧-click on the anchor itself leaves one row", s.ids == [ids[1]]))

        s = Selection()
        s.range(anchor: ids[2], to: ids[4], in: today)
        out.append(("with nothing selected, ⇧-click ranges from the current tab",
                    s.ids == Set(ids[2...4])))
        s = Selection()
        s.range(anchor: nil, to: ids[2], in: today)
        out.append(("…and with no current tab either, it selects just the row clicked",
                    s.ids == [ids[2]]))

        s = Selection()
        s.toggle(ids[2], in: today)
        s.toggle(ids[0], in: pinned)
        out.append(("a ⌘-click in another section starts over rather than spanning both",
                    s.ids == [ids[0]] && s.section == .pinned))
        s.range(anchor: nil, to: ids[1], in: pinned)
        out.append(("the run stays inside its own section", s.ids == Set(pinned.ids)))
        s.range(anchor: nil, to: ids[4], in: today)
        out.append(("⇧-click into another section ranges from the row clicked, alone",
                    s.ids == [ids[4]] && s.section == .today))

        s = Selection()
        s.selectAll(in: today)
        out.append(("⌘A takes the whole section", s.ids == Set(ids) && s.section == .today))
        s.selectAll(in: Section(kind: .today, ids: []))
        out.append(("⌘A on an empty section changes nothing", s.ids == Set(ids)))
        s.clear()
        out.append(("Escape clears everything, anchor included",
                    s.isEmpty && s.section == nil && s.anchor == nil))

        s = Selection()
        s.range(anchor: nil, to: ids[4], in: today)
        s.range(anchor: nil, to: ids[0], in: today)
        s.keep(Set(ids[0...2]))
        out.append(("tabs that left the store leave the selection", s.ids == Set(ids[0...2])))
        s.keep([ids[1]])
        out.append(("…and the anchor follows them out", s.anchor == ids[1]))
        s.keep([])
        out.append(("a selection whose tabs have all gone is no selection at all",
                    s.isEmpty && s.section == nil))

        s = Selection()
        s.selectAll(in: today)
        s.moved(to: .pinned)
        out.append(("a bulk pin moves the selection's section with it",
                    s.section == .pinned && s.ids == Set(ids)))
        var empty = Selection()
        empty.moved(to: .pinned)
        out.append(("…but an empty selection is not given one", empty.section == nil))

        s = Selection()
        s.toggle(UUID(), in: today)
        out.append(("a row that is not in the section cannot be selected", s.isEmpty))

        s = Selection()
        s.toggle(ids[0], in: today)
        out.append(("one tab announces itself in the singular",
                    s.announcement == "1 tab selected."))
        s.toggle(ids[1], in: today)
        out.append(("two announce in the plural", s.announcement == "2 tabs selected."))

        return out
    }
}
