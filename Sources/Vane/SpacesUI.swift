import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only the sliding sections, tint and footer track these per-frame gesture values.
/// Publishing them on TabStore would invalidate the entire browser on every scroll event.
@MainActor final class SpaceGesture: ObservableObject {
    @Published var drag: CGFloat = 0
    @Published var pull: CGFloat = 0
    @Published var swiping = false
    @Published var travelsFavorites = false
    var strip: [Space]?
    var neighbour: Space?
    var previewDirection = 0
    var previews: [UUID: SpacePreviewList] = [:]
}

/// The Spaces chrome: the header row's two clicks, the footer's dots and its `+`, the inline
/// editor Arc's `+` opens, "Move to Space" and the two-finger swipe.
///
/// In its own file so the sidebar's look and the sidebar's Spaces can be worked on at once.
/// The tokens are `Look`'s, extended rather than edited.

extension Look {
    /// The strip sliding sideways as the Space changes. A touch longer than `appear`: it is
    /// the whole column moving, and at 0.15 it read as a flicker rather than as travel.
    static let spaceSlide = Animation.easeOut(duration: 0.24)
    /// The strip finishing a swipe: the rest of the travel after the fingers leave, and the
    /// spring back when they did not go far enough. A spring rather than an ease because the
    /// gesture handed it a velocity and an ease throws that away — the strip has to leave the
    /// fingers at the speed they left it at.
    static let spaceSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// A committed swipe should hand focus to the destination promptly. Keep its final
    /// travel short; canceled gestures still use the more forgiving return spring.
    static let spaceLanding = Animation.spring(response: 0.16, dampingFraction: 0.9)
    /// How many rows the neighbouring Space's preview draws. Past what a sidebar shows at
    /// once the rows are scrolled-off content nobody sees, costing a favicon lookup each.
    static let spacePreviewRows = 16
    /// The dot's hit target — `Look.dot` is 6pt, which is not a thing anyone can hit or
    /// drop a tab onto.
    static let spaceDotHit: CGFloat = 20
}

// MARK: - The Space's name

/// The space's name in the sidebar header, which is a label until it is being renamed and a
/// field while it is. Arc renames in place; an OS alert for two words is a modal dialog for
/// something the user is already looking at.
struct SpaceName: View {
    @ObservedObject var store: TabStore
    let space: Space?
    /// What a window outside any Space shows instead — the profile's name.
    let fallback: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var renaming: Bool { space.map { store.renamingSpace == $0.id } ?? false }

    var body: some View {
        if let space, renaming {
            TextField("Space name", text: $draft)
                .textFieldStyle(.plain)
                .font(Look.spaceTitle)
                .focused($focused)
                .onSubmit { commit(space) }
                // Escape reverts. `onExitCommand` and not a key handler: the field is first
                // responder, and Escape has to leave the field rather than the window.
                .onExitCommand { store.renamingSpace = nil }
                .onAppear { draft = space.name; focused = true }
                // Clicking away commits, the way renaming a file in the Finder does — the
                // alternative is a field the user has to press Return in to be rid of.
                .onChange(of: focused) { _, now in if !now { commit(space) } }
                .accessibilityLabel("Space name")
        } else {
            Text(space?.name ?? fallback).font(Look.spaceTitle)
        }
    }

    private func commit(_ space: Space) {
        defer { store.renamingSpace = nil }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != space.name else { return }
        var edited = space
        edited.name = name
        store.update(space: edited)
        rebuild()                       // the Spaces menu lists the names
    }
}

/// The Space picker uses the same custom surface as the footer's creation menu.
@MainActor func showSpaceList(_ store: TabStore, anchor: ChromeMenuAnchor) {
    let items = store.strip.enumerated().map { n, space in
        ChromeMenuItem(title: space.name, symbol: space.icon ?? "cloud",
                       shortcut: n < 9 ? "⌃\(n + 1)" : "",
                       checked: store.currentSpaceID == space.id) {
            store.switchTo(space: space); rebuild()
        }
    } + [ChromeMenuItem(title: "New Space", symbol: "rectangle.stack.badge.plus", startsGroup: true) {
        store.newSpace(); rebuild()
    }]
    anchor.show(items, title: "Spaces")
}

// MARK: - Creating a Space

/// The footer's `+`. Arc does not ask for a name first: the Space appears, and its name,
/// icon and colour are edited in place in a small panel hanging off the button. This is that
/// button and that panel.
struct NewSpaceButton: View {
    @EnvironmentObject var store: TabStore
    @StateObject private var menuAnchor = ChromeMenuAnchor()

    var body: some View {
        Button {
            let shortcut = Keybindings.binding(for: .newTab)
            menuAnchor.show([
                ChromeMenuItem(title: "New Space", symbol: "rectangle.stack.badge.plus") {
                    store.newSpace()
                },
                ChromeMenuItem(title: "New Folder", symbol: "folder") { store.newFolder() },
                ChromeMenuItem(title: "New Easel", symbol: "paintpalette",
                               shortcut: Keybindings.binding(for: .newEasel).display) { store.openEasel(create: true) },
                ChromeMenuItem(title: "New Tab", symbol: "plus.square",
                               shortcut: shortcut == .unassigned ? "" : shortcut.display,
                               startsGroup: true) { store.newTab(nil) },
            ], above: true, title: "Create")
        } label: {
            Image(systemName: "plus")
                .frame(width: Look.rowTarget, height: Look.rowTarget).contentShape(.rect)
        }
            .buttonStyle(.plain)
            .background(ChromeMenuAnchorView(anchor: menuAnchor))
            .foregroundStyle(Look.inkSecondary)
            .help("New Space, Folder, Easel, or Tab")
            .accessibilityLabel("New Space, Folder, Easel, or Tab")
            .popover(isPresented: Binding(get: { store.editingSpace != nil },
                                          set: { if !$0 { store.editingSpace = nil } }),
                     arrowEdge: .top) {
                // The strip, not this profile's list: `+` can make a Space in another
                // profile, and the editor that opens on it hangs off this same button.
                if let id = store.editingSpace, let space = store.strip.first(where: { $0.id == id }) {
                    ThemeEditor(store: store, space: space, naming: true)
                }
            }
    }
}

// MARK: - The footer's dots

/// The dot being dragged, for a reorder. Separate from `Dragging`, which carries a *tab*: a
/// dot is a drop target for both, and the two have to be told apart before the drop lands.
@MainActor final class SpaceDragging: ObservableObject {
    static let shared = SpaceDragging()
    @Published var id: UUID?
}

/// A footer dot as a drop target. A tab dropped on it moves into that Space (Arc's shortcut
/// for "Move to Space"); a dot dropped on it reorders the strip.
struct SpaceDrop: DropDelegate {
    let store: TabStore
    let space: Space
    @Binding var over: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // A tab may not cross profiles: its page belongs to this profile's cookie jar and its
        // history, and `Spaces.move` only ever writes into a Space this store owns. Refused
        // here rather than in `performDrop` so the dot never lights up as somewhere to drop.
        if Dragging.shared.tab != nil { return space.profileID == store.profileID }
        return SpaceDragging.shared.id.map { $0 != space.id } ?? false
    }
    func dropEntered(info: DropInfo) { over = true }
    func dropExited(info: DropInfo) { over = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        if Dragging.shared.tab != nil {
            // A dragged multi-select moves as one, in the order its rows were drawn.
            let (tabs, _) = Dragging.shared.takeAll()
            // `Spaces.move` closes each tab and `close` prunes the selection, so a dragged
            // selection empties itself and a drag of some other row leaves it alone.
            tabs.forEach { Spaces.move($0, to: space.id, as: .today, from: store) }
            axAnnounce(tabs.count == 1 ? "Moved to \(space.name)."
                       : "Moved \(tabs.count) tabs to \(space.name).")
            return true
        }
        guard let dragged = SpaceDragging.shared.id else { return false }
        SpaceDragging.shared.id = nil
        // The strip runs across profiles, but an *order* only exists inside one: dragging a
        // dot onto another profile's would have to change which profile the Space belongs to,
        // which is what the context menu's "Set Profile" is for. So the drop is simply
        // refused unless both ends are the same profile's, and the list it reorders is that
        // profile's own rather than the strip's.
        let list = ProfileManager.shared.spaces(for: space.profileID)
        guard let from = list.firstIndex(where: { $0.id == dragged }),
              let to = list.firstIndex(where: { $0.id == space.id }) else { return false }
        // A dot dropped on a dot means "put it where that one is", so a rightward drag has to
        // land *after* the target — which is what `reordered` reads `to` as.
        store.reorderSpaces(from: from, to: to > from ? to + 1 : to, in: space.profileID)
        return true
    }
}

/// What a dot hands over when it is the thing being dragged.
@MainActor func spaceDragPayload(_ space: Space) -> NSItemProvider {
    let id = space.id
    // Next turn, not now: a state change inside the drag's own start re-renders the dot under
    // the pointer and SwiftUI drops the drag with it. Same reason as `dragPayload`.
    DispatchQueue.main.async { SpaceDragging.shared.id = id }
    return NSItemProvider(object: id.uuidString as NSString)
}

// MARK: - Move to Space

/// "Move to Space ▸ Work ▸ Pinned", under the tab context menu's own `Move To`. Arc's wording
/// and Arc's two destinations; Favourites is not among them because a favourite is in every
/// Space already.
struct MoveToSpaceMenu: View {
    let store: TabStore
    let tab: Tab

    var body: some View {
        // Never in a private window: it is in no Space, so every Space in the profile would
        // look like somewhere to move to — and moving there writes the page down.
        let others = store.isPrivate ? [] : store.spaces.filter { $0.id != store.currentSpaceID }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { space in
                    Menu(space.name) {
                        Button("Pinned") { Spaces.move(tab.id, to: space.id, as: .pinned, from: store) }
                        Button("Today") { Spaces.move(tab.id, to: space.id, as: .today, from: store) }
                    }
                }
            }
            .disabled(!TabAddress.restorable(tab.currentURL))
        }
    }
}

// MARK: - Switching: the slide and the swipe

extension View {
    /// The sidebar's Space-owned sections sliding in from the direction of travel while the
    /// tint cross-fades under them. Within a profile the shared favourites stay in place;
    /// at a profile boundary the grid travels with the incoming profile's sections.
    func spaceSlide(_ store: TabStore) -> some View { modifier(SpaceSlide(store: store)) }

    /// Two-finger horizontal swipe on the sidebar switches Space.
    func spaceSwipe(_ store: TabStore) -> some View { modifier(SpaceSwipe(store: store)) }
}

/// Profile favourites travel with the incoming Space only at a profile boundary.
/// Observing the gesture here keeps the rest of the browser out of per-frame updates.
struct SpaceSidebarStrip<Favorites: View, Sections: View>: View {
    let store: TabStore
    let favorites: Favorites
    let sections: Sections
    private let favoriteCount: Int
    @ObservedObject private var gesture: SpaceGesture
    @ObservedObject private var sidebar = SidebarWidth.shared

    init(store: TabStore, favorites: Favorites, sections: Sections) {
        self.store = store
        self.favorites = favorites
        self.sections = sections
        favoriteCount = store.tabs.filter { $0.kind == .favourite }.count
        gesture = store.spaceGesture
    }

    var body: some View {
        // Keep both sections in one tree when a gesture starts, reverses or springs back.
        // Only profile boundaries move the grid; ordinary Space switches leave it fixed.
        VStack(spacing: Look.rowGap) {
            favorites.offset(x: gesture.travelsFavorites ? gesture.drag : 0)
            sections.spaceSlide(store)
        }
        .overlay(alignment: .topLeading) { preview }
    }

    @ViewBuilder private var preview: some View {
        let drag = gesture.drag
        if gesture.swiping, let space = gesture.neighbour {
            let preview = store.swipePreview(in: space)
            preview.equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                // Within a profile the grid stays put, so its ghost starts below it.
                // Across profiles the ghost includes its own grid and starts at the top.
                .padding(.top, preview.includingFavorites ? 0 : favoriteHeight)
                .offset(x: drag + CGFloat(gesture.previewDirection) * sidebar.width)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var favoriteHeight: CGFloat {
        guard favoriteCount > 0 else { return 0 }
        let columns = SidebarWidth.favouriteColumns(favoriteCount, width: sidebar.width)
        let rows = (favoriteCount + columns - 1) / columns
        // Tile rows, their gaps, and the inset before the Space heading. Matches Favorites.
        return CGFloat(rows) * (Look.tileHeight + Look.inset)
    }
}

private struct SpaceSlide: ViewModifier {
    @ObservedObject var store: TabStore
    @ObservedObject private var gesture: SpaceGesture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: TabStore) {
        self.store = store
        gesture = store.spaceGesture
    }

    func body(content: Content) -> some View {
        let forwards = store.spaceDirection > 0
        content
            // The identity is the Space, so a switch is a removal and an insertion rather
            // than a list quietly changing under the pointer — which is the only way SwiftUI
            // will run a transition on it at all.
            .id(store.currentSpaceID)
            .transition(.asymmetric(
                insertion: .move(edge: forwards ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forwards ? .leading : .trailing).combined(with: .opacity)))
            // A swipe has already carried the sections to where the new Space's preview was
            // standing; letting this run on top would slide the same content a second time.
            .animation(reduceMotion || gesture.swiping ? nil : Look.spaceSlide,
                       value: store.currentSpaceID)
            .offset(x: gesture.drag)
    }
}

/// The neighbouring Space's sidebar, as a ghost, for the width of a swipe: its name, its
/// pinned rows, its tabs.
///
/// Rows use already loaded tabs when available, and saved metadata otherwise. Previewing
/// another Space never creates a tab or loads a page.
/// Ceiling: a site never visited has no cached favicon. The label climbs the same ladder the
/// real row does — a typed name, the tidied name, the name it was pinned under, the title
/// the sidecar saved — and only a row nothing has ever named is its host.
struct SpacePreviewList: View, Equatable {
    let space: Space
    let liveTabs: [Tab]?
    private let identity = UUID()
    private let saved: [String: Parked]
    let rows: (pinned: [Row], today: [Row])
    private let todayCount: Int
    let favorites: [URL]
    let includingFavorites: Bool
    let pinnedCollapsed: Bool

    /// Capture once, before the preview moves. Decoding interaction states and rebuilding
    /// folders in body would repeat disk work on every frame of a populated Space swipe.
    init(space: Space, liveTabs: [Tab]?, state: Stash? = nil,
         favorites: [URL] = [], includingFavorites: Bool = false, pinnedCollapsed: Bool = false) {
        self.space = space
        self.liveTabs = state?.tabs ?? liveTabs
        self.favorites = favorites
        self.includingFavorites = includingFavorites
        self.pinnedCollapsed = pinnedCollapsed
        saved = Suspension.SpaceState.load(space: space.id, profileID: space.profileID,
                                            in: Store.directory)
        let pinned = pinnedCollapsed ? [] : Self.section(space: space, kind: .pinned, tabs: self.liveTabs,
                                                         liveShape: state?.pins, splits: state?.splits ?? [])
        let today = Self.section(space: space, kind: .today, tabs: self.liveTabs,
                                 liveShape: state?.todayShape, splits: state?.splits ?? [])
        todayCount = self.liveTabs?.filter { $0.kind == .today }.count ?? space.tabURLs.count
        let room = max(0, Look.spacePreviewRows - pinned.count)
        rows = (Array(pinned.prefix(Look.spacePreviewRows)), Array(today.prefix(room)))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    enum Row {
        case folder(Folder, depth: Int = 0)
        case site(URL, TabKind, Tab? = nil, depth: Int = 0)

        var depth: Int {
            switch self {
            case .folder(_, let depth), .site(_, _, _, let depth): return depth
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.rowGap) {
            if includingFavorites { favoriteGrid }
            // The same metrics as `SpaceRow`, glyph for glyph: the ghost slides under the real
            // heading and any difference in size or ink reads as the row jumping on landing.
            HStack(spacing: 0) {
                HStack(spacing: Look.rowSpacing) {
                    Image(systemName: (space.icon ?? "cloud") == "cloud" ? "cloud.fill" : (space.icon ?? "cloud"))
                        .font(Look.spaceIcon).foregroundStyle(Look.inkPrimary).frame(width: Look.tileIcon)
                    Text(space.name).font(Look.spaceTitle).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                Color.clear.frame(width: Look.rowTarget)
            }
            .foregroundStyle(Look.inkTertiary)
            .padding(.leading, Look.rowInset)
            .padding(.trailing, Look.rowInset / 2)
            .frame(height: Look.rowHeight)
            .padding(.bottom, rows.pinned.isEmpty ? 0 : Look.sectionGap / 2 - Look.rowGap)
            // Offsets, not the url: the same page can be pinned and open at once, and two
            // rows sharing an id makes SwiftUI draw one of them.
            ForEach(Array(rows.pinned.enumerated()), id: \.offset) { row($0.element) }
            tidy
            newTab
            ForEach(Array(rows.today.enumerated()), id: \.offset) { row($0.element) }
            Spacer(minLength: 0)
        }
    }

    /// Use the same visible outline as the live sidebar, including nesting and collapse.
    /// Disk shapes name URLs; live shapes name Tab IDs, so restore the former with the
    /// same counted URL mapping as the real section (duplicates remain distinct).
    private static func section(space: Space, kind: TabKind, tabs: [Tab]?,
                                liveShape: Pins?, splits: [Split]) -> [Row] {
        let urls = kind == .pinned ? space.pinnedTabURLs ?? [] : space.tabURLs
        let loaded = tabs?.filter { $0.kind == kind }
        let opened: [(url: String, id: String)] = loaded.map { tabs in
            tabs.compactMap { tab in tab.pinnedURL.map { ($0.absoluteString, tab.id.uuidString) } }
        } ?? urls.enumerated().map { ($0.element.absoluteString, String($0.offset)) }
        let disk = TabStore.savedShape(kind, space: space.id, profileID: space.profileID)
        var shape = liveShape ?? TabStore.adopted(disk, opened: opened)
        if kind == .today { shape.removeEmptyFolders() }
        let byID = Dictionary(uniqueKeysWithValues: opened.map { ($0.id, $0.url) })
        let liveByID = Dictionary(uniqueKeysWithValues: (loaded ?? []).map { ($0.id.uuidString, $0) })
        let strip = (tabs ?? []).map { ($0.id, $0.kind) }
        return shape.visible.compactMap { visible in
            if let folder = visible.entry.folder { return .folder(folder, depth: visible.depth) }
            guard let id = visible.entry.tab, let name = byID[id], let url = URL(string: name) else { return nil }
            let tab = liveByID[id]
            if let tab, let split = splits.first(where: { $0.contains(tab.id) }),
               Split.lead(of: split.tabs, strip: strip) != tab.id { return nil }
            return .site(url, kind, tab, depth: visible.depth)
        }
    }

    private var favoriteGrid: some View {
        Group {
            if !favorites.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.inset),
                    count: SidebarWidth.favouriteColumns(favorites.count, width: SidebarWidth.shared.width)),
                    spacing: Look.inset) {
                    ForEach(Array(favorites.enumerated()), id: \.offset) { _, url in
                        SiteIcon(icon: Favicons.cache(for: space.profileID).icon(for: url), size: Look.tileIcon)
                            .frame(maxWidth: .infinity, minHeight: Look.tileHeight)
                            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
                    }
                }
                .padding(.bottom, Look.inset - Look.rowGap)
            }
        }
    }

    /// The divider under Pinned. Not the real `TidyRow`: its two buttons act on the window's
    /// own tabs, and a preview has none — the line is the part that holds the shape. The
    /// words only when the real row would have them (six Today tabs, `Look.tidyThreshold`):
    /// drawn always, they flashed in beside a bare line on every swipe into a small Space.
    private var tidy: some View {
        HStack(spacing: 8) {
            Hairline()
            if todayCount >= Look.tidyThreshold {
                Text("Tidy | Clear").font(Look.sectionCaption).foregroundStyle(Look.inkTertiary)
            }
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.tidyRow)
        .padding(.vertical, Look.sectionGap / 2 - Look.rowGap)
    }

    private var newTab: some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: "plus").frame(width: Look.rowIcon)
            Text("New Tab").font(Look.rowTitle).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Look.inkTertiary)
        .padding(.leading, Look.rowInset)
        .padding(.trailing, Look.rowTrailingInset)
        .frame(height: Look.rowHeight)
    }

    @ViewBuilder private func row(_ row: Row) -> some View {
        let tab = liveTab(for: row)
        let page = pageURL(for: row, saved: saved, tab: tab)
        let developer = page.map { DeveloperMode.wants($0, profile: space.profileID) } ?? false
        HStack(spacing: Look.rowSpacing) {
            switch row {
            case .folder(let f, _):
                Group {
                    if f.iconIsEmoji { Text(f.icon).font(Look.small) } else { Image(systemName: f.icon) }
                }
                .frame(width: Look.tileIcon)
                // A live folder wears its source here too, or the badge pops in on landing.
                .overlay(alignment: .bottomTrailing) {
                    if f.live != nil {
                        LiveBadge(live: LiveFolders.shared(for: space.profileID), folder: f.id)
                            .offset(x: Look.sourceBadgeOffset, y: Look.sourceBadgeOffset)
                    }
                }
                Text(f.name).font(Look.folderTitle).lineLimit(1).foregroundStyle(Look.inkPrimary)
            case .site(let url, _, _, _):
                SiteIcon(icon: Favicons.cache(for: space.profileID).icon(for: url), size: Look.rowIcon)
                LivePRTitle(title: title(for: row),
                            pr: nil, developerEndpoint: developer ? DeveloperMode.endpoint(page) : nil)
                    .font(Look.rowTitle).lineLimit(1)
                    .foregroundStyle(Look.inkPrimary)
            }
            Spacer(minLength: 0)
            if case .folder(let folder, _) = row {
                Image(systemName: "chevron.down")
                    .font(Look.rowGlyph).foregroundStyle(Look.inkSecondary)
                    .rotationEffect(.degrees(folder.collapsed ? -90 : 0))
            }
        }
        .padding(.leading, Look.rowInset)
        .padding(.trailing, Look.rowTrailingInset)
        .frame(height: Look.rowHeight)
        .overlay { if developer { DeveloperTabBorder() } }
        .padding(.leading, CGFloat(row.depth) * Look.folderIndent)
    }

    func title(for row: Row) -> String { title(for: row, saved: saved) }

    func title(for row: Row, saved: [String: Parked]) -> String {
        switch row {
        case .folder(let folder, _): return folder.name
        case .site(let url, let kind, _, _):
            return liveTab(for: row).map { TidyTitles.title(for: $0) }
                ?? TidyTitles.previewName(for: url, in: space.profileID,
                    saved: saved[url.absoluteString]?.title, stays: kind != .today)
        }
    }

    private func liveTab(for row: Row) -> Tab? {
        guard case .site(let url, let kind, let live, _) = row else { return nil }
        return live ?? liveTabs?.first { $0.kind == kind && $0.pinnedURL == url }
    }

    private func pageURL(for row: Row, saved: [String: Parked], tab: Tab?) -> URL? {
        guard case .site(let url, _, _, _) = row else { return nil }
        return tab?.currentURL ?? saved[url.absoluteString]?.page ?? url
    }
}

extension TabStore {
    func swipeNeighbour(for drag: CGFloat) -> Space? {
        guard drag != 0, let index = swipeStrip.firstIndex(where: { $0.id == currentSpaceID }) else { return nil }
        let next = drag < 0 ? index + 1 : index - 1
        return swipeStrip.indices.contains(next) ? swipeStrip[next] : nil
    }

    /// Cache the complete visual state once per neighbour, including a parked profile.
    func swipePreview(in space: Space) -> SpacePreviewList {
        if spaceSwiping, let preview = spaceGesture.previews[space.id] { return preview }
        let state = previewState(in: space)
        let owner = previewOwner(for: space)
        // Shared content can come from another window; presentation must come from this one.
        let presentationOwner = space.profileID == profileID ? self : TabStore.all.first {
            $0.profileID == space.profileID && window != nil && $0.parkedIn === window
        }
        let favorites = owner?.tabs.filter { $0.kind == .favourite }.compactMap(\.pinnedURL)
            ?? (UserDefaults.vane.stringArray(forKey: TabStore.defaultsKey(.favourite, space.profileID)) ?? [])
                .compactMap { URL(string: $0) }
        let preview = SpacePreviewList(space: space, liveTabs: state?.tabs, state: state,
                                       favorites: favorites, includingFavorites: space.profileID != profileID,
                                       pinnedCollapsed: presentationOwner?.collapsedPinnedSpaces.contains(space.id) ?? false)
        if spaceSwiping { spaceGesture.previews[space.id] = preview }
        return preview
    }

    private func previewOwner(for space: Space) -> TabStore? {
        if space.profileID == profileID { return self }
        return TabStore.all.first { $0.profileID == space.profileID && $0.parkedIn === window && window != nil }
            ?? TabStore.all.first { $0.profileID == space.profileID && $0.sharesTabs }
    }

    func previewState(in space: Space) -> Stash? {
        guard let owner = previewOwner(for: space) else { return nil }
        if owner !== self { return owner.previewState(in: space) }
        if currentSpaceID == space.id {
            return Stash(tabs: tabs.filter { $0.kind != .favourite }, pins: pins, todayShape: todayShape,
                         splits: splits, current: current, fingerprint: "")
        }
        if let shared = SharedTabs.state(for: self, space: space.id) { return shared }
        guard let kept = stashes[space.id], kept.fingerprint == fingerprint(of: space.id) else { return nil }
        return kept
    }

    func previewTabs(in space: Space) -> [Tab]? { previewState(in: space)?.tabs }

}

private struct SpaceSwipe: ViewModifier {
    let store: TabStore
    @State private var monitor = SwipeMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.install(store) }
            .onDisappear { monitor.remove() }
    }
}

/// The scroll-wheel monitor behind the swipe. A local `NSEvent` monitor rather than a view
/// that overrides `scrollWheel(with:)`: the sidebar's `ScrollView` is an `NSScrollView` and
/// gets the event first, so anything sitting behind it never sees one.
///
/// Its only job is to turn `NSEvent`s into `Spaces.Swipe`'s vocabulary and to put the answer
/// on the store. Everything that can be got wrong — the threshold, the velocity, the band at
/// the ends, the one-commit rule — lives in the pure state machine, where `check()` can hold
/// it to account.
@MainActor final class SwipeMonitor {
    private var monitor: Any?
    /// Weak, and kept, so `abort` has something to put back when the gesture is taken away
    /// rather than finished.
    private weak var store: TabStore?
    private var watchers: [any NSObjectProtocol] = []
    private var swipe = Spaces.Swipe()
    /// The previous event's timestamp, for the velocity. 0 means "no sample yet".
    private var last: TimeInterval = 0
    /// True while the landing spring is running, so a stray second fingers-up cannot spring
    /// the strip home over the top of it.
    private var landing = false
    /// The strip as it was when this gesture was claimed — every profile's Spaces, which is
    /// what a swipe walks. `store.strip` reads and decodes one `spaces.json` per profile every
    /// time it is touched, and a gesture is a hundred events.
    private var list: [Space] = []

    /// Which way a gesture turned out to be going. Undecided until it has travelled far
    /// enough to have an answer — see `mine`.
    private enum Claim { case undecided, mine, theirs }
    private var claim = Claim.undecided
    private var travelled = (h: CGFloat(0), v: CGFloat(0))

    func install(_ store: TabStore) {
        guard monitor == nil else { return }
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak store] event in
            guard let store, self.mine(event, store) else { return event }
            let phase = Self.phase(of: event)
            let width = SidebarWidth.shared.width
            let dt = self.last > 0 ? event.timestamp - self.last : 0
            self.last = event.timestamp
            // The Create a Space form is one slot past the last Space: a swipe back from it
            // is Cancel, the same as ⎋, and a swipe further on is the band. Its offset is
            // never applied — the form does not slide, it goes.
            let creating = store.creatingSpace
            let index = creating ? self.list.count
                : (self.list.firstIndex { $0.id == store.currentSpaceID } ?? 0)
            let count = creating ? self.list.count + 1 : self.list.count
            let creatable = !store.isPrivate && !store.isLittle && !creating
            let out = self.swipe.feed(dx: event.scrollingDeltaX, dt: dt, phase: phase,
                                      width: width, count: count, index: index,
                                      create: creatable)
            if creating {
                if let direction = out.commit, direction < 0 { store.cancelCreatingSpace() }
                if phase == .ended || phase == .cancelled || event.momentumPhase.contains(.ended) { self.forget() }
                return nil
            }
            if let offset = out.offset {
                store.spaceSwiping = true
                store.spaceDrag = offset             // straight on, no animation: it is the fingers
            }
            store.spacePull = out.pull
            if let direction = out.commit {
                if creatable, direction > 0, index == self.list.count - 1 {
                    self.create(store)
                } else {
                    if self.list.indices.contains(index + direction) {
                        self.land(direction, to: self.list[index + direction], width: width, store: store)
                    } else {
                        self.settle(store)
                    }
                }
            } else if phase == .ended || phase == .cancelled, !self.landing {
                // Not while landing: a `.cancelled` followed by an `.ended` would otherwise
                // spring the strip home over the top of the spring taking it the other way.
                self.settle(store)
            }
            // The verdict is what carries the fingers-up event, which has no deltas of its
            // own to be judged on; past the end of the gesture it must not carry the next
            // one. The momentum tail re-decides itself, on deltas that are still going the
            // way the fingers were.
            if phase == .ended || phase == .cancelled || event.momentumPhase.contains(.ended) { self.forget() }
            return nil              // swallowed, so the tab list does not scroll sideways too
        }
        // The fingers can be taken away without an `.ended`: ⌘S hides the sidebar mid-swipe
        // and `mine`'s own guard then drops the rest of the gesture, the window can lose key,
        // the app can deactivate. Each of those leaves the strip parked sideways with
        // `spaceSwiping` stuck true, and nothing short of another swipe would put it back.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            watchers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.abort() }
                })
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
        abort()
        store = nil
    }

    /// Everything a finished gesture forgets, without touching the strip: the next gesture
    /// starts from scratch whether this one committed, sprang back or was interrupted.
    private func forget() {
        swipe = Spaces.Swipe()
        claim = .undecided
        travelled = (0, 0)
        last = 0
        list = []
    }

    /// The gesture is gone rather than finished: put the strip back where an idle sidebar
    /// has it. A cut, not a spring — the fingers have already left, and there is nothing
    /// left for a spring to be the tail of.
    func abort() {
        let landed = landing
        landing = false
        forget()
        guard let store, !landed, store.spaceDrag != 0 || store.spaceSwiping else { return }
        store.spaceDrag = 0
        store.spacePull = 0
        store.spaceSwiping = false
    }

    private static func phase(of event: NSEvent) -> Spaces.Swipe.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.cancelled) { return .cancelled }
        if event.phase.contains(.ended) { return .ended }
        return .changed
    }

    /// Over the line: run the rest of the travel out under the spring and swap the Space at
    /// the far end, where the preview is already standing exactly where the real sections
    /// are about to be — which is the whole reason the swap is invisible.
    func land(_ direction: Int, to target: Space, width: CGFloat, store: TabStore) {
        // Finish the preview's travel before swapping hosts, including across profiles.
        // Cached profile interfaces can be attached at rest without tearing down the page.
        guard !Motion.reduced else {
            store.spaceDrag = 0
            store.spaceSwiping = false
            store.switchTo(space: target)
            rebuild()
            return
        }
        let from = store.currentSpaceID
        landing = true
        withAnimation(Look.spaceLanding) {
            store.spaceDrag = -CGFloat(direction) * width
        } completion: { [weak store] in
            self.landing = false
            guard let store, store.window != nil, store.currentSpaceID == from else {
                // Somebody else got there first, or the window is gone: drop the offset and
                // leave the Space alone.
                store?.spaceDrag = 0
                store?.spaceSwiping = false
                return
            }
            // Keep the old Space in place until the preview has finished sliding in.
            // The incoming rows replace it at rest, without a second slide transition.
            store.switchTo(space: target)
            store.spaceDrag = 0
            rebuild()
            DispatchQueue.main.async { store.spaceSwiping = false }
        }
    }

    /// The plus is full: the form takes the sidebar, and the strip, which only banded,
    /// goes home underneath it. Nothing is made yet — Create Space is a button.
    private func create(_ store: TabStore) {
        withAnimation(Look.spaceSlide) {
            store.spacePull = 0
            store.creatingSpace = true
        }
        settle(store)
    }

    /// Not far enough, or nowhere to go: the strip goes home.
    private func settle(_ store: TabStore) {
        withAnimation(Look.spaceSpring) { store.spacePull = 0 }
        guard store.spaceDrag != 0 else { store.spaceSwiping = false; return }
        guard !Motion.reduced else {
            store.spaceDrag = 0
            store.spaceSwiping = false
            return
        }
        withAnimation(Look.spaceSpring) { store.spaceDrag = 0 } completion: {
            store.spaceSwiping = false
        }
    }

    /// A horizontal trackpad swipe, over this window's sidebar, decided once per gesture.
    /// Everything else — a mouse wheel, a scroll down the tab list, a scroll over the page,
    /// anything while the command bar or the Library panel is over the sidebar — is left
    /// alone for whoever it was meant for.
    private func mine(_ event: NSEvent, _ store: TabStore) -> Bool {
        // Above the guard on purpose: a gesture that starts over the page card still has to
        // clear the last one's verdict, or a swipe made over the sidebar goes on claiming
        // events long after the fingers have moved somewhere else.
        if event.phase.contains(.began) { forget() }
        guard event.hasPreciseScrollingDeltas, event.window === store.window,
              store.sidebarShown, !store.libraryOpen, store.palette == nil,
              event.locationInWindow.x < SidebarWidth.shared.width
        else { return false }
        switch claim {
        case .mine:   return true
        case .theirs: return false
        case .undecided: break
        }
        travelled.h += abs(event.scrollingDeltaX)
        travelled.v += abs(event.scrollingDeltaY)
        // A gesture that has gone this far down is a scroll, whatever it does next: a flick
        // down a long tab list wanders sideways as the fingers roll, and a monitor that
        // re-asks on every frame will eventually catch one of those wobbles and eat the rest
        // of the flick.
        if travelled.v >= Self.verticalVeto { claim = .theirs; return false }
        // Undecided until there is enough travel to have a direction at all — the opening
        // frames of any two-finger gesture are a pixel of noise in both axes.
        guard travelled.h + travelled.v >= Self.lockDistance else { return false }
        // 1.5, not 1: even a deliberate sideways swipe drifts down a little, and at parity
        // that drift is enough to lose the toss.
        claim = travelled.h > travelled.v * 1.5 ? .mine : .theirs
        guard claim == .mine else { return false }
        // The first claimed event is the gesture's beginning as far as the state machine is
        // concerned: the `.began` that opened it carried no deltas and went to the tab list.
        swipe = Spaces.Swipe()
        last = 0
        list = store.strip
        return true
    }

    /// Points of travel, in both axes together, before the gesture is given a direction.
    private static let lockDistance: CGFloat = 10
    /// …and points *down* after which it can never be a Space swipe, however far it then
    /// wanders sideways.
    private static let verticalVeto: CGFloat = 6
}

// MARK: - Pull to create

/// Arc's plus at the sidebar's edge: a ring that fills as the fingers pull past the last
/// Space, and a form the moment it is full. Overlaid on the sidebar's scroll view, trailing
/// and centred, so it sits where the pull is coming from.
struct PullPlus: View {
    @ObservedObject private var gesture: SpaceGesture

    init(store: TabStore) { gesture = store.spaceGesture }

    var body: some View {
        let pull = gesture.pull
        let ring = min(1, pull)
        let solid = max(0, pull - 1)
        ZStack {
            Circle().fill(Look.barFill)
            // The second stage: the circle fills from the centre out, and only a full one
            // makes a Space. The plus turns dark against it so it stays a plus.
            Circle().fill(Look.inkPrimary).scaleEffect(solid)
            Circle().stroke(Look.inkTertiary, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Look.inkPrimary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(solid > 0.5 ? Look.barFill : Look.inkPrimary)
        }
        .frame(width: Look.pullPlus, height: Look.pullPlus)
        // Rides in from the edge with the first stage, and is gone the moment it is over:
        // the ring is the progress, not a control.
        .offset(x: Look.pullPlus / 2 - ring * Look.pullPlus)
        .opacity(pull > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Arc's Create a Space: the sidebar's sections give way to a name, a profile, a theme and
/// two buttons. Nothing exists until Create Space is pressed; Cancel puts the sections back.
struct CreateSpaceForm: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var name = ""
    @State private var profile: Profile?
    @State private var colorHex: String?
    @State private var theming = false
    @FocusState private var naming: Bool

    private var chosenProfile: Profile {
        profile ?? profiles.profiles.first { $0.id == store.profileID } ?? profiles.active
    }

    var body: some View {
        VStack(spacing: Look.inset) {
            Spacer(minLength: Look.rowHeight)
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Look.inkSecondary)
                .padding(.bottom, Look.inset)
            Text("Create a Space").font(Look.dialogTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Look.inkPrimary)
            Text("Separate your tabs for life, work, projects, and more.")
                .font(Look.text).foregroundStyle(Look.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Look.inset * 2)
            field {
                Image(systemName: "plus.square.dashed").frame(width: Look.tileIcon)
                TextField("Space name…", text: $name)
                    .textFieldStyle(.plain)
                    .focused($naming)
                    .onSubmit(create)
            }
            field {
                Image(systemName: "person.crop.square").frame(width: Look.tileIcon)
                Text("Profile")
                Spacer(minLength: 0)
                Menu {
                    ForEach(profiles.profiles) { p in
                        Button(p.name) { profile = p }
                    }
                } label: {
                    Text(chosenProfile.name).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
            }
            field {
                Image(systemName: "paintbrush").frame(width: Look.tileIcon)
                Button(colorHex == nil ? "Choose a Theme" : "Theme") { theming.toggle() }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                if let colorHex, let color = Color(hex: colorHex) {
                    Circle().fill(color).frame(width: 14, height: 14)
                }
            }
            if theming {
                // The first page of the theme editor's own swatches: one tap, one colour.
                // The full editor, with its gradients and grain, is a right-click away once
                // the Space exists.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Look.swatch * 0.6),
                                           spacing: Look.inset / 2)], spacing: Look.inset / 2) {
                    ForEach(Look.themeSwatches.prefix(Look.swatchPage), id: \.self) { hex in
                        Button { colorHex = hex; theming = false } label: {
                            Circle().fill(Color(hex: hex) ?? .clear)
                                .frame(width: Look.swatch * 0.6, height: Look.swatch * 0.6)
                                .overlay(Circle().stroke(Look.inkPrimary,
                                                         lineWidth: colorHex == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Theme colour \(hex)")
                    }
                }
                .padding(.vertical, Look.inset / 2)
            }
            Spacer(minLength: 0)
            Button(action: create) {
                Text("Create Space").font(Look.rowTitle).frame(maxWidth: .infinity)
                    .frame(height: Look.rowHeight)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(cleaned == nil)
            Button("Cancel") { store.cancelCreatingSpace() }
                .buttonStyle(.plain)
                .foregroundStyle(Look.inkSecondary)
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, Look.inset)
        }
        .padding(.horizontal, Look.inset)
        .onAppear { naming = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create a Space")
    }

    private var cleaned: String? { TabActions.cleanName(name) }

    private func create() {
        guard let cleaned else { return }
        store.createSpace(named: cleaned, in: chosenProfile, colorHex: colorHex)
    }

    @ViewBuilder private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Look.rowSpacing) { content() }
            .font(Look.rowTitle)
            .foregroundStyle(Look.inkPrimary)
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.rowHeight)
            .background(Look.selected, in: .rect(cornerRadius: Look.pillRadius))
    }
}
