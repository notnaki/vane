import AppKit
import SwiftUI

/// Arc's Library: the panel that slides out over the sidebar with everything that has left
/// the window but is not gone — archived tabs, downloads, every Space's pages, and history.
///
/// ponytail: a panel inside the window, not an NSWindow. Arc's Library *is* part of the
/// browser window — it pushes out from the sidebar's edge and the page stays put behind it —
/// and a separate window would need its own store, its own profile plumbing and its own
/// traffic lights to say the same thing. Ceiling: it is one panel per window and it cannot
/// be dragged out onto its own screen; History, which really is a window, is linked rather
/// than duplicated here.

// MARK: - Sections

/// The rail's four rows. `history` is the odd one: it opens `HistoryWindow`, because the
/// searchable history already exists as a window and a second copy of it would be a second
/// thing to keep honest.
enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case archived, downloads, spaces, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archived:  "Archived Tabs"
        case .downloads: "Downloads"
        case .spaces:    "Spaces"
        case .history:   "History"
        }
    }

    var icon: String {
        switch self {
        case .archived:  "tray.full"
        case .downloads: "arrow.down.circle"
        case .spaces:    "square.on.square"
        case .history:   "clock"
        }
    }
}

// MARK: - State

/// What the panel is showing. App-wide rather than per window: which section you were last
/// looking at is a preference, not a property of a window, and every window's panel opening
/// on the section you left is what Arc does.
@MainActor final class Library: ObservableObject {
    static let shared = Library()

    @Published var section: LibrarySection = .archived
    /// The Archived Tabs search field, live as it is typed.
    @Published var query = ""
    /// Arc's "Little Arc" chip: only the tabs that were archived out of a Little Arc window.
    @Published var littleArcOnly = false

    /// Opening at a section — the footer glyph, the Archive menu, ⇧⌘J, "Manage Spaces…".
    static func open(_ section: LibrarySection, in store: TabStore?) {
        shared.section = section
        if section == .history { HistoryWindow.show() }
        store?.libraryOpen = true
    }

    /// ⇧⌘L and the footer glyph: the same keystroke that opened it closes it again.
    static func toggle(_ section: LibrarySection, in store: TabStore?) {
        guard let store else { return }
        if store.libraryOpen && shared.section == section { store.libraryOpen = false; return }
        open(section, in: store)
    }
}

// MARK: - The rules, as pure functions

extension Library {
    /// Live search over the archive: the title or the address, ignoring case and accents,
    /// so "cafe" finds "Café". Substring rather than fuzzy — the archive is a list of pages
    /// the user has actually seen, and they type the word they remember.
    nonisolated static func matches(_ entry: Archive.Entry, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let how: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entry.title.range(of: q, options: how) != nil
            || entry.url.range(of: q, options: how) != nil
    }

    /// The list the Archived Tabs section draws, before it is cut into days: the chip first
    /// (it is a filter on what the list is *about*), then the query.
    nonisolated static func filtered(_ entries: [Archive.Entry],
                                     query: String, littleArcOnly: Bool) -> [Archive.Entry] {
        entries.filter { (!littleArcOnly || $0.isLittleArc) && matches($0, query) }
    }

    /// Entries under the day they were archived, newest day first. The day's name comes from
    /// `HistoryWindow.dayTitle` — "Today", "Yesterday", then the weekday and date — because
    /// two lists in the same app that group by day must not disagree about what to call one.
    nonisolated static func grouped(_ entries: [Archive.Entry], now: Date = .now,
                                    calendar: Calendar = .current)
        -> [(title: String, entries: [Archive.Entry])] {
        var out: [(title: String, entries: [Archive.Entry])] = []
        var day: Date?
        for entry in entries.sorted(by: { $0.at > $1.at }) {
            let start = calendar.startOfDay(for: entry.at)
            if start != day {
                out.append((HistoryWindow.dayTitle(start, now: now, calendar: calendar), []))
                day = start
            }
            out[out.count - 1].entries.append(entry)
        }
        return out
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
    /// ponytail ceiling: a real title needs a lookup in the history table per row. The
    /// current Space's rows do have titles, because those tabs are open.
    nonisolated static func label(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString)
            .replacingOccurrences(of: "www.", with: "", options: .anchored)
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

// MARK: - Moving a page between Spaces

extension Library {
    /// Dragging a row from one Space's column onto another's, and the right-click that says
    /// the same thing. Two cases, because a Space that is on screen and a Space that is not
    /// are stored in different places: the window owns the current Space's tabs until it
    /// saves them, and every other Space is a list of urls in spaces.json.
    static func move(_ url: URL, from source: UUID, to target: UUID, in store: TabStore) {
        guard source != target else { return }
        // On screen: it is a live tab, so hand it to the code that already moves live tabs —
        // that one carries the tab's scroll position and back/forward list with it.
        if source == store.currentSpaceID,
           let tab = store.tabs.first(where: { $0.currentURL == url }) {
            Spaces.move(tab.id, to: target, as: .today, from: store)
            return
        }
        guard var from = store.spaces.first(where: { $0.id == source }) else { return }
        from.tabURLs.removeAll { $0 == url }
        from.pinnedTabURLs?.removeAll { $0 == url }
        ProfileManager.shared.updateSpace(from)
        if target == store.currentSpaceID {
            // Into the Space this window is showing: open it, because the window's strip is
            // what gets written back to spaces.json and a url added behind its back would be
            // overwritten by the next save.
            store.newTab(url)
        } else if var to = store.spaces.first(where: { $0.id == target }) {
            to.tabURLs = Spaces.appending(url, to: to.tabURLs)
            ProfileManager.shared.updateSpace(to)
        }
        store.spacesChanged()
    }
}

/// The row being dragged between Space columns. `Dragging` carries a live `Tab.ID` and
/// `SpaceDragging` a Space; a Library row is neither — it is a url and the Space it came
/// from, which is all a move needs.
@MainActor final class LibraryDragging: ObservableObject {
    static let shared = LibraryDragging()
    @Published var url: URL?
    @Published var from: UUID?
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
    /// The Library's rail: wide enough for "Archived Tabs" beside its symbol at row type.
    static let libraryRail: CGFloat = 180
    /// The whole panel. It covers the sidebar and reaches over the page the way Arc's does —
    /// the page card does not move, it is simply behind this.
    static let libraryWidth: CGFloat = 660
    /// A Space's column in the Spaces section.
    static let spaceColumn: CGFloat = 260
}

// MARK: - The panel

/// Slides in from the window's leading edge over the sidebar. Lives in `BrowserWindow`'s
/// ZStack, so the page card behind it never re-lays out when it opens.
struct LibraryPanel: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var library = Library.shared

    var body: some View {
        HStack(spacing: 0) {
            rail
            Hairline().frame(width: 1, height: nil).frame(maxHeight: .infinity)
            content
        }
        .frame(width: Look.libraryWidth)
        .frame(maxHeight: .infinity)
        .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
        .background(Look.barMaterial, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius)
        .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
        .padding(Look.cardGap)
        // Escape closes it, the way every other floating surface in the window closes.
        // A zero-size button rather than `.onExitCommand`: the panel is not focused until
        // something inside it is clicked, and a cancel action is heard either way.
        .background {
            Button("Close Library") { store.libraryOpen = false }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .accessibilityAddTraits(.isModal)
        .onAppear { axAnnounce("Library, \(library.section.title).") }
    }

    // MARK: The rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Look.rowGap) {
            HStack(spacing: 0) {
                Text("Library").font(Look.heading).foregroundStyle(Look.inkSecondary)
                Spacer(minLength: 0)
                Button { store.libraryOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(Look.rowGlyph)
                    .foregroundStyle(Look.inkTertiary)
                    .help("Close the Library (\(Keybindings.binding(for: .showLibrary).display))")
                    .accessibilityLabel("Close the Library")
            }
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.topRow)
            .padding(.top, Look.topInset)

            ForEach(LibrarySection.allCases) { section in
                LibraryRailRow(section: section, selected: library.section == section) {
                    Library.open(section, in: store)
                    axAnnounce(section.title)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.inset)
        .padding(.bottom, Look.inset)
        .frame(width: Look.libraryRail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library sections")
    }

    // MARK: The content

    @ViewBuilder private var content: some View {
        Group {
            switch library.section {
            case .archived:  ArchivedTabsPane(archive: Archive.shared(for: store.profileID))
            case .downloads: DownloadsPane(downloads: Downloads.manager(for: store.profileID))
            case .spaces:    SpacesPane()
            case .history:   HistoryPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A rail row, in the sidebar's row look: a symbol in a favicon's box, a title beside it,
/// and the selection as a fill rather than a change of ink.
private struct LibraryRailRow: View {
    let section: LibrarySection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: section.icon).frame(width: Look.tileIcon)
                .foregroundStyle(Look.inkSecondary)
            Text(section.title).font(Look.rowTitle).lineLimit(1)
                .foregroundStyle(Look.inkPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.rowHeight)
        .background(selected ? Look.selected : (hovering ? Look.hovered : .clear),
                    in: .rect(cornerRadius: Look.pillRadius))
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

/// A pane's header: its title, and whatever the pane needs beside it.
private struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Look.inset) {
            Text(title).font(Look.heading).foregroundStyle(Look.inkPrimary)
            Spacer(minLength: Look.inset)
            trailing()
        }
        .padding(.horizontal, Look.cardInset)
    }
}

/// A pane's quiet button: Clear, Clear Archive…, Open History.
private struct PaneButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Look.small).foregroundStyle(Look.inkSecondary)
            .padding(.horizontal, Look.inset + 2)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
    }
}

// MARK: - Archived Tabs

private struct ArchivedTabsPane: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var archive: Archive
    @ObservedObject private var library = Library.shared
    @State private var hovered: Archive.Entry.ID?

    private var groups: [(title: String, entries: [Archive.Entry])] {
        Library.grouped(Library.filtered(archive.entries,
                                         query: library.query,
                                         littleArcOnly: library.littleArcOnly))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            PaneHeader(title: "Archived Tabs") {
                PaneButton(title: "Clear Archive…") { clear() }
                    .disabled(archive.entries.isEmpty)
                    .opacity(archive.entries.isEmpty ? 0.4 : 1)
            }
            search
            if groups.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Look.inset * 1.5) {
                        ForEach(groups, id: \.title) { group in
                            SettingsSection(group.title) {
                                SettingsCard { ForEach(group.entries) { row($0) } }
                            }
                        }
                    }
                    .padding(.bottom, Look.inset)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Archived Tabs")
    }

    private var search: some View {
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset - 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Look.inkTertiary)
                TextField("Search archived tabs", text: $library.query)
                    .textFieldStyle(.plain).font(Look.text)
            }
            .padding(.horizontal, Look.inset)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
            .accessibilityLabel("Search Archived Tabs")
            .accessibilityHint("Matches the title or the address of an archived tab.")

            // Arc's filter chip. A toggle rather than a segmented control: there are two
            // states and the off one is "everything", which needs no label of its own.
            Button { library.littleArcOnly.toggle() } label: {
                Text("Little Arc").font(Look.caption)
                    .foregroundStyle(library.littleArcOnly ? Look.inkPrimary : Look.inkSecondary)
                    .padding(.horizontal, Look.inset + 2)
                    .frame(height: Look.control)
                    .background(library.littleArcOnly ? Look.selected : Look.controlFill,
                                in: .rect(cornerRadius: Look.chipRadius))
            }
            .buttonStyle(.plain)
            .help("Only tabs archived from a Little Arc window")
            .accessibilityLabel("Little Arc only")
            .accessibilityAddTraits(library.littleArcOnly ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.horizontal, Look.cardInset)
    }

    private var empty: some View {
        Text(archive.entries.isEmpty
             ? "Nothing archived yet — a tab you close with \(Keybindings.binding(for: .closeTab).display) is kept here."
             : "No archived tab matches this filter.")
            .font(Look.text).foregroundStyle(Look.inkTertiary)
            .padding(.horizontal, Look.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ entry: Archive.Entry) -> some View {
        HStack(spacing: Look.inset) {
            SiteIcon(icon: URL(string: entry.url).flatMap(store.favicons.icon(for:)))
            VStack(alignment: .leading, spacing: Look.captionGap) {
                Text(entry.title).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(entry.url).font(Look.caption).foregroundStyle(Look.inkQuiet).lineLimit(1)
            }
            Spacer(minLength: Look.inset)
            if entry.isLittleArc {
                Text("Little Arc").font(Look.caption).foregroundStyle(Look.inkQuiet)
            }
            // Under the pointer only, the way Arc's restore icon appears: a list where every
            // row wears a button reads as a list of buttons.
            if hovered == entry.id {
                Button { store.restore(entry) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain).font(Look.caption).foregroundStyle(Look.inkSecondary)
                .help("Restore this tab")
                .accessibilityLabel("Restore \(entry.title)")
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(minHeight: Look.settingsRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered == entry.id ? Look.hovered : .clear)
        .contentShape(.rect)
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .onTapGesture { store.restore(entry) }
        .contextMenu {
            Button("Restore") { store.restore(entry) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
                axAnnounce("Link copied.")
            }
            Divider()
            Button("Remove from Archive") { archive.remove(entry.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue("Archived tab, \(entry.url)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this page again and takes it out of the archive.")
        .accessibilityAction { store.restore(entry) }
        .accessibilityAction(named: "Remove from Archive") { archive.remove(entry.id) }
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

// MARK: - Downloads

private struct DownloadsPane: View {
    @ObservedObject var downloads: Downloads
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            PaneHeader(title: "Downloads") {
                PaneButton(title: "Clear") { downloads.clear() }
                    .disabled(downloads.items.isEmpty)
                    .opacity(downloads.items.isEmpty ? 0.4 : 1)
            }
            if downloads.items.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(Look.text).foregroundStyle(Look.inkTertiary)
                    .padding(.horizontal, Look.cardInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    SettingsCard {
                        ForEach(downloads.items) { row($0) }
                    }
                    .padding(.bottom, Look.inset)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }

    private func row(_ item: Downloads.Item) -> some View {
        DownloadRow(item: item, downloads: downloads)
            .padding(.horizontal, Look.cardInset)
            .padding(.vertical, Look.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered == item.id ? Look.hovered : .clear)
            .contentShape(.rect)
            .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
            // Arc lets a finished download be dragged straight out of the Library into a
            // Finder window or another app. A file promise would be the thorough version;
            // the file is already on disk, so its url is the whole payload.
            .onDrag { provider(item) }
            .contextMenu {
                if item.status == .done {
                    Button("Open") { downloads.open(item) }
                    Button("Show in Finder") { downloads.reveal(item) }
                }
                Divider()
                Button("Remove from List") { downloads.forget(item) }
            }
    }

    private func provider(_ item: Downloads.Item) -> NSItemProvider {
        guard item.status == .done, let url = item.url,
              let p = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        return p
    }
}

// MARK: - Spaces

/// Arc's "Manage Spaces": every Space of this profile side by side with its pages, and a
/// page draggable from one column into another.
private struct SpacesPane: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            PaneHeader(title: "Spaces") {
                PaneButton(title: "New Space") { store.newSpace() }
            }
            if store.spaces.isEmpty {
                Text("This profile has no Spaces yet.")
                    .font(Look.text).foregroundStyle(Look.inkTertiary)
                    .padding(.horizontal, Look.cardInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Look.inset) {
                        ForEach(store.spaces) { SpaceColumn(space: $0) }
                    }
                    .padding(.horizontal, Look.cardInset)
                    .padding(.bottom, Look.inset)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.inset)
        // The columns are read off spaces.json, which is a file rather than a published
        // property: without this a move would not redraw the column it came out of.
        .id(store.spaceRevision)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }
}

private struct SpaceColumn: View {
    @EnvironmentObject var store: TabStore
    let space: Space
    @State private var over = false
    @State private var editing = false

    /// The Space this window is showing is live: its tabs are in the strip, not in
    /// spaces.json, and they have real titles. Every other Space is a list of urls.
    private var pinned: [URL] {
        space.id == store.currentSpaceID
            ? store.tabs.filter { $0.kind == .pinned }.compactMap(\.currentURL)
            : (space.pinnedTabURLs ?? [])
    }

    private var today: [URL] {
        space.id == store.currentSpaceID
            ? store.tabs.filter { $0.kind == .today }.compactMap(\.currentURL)
            : space.tabURLs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            header
            SettingsCard {
                if pinned.isEmpty && today.isEmpty {
                    Text("No pages").font(Look.caption).foregroundStyle(Look.inkQuiet)
                        .padding(.horizontal, Look.cardInset).frame(height: Look.linkRow)
                }
                ForEach(pinned, id: \.absoluteString) { PageRow(space: space, url: $0, pinned: true) }
                ForEach(today, id: \.absoluteString) { PageRow(space: space, url: $0, pinned: false) }
            }
        }
        .frame(width: Look.spaceColumn)
        .padding(Look.inset / 2)
        .background(over ? Look.hovered : .clear, in: .rect(cornerRadius: Look.cardRadius))
        .onDrop(of: [.text], isTargeted: $over) { _ in drop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(space.name), \(pinned.count + today.count) page\(pinned.count + today.count == 1 ? "" : "s")")
    }

    private var header: some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: space.icon ?? "cloud").font(Look.spaceIcon)
                .foregroundStyle(Look.inkSecondary)
            Text(space.name).font(Look.rowTitle).lineLimit(1)
                .foregroundStyle(space.id == store.currentSpaceID ? Look.inkPrimary : Look.inkSecondary)
            Spacer(minLength: 0)
            Button { editing = true } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.plain).font(Look.rowGlyph).foregroundStyle(Look.inkTertiary)
                .help("Rename this Space, or change its icon and colour")
                .accessibilityLabel("Edit \(space.name)")
                // The sidebar's own editor, so a Space is renamed in one place in the app.
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    SpaceEditor(store: store, space: space)
                }
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.rowHeight)
        .background(space.id == store.currentSpaceID ? Look.selected : Look.hovered,
                    in: .rect(cornerRadius: Look.pillRadius))
        .contentShape(.rect)
        .onTapGesture { store.switchTo(spaceID: space.id) }
    }

    private func drop() -> Bool {
        over = false
        guard let url = LibraryDragging.shared.url,
              let from = LibraryDragging.shared.from, from != space.id else { return false }
        LibraryDragging.shared.url = nil
        LibraryDragging.shared.from = nil
        Library.move(url, from: from, to: space.id, in: store)
        axAnnounce("Moved to \(space.name).")
        return true
    }
}

private struct PageRow: View {
    @EnvironmentObject var store: TabStore
    let space: Space
    let url: URL
    let pinned: Bool
    @State private var hovering = false

    /// An open tab knows what it is called; a url in spaces.json does not.
    private var title: String {
        store.tabs.first { $0.currentURL == url }.map { TidyTitles.title(for: $0) }
            ?? Library.label(for: url)
    }

    var body: some View {
        HStack(spacing: Look.inset) {
            SiteIcon(icon: store.favicons.icon(for: url))
            Text(title).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
            Spacer(minLength: Look.inset)
            if pinned {
                Image(systemName: "pin.fill").font(Look.caption).foregroundStyle(Look.inkQuiet)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(height: Look.linkRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Look.hovered : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .onDrag { payload() }
        .contextMenu {
            Button("Open") { open() }
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != space.id }) { other in
                    Button(other.name) { Library.move(url, from: space.id, to: other.id, in: store) }
                }
            }
            Divider()
            Button("Copy URL") {
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
        store.libraryOpen = false
    }

    private func payload() -> NSItemProvider {
        // Next turn, not now: a state change inside the drag's own start re-renders the row
        // under the pointer and SwiftUI drops the drag with it. Same reason as `dragPayload`.
        let url = url, from = space.id
        DispatchQueue.main.async {
            LibraryDragging.shared.url = url
            LibraryDragging.shared.from = from
        }
        return NSItemProvider(object: url.absoluteString as NSString)
    }
}

// MARK: - History

/// History is a window (⌘Y), and this is the link to it rather than a second copy of it:
/// the searchable, day-grouped list already exists in `HistoryWindow`, and two lists over
/// one table is two things to keep honest.
private struct HistoryPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            PaneHeader(title: "History") {
                PaneButton(title: "Open History") { HistoryWindow.show() }
            }
            SettingsCard {
                Text("History opens in its own window (\(Keybindings.binding(for: .viewHistory).display)), "
                     + "where every page you have visited is searchable and grouped by day.")
                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Look.cardInset)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
    }
}

// MARK: - check

extension Library {
    /// The Library's rules, proved offline: how the archive is cut into days, what the
    /// search matches, what the Little Arc chip filters, and where Restore sends a tab.
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
        let groups = grouped(all, now: now, calendar: calendar)

        var out: [(String, Bool)] = [
            ("an empty archive groups into nothing", grouped([], now: now, calendar: calendar).isEmpty),
            ("archived tabs group by day, newest day first",
             groups.map(\.title) == ["Today", "Yesterday",
                                     HistoryWindow.dayTitle(older.at, now: now, calendar: calendar)]),
            ("today's archived tabs share one group", groups.first?.entries.count == 2),
            ("…newest first inside it",
             groups.first?.entries.map(\.url) == [today.url, earlier.url]),
            ("every entry lands in exactly one group",
             groups.flatMap(\.entries).count == 4
                && Set(groups.flatMap(\.entries).map(\.url)).count == 4),
            ("an out-of-order archive still makes one group per day",
             grouped([older, earlier, yesterday, today], now: now, calendar: calendar)
                .map(\.title) == groups.map(\.title)),
            ("the day headers are History's, so the two lists never disagree",
             grouped([today], now: now, calendar: calendar).first?.title
                == HistoryWindow.dayTitle(today.at, now: now, calendar: calendar)),
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
        ]

        // The Little Arc chip.
        out += [
            ("the Little Arc chip keeps only Little Arc entries",
             filtered(all, query: "", littleArcOnly: true).map(\.url) == [yesterday.url]),
            ("…and off, it keeps everything", filtered(all, query: "", littleArcOnly: false).count == 4),
            ("the chip and the search field compose",
             filtered(all, query: "little", littleArcOnly: true).count == 1
                && filtered(all, query: "swift", littleArcOnly: true).isEmpty),
            ("an entry from before the flag existed is not a Little Arc entry",
             !today.isLittleArc && yesterday.isLittleArc),
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

        out.append(("every section has a symbol and a title",
                    LibrarySection.allCases.allSatisfy { !$0.icon.isEmpty && !$0.title.isEmpty }))
        return out
    }
}
