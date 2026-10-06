import Foundation
import SQLite3

/// History LIKE/GROUP BY scans belong on this actor, with a connection that never
/// crosses actors. The main connection remains responsible for all writes.
actor LocalSuggestionReader {
    static let debounce = Duration.milliseconds(75)
    private let path: String
    // Only deinit needs nonisolated access; queries are serialized by this actor.
    private nonisolated(unsafe) var db: OpaquePointer?

    init(path: String) { self.path = path }
    deinit { sqlite3_close(db) }

    func suggest(_ query: String, limit: Int = 8, scopedTo engine: SearchEngine? = nil) -> [Suggestion] {
        guard !Task.isCancelled else { return [] }
        if db == nil {
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                db = nil
                return []
            }
        }
        // Superseded scans stop instead of making the newest query queue behind them.
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return Self.read(db, query: query, limit: limit, scopedTo: engine)
    }

    /// Shared with Store's synchronous callers so ranking and wildcard escaping agree.
    nonisolated static func read(_ db: OpaquePointer?, query: String, limit: Int,
                                scopedTo engine: SearchEngine? = nil) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let db, q.count >= 2, limit > 0 else { return [] }
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var out: [Suggestion] = []
        var seen = Set<String>()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        // Scoped reads walk ranked matches until enough belong to the site. A global SQL
        // LIMIT would hide a site's page behind unrelated, more frequently visited pages.
        let cap = engine == nil ? "LIMIT ?" : ""
        func collect(_ sql: String, bookmarked: Bool) {
            if engine != nil, out.count >= limit { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, like, -1, transient)
            sqlite3_bind_text(statement, 2, like, -1, transient)
            if engine == nil { sqlite3_bind_int64(statement, 3, Int64(limit)) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                if let engine, !Bangs.contains(URL(string: url), in: engine) { continue }
                if seen.insert(url).inserted {
                    out.append(Suggestion(url: url, title: title, bookmarked: bookmarked))
                    if engine != nil, out.count >= limit { break }
                }
            }
        }
        collect("""
            SELECT url, title FROM bookmarks
            WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            ORDER BY at DESC \(cap)
            """, bookmarked: true)
        collect("""
            SELECT url, title, COUNT(*) AS hits, MAX(at) AS last FROM visits
            WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
            GROUP BY url ORDER BY hits DESC, last DESC \(cap)
            """, bookmarked: false)
        return Array(out.prefix(limit))
    }
}
