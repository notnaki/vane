import AppKit
import SwiftUI

/// Search, organize and edit the active profile's bookmarks in one native window.
@MainActor enum BookmarkManager {
    private static var window: NSWindow?
    private static var profileID: UUID?

    enum KeyCommand: Equatable { case previous, next, open }

    nonisolated static func actionProfile(window: UUID?, active: UUID) -> UUID {
        window ?? active
    }

    static var currentActionProfile: UUID {
        actionProfile(window: Windows.current?.profileID, active: ProfileManager.activeProfileID)
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
        profileID = requested
        if let window {
            window.contentView = NSHostingView(rootView: BookmarkManagerView(profileID: requested))
            window.title = title(for: requested)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        made.title = title(for: requested)
        made.minSize = NSSize(width: 620, height: 400)
        made.isReleasedWhenClosed = false
        made.contentView = NSHostingView(rootView: BookmarkManagerView(profileID: requested))
        if !made.setFrameUsingName("VaneBookmarks") { made.center() }
        made.setFrameAutosaveName("VaneBookmarks")
        window = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func refresh(profileID requested: UUID) {
        guard let window, window.isVisible, profileID == requested else { return }
        window.contentView = NSHostingView(rootView: BookmarkManagerView(profileID: requested))
    }

    private static func title(for id: UUID) -> String {
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

private enum BookmarkLocation: Hashable {
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
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var store: Store { Store.store(for: profileID) }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 170, idealWidth: 190, maxWidth: 230)
            VStack(alignment: .leading, spacing: Look.inset * 1.5) {
                header
                if marks.isEmpty { empty } else { list }
            }
            .padding(.top, Look.inset * 2)
            .padding(.horizontal, Look.paneMargin)
            .padding(.bottom, Look.paneMargin)
        }
        .background(.windowBackground)
        .onAppear { reload(); searchFocused = true }
        .onChange(of: query) { reloadMarks() }
        .onChange(of: location) { selection.removeAll(); reloadMarks() }
        .sheet(item: $editing) { mark in
            BookmarkEditor(mark: mark, folders: folders) { title, url, folder in
                guard store.updateBookmark(mark.id, url: url, title: title,
                                           folderID: folder) else { return false }
                reload(); rebuild()
                return true
            }
        }
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
                    .buttonStyle(.plain).help("New Folder")
            }.padding(.horizontal, Look.cardInset)
            ForEach(folders) { folder in
                locationRow(folder.name, icon: "folder", value: .folder(folder.id))
                    .contextMenu {
                        Button("Rename…") { rename(folder) }
                        Button("Delete Folder…", role: .destructive) { delete(folder) }
                    }
            }
            Spacer()
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
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset - 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search bookmarks", text: $query).textFieldStyle(.plain)
                    .font(Look.text).focused($searchFocused)
            }
            .padding(.horizontal, Look.inset).frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
            if !selection.isEmpty {
                Menu("Move \(selection.count)") {
                    Button("Unfiled") { moveSelected(to: nil) }
                    ForEach(folders) { folder in Button(folder.name) { moveSelected(to: folder.id) } }
                }
                Button("Delete \(selection.count)") { deleteSelected() }
                    .foregroundStyle(.red)
            }
            Button { createFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
        }
        .buttonStyle(.plain).font(Look.text)
    }

    private var empty: some View {
        Text(query.isEmpty ? "No bookmarks in this folder." : "No bookmark matches “\(query)”.")
            .font(Look.text).foregroundStyle(.secondary)
            .padding(.horizontal, Look.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        ScrollView {
            SettingsCard {
                ForEach(marks) { mark in row(mark) }
            }
        }
        .focusable().focusEffectDisabled().focused($listFocused)
        .onDeleteCommand { deleteSelected() }
        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: .down) { press in
            handle(BookmarkManager.keyCommand(for: press.key, press.modifiers))
        }
        .accessibilityLabel("Bookmarks")
    }

    private func row(_ mark: Bookmark) -> some View {
        let picked = selection.contains(mark.id)
        return HStack(spacing: Look.inset) {
            Image(systemName: picked ? "checkmark.circle.fill" : "bookmark")
                .foregroundStyle(picked ? Color.accentColor : Look.inkQuiet).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(mark.display).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(mark.url).font(Look.caption).foregroundStyle(Look.inkQuiet).lineLimit(1)
            }
            Spacer()
            Button("Edit") { editing = mark }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Look.cardInset).frame(minHeight: Look.linkRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Look.selected : .clear).contentShape(.rect)
        .onTapGesture(count: 2) { open(mark) }
        .onTapGesture { select(mark); listFocused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.display)
        .accessibilityValue(mark.url)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens this page in a new tab.")
        .accessibilityAction { open(mark) }
        .accessibilityAction(named: picked ? "Deselect" : "Select") {
            if picked { selection.remove(mark.id) } else { selection.insert(mark.id) }
        }
        .accessibilityAction(named: "Edit") { editing = mark }
        .accessibilityAction(named: "Delete") { remove([mark.id]) }
        .contextMenu {
            Button("Open in New Tab") { open(mark) }
            Button("Edit…") { editing = mark }
            Menu("Move to Folder") {
                Button("Unfiled") { move(Set([mark.id]), to: nil) }
                ForEach(folders) { folder in Button(folder.name) { move(Set([mark.id]), to: folder.id) } }
            }
            Divider()
            Button("Delete", role: .destructive) { remove(Set([mark.id])) }
        }
    }

    private func reload() { folders = store.bookmarkFolders(); reloadMarks() }
    private func reloadMarks() {
        switch location {
        case .all: marks = store.managedBookmarks(matching: query)
        case .unfiled: marks = store.managedBookmarks(matching: query, unfiledOnly: true)
        case .folder(let id): marks = store.managedBookmarks(matching: query, folderID: id)
        }
        selection.formIntersection(Set(marks.map(\.id)))
    }

    private func select(_ mark: Bookmark) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(mark.id) { selection.remove(mark.id) } else { selection.insert(mark.id) }
        } else { selection = [mark.id] }
    }

    private func handle(_ command: BookmarkManager.KeyCommand?) -> KeyPress.Result {
        guard let command else { return .ignored }
        switch command {
        case .previous:
            selection = BookmarkManager.keyboardSelection(ids: marks.map(\.id), selected: selection, step: -1)
        case .next:
            selection = BookmarkManager.keyboardSelection(ids: marks.map(\.id), selected: selection, step: 1)
        case .open:
            guard let mark = marks.first(where: { selection.contains($0.id) }) else { return .ignored }
            open(mark)
        }
        return .handled
    }

    private func open(_ mark: Bookmark) {
        selection = [mark.id]
        listFocused = true
        guard let url = URL(string: mark.url) else { return }
        let target = Windows.current(in: profileID)
            ?? ProfileManager.shared.profiles.first(where: { $0.id == profileID }).map {
                Windows.open(profile: $0)
            }
        target?.shown.newTab(url)
    }

    private func moveSelected(to folder: String?) { move(selection, to: folder) }
    private func move(_ ids: Set<Int64>, to folder: String?) {
        if store.moveBookmarks(ids, to: folder) { selection.removeAll(); reloadMarks(); rebuild() }
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
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
        if store.deleteBookmarks(ids) { selection.subtract(ids); reloadMarks(); rebuild() }
    }

    private func createFolder() {
        let alert = textAlert(title: "New Bookmark Folder", action: "Create", value: "")
        guard alert.alert.runModal() == .alertFirstButtonReturn,
              let folder = store.createBookmarkFolder(named: alert.field.stringValue) else { return }
        reload(); location = .folder(folder.id)
    }

    private func rename(_ folder: BookmarkFolder) {
        let alert = textAlert(title: "Rename Bookmark Folder", action: "Rename", value: folder.name)
        guard alert.alert.runModal() == .alertFirstButtonReturn,
              store.renameBookmarkFolder(folder.id, to: alert.field.stringValue) else { return }
        reload()
    }

    private func delete(_ folder: BookmarkFolder) {
        let alert = NSAlert(); alert.messageText = "Delete the folder “\(folder.name)”?"
        alert.informativeText = "Its bookmarks will move to Unfiled."
        alert.addButton(withTitle: "Delete Folder"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn,
              store.deleteBookmarkFolder(folder.id) else { return }
        if location == .folder(folder.id) { location = .unfiled }
        reload()
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
            Text("Edit Bookmark").font(Look.heading)
            TextField("Title", text: $title)
            TextField("Address", text: $address)
            Picker("Folder", selection: $folderID) {
                Text("Unfiled").tag("")
                ForEach(folders) { Text($0.name).tag($0.id) }
            }
            if !error.isEmpty { Text(error).font(Look.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { commit() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Look.paneMargin).frame(width: 420)
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
