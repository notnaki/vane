import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Arc's Library: everything that has left the window but is not gone — archived tabs,
/// downloads, every Space's pages, and history — taking the window over while it is open.
/// A rail of section tiles stands where the sidebar does; the section's rows stand where
/// the page does.
///
/// ponytail: the window's own two columns, not an NSWindow. Arc's Library *is* the browser
/// window for as long as it is open, and a separate window would need its own store, its own
/// profile plumbing and its own traffic lights to say the same thing. Ceiling: it cannot be
/// dragged out onto its own screen; History, which really is a window, is raised rather than
/// duplicated here.

// MARK: - Sections

/// The rail's four tiles, in Arc's own order, minus the sections Vane has no feature behind.
/// `history` is the odd one: it is a button, not a pane. The searchable history already
/// exists as a window (⌘Y) and a second copy of it would be a second thing to keep honest,
/// so picking it raises that window and leaves the rail on whatever it was showing.
enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case downloads, spaces, archived, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archived:  "Archived Tabs"
        case .downloads: "Downloads"
        case .spaces:    "Spaces"
        case .history:   "History"
        }
    }

    /// Outlined symbols, at tile size: Arc's rail draws the thing itself, not a badge.
    var icon: String {
        switch self {
        // Not `archivebox`: that is the footer glyph that opens the Library, and a section
        // wearing the same symbol as the button that got you here reads as the same thing.
        case .archived:  "tray.full"
        case .downloads: "arrow.down.circle"
        case .spaces:    "square.on.square"
        case .history:   "clock"
        }
    }

    /// The pane's search field. Arc names the section in the placeholder rather than
    /// putting a title above the field, which is a whole row of chrome saved.
    var searchPrompt: String { "Search \(title)…" }

    /// A private window is in no Space and owns no profile furniture, so the Spaces columns
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

        if let live = owner(of: source), let tab = live.tabs.first(where: { $0.currentURL == url }) {
            // The source is on screen: hand the live tab to the code that already moves one,
            // which carries its scroll position and back/forward list across. That also
            // writes the target's list — harmless when the target is on screen too, because
            // that window rewrites the same list from its strip when it saves.
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
            into.newTab(url)
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
    /// A section tile in the rail: an outlined symbol over its name. Arc's rail is a column
    /// of tiles rather than a list of rows — the Library is a place you go, not a menu.
    static let libraryTile: CGFloat = 68
    static let libraryTileIcon = Font.system(size: 22)
    static let libraryTileLabel = Font.system(size: 12, weight: .semibold)
    /// A Library row: a thumbnail, what the thing is called, and what it is.
    static let libraryRow: CGFloat = 56
    static let libraryThumb: CGFloat = 28
    /// The search field and the Filter button over a pane's list. Taller than a settings
    /// `control` — it is the one thing on the pane being typed into.
    static let libraryField: CGFloat = 36
    /// Above that field, so its centre lands on the traffic lights' own line: the pane runs
    /// to the window's top edge, so this is measured from there and not from a card's inset.
    /// `Look.check` pins it.
    static let libraryHead: CGFloat = lightsCentre - libraryField / 2
    /// How wide the list itself gets, however wide the window is. A title at one end of a
    /// 1500pt row and its "…" at the other is not a row anybody can read across; Arc's
    /// Library keeps its column narrow and lets the ground take the rest.
    static let libraryColumn: CGFloat = 720
    /// A Space's column in the Spaces section. Narrow enough that two fit beside the rail;
    /// ponytail ceiling: a third Space scrolls horizontally rather than the pane growing.
    static let spaceColumn: CGFloat = 220
    /// The traffic lights' own strip at the leading edge of the sidebar's top row, which
    /// `TopRow` steps past before its first button.
    static let trafficLights: CGFloat = 62
}

// MARK: - The rail

/// Arc's Library takes the window over: the rail stands exactly where the sidebar does —
/// same width, same ground, the traffic lights on their own line above it — and the pane
/// stands where the page card does. Both live in `BrowserWindow`'s HStack in place of the
/// two they replace, which is why neither has a shadow or a scrim: nothing is floating.
struct LibraryRail: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared

    private var sections: [LibrarySection] {
        LibrarySection.allCases.filter { $0.available(private: store.isPrivate) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights' line, blank, the way the sidebar's top row starts blank.
            Spacer().frame(height: Look.topRow)
            Spacer(minLength: 0)
            ForEach(sections) { section in
                LibraryTile(section: section, selected: library.section == section) {
                    Library.open(section, in: store)
                    // History raises its own window, which announces itself when it takes
                    // the keyboard; saying "History" here would claim a rail selection that
                    // never happened.
                    if section != .history { axAnnounce(section.title) }
                }
                Spacer(minLength: 0)
            }
            // Arc's way back out is a plain arrow in the corner the Library button was in.
            HStack(spacing: 0) {
                Button { Library.close(store) } label: { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain).font(Look.icon).foregroundStyle(Look.inkSecondary)
                    .help("Close the Library (\(Keybindings.binding(for: .showLibrary).display))")
                    .accessibilityLabel("Close the Library")
                Spacer(minLength: 0)
            }
            .frame(height: Look.footer)
        }
        .padding(.horizontal, Look.inset)
        .padding(.top, Look.topInset)
        .padding(.bottom, Look.footerInset)
        // The rail is the window's handle while the Library is up, exactly as the sidebar is
        // the rest of the time: without this the window cannot be moved at all. A tile takes
        // the hover before the ground does, so `WindowDragGround` still says "bare ground".
        .background(WindowDragArea())
        // Escape closes it, the way every other surface over the window closes. A zero-size
        // button rather than `.onExitCommand`: the rail is not focused until something in it
        // is clicked, and a cancel action is heard either way. It is *not* in the tree while
        // the command bar or the find bar is up — those two read Escape themselves, and the
        // innermost cancel action would otherwise win.
        .background {
            if store.palette == nil && !store.findOpen {
                Button("Close Library") { Library.close(store) }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library sections")
        .onAppear { axAnnounce("Library, \(library.section.title).") }
    }
}

/// A rail tile: the section's symbol over its name, on a card fill when it is the one being
/// shown. The fill is the selection's, not a change of ink — a tile that only brightened
/// would be a label, and this is a place.
private struct LibraryTile: View {
    let section: LibrarySection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Look.captionGap * 3) {
            Image(systemName: section.icon).font(Look.libraryTileIcon)
            Text(section.title).font(Look.libraryTileLabel).lineLimit(1)
        }
        .foregroundStyle(selected ? Look.inkPrimary : Look.inkSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: Look.libraryTile)
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

// MARK: - The pane

/// The section's contents, where the page card would be. It runs to the window's top edge
/// rather than sitting under the card's inset, because its search field is the top row while
/// the Library is open and that row belongs on the traffic lights' line.
struct LibraryPane: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared

    var body: some View {
        Group {
            switch library.section {
            case .downloads: DownloadsPane(downloads: Downloads.manager(for: store.profileID))
            case .spaces where !store.isPrivate: SpacesPane()
            // History never becomes the section, and Spaces is not offered in a private
            // window — either way the archive is what a Library with nothing else shows.
            default: ArchivedTabsPane(archive: Archive.shared(for: store.profileID))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The pane's bare ground is the window's handle on this side, the way the sidebar's
        // is on the other: the head's strip, and the air beside the list. A field, a menu or
        // a scroll view takes the hover before this does, so `WindowDragGround` only ever
        // says "bare ground" where there is nothing to click.
        .background(WindowDragArea())
        .background(Look.cardFill, in: .rect(cornerRadius: Look.cardRadius))
        .clipShape(.rect(cornerRadius: Look.cardRadius))
        .padding([.trailing, .bottom], Look.cardGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(library.section.title)
    }
}

/// The head of a pane: Arc's wide rounded search field, the Filter menu beside it, and the
/// "…" that holds what is done to the whole list. Filter filters and nothing else — Clear
/// under a menu called Filter is a destructive verb nobody would look for there.
private struct LibraryHead<Filter: View, Actions: View>: View {
    let prompt: String
    let filtering: Bool
    @Binding var query: String
    @ViewBuilder let filter: () -> Filter
    @ViewBuilder let actions: () -> Actions
    /// The keyboard lands here when the Library opens and when ⌘F is pressed over it.
    @FocusState private var focused: Bool
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset) {
                Image(systemName: "magnifyingglass").font(Look.fieldIcon)
                    .foregroundStyle(Look.inkTertiary)
                TextField(prompt, text: $query).textFieldStyle(.plain).font(Look.text)
                    .foregroundStyle(Look.inkPrimary)
                    .focused($focused)
            }
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.libraryField)
            .frame(maxWidth: .infinity)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
            .accessibilityLabel(prompt)

            // The pill is on the Menu, not inside its label: a borderless menu lays its
            // label out at the label's own size, so a background put in there is drawn at
            // the size of the words rather than at the field's.
            pill(filling: filtering) {
                Menu { filter() } label: {
                    HStack(spacing: Look.inset - 2) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("Filter")
                    }
                    .font(Look.text)
                    .foregroundStyle(filtering ? Look.inkPrimary : Look.inkSecondary)
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(filtering ? "On" : "Off")
            }
            pill(filling: false) {
                Menu { actions() } label: {
                    Image(systemName: "ellipsis").font(Look.text)
                        .foregroundStyle(Look.inkSecondary)
                }
                .accessibilityLabel("More")
                .accessibilityActions { actions() }
            }
        }
        .padding(.horizontal, Look.cardInset)
        .padding(.top, Look.libraryHead)
        .frame(maxWidth: Look.libraryColumn + Look.cardInset * 2, alignment: .leading)
        .onAppear { takeKeyboard() }
        .onChange(of: library.focusToken) { takeKeyboard() }
    }

    /// A turn later, not now. `@FocusState` set while the field is still being installed in
    /// the window is dropped, and the keyboard stays where it was — which, the first time the
    /// Library opens over a page, is the web view behind it: every keystroke would go to a
    /// page nobody can see.
    private func takeKeyboard() {
        DispatchQueue.main.async { focused = true }
    }

    /// Both trailing controls are the same pill at the field's own height.
    private func pill<Label: View>(filling: Bool, @ViewBuilder _ label: () -> Label) -> some View {
        label()
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, Look.rowInset)
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
            .accessibilityAddTraits(.isHeader)
    }
}

/// One quiet line in the middle of the pane. Arc's empty Library is a sentence, not an
/// illustration — there is nothing here yet, and a picture would not change that.
private struct LibraryEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(Look.text).foregroundStyle(Look.inkQuiet)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Look.paneMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Library row: a thumbnail, a title over what the thing is, and — under the pointer — the
/// "…" that opens the row's verbs. The row is one accessibility element carrying the same
/// verbs as named actions rather than a row of buttons to tab through.
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
        HStack(spacing: Look.rowSpacing) {
            leading().frame(width: Look.libraryThumb, height: Look.libraryThumb)
            VStack(alignment: .leading, spacing: Look.captionGap) {
                Text(title).font(Look.rowTitle).foregroundStyle(Look.inkPrimary).lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle).font(Look.small).foregroundStyle(Look.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: Look.inset)
            // Always in the layout at its own fixed size, drawn only when the pointer is on
            // the row: opacity costs no space, so a title never shortens as the pointer
            // arrives and no row ever changes shape under it.
            Menu { actions() } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Look.rowGlyph).foregroundStyle(Look.inkSecondary)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Look.rowInset)
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
/// Library separates rows with the hovered row's own card fill and with air, and a hairline
/// between 56pt rows reads as a table.
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
            // The same column the head's field sits in, so a row's "…" is a hand's width
            // from its title however wide the window is.
            .frame(maxWidth: Look.libraryColumn, alignment: .leading)
            .padding(.horizontal, Look.cardInset)
            .padding(.bottom, Look.cardInset)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
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
        VStack(alignment: .leading, spacing: 0) {
            LibraryHead(prompt: LibrarySection.archived.searchPrompt,
                        filtering: library.littleArcOnly, query: $library.query) {
                Toggle("Little Vane only", isOn: $library.littleArcOnly)
                    .help("Only tabs archived from a Little Vane window")
            } actions: {
                Button("Clear Archive…") { clear() }.disabled(archive.entries.isEmpty)
            }
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

    /// Where it came from, when it went, and — when it applies — that it was never a tab in
    /// this window at all. One line, because that is the shape of every Library row.
    private var subtitle: String {
        let host = Library.host(entry.url)
        return [host.isEmpty ? entry.url : host,
                HistoryWindow.time(entry.at),
                entry.isLittleArc ? "Little Vane" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        LibraryRow(title: entry.title, subtitle: subtitle,
                   spoken: "Archived tab, \(subtitle)") {
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
    /// the list would be regrouped by a `onChange` on every tick anyway, and the list is
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
        VStack(alignment: .leading, spacing: 0) {
            LibraryHead(prompt: LibrarySection.downloads.searchPrompt,
                        filtering: library.completedOnly, query: $library.query) {
                Toggle("Completed only", isOn: $library.completedOnly)
                    .help("Hide the downloads that are still arriving or went wrong")
            } actions: {
                Button("Clear Downloads") { downloads.clear() }
                    .disabled(downloads.items.isEmpty)
            }
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
        } open: {
            // Clicking a finished download opens it, the way clicking one in Arc does; a row
            // that is still arriving has nothing to open yet.
            if item.status == .done { downloads.open(item) }
        }
        // Arc lets a finished download be dragged straight out of the Library into a Finder
        // window or another app. A file promise would be the thorough version; the file is
        // already on disk, so its url is the whole payload.
        .onDrag { provider() }
    }

    /// There is nothing to drag out of a row whose file has gone: mark the row instead of
    /// handing the Finder a url that resolves to nothing.
    private func provider() -> NSItemProvider {
        guard item.status == .done, let url = item.url,
              FileManager.default.fileExists(atPath: url.path) else {
            downloads.refreshMissing()
            return NSItemProvider()
        }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

// MARK: - Spaces

/// Arc's "Manage Spaces": every Space of this profile side by side with its pages, and a
/// page draggable from one column into another.
private struct SpacesPane: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No search field: a Space is found by looking at four columns, not by typing,
            // and no New Space button — the sidebar's `+` makes one and names it in place.
            // No empty state either: a profile always has at least one Space, and the window
            // this pane is over is showing one. See `ProfileManager.ensureSpaces`.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Look.inset) {
                    ForEach(store.spaces) { SpaceColumn(space: $0) }
                }
                .padding(Look.cardInset)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct SpaceColumn: View {
    @EnvironmentObject var store: TabStore
    let space: Space
    @State private var over = false
    @State private var editing = false

    /// The window showing this Space keeps its pages in its strip, with real titles; every
    /// other Space is the url list in spaces.json. `owner` rather than "is it this window's"
    /// so a Space open in another window reads from that window too.
    private var live: TabStore? { Library.owner(of: space.id) }

    /// Pinned first, then Today, as one list so the rows have one order to be indexed by.
    private var rows: [(url: URL, pinned: Bool)] {
        if let live {
            return live.tabs.filter { $0.kind == .pinned }.compactMap(\.currentURL).map { ($0, true) }
                + live.tabs.filter { $0.kind == .today }.compactMap(\.currentURL).map { ($0, false) }
        }
        return (space.pinnedTabURLs ?? []).map { ($0, true) } + space.tabURLs.map { ($0, false) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: Look.inset) {
            header(rows.count)
            LazyVStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("No pages").font(Look.caption).foregroundStyle(Look.inkQuiet)
                        .padding(.horizontal, Look.rowInset).frame(height: Look.linkRow)
                }
                // By position, not by url: the same page can be open in two tabs of one
                // Space, and two rows sharing an id is a list that scrolls to nowhere.
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    PageRow(space: space, url: row.url, pinned: row.pinned)
                }
            }
        }
        .frame(width: Look.spaceColumn)
        .padding(Look.inset / 2)
        .background(over ? Look.hovered : .clear, in: .rect(cornerRadius: Look.cardRadius))
        .onDrop(of: [.utf8PlainText], isTargeted: $over) { drop($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(space.name), \(rows.count) page\(rows.count == 1 ? "" : "s")")
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: space.icon ?? "cloud").font(Look.spaceIcon)
                .foregroundStyle(Look.inkSecondary)
            Text(space.name).font(Look.rowTitle).lineLimit(1)
                .foregroundStyle(space.id == store.currentSpaceID ? Look.inkPrimary : Look.inkSecondary)
            Spacer(minLength: Look.inset)
            // How many pages the Space holds, in the row rather than under it: Arc puts the
            // count beside the name, and a column with none has to say so before it is read.
            Text("\(count)").font(Look.caption).foregroundStyle(Look.inkQuiet)
                .monospacedDigit()
            Button { editing = true } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.plain).font(Look.rowGlyph).foregroundStyle(Look.inkTertiary)
                .help("Rename this Space, or change its icon and colour")
                .accessibilityLabel("Edit \(space.name)")
                // The sidebar's own editor, so a Space is renamed in one place in the app.
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    ThemeEditor(store: store, space: space, naming: true)
                }
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.rowHeight)
        .background(space.id == store.currentSpaceID ? Look.selected : Look.hovered,
                    in: .rect(cornerRadius: Look.pillRadius))
        .contentShape(.rect)
        .onTapGesture { store.switchTo(spaceID: space.id) }
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

/// A page in a Space's column. Not a `LibraryRow`: a column is 220pt wide, where a 56pt row
/// with a second line of grey under it would be one page filling a third of the column.
private struct PageRow: View {
    @EnvironmentObject var store: TabStore
    let space: Space
    let url: URL
    let pinned: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// An open tab knows what it is called; a url in spaces.json does not.
    private var title: String {
        store.tabs.first { $0.currentURL == url }.map { TidyTitles.title(for: $0) }
            ?? Library.label(for: url)
    }

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            SiteIcon(icon: store.favicons.icon(for: url))
            Text(title).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
            Spacer(minLength: Look.inset)
            if pinned {
                Image(systemName: "pin.fill").font(Look.caption).foregroundStyle(Look.inkQuiet)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.linkRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Look.selected : .clear, in: .rect(cornerRadius: Look.pillRadius))
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
            ("the rail is in Arc's order, Downloads first and History last",
             LibrarySection.allCases.map(\.rawValue)
                == ["downloads", "spaces", "archived", "history"]),
            ("every section's search field names the section",
             LibrarySection.allCases.allSatisfy { $0.searchPrompt.contains($0.title) }),
            ("a private window is offered no Spaces section",
             !LibrarySection.spaces.available(private: true)
                && LibrarySection.allCases.filter { $0.available(private: true) }.count == 3),
            ("an ordinary window is offered all four",
             LibrarySection.allCases.allSatisfy { $0.available(private: false) }),
        ]
        return out
    }
}
