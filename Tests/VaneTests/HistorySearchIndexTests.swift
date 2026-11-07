import XCTest
import SQLite3
@testable import vane

@MainActor final class HistorySearchIndexTests: XCTestCase {
    private func path() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.db").path
    }

    private func rows(_ sql: String, db: OpaquePointer) throws -> [[String]] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(db)))
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        var result: [[String]] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(prepared)).map {
                sqlite3_column_text(prepared, $0).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }

    private func assertURLDateIndex(_ db: OpaquePointer, file: StaticString = #filePath, line: UInt = #line) throws {
        let indexes = try rows("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'visits'", db: db)
        var found = false
        for name in indexes.compactMap(\.first) {
            let escaped = name.replacingOccurrences(of: "'", with: "''")
            let columns = try rows("PRAGMA index_info('\(escaped)')", db: db).map { $0[2] }
            if columns == ["url", "at"] { found = true }
        }
        XCTAssertTrue(found, "Ordinary browsing must have the URL/date index before any import", file: file, line: line)
        let plan = try rows("EXPLAIN QUERY PLAN SELECT id FROM visits WHERE url = 'https://repeat.example' AND at = 1", db: db)
        XCTAssertTrue(plan.contains { $0.last?.contains("url=? AND at=?") == true },
                      "Exact-visit lookup should constrain both indexed columns: \(plan)", file: file, line: line)
    }

    func testNewBrowsingDatabaseHasURLDateIndexWithoutImport() throws {
        let store = Store(path: try path())
        let db = try StoreSQLiteFixture.writer(store)
        try assertURLDateIndex(db)
        let url = URL(string: "https://repeat.example")!
        XCTAssertEqual(store.record([(url, "First", Date(timeIntervalSince1970: 1)),
                                     (url, "Second", Date(timeIntervalSince1970: 1))]), 2)
        XCTAssertEqual(store.history().map(\.title), ["Second", "First"], "The index must remain nonunique")
    }

    func testOpeningExistingDatabaseAddsIndexAndPreservesVisitsAndTitles() throws {
        let database = try path()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &connection), SQLITE_OK)
        let legacy = try XCTUnwrap(connection)
        defer { sqlite3_close(legacy) }
        XCTAssertEqual(sqlite3_exec(legacy, """
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
            CREATE INDEX visits_at ON visits(at DESC);
            CREATE INDEX visits_url ON visits(url);
            INSERT INTO visits VALUES (11, 'https://repeat.example', 'Original', 1);
            INSERT INTO visits VALUES (12, 'https://repeat.example', 'Updated', 2);
            INSERT INTO visits VALUES (13, 'https://repeat.example', 'Duplicate time', 2);
            """, nil, nil, nil), SQLITE_OK)
        let store = Store(path: database)
        try assertURLDateIndex(try StoreSQLiteFixture.writer(store))
        XCTAssertEqual(store.history().map(\.id), [13, 12, 11])
        XCTAssertEqual(store.history().map(\.title), ["Duplicate time", "Updated", "Original"])
        XCTAssertEqual(store.suggest("repeat").map(\.title), ["Duplicate time"])
        let reopened = Store(path: database)
        try assertURLDateIndex(try StoreSQLiteFixture.writer(reopened))
        XCTAssertEqual(reopened.history().map(\.id), [13, 12, 11])
    }
}
