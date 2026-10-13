import AppKit
import SwiftUI

/// Search, organize and edit the active profile's bookmarks in one native window.
@MainActor enum BookmarkManager {
    private static var window: NSWindow?
    private static var profileID: UUID?
    static let refreshNotification = Notification.Name("vane.feel05.bookmarkRefresh")
    static let focusNotification = Notification.Name("vane.feel05.bookmarkFocus")

    enum KeyCommand: Equatable { case previous, next, open }

    nonisolated static func actionProfile(window: UUID?, active: UUID) -> UUID {
        window ?? active
    }

    static var currentActionProfile: UUID {
        actionProfile(window: Windows.current?.profileID, active: ProfileManager.activeProfileID)
    }

    static func browserWindow(for profileID: UUID) -> TabStore? {
        if profileID == Profile.incognito.id {
            return Windows.current(in: profileID, isPrivate: true) ?? Windows.open(isPrivate: true)
        }
        return Windows.current(in: profileID)
            ?? ProfileManager.shared.profiles.first(where: { $0.id == profileID }).map {
                Windows.open(profile: $0)
            }
    }

    nonisolated static func keyboardSelection(ids: [Int64], selected: Set<Int64>,
                                               step: Int) -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        guard let selectedID = ids.first(where: selected.contains),
              let index = ids.firstIndex(of: selectedID) else { return [step < 0 ? ids.last! : ids.first!] }
        return [ids[min(max(index + step, 0), ids.count - 1)]]
    }

    nonisolated static func keyCommand(for key: KeyEquivalent,
                                        _ modifiers: EventModifiers) -> KeyCommand? {
        guard modifiers.isEmpty else { return nil }
        if key == .upArrow { return .previous }
        if key == .downArrow { return .next }
        if key == .return { return .open }
        return nil
    }

    static func show(profileID requested: UUID = ProfileManager.activeProfileID) {
        if let window {
            if profileID != requested || window.contentView == nil {
                window.contentView = SecondaryWindowStyle.host(BookmarkManagerView(profileID: requested),
                    minimumSize: NSSize(width: 620, height: 400))
            } else {
                NotificationCenter.default.post(name: refreshNotification, object: requested)
                NotificationCenter.default.post(name: focusNotification, object: requested)
            }
            profileID = requested
            window.title = title(for: requested)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        profileID = requested
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        made.title = title(for: requested)
        SecondaryWindowStyle.apply(to: made)
        made.isReleasedWhenClosed = false
        made.contentView = SecondaryWindowStyle.host(BookmarkManagerView(profileID: requested),
                minimumSize: NSSize(width: 620, height: 400))
        if !made.setFrameUsingName("VaneBookmarks") { made.center() }
        made.setFrameAutosaveName("VaneBookmarks")
        window = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func refresh(profileID requested: UUID) {
        guard let window, window.isVisible, profileID == requested else { return }
        NotificationCenter.default.post(name: refreshNotification, object: requested)
    }

    private static func title(for id: UUID) -> String {
        if id == Profile.incognito.id { return "Bookmarks — Incognito" }
        guard let profile = ProfileManager.shared.profiles.first(where: { $0.id == id }) else { return "Bookmarks" }
        return profile.id == ProfileManager.defaultID ? "Bookmarks" : "Bookmarks — \(profile.name)"
    }

    /// Store-level checks use an isolated database and exercise the same APIs the window
    /// calls. Kept here so the manager feature owns its fixture without widening Store.
    static func check() -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-bookmarks-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(path: directory.appendingPathComponent("bookmarks.db").path)
        let first = URL(string: "https://example.test/100%25")!
        let second = URL(string: "https://swift.test")!
        var out: [(String, Bool)] = []
        func expect(_ name: String, _ condition: Bool) { out.append((name, condition)) }
        let profileA = UUID(), profileB = UUID()
        expect("bookmark actions prefer the focused window's profile",
               actionProfile(window: profileB, active: profileA) == profileB)
        expect("bookmark actions fall back to the active profile without a browser window",
               actionProfile(window: nil, active: profileA) == profileA)
        expect("bookmark fixture imports pages", store.addBookmarks([(first, "A 100% Guide"), (second, "Swift")]) == 2)
        let duplicateImport = store.importBookmarks([
            BookmarkImportItem(url: first, title: "First source title", folder: "First"),
            BookmarkImportItem(url: first, title: "Later source title", folder: "Later")
        ])
        expect("a valid import with only existing urls reports zero new rather than failure",
               duplicateImport == BookmarkImportResult(imported: 0, folders: 0))
        let fresh = Store(path: directory.appendingPathComponent("import.db").path)
        let ordered = fresh.importBookmarks([
            BookmarkImportItem(url: first, title: "First source title", folder: "First", at: Date(timeIntervalSince1970: 20)),
            BookmarkImportItem(url: first, title: "Later source title", folder: "Later", at: Date(timeIntervalSince1970: 30))
        ])
        expect("the first duplicate in source order owns title and folder",
               ordered == BookmarkImportResult(imported: 1, folders: 1)
               && fresh.managedBookmarks().first?.title == "First source title"
               && fresh.managedBookmarks().first?.at == Date(timeIntervalSince1970: 20)
               && fresh.bookmarkFolders().map(\.name) == ["First"])
        let bulk = Store(path: directory.appendingPathComponent("bulk.db").path)
        let many = (0..<1_005).map { (URL(string: "https://bulk.test/\($0)")!, "Page \($0)") }
        _ = bulk.addBookmarks(many)
        let manyIDs = Set(bulk.managedBookmarks(limit: 2_000).map(\.id))
        let bulkFolder = bulk.createBookmarkFolder(named: "Bulk")
        expect("bulk operations chunk beyond the conservative SQLite bind ceiling",
               manyIDs.count == 1_005
               && bulkFolder.map { bulk.moveBookmarks(manyIDs, to: $0.id) } == true
               && bulk.deleteBookmarks(manyIDs) && bulk.managedBookmarks().isEmpty)
        let folder = store.createBookmarkFolder(named: "  Reading  ")
        expect("folder names are trimmed", folder?.name == "Reading")
        let ids = Set(store.managedBookmarks().map(\.id))
        expect("bulk move puts every selected page in a folder",
               folder.map { store.moveBookmarks(ids, to: $0.id) && store.managedBookmarks(folderID: $0.id).count == 2 } == true)
        expect("search treats percent as text", store.managedBookmarks(matching: "%").count == 1)
        if let mark = store.managedBookmarks().first {
            expect("editing cannot collide with another bookmark url",
                   !store.updateBookmark(mark.id, url: mark.url == first.absoluteString ? second : first,
                                         title: mark.title, folderID: mark.folderID))
        }
        if let folder {
            expect("deleting a folder leaves its bookmarks unfiled",
                   store.deleteBookmarkFolder(folder.id) && store.managedBookmarks(unfiledOnly: true).count == 2)
        }
        expect("bulk delete removes every selected bookmark",
               store.deleteBookmarks(ids) && store.managedBookmarks().isEmpty)
        let dated = Export.Row(url: first.absoluteString, title: "Guide", at: Date(timeIntervalSince1970: 10))
        let html = Export.bookmarksHTML([Export.BookmarkEntry(row: dated, folder: "Reading")])
        let parsed = Export.parseNetscapeEntries(html)
        expect("bookmark export round-trips folder names",
               parsed.count == 1 && parsed.first?.folder == "Reading" && parsed.first?.row == dated)
        let compact = "<DL><p><DT><H3>Work</H3><DL><p><DT><A HREF=\"https://compact.test\">Compact</A></DL><p></DL><p>"
        let compactParsed = Export.parseNetscapeEntries(compact)
        expect("folder import does not depend on line breaks",
               compactParsed.count == 1 && compactParsed.first?.folder == "Work")
        let chronological = [
            Export.BookmarkEntry(row: .init(url: "https://new.test", title: "New", at: Date(timeIntervalSince1970: 30)), folder: "Work"),
            Export.BookmarkEntry(row: .init(url: "https://old.test", title: "Old", at: Date(timeIntervalSince1970: 10)), folder: "Work")
        ]
        let roundTrip = Export.parseNetscapeEntries(Export.bookmarksHTML(chronological))
        let datedImport = Store(path: directory.appendingPathComponent("dated.db").path)
        let importedRoundTrip = datedImport.importBookmarks(roundTrip.compactMap { entry in
            URL(string: entry.row.url).map {
                BookmarkImportItem(url: $0, title: entry.row.title,
                                   folder: entry.folder, at: entry.importedAt)
            }
        })
        expect("bookmark export and import preserve row order and ADD_DATE",
               importedRoundTrip?.imported == 2
               && datedImport.managedBookmarks().map(\.url) == chronological.map(\.row.url)
               && datedImport.managedBookmarks().map(\.at) == chronological.map(\.row.at))
        let undated = Store(path: directory.appendingPathComponent("undated.db").path)
        _ = undated.importBookmarks([
            BookmarkImportItem(url: URL(string: "https://first-undated.test")!, title: "First", folder: nil),
            BookmarkImportItem(url: URL(string: "https://second-undated.test")!, title: "Second", folder: nil)
        ])
        expect("bookmarks without ADD_DATE keep deterministic source order",
               undated.managedBookmarks().map(\.title) == ["First", "Second"])
        expect("keyboard arrows choose adjacent rows and Return opens the chosen row",
               keyboardSelection(ids: [1, 2, 3], selected: [], step: 1) == [1]
               && keyboardSelection(ids: [1, 2, 3], selected: [1], step: 1) == [2]
               && keyboardSelection(ids: [1, 2, 3], selected: [2], step: -1) == [1]
               && keyCommand(for: .return, []) == .open
               && keyCommand(for: .return, .command) == nil)
        return out
    }
}

private enum BookmarkLocation: Hashable, Sendable {
    case all, unfiled, folder(String)
}

private struct BookmarkManagerView: View {
    let profileID: UUID
    @State private var query = ""
    @State private var location: BookmarkLocation = .all
    @State private var folders: [BookmarkFolder] = []
    @State private var marks: [Bookmark] = []
    @State private var selection: Set<Int64> = []
    @State private var editing: Bookmark?
    @State private var revision = 0
    @State private var keyboardRevision = 0
    @State private var resultGate = Feel05ResultGate<Request>()
    private var rowsAreCurrent: Bool { resultGate.isCurrent(request, refreshing: searching) }
    @State private var searching = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var store: Store { Store.store(for: profileID) }

    private struct Request: Equatable {
        let profileID: UUID
        let query: String
        let location: BookmarkLocation
        let revision: Int
    }
    private var request: Request {
        Request(profileID: profileID, query: query, location: location, revision: revision)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 170, idealWidth: 190, maxWidth: 230,
                          minHeight: 0, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: Look.cardInset) {
                SecondaryWindowHeader(title: "Bookmarks",
                    subtitle: "Keep your favourite pages close at hand.", icon: "bookmark")
                header
                list.overlay(alignment: .topLeading) {
                    if marks.isEmpty { empty }
                }
            }
            .padding(.top, Look.cardInset)
            .padding(.horizontal, Look.paneMargin)
            .padding(.bottom, Look.paneMargin)
            // Native split panes must be allowed to shrink below their ideal content height.
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .font(Look.text)
        .foregroundStyle(Look.inkPrimary)
        .background(Look.panelFill)
        .animation(Motion.reduced ? nil : Look.quick, value: location)
        .animation(Motion.reduced ? nil : Look.quick, value: selection.isEmpty)
        .onAppear { reload(); searchFocused = true }
        .onChange(of: query) { searching = true }
        .onChange(of: location) { searching = true }
        .task(id: request) {
            let asked = request
            searching = true
            if !asked.query.isEmpty { try? await Task.sleep(for: LocalSuggestionReader.debounce) }
            guard !Task.isCancelled else { return }
            let folderID: String?
            if case .folder(let id) = asked.location { folderID = id } else { folderID = nil }
            let results = await store.managedBookmarksAsync(matching: asked.query, folderID: folderID,
                                                            unfiledOnly: asked.location == .unfiled)
            guard !Task.isCancelled, asked == request else { return }
            marks = results
            selection.formIntersection(Set(results.map(\.id)))
            resultGate.present(asked)
            searching = false
        }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkManager.refreshNotification)) { note in
            if note.object as? UUID == profileID { reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkManager.focusNotification)) { note in
            if note.object as? UUID == profileID { searchFocused = true }
        }
        .sheet(item: $editing) { mark in
            BookmarkEditor(mark: mark, folders: folders) { title, url, folder in
                guard store.updateBookmark(mark.id, url: url, title: title,
                                           folderID: folder) else { return false }
                reload(); rebuild()
                return true
            }
        }
        .vaneMotionPolicy()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BOOKMARKS").font(Look.caption).foregroundStyle(Look.inkQuiet)
                .padding(.horizontal, Look.cardInset).padding(.top, Look.paneMargin)
            locationRow("All Bookmarks", icon: "bookmark", value: .all)
            locationRow("Unfiled", icon: "tray", value: .unfiled)
            Divider().padding(.vertical, Look.inset / 2)
            HStack {
                Text("FOLDERS").font(Look.caption).foregroundStyle(Look.inkQuiet)
                Spacer()
                Button { createFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New Folder").accessibilityLabel("New Folder")
            }.padding(.horizontal, Look.cardInset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.rowGap) {
                    ForEach(folders) { folder in
                        locationRow(folder.name, icon: "folder", value: .folder(folder.id))
                            .contextMenu {
                                Button("Rename…") { rename(folder) }
                                Button("Delete Folder…", role: .destructive) { delete(folder) }
                            }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(Look.controlFill)
    }

    private func locationRow(_ title: String, icon: String, value: BookmarkLocation) -> some View {
        Button { location = value } label: {
            HStack(spacing: Look.inset) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(Look.text)
            .padding(.horizontal, Look.cardInset)
            .frame(height: Look.control)
            .background(location == value ? Look.selected : .clear,
                        in: .rect(cornerRadius: Look.chipRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).padding(.horizontal, Look.inset / 2)
    }

    private var header: some View {
        VStack(spacing: Look.cardInset) {
            HStack(spacing: Look.inset) {
                Image(systemName: "magnifyingglass").foregroundStyle(Look.inkSecondary)
                TextField("Search bookmarks", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search bookmarks")
            }
            .secondaryWindowSearchField()
            HStack(spacing: Look.inset) {
                Text(searching ? "Updating bookmarks…" : selection.isEmpty ? "\(marks.count) \(marks.count == 1 ? "bookmark" : "bookmarks")" : "\(selection.count) selected")
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .font(Look.caption).monospacedDigit().foregroundStyle(Look.inkSecondary)
                Spacer(minLength: 0)
                if !selection.isEmpty && rowsAreCurrent {
                    Menu("Move \(selection.count)") {
                        Button("Unfiled") { moveSelected(to: nil) }
                        ForEach(folders) { folder in Button(folder.name) { moveSelected(to: folder.id) } }
                    }
                    Button("Delete \(selection.count)", role: .destructive) { deleteSelected() }
                }
                Button { createFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("New Folder").help("New Folder")
            }
            .buttonStyle(.bordered)
        }
    }

    private var empty: some View {
        SecondaryWindowEmptyState(title: searching ? "Searching bookmarks…" : query.isEmpty ? "No bookmarks here yet" : "No matching bookmarks",
            subtitle: query.isEmpty ? "Save a page to find it here later." : "Try a different title or address.",
            icon: "bookmark")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(marks) { mark in
                        // One lazy child per bookmark, including its optional divider.
                        VStack(spacing: 0) {
                            row(mark)
                            if mark.id != marks.last?.id { Hairline().padding(.horizontal, Look.cardInset) }
                        }
                        .id(mark.id)
                    }
                }
                .secondaryWindowCard()
            }
            .focusable().focusEffectDisabled().focused($listFocused)
            .onDeleteCommand { deleteSelected() }
            .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: .down) { press in
                handle(BookmarkManager.keyCommand(for: press.key, press.modifiers))
            }
            .onChange(of: keyboardRevision) {
                guard selection.count == 1, let id = selection.first else { return }
                withAnimation(reduceMotion || batterySaver.isActive ? nil : Look.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .accessibilityLabel("Bookmarks")
        }
    }

    private func row(_ mark: Bookmark) -> some View {
        let picked = selection.contains(mark.id)
        return HStack(spacing: Look.inset) {
            ZStack {
                Image(systemName: "bookmark").opacity(picked ? 0 : 1)
                Image(systemName: "checkmark.circle.fill").opacity(picked ? 1 : 0)
                    .scaleEffect(picked ? 1 : 0.8)
            }
            .foregroundStyle(picked ? Color.accentColor : Look.inkQuiet).frame(width: Look.rowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(mark.display).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(mark.url).font(Look.caption).foregroundStyle(Look.inkQuiet).lineLimit(1)
            }
            Spacer()
            Button("Edit") { edit(mark) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Look.cardInset).padding(.vertical, Look.rowInset)
        .frame(minHeight: Look.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Look.selected : .clear)
        .animation(Motion.reduced ? nil : Look.quick, value: picked)
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(mark) }
        .onTapGesture {
            guard rowsAreCurrent else { return }
            select(mark); listFocused = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.display)
        .accessibilityValue(mark.url)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens this page in a new tab.")
        .accessibilityAction { open(mark) }
        .accessibilityAction(named: picked ? "Deselect" : "Select") {
            guard rowsAreCurrent else { return }
            if picked { selection.remove(mark.id) } else { selection.insert(mark.id) }
        }
        .accessibilityAction(named: "Edit") { edit(mark) }
        .accessibilityAction(named: "Delete") { remove([mark.id]) }
        .contextMenu {
            Button("Open in New Tab") { open(mark) }
            Button("Edit…") { edit(mark) }
            Menu("Move to Folder") {
                Button("Unfiled") { move(Set([mark.id]), to: nil) }
                ForEach(folders) { folder in Button(folder.name) { move(Set([mark.id]), to: folder.id) } }
            }
            Divider()
            Button("Delete", role: .destructive) { remove(Set([mark.id])) }
        }
        .disabled(!rowsAreCurrent)
    }

    private func reload() {
        folders = store.bookmarkFolders()
        if case .folder(let id) = location, !folders.contains(where: { $0.id == id }) { location = .unfiled }
        reloadMarks()
    }
    private func reloadMarks() { searching = true; revision += 1 }

    private func edit(_ mark: Bookmark) {
        resultGate.performIfCurrent(request, refreshing: searching) { editing = mark }
    }

    private func select(_ mark: Bookmark) {
        guard rowsAreCurrent else { return }
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(mark.id) { selection.remove(mark.id) } else { selection.insert(mark.id) }
        } else { selection = [mark.id] }
    }

    private func handle(_ command: BookmarkManager.KeyCommand?) -> KeyPress.Result {
        guard rowsAreCurrent, let command else { return .ignored }
        switch command {
        case .previous, .next:
            selection = BookmarkManager.keyboardSelection(ids: marks.map(\.id), selected: selection,
                                                           step: command == .previous ? -1 : 1)
            keyboardRevision += 1
        case .open:
            guard let mark = marks.first(where: { selection.contains($0.id) }) else { return .ignored }
            open(mark)
        }
        return .handled
    }

    private func open(_ mark: Bookmark) {
        guard rowsAreCurrent else { return }
        selection = [mark.id]
        listFocused = true
        guard let url = URL(string: mark.url) else { return }
        let target = BookmarkManager.browserWindow(for: profileID)
        target?.shown.newTab(url)
    }

    private func moveSelected(to folder: String?) { move(selection, to: folder) }
    private func move(_ ids: Set<Int64>, to folder: String?) {
        resultGate.performIfCurrent(request, refreshing: searching) {
            guard store.moveBookmarks(ids, to: folder) else { showWriteFailure(); return }
            reloadMarks(); rebuild()
        }
    }

    private func deleteSelected() {
        guard rowsAreCurrent, !selection.isEmpty else { return }
        if selection.count > 1 {
            let alert = NSAlert(); alert.messageText = "Delete \(selection.count) bookmarks?"
            alert.informativeText = "This cannot be undone."
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        remove(selection)
    }

    private func remove(_ ids: Set<Int64>) {
        resultGate.performIfCurrent(request, refreshing: searching) {
            guard store.deleteBookmarks(ids) else { showWriteFailure(); return }
            selection.subtract(ids); reloadMarks(); rebuild()
        }
    }

    private func createFolder() {
        let alert = textAlert(title: "New Bookmark Folder", action: "Create", value: "")
        guard alert.alert.runModal() == .alertFirstButtonReturn else { return }
        guard let folder = store.createBookmarkFolder(named: alert.field.stringValue) else { showWriteFailure(); return }
        reload(); location = .folder(folder.id)
    }

    private func rename(_ folder: BookmarkFolder) {
        let alert = textAlert(title: "Rename Bookmark Folder", action: "Rename", value: folder.name)
        guard alert.alert.runModal() == .alertFirstButtonReturn else { return }
        guard store.renameBookmarkFolder(folder.id, to: alert.field.stringValue) else { showWriteFailure(); return }
        reload()
    }

    private func delete(_ folder: BookmarkFolder) {
        let alert = NSAlert(); alert.messageText = "Delete the folder “\(folder.name)”?"
        alert.informativeText = "Its bookmarks will move to Unfiled."
        alert.addButton(withTitle: "Delete Folder"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard store.deleteBookmarkFolder(folder.id) else { showWriteFailure(); return }
        if location == .folder(folder.id) { location = .unfiled }
        reload()
    }

    private func showWriteFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update bookmarks"
        alert.informativeText = "The change could not be saved. Check the folder name or storage availability and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func textAlert(title: String, action: String, value: String) -> (alert: NSAlert, field: NSTextField) {
        let field = NSTextField(string: value); field.frame.size = NSSize(width: 300, height: 24)
        let alert = NSAlert(); alert.messageText = title; alert.accessoryView = field
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        return (alert, field)
    }
}

private struct BookmarkEditor: View {
    let mark: Bookmark
    let folders: [BookmarkFolder]
    let save: (String, URL, String?) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String
    @State private var folderID: String
    @State private var error = ""

    init(mark: Bookmark, folders: [BookmarkFolder], save: @escaping (String, URL, String?) -> Bool) {
        self.mark = mark; self.folders = folders; self.save = save
        _title = State(initialValue: mark.title); _address = State(initialValue: mark.url)
        _folderID = State(initialValue: mark.folderID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            SecondaryWindowHeader(title: "Edit Bookmark", subtitle: "Update this saved page.", icon: "bookmark")
            TextField("Title", text: $title)
            TextField("Address", text: $address)
            Picker("Folder", selection: $folderID) {
                Text("Unfiled").tag("")
                ForEach(folders) { Text($0.name).tag($0.id) }
            }
            if !error.isEmpty { Text(error).font(Look.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { commit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .padding(Look.paneMargin).frame(width: 420)
        .font(Look.text).foregroundStyle(Look.inkPrimary)
        .background(Look.panelFill)
        .vaneMotionPolicy()
    }

    private func commit() {
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https" else {
            error = "Enter a complete http or https address."; return
        }
        guard save(title, url, folderID.isEmpty ? nil : folderID) else {
            error = "That address is already bookmarked, or the change could not be saved."; return
        }
        dismiss()
    }
}
