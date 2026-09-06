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
    /// are dropped, so nothing selected is a tab that no longer exists. `live` is in strip
    /// order rather than a set: an anchor whose row has gone hands over to the first
    /// survivor *in that order*, so the next ⇧-click ranges from the same place twice.
    mutating func keep(_ live: [Tab.ID]) {
        guard !ids.isEmpty else { return }
        let alive = Set(live)
        ids.formIntersection(alive)
        if anchor.map(alive.contains) != true { anchor = live.first { ids.contains($0) } }
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
    ///
    /// Only rows that are actually on screen: a run the user cannot see is not a run they
    /// can draw, and a bulk action over one archives pages they were never shown.
    func section(_ kind: TabKind) -> Selection.Section {
        guard kind == .pinned else {
            return .init(kind: kind, ids: tabs.filter { $0.kind == kind && hasRow($0.id) }.map(\.id))
        }
        let live = Dictionary(tabs.map { ($0.id.uuidString, $0.id) }, uniquingKeysWith: { a, _ in a })
        return .init(kind: .pinned,
                     ids: pins.visible.compactMap { $0.entry.tab.flatMap { live[$0] } }.filter(hasRow))
    }

    /// Whether a tab has a row of its own. A split draws one row between all of its panes, at
    /// its lead pane's place (see `StripRow`), so the other panes are in the strip but not on
    /// screen — the same reason a tab inside a folded-up folder is left out of `pins.visible`.
    func hasRow(_ id: Tab.ID) -> Bool {
        guard let split = split(containing: id) else { return true }
        return leadPane(split) == id
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

    /// ⌘A on the sidebar: every tab in the current tab's section — unless that section is
    /// Favourites, which draws tiles rather than rows and so would build a selection with
    /// nothing on screen to show it and no row to click your way out of. Same rule as
    /// `moveSelection(to:)`; see the ponytail note there.
    func selectAllTabs() {
        guard let here = current, tabs.first(where: { $0.id == here })?.kind != .favourite else { return }
        selection.selectAll(in: section(of: here))
        axAnnounce(selection.announcement)
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        axAnnounce(selection.announcement)
    }

    /// A dragged run has landed. Dragging the selection moves every tab in it into the
    /// target's section, and a selection still naming the section it came from is one whose
    /// bulk actions all quietly do nothing — `selectedTabs` looks for its ids in the wrong
    /// list and finds none. Every drop that can move a tab between sections ends here.
    ///
    /// A drag of some *other* row leaves the selection alone: its own tabs have not moved.
    func selectionLanded(_ moved: [Tab.ID], in kind: TabKind) {
        guard !selection.isEmpty, moved.contains(where: selection.contains) else { return }
        // Favourites are tiles, not rows — see the ponytail note on `moveSelection(to:)`.
        if kind == .favourite { selection.clear() } else { selection.moved(to: kind) }
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
        // `Spaces.move` closes each tab, and `close` prunes the selection — so it empties
        // itself. Counted afterwards rather than before: a blank or file tab has no url to
        // write into a Space and is left where it is, and saying "moved 5" when 3 went is
        // worse than saying nothing.
        ids.forEach { Spaces.move($0, to: space, as: kind, from: self) }
        let gone = ids.filter { id in !tabs.contains { $0.id == id } }.count
        let name = spaces.first { $0.id == space }?.name ?? "the space"
        axAnnounce(gone == ids.count ? "Moved \(gone) tab\(gone == 1 ? "" : "s") to \(name)."
                   : "Moved \(gone) of \(ids.count) tabs to \(name).")
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
        guard selectionFitsSplit, ids.count == selection.count else { return }
        selection.clear()
        var anchor = ids[0]
        for id in ids.dropFirst() {
            addPane(id, beside: anchor)
            anchor = id
        }
    }

    /// Whether a selection is big enough for a split and small enough to fit in one — and
    /// is not already part of one. A pane cannot be split with itself, and half a split made
    /// before the refusal is worse than the refusal.
    var selectionFitsSplit: Bool {
        (2...Split.maxPanes).contains(selection.count)
            && !selectedTabs.contains { split(containing: $0.id) != nil }
    }
}

// MARK: - Escape and ⌘A

extension Selection {
    /// Escape on a window with a selection. Called from `VaneWindow.sendEvent`; true means
    /// the selection took it.
    ///
    /// Everything that puts its own Escape up gets it first, because each of those is a
    /// thing the user opened *after* making the selection: the command bar, a rename field
    /// armed on a row, the find bar, and any field editor taking keystrokes. Clearing a
    /// selection out from under an open command bar and leaving the bar there is the one
    /// outcome nobody means.
    ///
    /// ponytail: `editing`, not `typing` — a focused *page* is not asked about. The sidebar
    /// takes no focus when a row is clicked, so the page is usually still first responder,
    /// and gating on that would mean Escape never cleared a selection at all. Ceiling: a
    /// page using Escape for something of its own loses it while rows are ticked. Upgrade
    /// path is the same `@FocusState` on the row list that `selectAll` wants.
    @MainActor static func clear(in window: NSWindow) -> Bool {
        guard let store = TabStore.all.first(where: { $0.window === window }),
              !store.selection.isEmpty,
              store.palette == nil, store.renamingTab == nil, store.renamingFolder == nil,
              !store.findOpen, !editing(window.firstResponder) else { return false }
        store.clearSelection()
        return true
    }

    /// ⌘A belongs to whatever is typing — a url field, a rename field, a text box on the
    /// page — and only falls through to the sidebar when nothing is. Called from
    /// `VaneWindow.sendEvent`; true means the sidebar took it.
    ///
    /// ponytail: "the sidebar has focus" is read as "nothing that types has focus". The
    /// sidebar is a pile of SwiftUI rows with no focus ring and nothing to make first
    /// responder, so there is no state to ask; this is the same question from the other
    /// end. Ceiling: ⌘A anywhere on the chrome selects the section. Upgrade path: give the
    /// row list a real `@FocusState` and ask that instead.
    @MainActor static func selectAll(in window: NSWindow) -> Bool {
        guard !typing(window.firstResponder),
              let store = TabStore.all.first(where: { $0.window === window }),
              !store.isLittle, store.current != nil else { return false }
        store.selectAllTabs()
        return true
    }

    /// A field editor — a url field, a rename field, a text box. Escape is its Cancel.
    @MainActor private static func editing(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextView
    }

    /// The above, plus a focused page: ⌘A inside a text box on a website is the website's.
    @MainActor private static func typing(_ responder: NSResponder?) -> Bool {
        if editing(responder) { return true }
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

/// What a ticked row adds to its own value, so VoiceOver says the row is one of several
/// rather than only that it is selected — which on its own reads the same as "this is the
/// tab you are on". Empty for a row that is not in a selection, so nothing else changes.
@MainActor func selectionSuffix(_ ticked: Bool, _ count: Int) -> String {
    ticked && count > 1 ? ", one of \(count) selected" : ""
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
        // Never in a private window: it is in no Space, so with `currentSpaceID` nil every
        // Space in the profile would look like somewhere to move to — and moving there
        // writes the page down. The same guard `MoveToSpaceMenu` has.
        let others = store.isPrivate ? [] : store.spaces.filter { $0.id != store.currentSpaceID }
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
        s.keep(Array(ids[0...2]))
        out.append(("tabs that left the store leave the selection", s.ids == Set(ids[0...2])))
        out.append(("the anchor's row survived, so the anchor is left where it was",
                    s.anchor == ids[0]))
        s.keep([ids[2], ids[1]])
        out.append(("an anchor whose row has gone hands over in strip order, not set order",
                    s.anchor == ids[2] && s.ids == Set(ids[1...2])))
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

        // Switching Space empties the strip without going through `close`, so `switchTo`
        // clears by hand (Engine.swift). What must hold afterwards: the next ⌘-click in the
        // *same* kind starts a new set rather than adding to the one left behind — `toggle`
        // only resets when the kind differs, so a stale set of the same kind would survive
        // and the bulk menu would count tabs the window no longer has.
        s = Selection()
        s.selectAll(in: today)
        s.clear()
        s.toggle(ids[3], in: today)
        out.append(("a ⌘-click after the selection was cleared holds only that row",
                    s.ids == [ids[3]] && s.anchor == ids[3]))

        // A pane that is not its split's lead has no row, so the store leaves it out of the
        // section (`TabStore.hasRow`). Everything downstream has to honour that: a row the
        // section does not list can be reached by neither ⇧-click nor ⌘A, so no bulk action
        // can ever name a tab the sidebar never drew.
        let hidden = ids[2]
        let drawn = Section(kind: .today, ids: ids.filter { $0 != hidden })
        s = Selection()
        s.toggle(ids[0], in: drawn)
        s.range(anchor: nil, to: hidden, in: drawn)
        out.append(("⇧-click onto a row the section does not list changes nothing",
                    s.ids == [ids[0]]))
        s.range(anchor: nil, to: ids[3], in: drawn)
        out.append(("…and a run drawn over it steps past it rather than through it",
                    s.ids == [ids[0], ids[1], ids[3]] && !s.contains(hidden)))
        s = Selection()
        s.selectAll(in: drawn)
        out.append(("⌘A takes the rows the section lists and no others",
                    s.count == 4 && !s.contains(hidden)))

        return out
    }
}
