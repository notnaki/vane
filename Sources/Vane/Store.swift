import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Suggestion: Identifiable, Equatable {
    var id: String { url }
    let url: String
    let title: String
    let bookmarked: Bool
    /// True for a phrase the search engine completed, false for the user's own history and
    /// bookmarks. Only the command bar cares: a completion draws a magnifying glass and no
    /// url, because it is a search that has not happened yet rather than a place. This is
    /// the field `SearchSuggestions.merge` said to add when a list wanted to tell them apart.
    var completion = false
}

/// One visit, as the History window lists it: every row, with its own time, rather than the
/// one-row-per-url roll-up the address bar wants. Its id is the visits row, so deleting a
/// line deletes that visit and leaves the other times you went there alone.
struct Visit: Identifiable, Hashable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let at: Date

    /// What the row shows when the page never reported a title.
    var display: String { title.isEmpty ? url : title }
}

/// A saved page as shown in the bookmark manager. Folder ids are strings because folders
/// are portable UUIDs; bookmark ids stay SQLite row ids so edits survive title/url changes.
struct Bookmark: Identifiable, Hashable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let at: Date
    let folderID: String?

    var display: String { title.isEmpty ? url : title }
}

struct BookmarkFolder: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let position: Int
}

struct BookmarkImportItem: Sendable {
    let url: URL
    let title: String
    let folder: String?
    let at: Date?

    init(url: URL, title: String, folder: String?, at: Date? = nil) {
        self.url = url; self.title = title; self.folder = folder; self.at = at
    }
}

struct BookmarkImportResult: Equatable, Sendable {
    let imported: Int
    let folders: Int
}

/// History and bookmarks in one SQLite file.
/// ponytail: sqlite3 ships in the OS, so no wrapper dependency and no Core Data. One
/// connection, used from the main thread — writes are a single row and reads are indexed.
/// If that ever shows up in a profile the fix is a serial queue, not a different database.
@MainActor final class Store {
    /// The active profile's store. Still spelled `Store.shared` everywhere; it just resolves
    /// per profile now, and the default profile's file is still `vane.db`.
    static var shared: Store { store(for: ProfileManager.shared.active.id) }

    /// One open connection per profile, kept for the life of the process.
    private static var cache: [UUID: Store] = [:]

    static func store(for profileID: UUID) -> Store {
        if let hit = cache[profileID] { return hit }
        let fresh = Store(path: ProfileManager.dbURL(for: profileID, in: directory).path)
        cache[profileID] = fresh
        return fresh
    }

    /// Drop the connection and the files. Called when a profile is deleted.
    static func forget(_ profileID: UUID) {
        cache[profileID] = nil
        let path = ProfileManager.dbURL(for: profileID, in: directory).path
        for p in [path, path + "-wal", path + "-shm"] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    // nonisolated(unsafe) only so deinit can close it — a deinit is never actor-isolated.
    // Every other access is from the main thread, as it always was.
    private nonisolated(unsafe) var db: OpaquePointer?

    /// The data dir a second instance was pointed at, if any. A debug build running beside
    /// the real app gets its own everything: files here, preferences in `UserDefaults.vane`,
    /// and no copy of the user's pre-sandbox folder (see `LegacyData.migrateIfNeeded`).
    nonisolated static var overrideDirectory: String? {
        ProcessInfo.processInfo.environment["VANE_DATA_DIR"]
    }

    static var directory: URL {
        // VANE_DATA_DIR: a second instance — a debug build running beside the real app —
        // gets its own history, session and spaces instead of racing the other over one
        // set of files (and tripping its crash marker). Unset in normal use.
        let base = overrideDirectory
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Vane", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    init(path: String? = nil) {
        sqlite3_open(path ?? Store.directory.appendingPathComponent("vane.db").path, &db)
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS visits (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS visits_at ON visits(at DESC);
        CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
        CREATE TABLE IF NOT EXISTS bookmarks (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS bookmark_folders (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, created_at REAL NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS bookmark_folders_name
            ON bookmark_folders(name COLLATE NOCASE);
        """)
        var hasFolder = false
        run("PRAGMA table_info(bookmarks)", [], {
            if self.text($0, 1) == "folder_id" { hasFolder = true }
        })
        if !hasFolder { exec("ALTER TABLE bookmarks ADD COLUMN folder_id TEXT") }
    }

    deinit { sqlite3_close(db) }

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Any], _ row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var st: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &st, nil)
        guard prepared == SQLITE_OK, let st else { return false }
        defer { sqlite3_finalize(st) }
        guard bind(binds, to: st) else { return false }
        var code = sqlite3_step(st)
        while code == SQLITE_ROW {
            row?(st)
            code = sqlite3_step(st)
        }
        return code == SQLITE_DONE
    }

    private func bind(_ values: [Any], to statement: OpaquePointer) -> Bool {
        for (i, value) in values.enumerated() {
            let n = Int32(i + 1)
            let code: Int32
            switch value {
            case let value as String: code = sqlite3_bind_text(statement, n, value, -1, TRANSIENT)
            case let value as Double: code = sqlite3_bind_double(statement, n, value)
            case let value as Int: code = sqlite3_bind_int64(statement, n, Int64(value))
            case let value as Int64: code = sqlite3_bind_int64(statement, n, value)
            default: code = sqlite3_bind_null(statement, n)
            }
            guard code == SQLITE_OK else { return false }
        }
        return true
    }

    /// A failed row or commit rolls the entire import back. Counts describe committed rows.
    private func batch(_ sql: String, rows: [[Any]]) -> Int {
        guard !rows.isEmpty, exec("BEGIN IMMEDIATE") else { return 0 }
        var committed = false
        // SQLITE_FULL can roll back the transaction itself. A redundant ROLLBACK would
        // replace the useful disk-full error with "no transaction is active".
        defer { if !committed && sqlite3_get_autocommit(db) == 0 { exec("ROLLBACK") } }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        var count = 0
        for row in rows {
            guard bind(row, to: statement) else { return 0 }
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { return 0 }
            count += Int(sqlite3_changes(db))
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        guard exec("COMMIT") else { return 0 }
        committed = true
        return count
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }
        var committed = false
        defer { if !committed && sqlite3_get_autocommit(db) == 0 { exec("ROLLBACK") } }
        guard body(), exec("COMMIT") else { return false }
        committed = true
        return true
    }

    private func variableChunkSize(reserving reserved: Int = 0) -> Int {
        max(1, min(900, Int(sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1)) - reserved))
    }

    private func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    // MARK: History

    func record(_ url: URL, title: String) {
        // about:blank, the new-tab page and non-web schemes are not history.
        guard url.scheme == "http" || url.scheme == "https" else { return }
        run("INSERT INTO visits (url, title, at) VALUES (?, ?, ?)",
            [url.absoluteString, title, Date.now.timeIntervalSince1970])
    }

    /// Titles arrive after the visit row is written, so backfill the newest row for that url.
    func retitle(_ url: URL, title: String) {
        guard !title.isEmpty else { return }
        run("UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY at DESC LIMIT 1)",
            [title, url.absoluteString])
    }

    /// The last title this profile saw for a page. For a row that has to be redrawn as a
    /// page it is no longer on — a pinned tab sent back to the url it was pinned at, see
    /// `TabStore.close` — where leaving the wandered page's name on the row would be a lie.
    /// nil for a page never visited, and for one whose title never arrived.
    func title(for url: URL) -> String? {
        var out: String?
        run("SELECT title FROM visits WHERE url = ? AND title <> '' ORDER BY at DESC LIMIT 1",
            [url.absoluteString]) { out = self.text($0, 0) }
        return out
    }

    /// Bulk insert in one transaction, keeping each visit's real timestamp.
    /// ponytail: the single-row `record` above is one implicit transaction — and one fsync
    /// — per row. That is why importing used to cap at 5000 pages and throw the real dates
    /// away. One BEGIN and one reused statement makes both limits unnecessary.
    func record(_ visits: [(url: URL, title: String, at: Date)]) {
        guard !visits.isEmpty else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO visits (url, title, at) VALUES (?, ?, ?)",
                                 -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        exec("BEGIN")
        for visit in visits where visit.url.scheme == "http" || visit.url.scheme == "https" {
            sqlite3_bind_text(statement, 1, visit.url.absoluteString, -1, TRANSIENT)
            sqlite3_bind_text(statement, 2, visit.title, -1, TRANSIENT)
            sqlite3_bind_double(statement, 3, visit.at.timeIntervalSince1970)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
        exec("COMMIT")
    }

    func recent(limit: Int = 100) -> [Suggestion] {
        var out: [Suggestion] = []
        run("SELECT url, title, MAX(at) FROM visits GROUP BY url ORDER BY MAX(at) DESC LIMIT ?", [limit]) {
            out.append(Suggestion(url: self.text($0, 0), title: self.text($0, 1), bookmarked: false))
        }
        return out
    }

    /// Every visit, newest first, optionally narrowed by a substring of the title or the
    /// url. The search is SQL rather than a filter in the window, so a long history does
    /// not have to be in memory to be searchable; the wildcards are escaped for the same
    /// reason `suggest` escapes them.
    func history(matching query: String = "", limit: Int = 500) -> [Visit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Visit] = []
        let read: (OpaquePointer) -> Void = { st in
            out.append(Visit(id: sqlite3_column_int64(st, 0),
                             url: self.text(st, 1), title: self.text(st, 2),
                             at: Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
        }
        guard !q.isEmpty else {
            run("SELECT id, url, title, at FROM visits ORDER BY at DESC LIMIT ?", [limit], read)
            return out
        }
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "%", with: "\\%")
                          .replacingOccurrences(of: "_", with: "\\_") + "%"
        run("""
            SELECT id, url, title, at FROM visits
            WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            ORDER BY at DESC LIMIT ?
            """, [like, like, limit], read)
        return out
    }

    /// ⌫ in the History window: one line, not every visit to that page.
    func deleteVisit(_ id: Int64) { run("DELETE FROM visits WHERE id = ?", [Int(id)]) }

    /// ⌥⌘⌫ on a suggestion in the command bar, which is the opposite gesture: the bar rolls
    /// every visit to a page up into one row, so forgetting that row has to forget them all
    /// or the suggestion comes straight back. Bookmarks are untouched — deleting a
    /// suggestion is not the same as unbookmarking, and the bar does not offer it on one.
    func forget(url: String) { run("DELETE FROM visits WHERE url = ?", [url]) }

    /// `since: nil` is "all time", which is a DELETE with no WHERE rather than a very old
    /// date — a stored visit with a broken timestamp must not survive "clear everything".
    func clearHistory(since: Date? = nil) {
        guard let since else { exec("DELETE FROM visits"); return }
        run("DELETE FROM visits WHERE at >= ?", [since.timeIntervalSince1970])
    }

    // MARK: Bookmarks

    @discardableResult
    func toggleBookmark(_ url: URL, title: String) -> Bool {
        if isBookmarked(url) {
            run("DELETE FROM bookmarks WHERE url = ?", [url.absoluteString])
            return false
        }
        run("INSERT OR REPLACE INTO bookmarks (url, title, at) VALUES (?, ?, ?)",
            [url.absoluteString, title, Date.now.timeIntervalSince1970])
        return true
    }

    func isBookmarked(_ url: URL) -> Bool {
        var found = false
        run("SELECT 1 FROM bookmarks WHERE url = ? LIMIT 1", [url.absoluteString]) { _ in found = true }
        return found
    }

    /// INSERT OR IGNORE against the UNIQUE url, so re-importing is a no-op instead of the
    /// hazard toggleBookmark would be — a second import would otherwise *delete* every
    /// bookmark it added the first time. Returns how many were actually new.
    @discardableResult
    func addBookmarks(_ marks: [(url: URL, title: String)]) -> Int {
        let now = Date.now.timeIntervalSince1970
        return batch("INSERT OR IGNORE INTO bookmarks (url, title, at) VALUES (?, ?, ?)",
                     rows: marks.filter { $0.url.scheme == "http" || $0.url.scheme == "https" }
                        .map { [$0.url.absoluteString, $0.title, now] })
    }

    @discardableResult
    func addBookmarks(_ marks: [(url: URL, title: String)], to folderID: String?) -> Int {
        let now = Date.now.timeIntervalSince1970
        let folder: Any = folderID.map { $0 as Any } ?? NSNull()
        return batch("INSERT OR IGNORE INTO bookmarks (url, title, at, folder_id) VALUES (?, ?, ?, ?)",
                     rows: marks.filter { $0.url.scheme == "http" || $0.url.scheme == "https" }
                        .map { [$0.url.absoluteString, $0.title, now, folder] })
    }

    /// One all-or-nothing folder-aware import. The first occurrence of a URL in source
    /// order wins; bookmarks already in this profile are left exactly where they are.
    func importBookmarks(_ source: [BookmarkImportItem]) -> BookmarkImportResult? {
        var seen = Set<String>()
        let rows = source.filter {
            ($0.url.scheme == "http" || $0.url.scheme == "https")
                && seen.insert($0.url.absoluteString).inserted
        }
        guard exec("BEGIN IMMEDIATE") else { return nil }
        var committed = false
        defer { if !committed && sqlite3_get_autocommit(db) == 0 { exec("ROLLBACK") } }
        var existing = Set<String>()
        let urls = rows.map { $0.url.absoluteString }
        for chunk in urls.chunked(max: variableChunkSize()) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            guard run("SELECT url FROM bookmarks WHERE url IN (\(placeholders))", chunk, {
                existing.insert(self.text($0, 0))
            }) else { return nil }
        }
        let fresh = rows.filter { !existing.contains($0.url.absoluteString) }
        let fallbackDate = Date.now
        var folders: [String: BookmarkFolder] = [:]
        for folder in bookmarkFolders() { folders[folder.name.lowercased()] = folder }
        var imported = 0, made = 0
        for (index, item) in fresh.enumerated() {
            let name = item.folder?.trimmingCharacters(in: .whitespacesAndNewlines)
            var folderID: String?
            if let name, !name.isEmpty {
                let key = name.lowercased()
                if let folder = folders[key] { folderID = folder.id }
                else {
                    guard let folder = createBookmarkFolder(named: name) else { return nil }
                    folders[key] = folder; folderID = folder.id; made += 1
                }
            }
            let folder: Any = folderID.map { $0 as Any } ?? NSNull()
            let date = item.at ?? fallbackDate.addingTimeInterval(-Double(index))
            guard run("INSERT INTO bookmarks (url, title, at, folder_id) VALUES (?, ?, ?, ?)",
                      [item.url.absoluteString, item.title, date.timeIntervalSince1970, folder]) else { return nil }
            imported += 1
        }
        guard exec("COMMIT") else { return nil }
        committed = true
        return BookmarkImportResult(imported: imported, folders: made)
    }

    func bookmarks(limit: Int = 500) -> [Suggestion] {
        var out: [Suggestion] = []
        run("SELECT url, title FROM bookmarks ORDER BY at DESC LIMIT ?", [limit]) {
            out.append(Suggestion(url: self.text($0, 0), title: self.text($0, 1), bookmarked: true))
        }
        return out
    }

    /// The manager's full-fidelity bookmark read. Search is done in SQLite so imported
    /// libraries do not have to be loaded before they can be narrowed.
    func managedBookmarks(matching query: String = "", folderID: String? = nil,
                          unfiledOnly: Bool = false, limit: Int = .max) -> [Bookmark] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var clauses: [String] = [], binds: [Any] = []
        if !q.isEmpty {
            clauses.append("(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')")
            binds += [like, like]
        }
        if let folderID { clauses.append("folder_id = ?"); binds.append(folderID) }
        else if unfiledOnly { clauses.append("folder_id IS NULL") }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        binds.append(limit)
        var out: [Bookmark] = []
        run("SELECT id, url, title, at, folder_id FROM bookmarks\(whereSQL) ORDER BY at DESC LIMIT ?", binds) {
            let folder = sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : self.text($0, 4)
            out.append(Bookmark(id: sqlite3_column_int64($0, 0), url: self.text($0, 1),
                                title: self.text($0, 2),
                                at: Date(timeIntervalSince1970: sqlite3_column_double($0, 3)),
                                folderID: folder))
        }
        return out
    }

    func bookmarkFolders() -> [BookmarkFolder] {
        var out: [BookmarkFolder] = []
        run("SELECT id, name, position FROM bookmark_folders ORDER BY position, name COLLATE NOCASE", []) {
            out.append(BookmarkFolder(id: self.text($0, 0), name: self.text($0, 1),
                                      position: Int(sqlite3_column_int64($0, 2))))
        }
        return out
    }

    @discardableResult func createBookmarkFolder(named rawName: String) -> BookmarkFolder? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var collision = false
        guard run("SELECT 1 FROM bookmark_folders WHERE name = ? COLLATE NOCASE LIMIT 1",
                  [name], { _ in collision = true }), !collision else { return nil }
        let id = UUID().uuidString
        let position = (bookmarkFolders().map(\.position).max() ?? -1) + 1
        guard run("INSERT INTO bookmark_folders (id, name, position, created_at) VALUES (?, ?, ?, ?)",
                  [id, name, position, Date.now.timeIntervalSince1970]) else { return nil }
        return BookmarkFolder(id: id, name: name, position: position)
    }

    @discardableResult func renameBookmarkFolder(_ id: String, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        var collision = false
        guard run("SELECT 1 FROM bookmark_folders WHERE name = ? COLLATE NOCASE AND id <> ? LIMIT 1",
                  [name, id], { _ in collision = true }), !collision else { return false }
        return run("UPDATE bookmark_folders SET name = ? WHERE id = ?", [name, id])
    }

    /// Removing a folder keeps its pages and returns them to Unfiled.
    @discardableResult func deleteBookmarkFolder(_ id: String) -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }
        var committed = false
        defer { if !committed && sqlite3_get_autocommit(db) == 0 { exec("ROLLBACK") } }
        guard run("UPDATE bookmarks SET folder_id = NULL WHERE folder_id = ?", [id]),
              run("DELETE FROM bookmark_folders WHERE id = ?", [id]), exec("COMMIT") else { return false }
        committed = true
        return true
    }

    @discardableResult func updateBookmark(_ id: Int64, url: URL, title: String,
                                           folderID: String?) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        var collision = false
        guard run("SELECT 1 FROM bookmarks WHERE url = ? AND id <> ? LIMIT 1",
                  [url.absoluteString, id], { _ in collision = true }), !collision else { return false }
        let folder: Any = folderID.map { $0 as Any } ?? NSNull()
        return run("UPDATE bookmarks SET url = ?, title = ?, folder_id = ? WHERE id = ?",
                   [url.absoluteString, title.trimmingCharacters(in: .whitespacesAndNewlines),
                    folder, id])
    }

    @discardableResult func moveBookmarks(_ ids: Set<Int64>, to folderID: String?) -> Bool {
        guard !ids.isEmpty else { return true }
        let marks = ids.sorted()
        let folder: Any = folderID.map { $0 as Any } ?? NSNull()
        return transaction {
            for chunk in marks.chunked(max: self.variableChunkSize(reserving: 1)) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                guard self.run("UPDATE bookmarks SET folder_id = ? WHERE id IN (\(placeholders))",
                               [folder] + chunk.map { $0 as Any }) else { return false }
            }
            return true
        }
    }

    @discardableResult func deleteBookmarks(_ ids: Set<Int64>) -> Bool {
        guard !ids.isEmpty else { return true }
        let marks = ids.sorted()
        return transaction {
            for chunk in marks.chunked(max: self.variableChunkSize()) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                guard self.run("DELETE FROM bookmarks WHERE id IN (\(placeholders))",
                               chunk.map { $0 as Any }) else { return false }
            }
            return true
        }
    }

    // MARK: Address bar

    /// Bookmarks first, then history ranked by visit count and recency — the ordering that
    /// makes an address bar feel like it knows you. Duplicates of a bookmarked url are dropped.
    func suggest(_ query: String, limit: Int = 8) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        // LIKE with escaped wildcards: a user typing "100%" must not match everything.
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "%", with: "\\%")
                          .replacingOccurrences(of: "_", with: "\\_") + "%"
        var out: [Suggestion] = []
        var seen = Set<String>()
        run("""
            SELECT url, title FROM bookmarks
            WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            ORDER BY at DESC LIMIT ?
            """, [like, like, limit]) {
            let s = Suggestion(url: self.text($0, 0), title: self.text($0, 1), bookmarked: true)
            if seen.insert(s.url).inserted { out.append(s) }
        }
        run("""
            SELECT url, title, COUNT(*) AS hits, MAX(at) AS last FROM visits
            WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            GROUP BY url ORDER BY hits DESC, last DESC LIMIT ?
            """, [like, like, limit]) {
            let s = Suggestion(url: self.text($0, 0), title: self.text($0, 1), bookmarked: false)
            if seen.insert(s.url).inserted { out.append(s) }
        }
        return Array(out.prefix(limit))
    }
}

private extension Array {
    func chunked(max size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var chunks: [[Element]] = []
        var start = 0
        while start < count {
            let end = Swift.min(start + size, count)
            chunks.append(Array(self[start..<end]))
            start = end
        }
        return chunks
    }
}

/// Where every preference goes.
///
/// `Store.directory` already sends a test instance's *files* somewhere of its own, but a
/// preference is not a file the app names: the standard defaults are the *process's* own
/// domain, so a debug build launched with `VANE_DATA_DIR` still read — and worse, wrote —
/// the user's pinned rows, favourites, last Space and every Settings toggle. That is not an
/// isolated instance; it is the same browser with a different history file.
///
/// ponytail: one `static let` and a rename at every call site, rather than an injected store
/// threaded through eighty of them. With the variable unset — normal use — this *is* the
/// standard defaults, so nothing about the shipping app changes. Ceiling: a suite plist is
/// left in `~/Library/Preferences` per test dir; `defaults delete <suite>` clears it.
extension UserDefaults {
    // `nonisolated(unsafe)` for the same reason the standard defaults are: the object is
    // made once and `UserDefaults` is thread-safe by contract — it simply predates Sendable.
    nonisolated(unsafe) static let vane: UserDefaults = {
        guard let dir = Store.overrideDirectory else { return .standard }
        return UserDefaults(suiteName: suiteName(forDataDir: dir)) ?? .standard
    }()

    /// A suite name derived from the data dir, so two test instances on two dirs keep their
    /// preferences apart and one dir keeps its own across launches. djb2 rather than
    /// `hashValue`: Swift's string hashing is seeded per process and would hand the same
    /// directory a different suite on every launch.
    nonisolated static func suiteName(forDataDir dir: String) -> String {
        var h: UInt64 = 5381
        for byte in dir.utf8 { h = h &* 33 &+ UInt64(byte) }
        return "vane.datadir." + String(h, radix: 36)
    }

    /// The file `UserDefaults` keeps a suite in. Pure, so `selfcheck --pure` can prove the
    /// arithmetic without deleting anything.
    nonisolated static func suitePlist(_ suite: String, home: String) -> String {
        home + "/Library/Preferences/" + suite + ".plist"
    }

    /// Empty a suite this process made for itself, and note it down for the sweep.
    ///
    /// `removePersistentDomain` empties the suite but leaves the plist behind, so every
    /// `check()` that wanted a defaults suite of its own was leaving one file per run in
    /// `~/Library/Preferences` — twelve thousand of them on the machine that noticed.
    /// Unlinking it here is worth the one line, but it is not the end of the story: see
    /// `sweepScratchSuites`. Only ever call this on a scratch suite — a suite somebody's real
    /// preferences are in is not this function's business.
    nonisolated static func dropScratchSuite(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        droppedSuites.append(suite)
        unlinkSuitePlist(suite)
    }

    // Every suite `dropScratchSuite` has emptied. `nonisolated(unsafe)` for the same reason
    // the defaults above are: this is only ever touched by `check()` bodies, which the
    // selfcheck runs one after another on one thread.
    nonisolated(unsafe) private static var droppedSuites: [String] = []

    /// Delete every dropped suite's plist for good, once this process is gone.
    ///
    /// Unlinking the file while the process is alive does not keep it gone: cfprefsd holds the
    /// domain in memory and writes an empty 42-byte plist back over the missing path whenever
    /// it next gets round to it — including once more when the process it belonged to dies.
    /// Whoever deletes it last wins, and that cannot be us.
    ///
    /// So the last word goes to somebody who outlives us: the same detached `/bin/sh` that
    /// waits on this pid in `Updater.restart`, sleeping past cfprefsd's parting write and
    /// then removing the files. Called at the end of a check run and nowhere else.
    ///
    /// ponytail: a shell that deletes for half a minute, rather than anything that tries to
    /// make cfprefsd forget a domain. These files are a check's litter; nobody reads them.
    nonisolated static func sweepScratchSuites() {
        let homes = Set([NSHomeDirectory(), Updater.realHome])
        let paths = droppedSuites.flatMap { s in homes.map { suitePlist(s, home: $0) } }
        guard !paths.isEmpty else { return }
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits this process out, then keeps deleting for half a minute: cfprefsd settles the
        // domain a few seconds *after* its client is gone, and that write is the one that put
        // the file back. Measured — the plists reappeared between two and ten seconds later.
        reaper.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; "
            + "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 3; rm -f "
            + quoted.joined(separator: " ") + "; done"]
        // Detached from our pipes too: a shell holding stdout open keeps `selfcheck | tail`
        // waiting the whole half minute for it.
        reaper.standardInput = FileHandle.nullDevice
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        try? reaper.run()
    }

    nonisolated private static func unlinkSuitePlist(_ suite: String) {
        for home in Set([NSHomeDirectory(), Updater.realHome]) {
            try? FileManager.default.removeItem(atPath: suitePlist(suite, home: home))
        }
    }
}
