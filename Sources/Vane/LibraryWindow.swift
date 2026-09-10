import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Arc's Library: everything that has left the window but is not gone — media, downloads,
/// every Space's pages, and archived tabs. It replaces the *sidebar*, not the window: an
/// icon rail and one list column beside it, with the page still there to the right, simply
/// pushed over by the difference in width.
///
/// ponytail: two columns inside the browser window, not an NSWindow. A separate window would
/// need its own store, its own profile plumbing and its own traffic lights to say the same
/// thing. Ceiling: it cannot be dragged out onto its own screen; History, which really is a
/// window, is raised rather than duplicated here.

// MARK: - Sections

/// The rail's tiles, in Arc's own order, minus the sections Vane has no feature behind —
/// Easels and Boosts are whole features, and a tile that opens an apology is worse than no
/// tile. `history` is the odd one: it is a button, not a pane. The searchable history
/// already exists as a window (⌘Y) and a second copy of it would be a second thing to keep
/// honest, so picking it raises that window and leaves the rail on whatever it was showing.
enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case media, downloads, spaces, archived, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media:     "Media"
        case .archived:  "Archived Tabs"
        case .downloads: "Downloads"
        case .spaces:    "Spaces"
        case .history:   "History"
        }
    }

    /// Outlined symbols, at tile size: Arc's rail draws the thing itself, not a badge.
    var icon: String {
        switch self {
        case .media:     "photo.on.rectangle"
        // Not `archivebox`: that is the footer glyph that opens the Library, and a section
        // wearing the same symbol as the button that got you here reads as the same thing.
        case .archived:  "tray.full"
        case .downloads: "arrow.down.circle"
        case .spaces:    "square.on.square"
        case .history:   "clock"
        }
    }

    /// The column's search field. Arc names the section in the placeholder rather than
    /// putting a title above the field, which is a whole row of chrome saved — and it says
    /// "Archive", not "Archived Tabs", because that is what fits a 246pt column.
    var searchPrompt: String { "Search \(self == .archived ? "Archive" : title)…" }

    /// Whether the column has anything to filter. Media is every picture there is, so a
    /// Filter chip beside its field would open an empty menu.
    var filterable: Bool { self == .archived || self == .downloads }

    /// Whether the section has a search field at all. Spaces is a row of cards, not a list,
    /// so ⌘T over it has nowhere to land and ⌘F must mean the page instead.
    var searchable: Bool { self != .spaces && self != .history }

    /// A private window is in no Space and owns no profile furniture, so the Spaces cards
    /// would have nothing to show and nothing they could safely move.
    func available(private isPrivate: Bool) -> Bool { !(isPrivate && self == .spaces) }
}

// MARK: - State

/// What the Library is showing. App-wide rather than per window: which section you were last
/// looking at is a preference, not a property of a window, and every window's Library opening
/// on the section you left is what Arc does.
@MainActor final class Library: ObservableObject {
    static let shared = Library()

    /// Never `.history`: that tile raises a window instead of changing the pane, so ⇧⌘L can
    /// never come back to a section that would raise it again.
    @Published private(set) var section: LibrarySection = .archived
    /// The pane's search field, live as it is typed. One field for whichever section is
    /// showing: it is the same box in the same place, and a query left behind from the
    /// section before would silently hide rows.
    @Published var query = ""
    /// The Filter menu's toggle on Archived Tabs: only the tabs that were archived out of
    /// a Little Vane window.
    @Published var littleArcOnly = false
    /// The Filter menu's toggle on Downloads: only the rows that are a finished file.
    @Published var completedOnly = false
    /// The Space whose card should open its naming panel: set by the Library's own `+`, read
    /// and cleared by the card that turns up for it. `TabStore.editingSpace` cannot be used
    /// — its popover hangs off the sidebar's footer `+`, which is not in the tree while the
    /// Library stands where the sidebar does.
    @Published var naming: UUID?
    /// Bumped to put the keyboard in the pane's search field — on opening, and on ⌘F, which
    /// while the Library is up means this box rather than the find bar over a hidden page.
    /// A counter rather than a Bool: `@FocusState` is the field's, and asking twice in a row
    /// has to be heard twice.
    @Published private(set) var focusToken = 0

    func focusSearch() { focusToken &+= 1 }

    /// ⌘F while the Library is over the page. Its own entry point so `TabStore.openFind`
    /// does not have to reach into the singleton.
    static func focusSearch() { shared.focusSearch() }

    /// Opening at a section — the footer glyph, the Archive menu, ⇧⌘J, "Manage Spaces…".
    static func open(_ requested: LibrarySection, in store: TabStore?) {
        // History is a window of its own. Raising it must not become the rail's section,
        // or every later ⇧⌘L would raise it again.
        guard requested != .history else { HistoryWindow.show(); return }
        guard let store else { return }
        // A private window has no Spaces, and ⇧⌘L must still open *something*: falling back
        // beats a keystroke that silently does nothing and a rail with no tile lit.
        let section = requested.available(private: store.isPrivate) ? requested : .archived
        // A filter belongs to the visit, not to the user: a Library opened fresh shows
        // everything, the way a reopened Finder window is not still filtered.
        if !store.libraryOpen {
            shared.littleArcOnly = false
            shared.completedOnly = false
        }
        // …and the one search field is shared by every section, so a query typed at the
        // downloads must not still be filtering the archive a click later.
        if !store.libraryOpen || shared.section != section { shared.query = "" }
        shared.section = section
        // The find bar searches the page, and the page is about to be covered by this. A bar
        // left open would be invisible, would still be eating Escape, and would have nothing
        // to search.
        store.findOpen = false
        store.libraryOpen = true
        shared.focusSearch()
    }

    /// ⇧⌘L and the footer glyph: the same keystroke that opened it closes it again.
    static func toggle(_ section: LibrarySection, in store: TabStore?) {
        guard let store else { return }
        if store.libraryOpen && shared.section == section { close(store); return }
        open(section, in: store)
    }

    /// Escape, the back arrow, and opening a page out of the Library. The key view goes back
    /// to the page, so the next keystroke is the page's rather than falling on a rail that is
    /// not there any more.
    static func close(_ store: TabStore) {
        store.libraryOpen = false
        if let web = store.active?.web { store.window?.makeFirstResponder(web) }
    }
}

// MARK: - The rules, as pure functions

extension Library {
    /// Live search, ignoring case and accents so "cafe" finds "Café". Substring rather than
    /// fuzzy — the Library lists things the user has actually seen, and they type the word
    /// they remember. The fields are whatever the row shows: a title and an address, a
    /// filename and where it came from.
    nonisolated static func matches(_ fields: [String], _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let how: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return fields.contains { $0.range(of: q, options: how) != nil }
    }

    nonisolated static func matches(_ entry: Archive.Entry, _ query: String) -> Bool {
        matches([entry.title, entry.url], query)
    }

    /// The list the Archived Tabs section draws, before it is cut into days: the Filter
    /// menu first (it is a filter on what the list is *about*), then the query.
    nonisolated static func filtered(_ entries: [Archive.Entry],
                                     query: String, littleArcOnly: Bool) -> [Archive.Entry] {
        entries.filter { (!littleArcOnly || $0.isLittleArc) && matches($0, query) }
    }

    /// The Downloads Filter menu's one toggle. A Bool rather than the status enum, which is
    /// nested in a `@MainActor` class and so cannot be compared from a pure function.
    nonisolated static func keeps(done: Bool, completedOnly: Bool) -> Bool {
        !completedOnly || done
    }

    /// The header a group of rows falls under. Arc heads the Library's groups with how long
    /// ago rather than with a date — "Today", "Yesterday", "3 days ago", "1 week ago", then
    /// the month's own name — because a file is remembered by how recently it arrived, not
    /// by which Tuesday it was. History's own window keeps `dayTitle`: that list is read by
    /// date, this one by recency, and they are not the same question.
    ///
    /// ponytail ceiling: past four weeks a row is headed by its month, so on the 29th of a
    /// month a row 28 days old can be headed with the month it is still in. Arc does the
    /// same, and the alternative is a "4 weeks ago" bucket that means nothing to anybody.
    nonisolated static func bucket(_ date: Date, now: Date = .now,
                                   calendar: Calendar = .current) -> String {
        let days = daysBack(date, now: now, calendar: calendar)
        switch days {
        case ..<1:    return "Today"            // and anything dated in the future
        case 1:       return "Yesterday"
        case 2...6:   return "\(days) days ago"
        case 7...13:  return "1 week ago"
        case 14...27: return "\(days / 7) weeks ago"
        default:
            let sameYear = calendar.component(.year, from: date)
                == calendar.component(.year, from: now)
            return DateText.string(date, template: sameYear ? "MMMM" : "MMMMy",
                                   calendar: calendar)
        }
    }

    /// Whole days from `date` to `now`, counted between the two days rather than in seconds,
    /// so an hour lost or gained to daylight saving cannot move a row into the next bucket.
    nonisolated static func daysBack(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: date),
                                to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// The same answer as `bucket`, as a number nothing has to be formatted to work out.
    /// Two dates under one header share a key, and `grouped` compares keys — so a month's
    /// name is written once per group rather than once per row, which on a two-thousand-row
    /// archive being regrouped at every keystroke is the whole cost of the list.
    nonisolated static func bucketKey(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let days = daysBack(date, now: now, calendar: calendar)
        switch days {
        case ..<1:    return 0
        case 1:       return 1
        case 2...6:   return days                       // 2…6
        case 7...13:  return 7
        case 14...27: return 20 + days / 7              // 22, 23
        default:
            // Month and year, so October 2022 and October 2023 are never one group.
            return 1000 + calendar.component(.year, from: date) * 12
                + calendar.component(.month, from: date)
        }
    }

    /// Rows under the header they belong to, newest first. Generic over the row because the
    /// archive and the downloads list are grouped by the same rule and disagreeing about
    /// where "1 week ago" starts would be the kind of bug nobody reports.
    nonisolated static func grouped<T>(_ items: [T], by date: (T) -> Date,
                                       now: Date = .now, calendar: Calendar = .current)
        -> [(title: String, items: [T])] {
        var out: [(title: String, items: [T])] = []
        var key: Int?
        for item in items.sorted(by: { date($0) > date($1) }) {
            let at = date(item)
            let next = bucketKey(at, now: now, calendar: calendar)
            if next != key {
                out.append((bucket(at, now: now, calendar: calendar), []))
                key = next
            }
            out[out.count - 1].items.append(item)
        }
        return out
    }

    /// A download's second line, the way Arc writes it: what kind of file it is and where
    /// it came from — "Disk Image from atkgear.com". The kind is the extension's declared
    /// type, so it is whatever the Finder would call the file; one nobody has declared is
    /// just a download.
    nonisolated static func describe(name: String, source: URL?) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension
        let what = (ext.isEmpty ? nil : UTType(filenameExtension: ext))?.localizedDescription
            ?? "Download"
        let from = source.map { host($0.absoluteString) } ?? ""
        return from.isEmpty ? what : "\(what) from \(from)"
    }

    /// The host a row came from, without its "www.". Empty for anything that is not a url
    /// with a host in it, so a caller can fall back rather than print "from ".
    nonisolated static func host(_ url: String) -> String {
        URL(string: url)?.host?
            .replacingOccurrences(of: "www.", with: "", options: .anchored) ?? ""
    }

    /// The Media section: the downloads that are pictures. Arc's Media is every image the
    /// browser has saved, and Vane keeps no second store for them — a download whose file is
    /// an image *is* the picture, so the section is the downloads list read through a type
    /// filter. ponytail ceiling: an image the user looked at but never saved is not here.
    nonisolated static func isImage(name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// How wide the whole panel is. Every section but Spaces is the rail and one list
    /// column; Spaces is the rail plus a card per Space and the `+` that makes another, so
    /// the panel grows with the profile and the page gives up the difference.
    ///
    /// Capped, because a profile with ten Spaces would otherwise push the page off the
    /// window: past the cap the cards scroll sideways instead. The cap never bites below the
    /// ordinary width, so a narrow window still gets its list column whole.
    nonisolated static func panelWidth(section: LibrarySection, spaces: Int,
                                       private isPrivate: Bool = false,
                                       available: CGFloat) -> CGFloat {
        let ordinary = Look.libraryRail + Look.libraryList
        // A private window draws no Spaces cards — `open` falls it back to the archive — so
        // it must not widen for cards another window happens to be looking at.
        guard section == .spaces, section.available(private: isPrivate) else { return ordinary }
        let cards = CGFloat(max(spaces, 1)) * (Look.spaceCard + Look.spaceCardGap)
        let wanted = Look.libraryRail + Look.spaceCardGap + cards
            + Look.spaceCardGap + Look.libraryField + Look.spaceCardGap
        return max(ordinary, min(wanted, available - Look.libraryMinPage))
    }

    /// The rows a Space's card draws for its Pinned section: the saved shape's folders and
    /// tabs in the order it holds them, then anything the shape has never heard of — a tab
    /// another window pinned into that Space while this one was shut.
    ///
    /// The same walk as `TabStore.pinOrder`, but keeping the folders: the card is a
    /// miniature of that Space's sidebar, and a sidebar without its folders is a flat list
    /// of pages that does not look like the Space you left.
    nonisolated static func cardRows(shape: Pins?, urls: [URL]) -> [CardRow] {
        guard let shape, !shape.entries.isEmpty else {
            return urls.enumerated().map { CardRow(id: "\($0.offset)", url: $0.element) }
        }
        // Counted, not a Set: two pinned tabs can sit on the same page, and matching by
        // membership alone either drops the second one or invents one that is not there.
        var left: [String: Int] = [:]
        for u in urls { left[u.absoluteString, default: 0] += 1 }
        var out: [CardRow] = []
        for (i, entry) in shape.entries.enumerated() {
            switch entry.row {
            case .folder(let folder):
                out.append(CardRow(id: folder.id.uuidString, folder: folder,
                                   parent: entry.parent, depth: shape.depth(of: i)))
            case .tab(let name):
                guard let n = left[name], n > 0, let url = URL(string: name) else { continue }
                left[name] = n - 1
                out.append(CardRow(id: "\(out.count)|\(name)", url: url,
                                   parent: entry.parent, depth: shape.depth(of: i)))
            }
        }
        for url in urls {
            guard let n = left[url.absoluteString], n > 0 else { continue }
            left[url.absoluteString] = n - 1
            out.append(CardRow(id: "\(out.count)|\(url.absoluteString)", url: url))
        }
        return out
    }

    /// The rows left once the shut folders have swallowed theirs. A folder is shut when its
    /// own record says so or when the card's chevron has been clicked; either way everything
    /// under it goes, however deep.
    nonisolated static func visible(_ rows: [CardRow], shut: Set<UUID>) -> [CardRow] {
        var hidden: Set<UUID> = []
        return rows.filter { row in
            let buried = row.parent.map { hidden.contains($0) } ?? false
            if let folder = row.folder, buried || shut.contains(folder.id) {
                hidden.insert(folder.id)
            }
            return !buried
        }
    }

    /// Where Restore puts a tab back: the Space it was archived from, if that Space is still
    /// there. An entry from before Spaces were recorded, or from a Space since deleted, has
    /// nowhere of its own to go and lands in the window's current Space.
    nonisolated static func restoreTarget(_ entry: Archive.Entry,
                                          spaces: [UUID], current: UUID?) -> UUID? {
        guard let space = entry.space, spaces.contains(space) else { return current }
        return space
    }

    /// A page in a Space with no tab open on it has no title to show — spaces.json is a list
    /// of urls. This is what a row is labelled with instead: the host without its "www.",
    /// and the path when there is one, which is as much as an address says on one line.
    /// ponytail ceiling: a real title needs a lookup in the history table per row. A Space
    /// that is on screen does have titles, because those tabs are open.
    nonisolated static func label(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString)
            .replacingOccurrences(of: "www.", with: "", options: .anchored)
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// One row on a Space's card: a folder, or a page, at the depth its folders put it. A value
/// rather than a view model — `Library.cardRows` builds these from a saved shape and a url
/// list, which is what makes the walk provable offline.
struct CardRow: Identifiable, Equatable, Sendable {
    let id: String
    var folder: Folder?
    var url: URL?
    var parent: UUID?
    var depth: Int = 0
}

/// Where each picture goes in a masonry: two columns of their own natural heights, packed
/// so nothing is left waiting for a tall neighbour.
///
/// A grid would row-align the pair, which leaves a hole under whichever of the two is
/// shorter — a wall of pictures with gaps punched through it. This is the other way round:
/// the next picture joins whichever column is currently the shorter, so the two columns end
/// up within one picture's height of each other and there are no holes at all.
enum Masonry {
    /// The column each item lands in, in order. `heights` are what the pictures will be at
    /// column width; a height nobody knows yet counts as whatever it is given, and a
    /// negative one counts as nothing.
    ///
    /// Ties go left, so the first row reads left to right the way a list does.
    nonisolated static func place(heights: [CGFloat], columns: Int) -> [Int] {
        guard columns > 1 else { return Array(repeating: 0, count: heights.count) }
        var totals = [CGFloat](repeating: 0, count: columns)
        var out: [Int] = []
        out.reserveCapacity(heights.count)
        for height in heights {
            var pick = 0
            // Strictly shorter, with a hair of slack: two columns a float's width apart are
            // the same height to the eye, and the left one should keep winning.
            for c in 1..<columns where totals[c] < totals[pick] - 0.001 { pick = c }
            out.append(pick)
            totals[pick] += max(height, 0)
        }
        return out
    }

    /// What each column adds up to, which is what `place` is balancing. Its own function so
    /// a check can say "the two columns end up within the tallest picture of each other"
    /// rather than repeating the sum.
    nonisolated static func totals(heights: [CGFloat], columns: Int) -> [CGFloat] {
        let placed = place(heights: heights, columns: columns)
        var out = [CGFloat](repeating: 0, count: max(columns, 1))
        for (i, height) in heights.enumerated() where placed.indices.contains(i) {
            out[placed[i]] += max(height, 0)
        }
        return out
    }
}

// MARK: - Moving a page between Spaces

extension Library {
    /// The window showing this Space, if one is. A Space that is on screen keeps its pages
    /// in that window's strip, not in spaces.json — the file is only written when the window
    /// saves — so a move that edits the file behind such a window's back is undone by its
    /// next save and the page either comes back or disappears. Every move therefore asks who
    /// owns each end first. A Little Arc and a private window are in no Space and own none.
    static func owner(of space: UUID) -> TabStore? {
        TabStore.all.first { $0.currentSpaceID == space && !$0.isLittle && !$0.isPrivate }
    }

    /// Dragging a row from one Space's column onto another's, and the right-click that says
    /// the same thing. Either end can be on screen or on disk, and the two are stored in
    /// different places, so both ends are asked separately.
    ///
    /// A profile id rather than a `TabStore`: nothing here belongs to the window the drag
    /// started in, and a drop's payload arrives on a background queue, where a store is not
    /// something that can be carried.
    static func move(_ url: URL, from source: UUID, to target: UUID,
                     pinned: Bool, profile: UUID) {
        guard source != target else { return }
        let kind: TabKind = pinned ? .pinned : .today
        let into = owner(of: target)
        // What the target opens. The card names a row by the page it is on, and a pinned row
        // browsed away from its home travels as its home — the same page `Spaces.move`
        // writes down — or the target window's strip would put the wander back on disk.
        var opens = url

        if let live = owner(of: source), let tab = live.tabs.first(where: { $0.currentURL == url }) {
            // The source is on screen: hand the live tab to the code that already moves one,
            // which carries its scroll position and back/forward list across. That also
            // writes the target's list — harmless when the target is on screen too, because
            // that window rewrites the same list from its strip when it saves.
            opens = tab.pinnedURL ?? url
            Spaces.move(tab.id, to: target, as: kind, from: live)
        } else {
            let spaces = ProfileManager.shared.spaces(for: profile)
            guard var from = spaces.first(where: { $0.id == source }) else { return }
            from.tabURLs.removeAll { $0 == url }
            from.pinnedTabURLs?.removeAll { $0 == url }
            ProfileManager.shared.updateSpace(from)
            // The state sidecar travels with the page, the way `Spaces.move` carries it, so
            // a moved tab comes up where it was left rather than reloading from the top.
            var parked = Suspension.SpaceState.load(space: source, profileID: profile,
                                                    in: Store.directory)
            let carried = parked.removeValue(forKey: url.absoluteString)
            Suspension.SpaceState.save(parked, space: source, profileID: profile,
                                       in: Store.directory)
            if into == nil, var to = spaces.first(where: { $0.id == target }) {
                switch kind {
                case .pinned: to.pinnedTabURLs = Spaces.appending(url, to: to.pinnedTabURLs ?? [])
                default:      to.tabURLs = Spaces.appending(url, to: to.tabURLs)
                }
                ProfileManager.shared.updateSpace(to)
                if let carried {
                    var landing = Suspension.SpaceState.load(space: target, profileID: profile,
                                                             in: Store.directory)
                    landing[url.absoluteString] = carried
                    Suspension.SpaceState.save(landing, space: target, profileID: profile,
                                               in: Store.directory)
                }
            }
        }
        // The target is on screen: that window's strip is the truth, so the page has to open
        // there rather than only landing in a file the window is about to overwrite.
        if let into {
            into.newTab(opens)
            if pinned, let id = into.tabs.last?.id { into.move(id, to: .pinned) }
        }
        // Every window of the profile draws these columns, and `spaces` is a file read.
        for store in TabStore.all where store.profileID == profile { store.spacesChanged() }
    }
}

/// The row being dragged between Space columns. `Dragging` carries a live `Tab.ID` and
/// `SpaceDragging` a Space; a Library row is neither — it is a page, the Space it came from
/// and which section of that Space it sat in.
///
/// The page is in the drag's own payload as well; this only says where the drag started, and
/// a drop checks that the two agree before anything moves. So a drag that ended somewhere
/// else, leaving this behind, can never be picked up by a later drop.
@MainActor final class LibraryDragging: ObservableObject {
    static let shared = LibraryDragging()
    @Published var url: URL?
    @Published var from: UUID?
    @Published var pinned = false

    func clear() { url = nil; from = nil; pinned = false }
}

// MARK: - Restoring

extension TabStore {
    /// The restore icon on an archived row, and the row itself: open the page again, in the
    /// Space it was archived from, and take it out of the archive because it is not archived
    /// any more. `unarchive` is the same thing without the Library's announcement.
    func restore(_ entry: Archive.Entry) {
        unarchive(entry)
        axAnnounce("Restored \(entry.title).")
    }
}

// MARK: - Geometry

extension Look {
    /// The icon rail: a column of section tiles where the sidebar's own leading edge is.
    /// Wide enough for "Archived Tabs" on one line under its glyph, and no wider — the rail
    /// is a set of destinations, and the list beside it is what is being read.
    static let libraryRail: CGFloat = 88
    /// The list column beside it. Arc's is narrow on purpose: a row is a favicon, a title
    /// and one grey line, and a title that runs half a window wide is not read, it is
    /// scanned past.
    static let libraryList: CGFloat = 246
    /// What the page keeps, however many Spaces the Spaces section wants to show side by
    /// side. Past this the cards scroll instead of the panel growing. The card's own gaps are
    /// in it, so this is the width of the *page*, not of the space it is given.
    static let libraryMinPage: CGFloat = 420 + cardGap * 2
    /// A rail tile: the card under it and the two type sizes. Arc's tile is a glyph with its
    /// name underneath, not a row — and it wears one fill, the card's, never a second one
    /// behind the glyph.
    static let libraryTile: CGFloat = 62
    static let libraryTileIcon = Font.system(size: 19)
    static let libraryTileLabel = Font.system(size: 10, weight: .medium)
    /// A Library row: a favicon or a file icon, a title, and one grey line under it.
    static let libraryRow: CGFloat = 44
    static let libraryThumb: CGFloat = 20
    /// The search field and the Filter chip over the list.
    static let libraryField: CGFloat = 30
    /// Above that field, so its centre lands on the traffic lights' own line — the column
    /// runs to the window's top edge, so this is measured from there. `Look.check` pins it.
    static let libraryHead: CGFloat = lightsCentre - libraryField / 2
    /// A Space's card in the Spaces section, and the air around it. Each card wears its own
    /// Space's ground, so the gap between two of them has to read as a gap.
    static let spaceCard: CGFloat = 180
    static let spaceCardGap: CGFloat = 10
    /// A row inside a card: tighter than a Library row, because a card is 180pt wide and a
    /// Space can have twenty pinned pages.
    static let cardRow: CGFloat = 28
    /// How far a folder's contents step in on a card. Half the sidebar's `folderIndent`:
    /// the card is two thirds the sidebar's width and the same nesting has to fit.
    static let cardIndent: CGFloat = folderIndent / 2
    /// The media masonry: two columns of pictures at their own heights, an `inset` apart and
    /// an `inset` in from each edge of the list column. `Look.check` pins the arithmetic.
    static let mediaColumns = 2
    static let mediaColumn: CGFloat = (libraryList - inset * 3) / 2
    /// What a thumbnail is decoded to: twice the width it is drawn at, so it is sharp on a
    /// retina screen and not a byte bigger. A 512px one was four times the pixels for the
    /// same picture.
    static let mediaPixels = Int(mediaColumn * 2)
    /// The traffic lights' own strip at the leading edge of the sidebar's top row, which
    /// `TopRow` steps past before its first button.
    static let trafficLights: CGFloat = 62
}

// MARK: - The panel

/// Arc's Library replaces the sidebar: an icon rail and one list column standing where the
/// sidebar stood, with the page still on the right — pushed over by the difference in width
/// and pushed back when the Library closes. Nothing floats and nothing is covered.
///
/// It lives in `BrowserWindow`'s HStack in place of `Sidebar`, which is why it has no shadow
/// and no scrim, and why the page card never has to be unmounted: the web views stay in the
/// window, so media, the mini player and picture-in-picture all carry on.
struct LibraryPanel: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: 0) {
            LibraryRail()
            content
        }
        // The rail and the air around the list are the window's handle while the Library is
        // up, exactly as the sidebar is the rest of the time: without this the window could
        // not be moved at all. A tile, a field or a row takes the hover first, so
        // `WindowDragGround` only ever says "bare ground" where there is nothing to click.
        .background(WindowDragArea())
        // Escape closes it, the way every other surface over the window closes. A zero-size
        // button rather than `.onExitCommand`: the panel is not focused until something in
        // it is clicked, and a cancel action is heard either way. It is *not* in the tree
        // while the command bar is up — that reads Escape itself, and the innermost cancel
        // action would otherwise win.
        .background {
            if store.palette == nil && !store.findOpen {
                Button("Close Library") { Library.close(store) }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        // Toasts live in the sidebar, and the sidebar is not in the tree while this is: with
        // nowhere to draw one, ⌘Q's "hold to quit" warning was given invisibly and the app
        // simply refused to quit. Same place the sidebar puts it, above the footer.
        .overlay(alignment: .bottom) {
            ToastHost()
                .padding(.horizontal, Look.inset)
                .padding(.bottom, Look.footer + Look.footerInset + Look.inset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .onAppear { axAnnounce("Library, \(library.section.title).") }
    }

    @ViewBuilder private var content: some View {
        switch library.section {
        case .media:     MediaPane(downloads: Downloads.manager(for: store.profileID))
        case .downloads: DownloadsPane(downloads: Downloads.manager(for: store.profileID))
        case .spaces where !store.isPrivate: SpacesPane()
        // History never becomes the section, and Spaces is not offered in a private
        // window — either way the archive is what a Library with nothing else shows.
        default: ArchivedTabsPane(archive: Archive.shared(for: store.profileID))
        }
    }
}

// MARK: - The rail

private struct LibraryRail: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared

    private var sections: [LibrarySection] {
        LibrarySection.allCases.filter { $0.available(private: store.isPrivate) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights' line, blank, the way the sidebar's top row starts blank.
            Spacer().frame(height: Look.topRow)
            // Arc's tiles start under the lights and stay there: a group centred in the rail
            // drifts hundreds of points down a tall window, and the first thing in the
            // Library ends up in the middle of nowhere.
            Spacer().frame(height: Look.sectionGap)
            VStack(spacing: Look.rowGap) {
                ForEach(sections) { section in
                    LibraryTile(section: section, selected: library.section == section) {
                        Library.open(section, in: store)
                        // History raises its own window, which announces itself when it
                        // takes the keyboard; saying "History" here would claim a rail
                        // selection that never happened.
                        if section != .history { axAnnounce(section.title) }
                    }
                }
            }
            Spacer(minLength: 0)
            // Arc's way back out is a plain arrow in the corner the Library button was in —
            // to the point: the sidebar's footer row pads itself by `Look.inset` inside the
            // column's own inset, so this row does the same and the arrow lands on the
            // pixel the Library glyph left.
            HStack(spacing: 0) {
                Button { Library.close(store) } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain).font(Look.icon).foregroundStyle(Look.inkSecondary)
                    .help("Close the Library (\(Keybindings.binding(for: .showLibrary).display))")
                    .accessibilityLabel("Close the Library")
                Spacer(minLength: 0)
            }
            .frame(height: Look.footer)
            .padding(.horizontal, Look.inset)
        }
        .padding(.horizontal, Look.inset)
        .padding(.top, Look.topInset)
        .padding(.bottom, Look.footerInset)
        .frame(width: Look.libraryRail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library sections")
    }
}

/// A rail tile: the section's outlined glyph with its name underneath, on one card fill when
/// it is the section being shown.
///
/// One fill, not two. A box behind the glyph *and* a plate behind the tile read as two
/// selections stacked on each other — the glyph is drawn bare and the card is what says
/// which section this is.
private struct LibraryTile: View {
    let section: LibrarySection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Look.captionGap * 2) {
            Image(systemName: section.icon).font(Look.libraryTileIcon)
            // Two lines rather than one squeezed: "Archived Tabs" at this size is wider than
            // the tile with any air left around it, and shrinking it ran the "s" into the
            // edge. A name that needs the second line takes it; the rest stay on one.
            Text(section.title).font(Look.libraryTileLabel).lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Look.captionGap)
        }
        .foregroundStyle(selected ? Look.inkPrimary : Look.inkSecondary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Look.libraryTile)
        .background(selected ? Look.selected : (hovering ? Look.hovered : .clear),
                    in: .rect(cornerRadius: Look.cardRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - The list column

/// The head of a column: Arc's rounded search field, the Filter menu beside it on the two
/// sections that have anything to filter, and the "…" that holds what is done to the whole
/// list. Filter filters and nothing else — Clear under a menu called Filter is a destructive
/// verb nobody would look for there.
private struct LibraryHead<Filter: View, Actions: View>: View {
    let section: LibrarySection
    let filtering: Bool
    @Binding var query: String
    @ViewBuilder let filter: () -> Filter
    @ViewBuilder let actions: () -> Actions
    /// The keyboard lands here when the Library opens and when ⌘F is pressed over it.
    @FocusState private var focused: Bool
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: Look.inset - 2) {
            HStack(spacing: Look.inset - 3) {
                Image(systemName: "magnifyingglass").font(Look.caption)
                    .foregroundStyle(Look.inkTertiary)
                TextField(section.searchPrompt, text: $query)
                    .textFieldStyle(.plain).font(Look.small)
                    .foregroundStyle(Look.inkPrimary)
                    .focused($focused)
            }
            .padding(.horizontal, Look.captionGap * 3)
            .frame(height: Look.libraryField)
            .frame(maxWidth: .infinity)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
            .accessibilityLabel(section.searchPrompt)

            if section.filterable {
                // The pill is on the Menu, not inside its label: a borderless menu lays its
                // label out at the label's own size, so a background put in there is drawn
                // at the size of the words rather than at the field's.
                pill(filling: filtering) {
                    Menu { filter() } label: {
                        HStack(spacing: Look.captionGap * 2) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Filter")
                        }
                        .font(Look.small)
                        .foregroundStyle(filtering ? Look.inkPrimary : Look.inkSecondary)
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityValue(filtering ? "On" : "Off")
                }
                // Its own control, beside Filter and not inside it. Clear is a destructive
                // verb, and nobody goes looking for one in a menu called Filter.
                pill(filling: false) {
                    Menu { actions() } label: {
                        Image(systemName: "ellipsis").font(Look.small)
                            .foregroundStyle(Look.inkSecondary)
                    }
                    .accessibilityLabel("More")
                    .accessibilityActions { actions() }
                }
            }
        }
        .padding(.horizontal, Look.inset)
        .padding(.top, Look.libraryHead)
        .padding(.bottom, Look.inset)
        .onAppear { takeKeyboard() }
        .onChange(of: library.focusToken) { takeKeyboard() }
    }

    /// A turn later, not now. `@FocusState` set while the field is still being installed in
    /// the window is dropped, and the keyboard stays where it was — which, the first time the
    /// Library opens over a page, is the web view: every keystroke would go to the page.
    private func takeKeyboard() {
        DispatchQueue.main.async { focused = true }
    }

    private func pill<Label: View>(filling: Bool, @ViewBuilder _ label: () -> Label) -> some View {
        label()
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, Look.inset)
            .frame(height: Look.libraryField)
            .background(filling ? Look.selected : Look.controlFill,
                        in: .rect(cornerRadius: Look.pillRadius))
    }
}

/// A group's header. Quiet and small: it is a signpost between rows, not a title.
private struct LibraryGroupHeader: View {
    let title: String
    var body: some View {
        Text(title).font(Look.sectionCaption).foregroundStyle(Look.inkQuiet)
            .padding(.horizontal, Look.rowInset)
            .padding(.top, Look.inset)
            .padding(.bottom, Look.captionGap)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One quiet line in the middle of the column. Arc's empty Library is a sentence, not an
/// illustration — there is nothing here yet, and a picture would not change that.
private struct LibraryEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(Look.small).foregroundStyle(Look.inkQuiet)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Look.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Library row: a favicon or a file icon, a title over what the thing is, and — under the
/// pointer — the "…" that opens the row's verbs. The row is one accessibility element
/// carrying the same verbs as named actions rather than a row of buttons to tab through.
private struct LibraryRow<Leading: View, Actions: View>: View {
    let title: String
    let subtitle: String
    var spoken: String = ""
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Look.inset) {
            leading().frame(width: Look.libraryThumb, height: Look.libraryThumb)
            VStack(alignment: .leading, spacing: 0) {
                // Tail, not middle: the column is narrow enough that most titles are cut,
                // and a title read from the front is still recognisable where one with its
                // middle missing is not.
                Text(title).font(Look.small).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(subtitle).font(Look.caption).foregroundStyle(Look.inkQuiet).lineLimit(1)
            }
            Spacer(minLength: Look.captionGap)
            // Always in the layout at its own fixed size, drawn only when the pointer is on
            // the row: opacity costs no space, so a title never shortens as the pointer
            // arrives and no row ever changes shape under it.
            Menu { actions() } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Look.caption).foregroundStyle(Look.inkSecondary)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.libraryRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Look.hovered : .clear, in: .rect(cornerRadius: Look.cardRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { actions() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken.isEmpty ? subtitle : spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityActions { actions() }
    }
}

/// The list itself: groups a gap apart, rows butted together inside one. No dividers — Arc's
/// Library separates rows with the hovered row's own card fill and with air.
private struct LibraryList<T, ID: Hashable, Row: View>: View {
    let groups: [(title: String, items: [T])]
    let id: KeyPath<T, ID>
    @ViewBuilder let row: (T) -> Row

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { group in
                    LibraryGroupHeader(title: group.title)
                    ForEach(group.items, id: id) { row($0) }
                }
            }
            .padding(.horizontal, Look.inset)
            .padding(.bottom, Look.cardInset)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
    }
}

/// Every list section's shape: the head, then the list or one quiet line. Its own view so
/// the three panes cannot drift apart on padding or on where the column's width is set.
private struct LibraryColumn<Head: View, Body_: View>: View {
    @ViewBuilder let head: () -> Head
    @ViewBuilder let content: () -> Body_

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head()
            content()
        }
        .frame(width: Look.libraryList)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Archived Tabs

private struct ArchivedTabsPane: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var archive: Archive
    @ObservedObject private var library = Library.shared
    /// Cut into groups once per change rather than once per render: the grouping sorts the
    /// whole archive and formats a date per group, and a pointer moving over a row must not
    /// pay for that.
    @State private var groups: [(title: String, items: [Archive.Entry])] = []

    var body: some View {
        LibraryColumn {
            LibraryHead(section: .archived, filtering: library.littleArcOnly,
                        query: $library.query) {
                Toggle("Little Vane only", isOn: $library.littleArcOnly)
                    .help("Only tabs archived from a Little Vane window")
            } actions: {
                Button("Clear Archive…") { clear() }.disabled(archive.entries.isEmpty)
            }
        } content: {
            if groups.isEmpty {
                LibraryEmpty(text: archive.entries.isEmpty
                    ? "Nothing archived yet — a tab you close with \(Keybindings.binding(for: .closeTab).display) is kept here."
                    : "No archived tab matches this filter.")
            } else {
                LibraryList(groups: groups, id: \Archive.Entry.id) { entry in
                    ArchivedRow(entry: entry, archive: archive)
                }
            }
        }
        .onAppear { regroup() }
        .onChange(of: archive.entries) { regroup() }
        .onChange(of: library.query) { regroup() }
        .onChange(of: library.littleArcOnly) { regroup() }
    }

    private func regroup() {
        groups = Library.grouped(Library.filtered(archive.entries,
                                                  query: library.query,
                                                  littleArcOnly: library.littleArcOnly),
                                 by: \.at)
    }

    /// Arc asks before emptying the archive, because there is no undo for it.
    private func clear() {
        guard confirm("Clear the archive?", "Clear",
                      "\(archive.entries.count) archived tab\(archive.entries.count == 1 ? "" : "s") "
                        + "will be forgotten. Open tabs and history are not affected.")
        else { return }
        archive.clear()
        axAnnounce("Archive cleared.")
    }
}

/// One archived tab. Its own view so the hover state belongs to the row: held in the pane,
/// every pointer move redrew the whole list.
private struct ArchivedRow: View {
    @EnvironmentObject var store: TabStore
    let entry: Archive.Entry
    @ObservedObject var archive: Archive

    /// The address, as much of it as a 246pt column shows: host and path, the way Arc's
    /// archive rows read. The time and the Little Vane flag are what the row is *sorted* and
    /// *filtered* by, so they belong to the group header and the Filter chip, not to a
    /// second line that would push the address out.
    private var subtitle: String {
        URL(string: entry.url).map(Library.label(for:)) ?? entry.url
    }

    var body: some View {
        LibraryRow(title: entry.title, subtitle: subtitle,
                   spoken: "Archived tab, \(subtitle), \(HistoryWindow.time(entry.at))"
                    + (entry.isLittleArc ? ", Little Vane" : "")) {
            SiteIcon(icon: URL(string: entry.url).flatMap(store.favicons.icon(for:)),
                     size: Look.libraryThumb)
        } actions: {
            Button("Restore") { restore() }
            Button("Copy Link") { copyLink() }
            Divider()
            Button("Remove from Archive") { archive.remove(entry.id) }
        } open: {
            restore()
        }
    }

    private func restore() {
        store.restore(entry)
        Library.close(store)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
        axAnnounce("Link copied.")
    }
}

// MARK: - Downloads

private struct DownloadsPane: View {
    @ObservedObject var downloads: Downloads
    @ObservedObject private var library = Library.shared

    /// Not cached in `@State`: a running download republishes on every progress tick, so
    /// the list would be regrouped by an `onChange` on every tick anyway, and the list is
    /// capped at `Downloads.historyLimit` rather than at the archive's two thousand.
    private var groups: [(title: String, items: [Downloads.Item])] {
        let rows = downloads.items.filter {
            Library.keeps(done: $0.status == .done, completedOnly: library.completedOnly)
                && Library.matches([$0.name, $0.source?.absoluteString ?? ""], library.query)
        }
        // A row still arriving has no completion date: it is happening now, so it is today.
        // One `now` for the whole sort — `.now` inside the comparator gives two in-flight
        // rows a different answer every time they are compared, and they swap on each tick.
        let now = Date()
        return Library.grouped(rows, by: { $0.completed ?? now }, now: now)
    }

    var body: some View {
        let groups = groups
        LibraryColumn {
            LibraryHead(section: .downloads, filtering: library.completedOnly,
                        query: $library.query) {
                Toggle("Completed only", isOn: $library.completedOnly)
                    .help("Hide the downloads that are still arriving or went wrong")
            } actions: {
                Button("Clear Downloads") { downloads.clear() }
                    .disabled(downloads.items.isEmpty)
            }
        } content: {
            if groups.isEmpty {
                LibraryEmpty(text: downloads.items.isEmpty
                    ? "Nothing downloaded yet — files you save are listed here."
                    : "No download matches this filter.")
            } else {
                LibraryList(groups: groups, id: \Downloads.Item.id) { item in
                    DownloadListRow(item: item, downloads: downloads)
                }
            }
        }
        // A row that finished weeks ago may have been moved or thrown away since.
        .onAppear { downloads.refreshMissing() }
    }
}

private struct DownloadListRow: View {
    @ObservedObject var item: Downloads.Item
    let downloads: Downloads

    var body: some View {
        LibraryRow(title: item.name, subtitle: item.subtitle, spoken: item.spoken) {
            DownloadIcon(item: item)
        } actions: {
            DownloadVerbs(item: item, downloads: downloads)
        } open: {
            // Clicking a finished download opens it, the way clicking one in Arc does; a row
            // that is still arriving has nothing to open yet.
            if item.status == .done { downloads.open(item) }
        }
        // Arc lets a finished download be dragged straight out of the Library into a Finder
        // window or another app. A file promise would be the thorough version; the file is
        // already on disk, so its url is the whole payload.
        .onDrag { dragPayload(item, downloads) }
    }
}

/// What can be done to one download, in the order the state makes them useful. Shared by the
/// list row and the media tile, which are two pictures of the same thing.
private struct DownloadVerbs: View {
    @ObservedObject var item: Downloads.Item
    let downloads: Downloads

    var body: some View {
        if item.status == .done {
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.reveal(item) }
            if TidyDownloads.canUndo(item) {
                Button("Undo Rename") { _ = TidyDownloads.undo(item, in: downloads) }
            }
        }
        if item.status == .running {
            Button("Pause") { downloads.pause(item) }
            Button("Cancel") { downloads.cancel(item) }
        }
        if item.status == .paused {
            if downloads.canResume(item) { Button("Resume") { _ = downloads.resume(item) } }
            Button("Cancel") { downloads.cancel(item) }
        }
        if let source = item.source {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
                axAnnounce("Link copied.")
            }
        }
        Divider()
        Button("Remove from List") { downloads.forget(item) }
    }
}

/// There is nothing to drag out of a row whose file has gone: mark the row instead of
/// handing the Finder a url that resolves to nothing.
@MainActor private func dragPayload(_ item: Downloads.Item, _ downloads: Downloads) -> NSItemProvider {
    guard item.status == .done, let url = item.url,
          FileManager.default.fileExists(atPath: url.path) else {
        downloads.refreshMissing()
        return NSItemProvider()
    }
    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
}

// MARK: - Media

/// Arc's Media: every picture the browser has saved, as a grid rather than a list, because a
/// picture is recognised by looking at it and a filename tells you nothing about it.
///
/// ponytail: the downloads list read through `Library.isImage`, not a store of its own. The
/// files are already on disk with their dates and their sources; a second index would be a
/// second thing to keep in step for no answer it could give that this cannot. Ceiling: an
/// image the user looked at but never downloaded is not here.
private struct MediaPane: View {
    @ObservedObject var downloads: Downloads
    @ObservedObject private var library = Library.shared
    /// Watched, not read once: a picture that decodes after the wall is drawn changes the
    /// height the masonry balanced on, so the wall has to be laid out again.
    @ObservedObject private var thumbnails = Thumbnails.shared

    private var items: [Downloads.Item] {
        let now = Date()
        return downloads.items
            .filter { $0.status == .done && Library.isImage(name: $0.name)
                && Library.matches([$0.name, $0.source?.absoluteString ?? ""], library.query) }
            .sorted { ($0.completed ?? now) > ($1.completed ?? now) }
    }

    var body: some View {
        let wall = wall
        LibraryColumn {
            LibraryHead(section: .media, filtering: false, query: $library.query) {
                EmptyView()
            } actions: {
                EmptyView()
            }
        } content: {
            if wall.isEmpty {
                LibraryEmpty(text: downloads.items.contains(where: { Library.isImage(name: $0.name) })
                    ? "No picture matches that."
                    : "No pictures yet — images you save are shown here.")
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: Look.inset) {
                        ForEach(Array(wall.enumerated()), id: \.offset) { _, column in
                            LazyVStack(spacing: Look.inset) {
                                ForEach(column, id: \.item.id) { cell in
                                    MediaTile(item: cell.item, downloads: downloads,
                                              height: cell.height, order: cell.order)
                                }
                            }
                            .frame(width: Look.mediaColumn)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Look.inset)
                    .padding(.bottom, Look.cardInset)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { downloads.refreshMissing() }
    }

    /// One picture's place on the wall. `order` is where it came in the list, which is what
    /// VoiceOver reads by — a column of views would otherwise be read down one column and
    /// then down the next, which is not the order anything arrived in.
    private struct Cell {
        let item: Downloads.Item
        let height: CGFloat
        let order: Int
    }

    /// The columns, built once: two lists of cells rather than the whole list walked once per
    /// column. Asking for the thumbnails it has not got yet is part of laying out — the
    /// heights come from them, so the wall re-places itself as they land.
    private var wall: [[Cell]] {
        let items = items
        var out = [[Cell]](repeating: [], count: Look.mediaColumns)
        let heights = items.map(height)
        for (i, column) in Masonry.place(heights: heights, columns: Look.mediaColumns).enumerated()
        where out.indices.contains(column) {
            out[column].append(Cell(item: items[i], height: heights[i], order: i))
        }
        return out
    }

    /// How tall a picture will be at column width, which is what the masonry balances. One
    /// not decoded yet stands at a row's height and asks for itself; `Thumbnails.revision`
    /// is what brings the wall back to lay it out properly.
    private func height(_ item: Downloads.Item) -> CGFloat {
        guard let url = item.url else { return Look.libraryRow }
        guard let image = thumbnails.image(for: url),
              image.size.width > 0, image.size.height > 0 else {
            thumbnails.want(url)
            return Look.libraryRow
        }
        return (Look.mediaColumn * image.size.height / image.size.width).rounded()
    }
}

/// One picture, at column width and its own height. Clicking opens it, the way clicking a
/// finished download does; the pointer brings up the same verbs the list row has.
private struct MediaTile: View {
    @ObservedObject var item: Downloads.Item
    let downloads: Downloads
    let height: CGFloat
    /// Where this picture came in the list. VoiceOver reads by sort priority, so the two
    /// columns are read newest-first across both rather than down one and then the other.
    let order: Int
    @ObservedObject private var thumbnails = Thumbnails.shared
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image = item.url.flatMap(thumbnails.image(for:)) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // The file has gone, or is not a picture the decoder knows. A grey plate
                // beats a torn image or a blank hole.
                Image(systemName: "photo").font(Look.libraryTileIcon)
                    .foregroundStyle(Look.inkQuiet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Look.controlFill)
            }
        }
        .frame(width: Look.mediaColumn, height: height)
        .clipShape(.rect(cornerRadius: Look.cardRadius))
        // Over the picture, not around it: a plate behind would have to inset the image and
        // the column would stop being one clean edge.
        .overlay {
            if hovering {
                RoundedRectangle(cornerRadius: Look.cardRadius).fill(Look.hovered)
            }
        }
        .hairline(radius: Look.cardRadius, hovering ? Look.selectedEdge : .clear)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { downloads.open(item) }
        .onDrag { dragPayload(item, downloads) }
        .contextMenu { DownloadVerbs(item: item, downloads: downloads) }
        .help(item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.subtitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { downloads.open(item) }
        .accessibilityActions { DownloadVerbs(item: item, downloads: downloads) }
        // Higher is read first, so the newest picture leads however the columns fell.
        .accessibilitySortPriority(Double(-order))
    }
}

/// Thumbnails for the media wall and for a downloaded picture's row.
///
/// Two things this must not do: decode on the main thread, and keep every picture ever
/// looked at. `CGImageSourceCreateThumbnailAtIndex` on a phone photo is tens of milliseconds
/// — a wall of twelve of them was a third of a second of dropped frames inside `body` — and
/// a plain dictionary of them never gives the memory back.
///
/// So: the decode runs off the actor and the result lands in an `NSCache` with a cost limit,
/// which is the one collection AppKit will empty under pressure. Views ask `image(for:)` for
/// what is already there and `want(_:)` for what is not; `revision` is what tells the wall to
/// lay itself out again when one arrives.
///
/// ponytail: keyed by path, so a file replaced under the same name keeps its old thumbnail
/// until the cache drops it. That is the ceiling, and it is cheaper than stat-ing every row.
@MainActor final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()

    /// Bumped when a thumbnail lands. The wall's heights come from these, so it has to be
    /// told; a tile on its own would only need to redraw.
    @Published private(set) var revision = 0

    private let cache = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []

    private init() {
        // Bytes, roughly: a `mediaPixels`-wide thumbnail is about a quarter of a megabyte, so
        // this is a few hundred pictures — more than a wall holds, and small enough that the
        // system can take it back.
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    /// What is already decoded, or nil. Never touches the disk, so it is safe inside `body`.
    func image(for url: URL) -> NSImage? { cache.object(forKey: url.path as NSString) }

    /// Ask for one. Returns at once; `revision` says when it has arrived.
    func want(_ url: URL) {
        let key = url.path
        guard cache.object(forKey: key as NSString) == nil, !loading.contains(key) else { return }
        loading.insert(key)
        Task.detached(priority: .utility) {
            let made = Thumbnails.decode(url)
            await MainActor.run { Thumbnails.shared.landed(key, made) }
        }
    }

    private func landed(_ key: String, _ made: Decoded?) {
        loading.remove(key)
        guard let made else { return }
        cache.setObject(made.image, forKey: key as NSString, cost: made.bytes)
        revision &+= 1
    }

    /// A thumbnail on its way back from the background. `NSImage` is not `Sendable`, but this
    /// one was made on that thread and handed straight over — nothing else ever held it.
    private struct Decoded: @unchecked Sendable {
        let image: NSImage
        let bytes: Int
    }

    /// Decoded straight to the size drawn, never to the size stored: ImageIO never holds the
    /// full frame at all, which is the whole reason this is not `NSImage(contentsOf:)`.
    private nonisolated static func decode(_ url: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Look.mediaPixels,
              ] as CFDictionary)
        else { return nil }
        return Decoded(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
                       bytes: cg.width * cg.height * 4)
    }
}

// MARK: - Spaces

/// Arc's "Manage Spaces": every Space of this profile as a card of its own, side by side,
/// each wearing that Space's ground so the row of cards reads as the row of Spaces the
/// footer's dots stand for. A page drags from one card into another.
private struct SpacesPane: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        // No search field and no empty state: a profile always has at least one Space, and
        // a Space is found by looking at four cards rather than by typing.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Look.spaceCardGap) {
                ForEach(store.spaces) { SpaceCard(space: $0) }
                NewSpaceCard()
            }
            .padding(Look.spaceCardGap)
            .padding(.top, Look.libraryHead)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }
}

/// The `+` at the end of the row. Arc's is a plain circle between the cards; ours sits after
/// them, which is where a new Space is actually added.
///
/// It clears `editingSpace` on the way out. `TabStore.newSpace` sets it to open the sidebar's
/// inline editor, and that editor hangs off the footer's `+` — a button that is not in the
/// tree while the Library is standing where the sidebar is. Left set, the popover opened on
/// the sidebar minutes later, for a Space made from here. The naming panel belongs on the new
/// card instead; see `SpaceCard.editing`.
private struct NewSpaceCard: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared
    @State private var hovering = false

    var body: some View {
        Button { make() } label: {
            Image(systemName: "plus").font(Look.icon)
                .foregroundStyle(hovering ? Look.inkPrimary : Look.inkSecondary)
                .frame(width: Look.libraryField, height: Look.libraryField)
                .background(hovering ? Look.hovered : Look.controlFill,
                            in: .rect(cornerRadius: Look.pillRadius))
        }
        .buttonStyle(.plain)
        .frame(maxHeight: .infinity)
        .onHover { hovering = $0 }
        .help("New Space")
        .accessibilityLabel("New Space")
    }

    private func make() {
        guard let space = store.newSpace() else { return }
        store.editingSpace = nil        // the sidebar's editor is not on screen to open
        library.naming = space.id       // the new card's own pencil opens instead
        axAnnounce("New Space created.")
    }
}

private struct SpaceCard: View {
    @EnvironmentObject var store: TabStore
    @EnvironmentObject var profiles: ProfileManager
    @ObservedObject private var library = Library.shared
    @Environment(\.colorScheme) private var scheme
    let space: Space
    @State private var over = false
    @State private var editing = false
    /// Folders the chevron has shut on this card. ponytail: not written down — a card is
    /// looked at, not lived in, and persisting it would mean writing another window's Space
    /// shape from here. The folder's own `collapsed` is still honoured on the way in.
    @State private var shut: Set<UUID> = []
    /// The shape of a Space that is *not* open in a window, read once. `savedShape` is a
    /// defaults read and a JSON decode; in the body it ran per card on every pointer move.
    @State private var saved: Pins?

    /// The window showing this Space keeps its pages in its strip, with real titles; every
    /// other Space is the url list in spaces.json. `owner` rather than "is it this window's"
    /// so a Space open in another window reads from that window too.
    private var live: TabStore? { Library.owner(of: space.id) }

    /// The Pinned section, folders and all, then the Today pages under it — the card is a
    /// miniature of that Space's own sidebar. A live Space's shape is already in memory; a
    /// shut one's came off disk in `reload`.
    private var pinned: [CardRow] {
        if let live {
            let byID = Dictionary(live.tabs.map { ($0.id.uuidString, $0) },
                                  uniquingKeysWith: { a, _ in a })
            let shape = live.pins.mapped { byID[$0]?.currentURL?.absoluteString }
            return Library.cardRows(shape: shape,
                                    urls: live.tabs.filter { $0.kind == .pinned }
                                        .compactMap(\.currentURL))
        }
        return Library.cardRows(shape: saved, urls: space.pinnedTabURLs ?? [])
    }

    /// Read when the card appears and whenever the profile's Spaces change, never in `body`.
    private func reload() {
        saved = live == nil
            ? TabStore.savedShape(space: space.id, profileID: space.profileID)
            : nil
    }

    private var today: [URL] {
        live.map { $0.tabs.filter { $0.kind == .today }.compactMap(\.currentURL) } ?? space.tabURLs
    }

    /// The card's ground, off the same stops `SpaceGround` builds the window's from — so a
    /// Space the theme editor gave two colours reads as that diagonal here too, rather than
    /// as a flat wash of whichever one happens to be `colorHex`.
    ///
    /// Laid opaque, where the window lays its own at `groundOpacity`: the window has a
    /// wallpaper behind it to show through and a card has the panel, which is already
    /// wearing the *current* Space's wash. At 62 % every card would be tinted by the Space
    /// the window is in rather than by its own.
    private var stops: [Color] {
        let mine = Spaces.themeColors(of: space)
        let list = mine.isEmpty
            ? [profiles.profiles.first { $0.id == space.profileID }?.colorHex ?? store.profile.colorHex]
            : mine
        return Look.groundStops(list, towards: list, fraction: 0, dark: scheme == .dark,
                                strength: space.tint ?? Look.defaultTint)
    }

    /// One colour is one even wash; several are the diagonal, exactly as `SpaceGround` mixes
    /// them. The grain rides on top at the Space's own strength, so a grainy Space looks
    /// grainy here too.
    @ViewBuilder private var ground: some View {
        let stops = stops
        ZStack {
            if stops.count > 1 {
                LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                stops.first ?? Color.clear
            }
            if let grain = space.grain, grain > 0 {
                Image(nsImage: Look.grain)
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)          // one noisy pixel per pixel; see SpaceGround
                    .opacity(grain * Look.grainMax)
            }
        }
    }

    var body: some View {
        let pinned = Library.visible(pinned, shut: shut)
        let today = today
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pinned) { row in
                        if let folder = row.folder {
                            FolderCardRow(folder: folder, depth: row.depth,
                                          shut: shut.contains(folder.id)) { toggle(folder) }
                        } else if let url = row.url {
                            PageRow(space: space, url: url, pinned: true, depth: row.depth)
                        }
                    }
                    if !pinned.isEmpty && !today.isEmpty {
                        Hairline().padding(.horizontal, Look.inset).padding(.vertical, Look.captionGap * 2)
                    }
                    // By position, not by url: the same page can be open in two tabs of one
                    // Space, and two rows sharing an id is a list that scrolls to nowhere.
                    ForEach(Array(today.enumerated()), id: \.offset) { _, url in
                        PageRow(space: space, url: url, pinned: false, depth: 0)
                    }
                    if pinned.isEmpty && today.isEmpty {
                        Text("No pages").font(Look.caption).foregroundStyle(Look.inkQuiet)
                            .padding(.horizontal, Look.inset).frame(height: Look.cardRow)
                    }
                }
                .padding(.horizontal, Look.captionGap * 2)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: Look.spaceCard)
        .frame(maxHeight: .infinity)
        // The Space's own ground, then a lift over it — the ground is opaque, so a lift
        // cannot go under. The card the window is in wears the selection; a card a drag is
        // merely over wears the hover, which is what every other drop target in the app does.
        .background {
            ZStack {
                ground
                if space.id == store.currentSpaceID { Look.selected }
                if over { Look.hovered }
            }
            .clipShape(.rect(cornerRadius: Look.cardRadius))
        }
        .hairline(radius: Look.cardRadius, over ? Look.selectedEdge : Look.cardStroke)
        .onDrop(of: [.utf8PlainText], isTargeted: $over) { drop($0) }
        .onAppear { reload() }
        .onChange(of: store.spaceRevision) { reload() }
        // A Space made from the Library's `+` is named on its own card, not on a sidebar
        // button that is not on screen. See `NewSpaceCard`.
        .onChange(of: library.naming, initial: true) {
            guard library.naming == space.id else { return }
            editing = true
            library.naming = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(space.name), \(pinned.count + today.count) page\(pinned.count + today.count == 1 ? "" : "s")")
    }

    /// The Space's icon and name, whose profile it belongs to, and the pencil that opens the
    /// same theme editor the sidebar's `+` does — one place in the app renames a Space.
    private var header: some View {
        HStack(spacing: Look.captionGap * 3) {
            Image(systemName: space.icon ?? "cloud").font(Look.caption)
                .foregroundStyle(Look.inkSecondary)
            Text(space.name).font(Look.small).lineLimit(1)
                .foregroundStyle(space.id == store.currentSpaceID ? Look.inkPrimary : Look.inkSecondary)
            Spacer(minLength: Look.captionGap)
            if let profile = profiles.profiles.first(where: { $0.id == space.profileID }) {
                Text(profile.name).font(Look.caption).lineLimit(1)
                    .foregroundStyle(Look.inkQuiet)
                    .padding(.horizontal, Look.captionGap * 2)
                    .padding(.vertical, 1)
                    .background(Look.hovered, in: .rect(cornerRadius: Look.chipRadius))
                    .accessibilityLabel("Profile \(profile.name)")
            }
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).font(Look.caption).foregroundStyle(Look.inkTertiary)
                .help("Rename this Space, or change its icon and colour")
                .accessibilityLabel("Edit \(space.name)")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    ThemeEditor(store: store, space: space, naming: true)
                }
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.rowHeight)
        .contentShape(.rect)
        .onTapGesture { store.switchTo(spaceID: space.id) }
    }

    /// Arc's card foot: the handle a card is dragged by, and the "…" that holds what is done
    /// to the Space itself. ponytail ceiling: reordering Spaces is the sidebar's own drag —
    /// the handle switches to the Space rather than picking the card up.
    private var footer: some View {
        HStack(spacing: 0) {
            Button { store.switchTo(spaceID: space.id) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain).font(Look.caption).foregroundStyle(Look.inkTertiary)
            .help("Go to \(space.name)")
            .accessibilityLabel("Go to \(space.name)")
            Spacer(minLength: 0)
            // ponytail: no Delete here. The sidebar's Space menu already deletes one, with
            // its own confirmation, and a second route to the same irreversible thing is a
            // second place to keep that confirmation honest.
            Menu {
                Button("Go to \(space.name)") { store.switchTo(spaceID: space.id) }
                Button("Rename…") { editing = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .font(Look.caption).foregroundStyle(Look.inkTertiary)
            .accessibilityLabel("\(space.name) actions")
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.cardRow)
    }

    private func toggle(_ folder: Folder) {
        if shut.contains(folder.id) { shut.remove(folder.id) } else { shut.insert(folder.id) }
    }

    /// The payload says which page; `LibraryDragging` says where it started. Both have to
    /// agree before anything moves, so a drag that ended somewhere else — leaving the
    /// singleton behind — cannot be picked up by a later drop of somebody else's text.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        over = false
        guard let from = LibraryDragging.shared.from, from != space.id,
              let provider = providers.first else { return false }
        let pinned = LibraryDragging.shared.pinned
        let target = space.id, name = space.name, profile = store.profileID
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let url = URL(string: text) else { return }
            Task { @MainActor in
                guard LibraryDragging.shared.url == url,
                      LibraryDragging.shared.from == from else { return }
                LibraryDragging.shared.clear()
                Library.move(url, from: from, to: target, pinned: pinned, profile: profile)
                axAnnounce("Moved to \(name).")
            }
        }
        return true
    }
}

/// A folder on a card: its glyph, its name and the chevron that folds it shut. The rows it
/// holds are the ones after it at a greater depth — see `Library.visible`.
private struct FolderCardRow: View {
    let folder: Folder
    let depth: Int
    let shut: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Look.captionGap * 3) {
            Image(systemName: shut ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Look.inkTertiary)
                .frame(width: Look.captionGap * 4)
            if folder.iconIsEmoji {
                Text(folder.icon).font(Look.caption)
            } else {
                Image(systemName: folder.icon).font(Look.caption)
                    .foregroundStyle(Look.inkSecondary)
            }
            Text(folder.name).font(Look.caption).foregroundStyle(Look.inkPrimary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Look.inset + CGFloat(depth) * Look.cardIndent)
        .padding(.trailing, Look.inset)
        .frame(height: Look.cardRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Look.hovered : .clear, in: .rect(cornerRadius: Look.chipRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue(shut ? "Closed" : "Open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
}

/// A page on a Space's card. Not a `LibraryRow`: a card is 180pt wide, where a 44pt row with
/// a second line of grey under it would be one page filling a fifth of the card.
private struct PageRow: View {
    @EnvironmentObject var store: TabStore
    let space: Space
    let url: URL
    let pinned: Bool
    var depth: Int = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// An open tab knows what it is called; a url in spaces.json does not — and neither does
    /// a pinned tab that has been restored but not loaded, which is most of them in a window
    /// that has just come up. Either way the address is what the row falls back to.
    private var title: String {
        if let tab = store.tabs.first(where: { $0.currentURL == url }), !tab.title.isEmpty {
            return TidyTitles.title(for: tab)
        }
        return Library.label(for: url)
    }

    var body: some View {
        HStack(spacing: Look.captionGap * 3) {
            SiteIcon(icon: store.favicons.icon(for: url), size: Look.captionGap * 7)
            Text(title).font(Look.caption).foregroundStyle(Look.inkPrimary).lineLimit(1)
            Spacer(minLength: Look.captionGap)
        }
        .padding(.leading, Look.inset + CGFloat(depth) * Look.cardIndent)
        .padding(.trailing, Look.inset)
        .frame(height: Look.cardRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Look.selected : .clear, in: .rect(cornerRadius: Look.chipRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .onDrag { payload() }
        .contextMenu {
            Button("Open") { open() }
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != space.id }) { other in
                    Button(other.name) {
                        Library.move(url, from: space.id, to: other.id,
                                     pinned: pinned, profile: store.profileID)
                    }
                }
            }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                axAnnounce("Link copied.")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(pinned ? "Pinned in" : "In") \(space.name), \(url.absoluteString)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this page.")
        .accessibilityAction { open() }
    }

    /// Clicking a page in another Space goes to that Space first — a page opened out of a
    /// Space it does not belong to would be a tab in the wrong list.
    private func open() {
        if space.id != store.currentSpaceID { store.switchTo(spaceID: space.id) }
        if let tab = store.tabs.first(where: { $0.currentURL == url }) {
            store.current = tab.id
        } else {
            store.newTab(url)
        }
        Library.close(store)
    }

    private func payload() -> NSItemProvider {
        // Published on the next turn, not now: a state change inside the drag's own start
        // re-renders the row under the pointer and SwiftUI drops the drag with it. Same
        // reason as `dragPayload`. Every drag start overwrites what the last one left.
        let url = url, from = space.id, pinned = pinned
        DispatchQueue.main.async {
            LibraryDragging.shared.url = url
            LibraryDragging.shared.from = from
            LibraryDragging.shared.pinned = pinned
        }
        return NSItemProvider(object: url.absoluteString as NSString)
    }
}

// MARK: - check

extension Library {
    /// The Library's rules, proved offline: which header a row falls under, how rows are
    /// cut into groups, what the search matches, what the Filter menu filters, where
    /// Restore sends a tab, and how a download's second line is written.
    nonisolated static func check() -> [(String, Bool)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_700_000_000)          // 14 Nov 2023, 22:13 UTC
        let work = UUID(), play = UUID(), gone = UUID()

        func entry(_ n: Int, _ offset: TimeInterval, title: String = "Page",
                   space: UUID? = nil, little: Bool = false) -> Archive.Entry {
            Archive.Entry(url: "https://example.com/\(n)", title: title,
                          at: now.addingTimeInterval(offset), space: space,
                          littleArc: little ? true : nil)
        }

        let today = entry(1, -3600, title: "Swift Forums")
        let earlier = entry(2, -7200, title: "Café Racer", space: work)
        let yesterday = entry(3, -26 * 3600, title: "Little thing", little: true)
        let older = entry(4, -8 * 86_400, title: "Old news", space: gone)
        let all = [today, earlier, yesterday, older]
        let groups = grouped(all, by: \.at, now: now, calendar: calendar)

        /// A date this many days before `now`, at noon, so a bucket is never decided by
        /// which side of midnight the arithmetic landed on.
        func daysAgo(_ n: Int) -> Date {
            calendar.date(byAdding: .day, value: -n,
                          to: calendar.startOfDay(for: now).addingTimeInterval(43_200))!
        }
        func header(_ n: Int) -> String { bucket(daysAgo(n), now: now, calendar: calendar) }

        // The headers: Arc heads the Library by how long ago, not by which day.
        var out: [(String, Bool)] = [
            ("today's rows are headed Today", header(0) == "Today"),
            ("…including one dated later today",
             bucket(now.addingTimeInterval(3600), now: now, calendar: calendar) == "Today"),
            ("yesterday is named, not counted", header(1) == "Yesterday"),
            ("two to six days back are counted in days",
             header(2) == "2 days ago" && header(6) == "6 days ago"),
            ("a week back is one week, not seven days",
             header(7) == "1 week ago" && header(13) == "1 week ago"),
            ("two to three weeks back are counted in weeks",
             header(14) == "2 weeks ago" && header(27) == "3 weeks ago"),
            ("past four weeks a row is headed by its month",
             header(40) == "October" && header(60) == "September"),
            ("a month in another year carries the year",
             header(400).contains("2022") && !header(40).contains("2023")),
            ("every header is a different thing to read",
             Set([0, 1, 2, 7, 14, 40].map(header)).count == 6),
            ("the key agrees with the header, every day for a year",
             (0...365).allSatisfy { a in
                 (0...365).allSatisfy { b in
                     let sameKey = bucketKey(daysAgo(a), now: now, calendar: calendar)
                         == bucketKey(daysAgo(b), now: now, calendar: calendar)
                     return sameKey == (header(a) == header(b))
                 }
             }),
        ]

        // Daylight saving. A day is a day, not 86 400 seconds: on the two nights a year that
        // are 23 or 25 hours long, counting in seconds slides every older row one bucket.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        london.locale = Locale(identifier: "en_GB")
        // Sunday 29 October 2023, 02:00 local — the hour Britain puts the clocks back.
        let afterDST = Date(timeIntervalSince1970: 1_698_600_000)   // 29 Oct 2023, 17:20 UTC
        func londonDays(_ n: Int) -> Date {
            london.date(byAdding: .day, value: -n,
                        to: london.startOfDay(for: afterDST).addingTimeInterval(43_200))!
        }
        out += [
            ("a day that gained an hour is still yesterday",
             bucket(londonDays(1), now: afterDST, calendar: london) == "Yesterday"),
            ("…and the day before it is still two days ago",
             bucket(londonDays(2), now: afterDST, calendar: london) == "2 days ago"),
            ("a week across the clocks going back is still a week",
             bucket(londonDays(8), now: afterDST, calendar: london) == "1 week ago"),
        ]

        // Grouping, on those headers.
        out += [
            ("an empty archive groups into nothing",
             grouped([], by: \Archive.Entry.at, now: now, calendar: calendar).isEmpty),
            ("archived tabs group by header, newest first",
             groups.map(\.title) == ["Today", "Yesterday", "1 week ago"]),
            ("today's archived tabs share one group", groups.first?.items.count == 2),
            ("…newest first inside it",
             groups.first?.items.map(\.url) == [today.url, earlier.url]),
            ("every entry lands in exactly one group",
             groups.flatMap(\.items).count == 4
                && Set(groups.flatMap(\.items).map(\.url)).count == 4),
            ("an out-of-order archive still makes one group per header",
             grouped([older, earlier, yesterday, today], by: \.at, now: now, calendar: calendar)
                .map(\.title) == groups.map(\.title)),
            ("two days under one header are one group, not two",
             grouped([entry(5, -3 * 86_400), entry(6, -4 * 86_400)],
                     by: \.at, now: now, calendar: calendar).count == 2),
            ("…which a week-wide header proves: eight and nine days back share a group",
             grouped([entry(7, -8 * 86_400), entry(8, -9 * 86_400)],
                     by: \.at, now: now, calendar: calendar).count == 1),
            ("the same month a year apart is two groups, not one",
             grouped([daysAgo(40), daysAgo(400)], by: { $0 }, now: now, calendar: calendar)
                .count == 2),
            ("…and one of them says which year",
             grouped([daysAgo(40), daysAgo(400)], by: { $0 }, now: now, calendar: calendar)
                .map(\.title) == [header(40), header(400)]),
            ("the grouping is generic: any row with a date groups the same way",
             grouped([daysAgo(0), daysAgo(1)], by: { $0 }, now: now, calendar: calendar)
                .map(\.title) == ["Today", "Yesterday"]),
        ]

        // Search.
        out += [
            ("an empty query matches everything", filtered(all, query: "  ", littleArcOnly: false).count == 4),
            ("search matches the title", matches(today, "forums")),
            ("search ignores case", matches(today, "SWIFT")),
            ("search ignores accents, either way round",
             matches(earlier, "cafe") && matches(earlier, "Café")),
            ("search matches the address as well as the title",
             matches(today, "example.com/1") && !matches(today, "example.com/2")),
            ("a query matching nothing filters everything out",
             filtered(all, query: "zzzz", littleArcOnly: false).isEmpty),
            ("search keeps the archive's order",
             filtered(all, query: "example", littleArcOnly: false).map(\.url) == all.map(\.url)),
            ("one field is enough to match", matches(["a.dmg", ""], "dmg")),
            ("…and a row with nothing in it matches nothing but the empty query",
             matches([""], "") && !matches([""], "a")),
            ("the downloads list searches its filenames and its sources",
             matches(["atk.dmg", "https://atkgear.com/atk.dmg"], "atkgear")
                && !matches(["atk.dmg", "https://atkgear.com/atk.dmg"], "twimg")),
        ]

        // The Filter menu: Little Vane only, and Completed only.
        out += [
            ("the Little Vane filter keeps only Little Vane entries",
             filtered(all, query: "", littleArcOnly: true).map(\.url) == [yesterday.url]),
            ("…and off, it keeps everything", filtered(all, query: "", littleArcOnly: false).count == 4),
            ("the filter and the search field compose",
             filtered(all, query: "little", littleArcOnly: true).count == 1
                && filtered(all, query: "swift", littleArcOnly: true).isEmpty),
            ("an entry from before the flag existed is not a Little Vane entry",
             !today.isLittleArc && yesterday.isLittleArc),
            ("Completed only keeps a finished download and drops the rest",
             keeps(done: true, completedOnly: true) && !keeps(done: false, completedOnly: true)),
            ("…and off, it keeps both",
             keeps(done: true, completedOnly: false) && keeps(done: false, completedOnly: false)),
        ]

        // A download's second line, and the host a row is labelled with.
        out += [
            ("a download says what it is and where it came from",
             describe(name: "atk.dmg", source: URL(string: "https://www.atkgear.com/atk.dmg"))
                .hasSuffix(" from atkgear.com")),
            ("…and names a real type rather than the extension",
             describe(name: "atk.dmg", source: nil) != "Download"
                && !describe(name: "atk.dmg", source: nil).contains("dmg")),
            ("a file of no declared type is just a download",
             describe(name: "notes.zzzqq", source: nil) == "Download"),
            ("…and with a source, a download from somewhere",
             describe(name: "notes.zzzqq", source: URL(string: "https://example.com/a"))
                == "Download from example.com"),
            ("a file with no extension at all is a download too",
             describe(name: "LICENSE", source: nil) == "Download"),
            ("the host loses its www.", host("https://www.example.com/a") == "example.com"),
            ("…but only a leading one", host("https://a.www.example.com/") == "a.www.example.com"),
            ("something that is not a url has no host", host("not a url") == ""),
        ]

        // Restore.
        out += [
            ("a tab goes back to the Space it was archived from",
             restoreTarget(earlier, spaces: [work, play], current: play) == work),
            ("a tab whose Space has been deleted comes back where the window is",
             restoreTarget(older, spaces: [work, play], current: play) == play),
            ("an entry from before Spaces were recorded comes back where the window is",
             restoreTarget(today, spaces: [work, play], current: play) == play),
            ("outside any Space there is nowhere to send it",
             restoreTarget(today, spaces: [work], current: nil) == nil),
            ("a tab already in its own Space stays put",
             restoreTarget(earlier, spaces: [work], current: work) == work),
        ]

        // Row labels for a Space that is not open.
        out += [
            ("a page with no open tab is labelled by host and path",
             label(for: URL(string: "https://www.example.com/docs/a")!) == "example.com/docs/a"),
            ("a bare host loses its trailing slash",
             label(for: URL(string: "https://example.com/")!) == "example.com"),
            ("only a leading www. is dropped",
             label(for: URL(string: "https://a.www.example.com/")!) == "a.www.example.com"),
        ]

        // Which sections a window offers, and in what order.
        out += [
            ("every section has a symbol and a title",
             LibrarySection.allCases.allSatisfy { !$0.icon.isEmpty && !$0.title.isEmpty }),
            ("the rail is in Arc's order, Media first and History last",
             LibrarySection.allCases.map(\.rawValue)
                == ["media", "downloads", "spaces", "archived", "history"]),
            ("every section's search field names what it is searching",
             LibrarySection.allCases.allSatisfy { $0.searchPrompt.hasPrefix("Search ") }),
            ("…and the archive's says Archive, which is what fits the column",
             LibrarySection.archived.searchPrompt == "Search Archive…"
                && LibrarySection.media.searchPrompt == "Search Media…"),
            ("only the two lists with a filter offer a Filter chip",
             LibrarySection.allCases.filter(\.filterable).map(\.rawValue)
                == ["downloads", "archived"]),
            ("a private window is offered no Spaces section",
             !LibrarySection.spaces.available(private: true)
                && LibrarySection.allCases.filter { $0.available(private: true) }.count == 4),
            ("an ordinary window is offered all five",
             LibrarySection.allCases.allSatisfy { $0.available(private: false) }),
        ]

        // Media: which downloads are pictures.
        out += [
            ("the usual picture formats are media",
             ["a.jpg", "b.jpeg", "c.png", "d.heic", "e.gif", "f.tiff", "g.webp"]
                .allSatisfy(isImage(name:))),
            ("…however they are spelled", isImage(name: "SHOUTING.JPG")),
            ("a document, an archive or an app is not",
             !["a.pdf", "b.zip", "c.dmg", "d.txt", "e.xlsx"].contains(where: isImage(name:))),
            ("a file with no extension is not a picture",
             !isImage(name: "LICENSE") && !isImage(name: "")),
            ("nor is one whose extension nobody has declared", !isImage(name: "a.zzzqq")),
            ("a path is read by its last component, not its first",
             isImage(name: "holiday.zip/photo.png") && !isImage(name: "photo.png/notes.txt")),
        ]

        // How wide the panel is. The Spaces section is the only one that grows.
        let list = Look.libraryRail + Look.libraryList
        let step = Look.spaceCard + Look.spaceCardGap
        out += [
            ("a list section is the rail and one column, whatever the profile holds",
             LibrarySection.allCases.filter { $0 != .spaces }.allSatisfy {
                 panelWidth(section: $0, spaces: 7, available: 2000) == list
             }),
            ("Spaces is wider than a list section", panelWidth(section: .spaces, spaces: 2,
                                                               available: 2000) > list),
            ("…and grows by exactly one card per Space",
             panelWidth(section: .spaces, spaces: 3, available: 4000)
                - panelWidth(section: .spaces, spaces: 2, available: 4000) == step),
            ("one Space is narrower than three",
             panelWidth(section: .spaces, spaces: 1, available: 4000)
                < panelWidth(section: .spaces, spaces: 3, available: 4000)),
            ("a profile with no Spaces still gets a card's worth of room",
             panelWidth(section: .spaces, spaces: 0, available: 4000)
                == panelWidth(section: .spaces, spaces: 1, available: 4000)),
            ("the page always keeps its minimum, however many Spaces there are",
             panelWidth(section: .spaces, spaces: 20, available: 2000)
                <= 2000 - Look.libraryMinPage),
            ("…which is what makes the cards scroll instead of the panel growing",
             panelWidth(section: .spaces, spaces: 20, available: 2000)
                == panelWidth(section: .spaces, spaces: 40, available: 2000)),
            ("a narrow window still gets the list column whole",
             panelWidth(section: .spaces, spaces: 4, available: 300) == list
                && panelWidth(section: .archived, spaces: 4, available: 300) == list),
            ("a private window never widens for Spaces cards it does not draw",
             panelWidth(section: .spaces, spaces: 4, private: true, available: 2000) == list),
            ("…and an ordinary one still does",
             panelWidth(section: .spaces, spaces: 4, private: false, available: 2000) > list),
            ("only Spaces has no search field of its own",
             LibrarySection.allCases.filter { !$0.searchable }.map(\.rawValue)
                == ["spaces", "history"]),
        ]

        // A Space card's rows: the saved shape's folders and tabs, then the rest.
        let inbox = Folder(id: UUID(), name: "Inbox")
        let deep = Folder(id: UUID(), name: "Deep")
        let a = URL(string: "https://a.example/1")!, b = URL(string: "https://b.example/2")!
        let c = URL(string: "https://c.example/3")!
        var shape = Pins()
        shape.entries = [
            .init(row: .folder(inbox), parent: nil),
            .init(row: .tab(a.absoluteString), parent: inbox.id),
            .init(row: .folder(deep), parent: inbox.id),
            .init(row: .tab(b.absoluteString), parent: deep.id),
        ]
        let rows = cardRows(shape: shape, urls: [a, b, c])
        out += [
            ("with no shape a card is its urls, in order, flat",
             cardRows(shape: nil, urls: [a, b]).map(\.url) == [a, b]
                && cardRows(shape: nil, urls: [a, b]).allSatisfy { $0.depth == 0 }),
            ("an empty shape is no shape at all",
             cardRows(shape: Pins(), urls: [a]).map(\.url) == [a]),
            ("a shape puts its folders in the list", rows.compactMap(\.folder?.name) == ["Inbox", "Deep"]),
            ("…and steps its pages in by their nesting",
             rows.first { $0.url == a }?.depth == 1 && rows.first { $0.url == b }?.depth == 2),
            ("a page the shape has never heard of lands at the end, at the top level",
             rows.last?.url == c && rows.last?.depth == 0),
            ("a page the shape holds but the Space no longer has is dropped",
             cardRows(shape: shape, urls: [b]).compactMap(\.url) == [b]),
            ("the same page pinned twice is two rows, not one",
             cardRows(shape: nil, urls: [a, a]).count == 2
                && Set(cardRows(shape: nil, urls: [a, a]).map(\.id)).count == 2),
            ("every row has an id of its own", Set(rows.map(\.id)).count == rows.count),
        ]

        // Folding a card's folders shut.
        out += [
            ("nothing shut shows every row", visible(rows, shut: []).count == rows.count),
            ("a shut folder keeps its own row and takes its pages with it",
             visible(rows, shut: [inbox.id]).map(\.id) == [inbox.id.uuidString, rows.last!.id]),
            ("…however deep they are nested",
             !visible(rows, shut: [inbox.id]).contains { $0.url == b }),
            ("shutting the inner folder leaves the outer one open",
             visible(rows, shut: [deep.id]).compactMap(\.url) == [a, c]
                && visible(rows, shut: [deep.id]).compactMap(\.folder?.name) == ["Inbox", "Deep"]),
            ("a folder id that is not on the card changes nothing",
             visible(rows, shut: [UUID()]).count == rows.count),
        ]

        // The media masonry: two columns packed by height, not a grid of rows.
        let two = Look.mediaColumns
        out += [
            ("nothing to place places nothing", Masonry.place(heights: [], columns: two).isEmpty),
            ("the first picture goes on the left",
             Masonry.place(heights: [100], columns: two) == [0]),
            ("…and the second beside it, because the right column is still empty",
             Masonry.place(heights: [100, 100], columns: two) == [0, 1]),
            ("the third goes under whichever of the two is shorter",
             Masonry.place(heights: [200, 100, 50], columns: two) == [0, 1, 1]),
            ("…and a tall one does not stop the short column filling up",
             Masonry.place(heights: [400, 50, 50, 50], columns: two) == [0, 1, 1, 1]),
            ("equal columns go left, so the first row reads left to right",
             Masonry.place(heights: [100, 100, 100, 100], columns: two) == [0, 1, 0, 1]),
            ("every picture lands in exactly one column",
             Masonry.place(heights: [30, 90, 10, 70, 50], columns: two).count == 5),
            ("…and in a real column",
             Masonry.place(heights: [30, 90, 10, 70, 50], columns: two)
                .allSatisfy { (0..<two).contains($0) }),
            ("the columns come out within the tallest picture of each other", {
                let heights: [CGFloat] = [120, 40, 300, 60, 90, 45, 210, 30]
                let totals = Masonry.totals(heights: heights, columns: two)
                return abs(totals[0] - totals[1]) <= heights.max()!
            }()),
            ("the running totals are the heights, nothing lost and nothing counted twice", {
                let heights: [CGFloat] = [120, 40, 300, 60, 90]
                return Masonry.totals(heights: heights, columns: two).reduce(0, +)
                    == heights.reduce(0, +)
            }()),
            ("a picture of no height changes nothing about where the next one goes",
             Masonry.place(heights: [0, 100, 100], columns: two)
                == Masonry.place(heights: [0, 100, 100], columns: two)
                && Masonry.totals(heights: [0, 100], columns: two).reduce(0, +) == 100),
            ("a negative height counts as nothing rather than pulling a column up",
             Masonry.totals(heights: [-50, 100], columns: two).reduce(0, +) == 100),
            ("one column is a plain list", Masonry.place(heights: [1, 2, 3], columns: 1) == [0, 0, 0]),
            ("…and so is a nonsense column count",
             Masonry.place(heights: [1, 2], columns: 0) == [0, 0]),
            ("three columns fill left to right before anything doubles up",
             Masonry.place(heights: [10, 10, 10, 10], columns: 3) == [0, 1, 2, 0]),
        ]
        return out
    }
}
