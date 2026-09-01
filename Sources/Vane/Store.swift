import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Suggestion: Identifiable, Equatable {
    var id: String { url }
    let url: String
    let title: String
    let bookmarked: Bool
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

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        CREATE INDEX IF NOT EXISTS visits_at  ON visits(at DESC);
        CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
        CREATE TABLE IF NOT EXISTS bookmarks (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
        """)
    }

    /// Deleting a profile drops its Store; close the file rather than leaking the handle.
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Prepare, bind, step. Text binds use TRANSIENT because the Swift strings backing
    /// them are gone before sqlite3_step runs.
    private func run(_ sql: String, _ binds: [Any], _ row: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case let s as String: sqlite3_bind_text(st, n, s, -1, TRANSIENT)
            case let d as Double: sqlite3_bind_double(st, n, d)
            case let i as Int:    sqlite3_bind_int64(st, n, Int64(i))
            default: sqlite3_bind_null(st, n)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row?(st!) }
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

    /// Bulk insert in one transaction, keeping each visit's real timestamp.
    /// ponytail: the single-row `record` above is one implicit transaction — and one fsync
    /// — per row. That is why importing used to cap at 5000 pages and throw the real dates
    /// away. One BEGIN and one reused statement makes both limits unnecessary.
    func record(_ visits: [(url: URL, title: String, at: Date)]) {
        guard !visits.isEmpty else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO visits (url, title, at) VALUES (?, ?, ?)",
                                 -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        exec("BEGIN")
        for v in visits where v.url.scheme == "http" || v.url.scheme == "https" {
            sqlite3_bind_text(st, 1, v.url.absoluteString, -1, TRANSIENT)
            sqlite3_bind_text(st, 2, v.title, -1, TRANSIENT)
            sqlite3_bind_double(st, 3, v.at.timeIntervalSince1970)
            sqlite3_step(st)
            sqlite3_reset(st)
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

    func clearHistory() { exec("DELETE FROM visits") }

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
        guard !marks.isEmpty else { return 0 }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO bookmarks (url, title, at) VALUES (?, ?, ?)",
                                 -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        exec("BEGIN")
        var added = 0
        let now = Date.now.timeIntervalSince1970
        for m in marks where m.url.scheme == "http" || m.url.scheme == "https" {
            sqlite3_bind_text(st, 1, m.url.absoluteString, -1, TRANSIENT)
            sqlite3_bind_text(st, 2, m.title, -1, TRANSIENT)
            sqlite3_bind_double(st, 3, now)
            if sqlite3_step(st) == SQLITE_DONE { added += Int(sqlite3_changes(db)) }
            sqlite3_reset(st)
        }
        exec("COMMIT")
        return added
    }

    func bookmarks(limit: Int = 500) -> [Suggestion] {
        var out: [Suggestion] = []
        run("SELECT url, title FROM bookmarks ORDER BY at DESC LIMIT ?", [limit]) {
            out.append(Suggestion(url: self.text($0, 0), title: self.text($0, 1), bookmarked: true))
        }
        return out
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
