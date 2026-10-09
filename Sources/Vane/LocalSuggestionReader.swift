import Foundation
import SQLite3

/// Reads and cancellable scans own a connection away from the input actor.
actor LocalSuggestionReader {
    static let debounce = Duration.milliseconds(75)
    private let path: String
    private nonisolated(unsafe) var db: OpaquePointer?

    init(path: String) { self.path = path }
    deinit { sqlite3_close(db) }

    private func connect() -> Bool {
        guard !Task.isCancelled else { return false }
        if db == nil {
            guard path != ":memory:",
                  sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db); db = nil
                return false
            }
        }
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        return true
    }

    func suggest(_ query: String, limit: Int = 8, scopedTo engine: SearchEngine? = nil) -> [Suggestion] {
        guard connect() else { return [] }
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return Self.read(db, query: query, limit: limit, scopedTo: engine)
    }

    func history(_ query: String, limit: Int, interval: DateInterval?) -> [Visit] {
        guard connect() else { return [] }
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return Self.readHistory(db, query: query, limit: limit, interval: interval)
    }

    func bookmarks(_ query: String, folderID: String?, unfiledOnly: Bool, limit: Int) -> [Bookmark] {
        guard connect() else { return [] }
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        return Self.readBookmarks(db, query: query, folderID: folderID,
                                  unfiledOnly: unfiledOnly, limit: limit)
    }

    private final class Context {
        let match: SearchMatch
        let engine: SearchEngine?
        let fuzzy: Bool
        init(_ query: String, engine: SearchEngine? = nil) {
            match = SearchMatch(query)
            self.engine = engine
            fuzzy = match.query.count >= 3
        }
    }

    /// Compile the query once for the scalar function. SQLite ranks before LIMIT;
    /// an old exact match cannot be excluded by an arbitrary recent candidate cap.
    private nonisolated static func ranked<T>(_ db: OpaquePointer, query: String,
                                             engine: SearchEngine? = nil,
                                             _ body: () -> T) -> T {
        let context = Context(query, engine: engine)
        sqlite3_create_function_v2(db, "vane_match", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            Unmanaged.passUnretained(context).toOpaque(), { ctx, _, values in
                guard let ctx, let values, let data = sqlite3_user_data(ctx) else { return }
                let context = Unmanaged<Context>.fromOpaque(data).takeUnretainedValue()
                let title = sqlite3_value_text(values[0]).map { String(cString: $0) } ?? ""
                let url = sqlite3_value_text(values[1]).map { String(cString: $0) } ?? ""
                if let engine = context.engine, !Bangs.contains(URL(string: url), in: engine) {
                    sqlite3_result_int(ctx, -1)
                    return
                }
                sqlite3_result_int(ctx, Int32(context.match.page(title: title, url: url,
                    fuzzy: context.fuzzy) ?? -1))
            }, nil, nil, nil)
        defer {
            sqlite3_create_function_v2(db, "vane_match", 2, SQLITE_UTF8, nil, nil, nil, nil, nil)
            withExtendedLifetime(context) {}
        }
        return body()
    }

    private nonisolated static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private nonisolated static func rows(_ db: OpaquePointer, sql: String, pattern: String,
                                        limit: Int, interval: DateInterval? = nil,
                                        folderID: String? = nil,
                                        _ row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, pattern, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(limit))
        if let interval {
            sqlite3_bind_double(statement, 3, interval.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, interval.end.timeIntervalSince1970)
        } else if let folderID {
            sqlite3_bind_text(statement, 3, folderID, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard !Task.isCancelled else { return }
            row(statement)
        }
    }

    private nonisolated static let candidates = """
        (url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
         OR url GLOB '*[^ -~]*' OR title GLOB '*[^ -~]*')
        """

    nonisolated static func readBookmarks(_ db: OpaquePointer?, query: String, folderID: String?,
                                         unfiledOnly: Bool, limit: Int) -> [Bookmark] {
        guard let db, !Task.isCancelled else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        var clauses: [String] = []
        if !q.isEmpty { clauses.append("(url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\')") }
        if folderID != nil { clauses.append("folder_id = ?3") }
        else if unfiledOnly { clauses.append("folder_id IS NULL") }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var out: [Bookmark] = []
        rows(db, sql: "SELECT id, url, title, at, folder_id FROM bookmarks\(whereSQL) ORDER BY at DESC LIMIT ?2",
             pattern: like, limit: limit, folderID: folderID) {
            let folder = sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : text($0, 4)
            out.append(Bookmark(id: sqlite3_column_int64($0, 0), url: text($0, 1), title: text($0, 2),
                                at: Date(timeIntervalSince1970: sqlite3_column_double($0, 3)),
                                folderID: folder))
        }
        return Task.isCancelled ? [] : out
    }

    nonisolated static func read(_ db: OpaquePointer?, query: String, limit: Int,
                                scopedTo engine: SearchEngine? = nil) -> [Suggestion] {
        let match = SearchMatch(query)
        guard let db, match.query.count >= 2, limit > 0 else { return [] }
        struct Hit {
            var suggestion: Suggestion
            let score: Int
            let hits: Int
            let last: Double
        }
        var hits: [Hit] = []
        ranked(db, query: query, engine: engine) {
            rows(db, sql: """
                WITH scored AS MATERIALIZED (
                    SELECT url, title, at, vane_match(title, url) AS score
                    FROM bookmarks WHERE \(candidates))
                SELECT url, title, score, 0, at FROM scored WHERE score >= 0
                ORDER BY score DESC, at DESC, url LIMIT ?2
                """, pattern: match.candidatePattern, limit: limit) {
                    hits.append(Hit(suggestion: Suggestion(url: text($0, 0), title: text($0, 1), bookmarked: true),
                                    score: Int(sqlite3_column_int($0, 2)), hits: 0,
                                    last: sqlite3_column_double($0, 4)))
                }
            rows(db, sql: """
                WITH scored AS MATERIALIZED (
                    SELECT id, url, title, at, vane_match(title, url) AS score
                    FROM visits WHERE \(candidates)),
                pages AS (
                    SELECT *, COUNT(*) OVER (PARTITION BY url) AS hits,
                           MAX(at) OVER (PARTITION BY url) AS last,
                           ROW_NUMBER() OVER (PARTITION BY url ORDER BY score DESC, at DESC, id DESC) AS n
                    FROM scored WHERE score >= 0)
                SELECT url, title, score, hits, last,
                       EXISTS(SELECT 1 FROM bookmarks b WHERE b.url = pages.url) AS bookmarked
                FROM pages WHERE n = 1
                ORDER BY score DESC, bookmarked DESC, hits DESC, last DESC, url LIMIT ?2
                """, pattern: match.candidatePattern, limit: limit) {
                    hits.append(Hit(suggestion: Suggestion(url: text($0, 0), title: text($0, 1),
                                                       bookmarked: sqlite3_column_int($0, 5) != 0),
                                    score: Int(sqlite3_column_int($0, 2)), hits: Int(sqlite3_column_int($0, 3)),
                                    last: sqlite3_column_double($0, 4)))
                }
        }
        guard !Task.isCancelled else { return [] }
        let bookmarked = Set(hits.filter { $0.suggestion.bookmarked }.map { $0.suggestion.url })
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.suggestion.bookmarked != $1.suggestion.bookmarked { return $0.suggestion.bookmarked }
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            if $0.last != $1.last { return $0.last > $1.last }
            return $0.suggestion.url < $1.suggestion.url
        }
        var seen = Set<String>()
        return Array(hits.compactMap { hit -> Suggestion? in
            guard seen.insert(hit.suggestion.url).inserted else { return nil }
            return Suggestion(url: hit.suggestion.url, title: hit.suggestion.title,
                              bookmarked: bookmarked.contains(hit.suggestion.url))
        }.prefix(limit))
    }

    nonisolated static func readHistory(_ db: OpaquePointer?, query: String, limit: Int,
                                       interval: DateInterval? = nil) -> [Visit] {
        guard let db, limit > 0 else { return [] }
        let match = SearchMatch(query)
        var visits: [Visit] = []
        let dates = interval == nil ? "" : "AND at >= ?3 AND at < ?4"
        let collect: (OpaquePointer) -> Void = {
            visits.append(Visit(id: sqlite3_column_int64($0, 0), url: text($0, 1), title: text($0, 2),
                                at: Date(timeIntervalSince1970: sqlite3_column_double($0, 3))))
        }
        if match.query.isEmpty {
            // Browse the date index directly. Opening History must not score or sort
            // the whole database to show its newest five hundred visits.
            rows(db, sql: "SELECT id, url, title, at FROM visits WHERE 1 \(dates) ORDER BY at DESC, id DESC LIMIT ?2",
                 pattern: "%", limit: limit, interval: interval, collect)
        } else {
            ranked(db, query: query) {
                rows(db, sql: """
                    WITH scored AS MATERIALIZED (
                        SELECT id, url, title, at, vane_match(title, url) AS score
                        FROM visits WHERE \(candidates) \(dates))
                    SELECT id, url, title, at FROM scored WHERE score >= 0
                    ORDER BY score DESC, at DESC, id DESC LIMIT ?2
                    """, pattern: match.candidatePattern, limit: limit, interval: interval, collect)
            }
        }
        return Task.isCancelled ? [] : visits
    }
}
