import XCTest
import SQLite3
@testable import vane

@MainActor final class HistoryPersistenceTests: XCTestCase {
    private final class Notifications: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func receive() { lock.lock(); count += 1; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func fixture() throws -> (Store, OpaquePointer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.db").path
        let store = Store(path: path)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        addTeardownBlock { sqlite3_close(db); try? FileManager.default.removeItem(at: directory) }
        return (store, db)
    }

    private func execute(_ sql: String, on db: OpaquePointer) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func observe(_ store: Store) -> Notifications {
        let notifications = Notifications()
        let token = NotificationCenter.default.addObserver(forName: Store.historyChanged, object: nil, queue: nil) { note in
            if note.object as? Store === store { notifications.receive() }
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        return notifications
    }

    func testIdenticalRetitlesDoNotWriteOrRefreshHistory() throws {
        let (store, db) = try fixture()
        let url = URL(string: "https://example.com/title")!
        XCTAssertTrue(store.record([(url, "Old", Date(timeIntervalSince1970: 1)),
                                    (url, "Current", Date(timeIntervalSince1970: 2))]) == 2)
        execute("CREATE TABLE updates (n INTEGER); CREATE TRIGGER count_titles AFTER UPDATE ON visits BEGIN INSERT INTO updates VALUES (1); END", on: db)
        let notifications = observe(store)
        for _ in 0..<100 { XCTAssertTrue(store.retitle(url, title: "Current")) }
        XCTAssertEqual(notifications.total, 0)
        var updates = -1
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM updates", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        updates = Int(sqlite3_column_int(statement, 0))
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(store.retitle(url, title: "Changed"))
        XCTAssertEqual(notifications.total, 1)
        XCTAssertEqual(store.history().map(\.title), ["Changed", "Old"])
    }

    func testRejectedSingleWritesDoNotPublishHistoryChanges() throws {
        let (store, db) = try fixture()
        let url = URL(string: "https://example.com/keep")!
        store.record(url, title: "Original")
        let visit = try XCTUnwrap(store.history().first)
        execute("""
            CREATE TRIGGER reject_insert BEFORE INSERT ON visits BEGIN SELECT RAISE(ABORT, 'blocked insert'); END;
            CREATE TRIGGER reject_update BEFORE UPDATE ON visits BEGIN SELECT RAISE(ABORT, 'blocked update'); END;
            CREATE TRIGGER reject_delete BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT, 'blocked delete'); END;
            """, on: db)
        let notifications = observe(store)
        XCTAssertFalse(store.record(url, title: "Rejected"))
        XCTAssertFalse(store.retitle(url, title: "Rejected"))
        XCTAssertFalse(store.deleteVisit(visit.id))
        XCTAssertFalse(store.forget(url: url.absoluteString))
        XCTAssertFalse(store.clearHistory(since: .distantPast))
        XCTAssertFalse(store.clearHistory())
        XCTAssertTrue(store.lastHistoryError?.contains("blocked delete") == true)
        XCTAssertEqual(store.history(), [visit])
        XCTAssertEqual(notifications.total, 0)
    }

    func testPartialDeletionFailureRollsBackAllDeletedRows() throws {
        let (store, db) = try fixture()
        let url = URL(string: "https://example.com/delete")!
        XCTAssertTrue(store.record(url, title: "First"))
        XCTAssertTrue(store.record(url, title: "Reject"))
        let saved = store.history()
        execute("CREATE TRIGGER reject_delete BEFORE DELETE ON visits WHEN OLD.title = 'Reject' BEGIN SELECT RAISE(FAIL, 'partial delete'); END", on: db)
        let notifications = observe(store)
        XCTAssertFalse(store.clearHistory())
        XCTAssertEqual(store.history(), saved)
        XCTAssertFalse(store.forget(url: url.absoluteString))
        XCTAssertEqual(store.history(), saved)
        XCTAssertEqual(notifications.total, 0)
    }

    func testRejectedImportRollsBackEarlierRowsAndAllowsRetry() throws {
        let (store, db) = try fixture()
        execute("CREATE TRIGGER reject_import BEFORE INSERT ON visits WHEN NEW.title = 'Reject' BEGIN SELECT RAISE(ABORT, 'blocked row'); END", on: db)
        let notifications = observe(store)
        let rows = [(URL(string: "https://example.com/first")!, "First", Date(timeIntervalSince1970: 100)),
                    (URL(string: "https://example.com/reject")!, "Reject", Date(timeIntervalSince1970: 200))]
        XCTAssertNil(store.record(rows))
        XCTAssertTrue(store.lastHistoryError?.contains("blocked row") == true)
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(notifications.total, 0)
        execute("DROP TRIGGER reject_import", on: db)
        XCTAssertEqual(store.record(rows), 2)
        XCTAssertNil(store.lastHistoryError)
        XCTAssertEqual(store.history().map(\.title), ["Reject", "First"])
        XCTAssertEqual(store.history().map { $0.at.timeIntervalSince1970 }, [200, 100])
        XCTAssertEqual(notifications.total, 1)
    }

    func testFailedBeginDoesNotWriteOutsideTransaction() throws {
        let (store, db) = try fixture()
        execute("BEGIN IMMEDIATE", on: db)
        let notifications = observe(store)
        XCTAssertNil(store.record([(URL(string: "https://example.com/locked")!, "Locked", Date.now)]))
        XCTAssertTrue(store.lastHistoryError?.contains("locked") == true)
        execute("ROLLBACK", on: db)
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(notifications.total, 0)
        store.record(URL(string: "https://example.com/retry")!, title: "Retry")
        XCTAssertEqual(store.history().map(\.title), ["Retry"])
    }

    func testFailedCommitRollsBackAndAllowsRetry() throws {
        let (store, db) = try fixture()
        // Change the writer's journal mode before the second connection takes a read lock.
        let writer = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "db" }?.value as? OpaquePointer)
        execute("PRAGMA journal_mode=DELETE", on: writer)
        execute("BEGIN; SELECT * FROM visits", on: db)
        let notifications = observe(store)
        let rows = [(URL(string: "https://example.com/commit")!, "Commit", Date.now)]
        XCTAssertNil(store.record(rows))
        XCTAssertTrue(store.lastHistoryError?.contains("locked") == true)
        execute("ROLLBACK", on: db)
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(notifications.total, 0)
        XCTAssertEqual(store.record(rows), 1)
        XCTAssertEqual(store.history().map(\.title), ["Commit"])
        XCTAssertEqual(notifications.total, 1)
    }

    func testEmptyAndNonWebImportsDoNotPublishHistoryChanges() throws {
        let (store, _) = try fixture()
        let notifications = observe(store)
        XCTAssertEqual(store.record([]), 0)
        XCTAssertEqual(store.record([(URL(string: "about:blank")!, "Blank", Date.now)]), 0)
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(notifications.total, 0)
    }

    func testImportCountExcludesRowsIgnoredBySQLite() throws {
        let (store, db) = try fixture()
        execute("CREATE TRIGGER skip_import BEFORE INSERT ON visits WHEN NEW.title = 'Skip' BEGIN SELECT RAISE(IGNORE); END", on: db)
        XCTAssertEqual(store.record([(URL(string: "https://example.com/save")!, "Save", Date.now),
                                     (URL(string: "https://example.com/skip")!, "Skip", Date.now)]), 1)
        XCTAssertEqual(store.history().map(\.title), ["Save"])
    }

    func testAutomaticRollbackPreservesTheOriginalFailureAndAllowsRetry() throws {
        let (store, db) = try fixture()
        execute("CREATE TRIGGER reject_import BEFORE INSERT ON visits WHEN NEW.title = 'Reject' BEGIN SELECT RAISE(ROLLBACK, 'automatic rollback'); END", on: db)
        XCTAssertNil(store.record([(URL(string: "https://example.com/first")!, "First", Date.now),
                                  (URL(string: "https://example.com/reject")!, "Reject", Date.now)]))
        XCTAssertTrue(store.lastHistoryError?.contains("automatic rollback") == true)
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertTrue(store.record(URL(string: "https://example.com/retry")!, title: "Retry"))
    }

    func testFailedPrepareRollsBackAndAllowsRetry() throws {
        let (store, db) = try fixture()
        execute("ALTER TABLE visits RENAME TO saved_visits", on: db)
        let notifications = observe(store)
        XCTAssertNil(store.record([(URL(string: "https://example.com/prepare")!, "Prepare", Date.now)]))
        XCTAssertTrue(store.lastHistoryError?.contains("no such table") == true)
        execute("ALTER TABLE saved_visits RENAME TO visits", on: db)
        XCTAssertEqual(notifications.total, 0)
        XCTAssertTrue(store.record(URL(string: "https://example.com/retry")!, title: "Retry"))
    }

    func testFailedRollbackClosesTheConnectionBeforeLaterWrites() throws {
        let (store, db) = try fixture()
        let writer = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "db" }?.value as? OpaquePointer)
        execute("CREATE TRIGGER reject_import BEFORE INSERT ON visits WHEN NEW.title = 'Reject' BEGIN SELECT RAISE(ABORT, 'blocked row'); END", on: db)
        sqlite3_set_authorizer(writer, { _, action, name, _, _, _ in
            if action == SQLITE_TRANSACTION, let name, String(cString: name) == "ROLLBACK" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        let notifications = observe(store)
        XCTAssertNil(store.record([(URL(string: "https://example.com/first")!, "First", Date.now),
                                  (URL(string: "https://example.com/reject")!, "Reject", Date.now)]))
        XCTAssertTrue(store.lastHistoryError?.contains("Rollback failed") == true)
        XCTAssertFalse(store.record(URL(string: "https://example.com/later")!, title: "Later"))
        XCTAssertTrue(store.lastHistoryError?.contains("Restart Vane") == true)
        XCTAssertEqual(notifications.total, 0)
        var count: Int32 = -1
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM visits", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        count = sqlite3_column_int(statement, 0)
        XCTAssertEqual(count, 0)
    }

    func testBindingFailureRollsBackEarlierRows() throws {
        let (store, _) = try fixture()
        let writer = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "db" }?.value as? OpaquePointer)
        let previous = sqlite3_limit(writer, SQLITE_LIMIT_LENGTH, 100)
        defer { sqlite3_limit(writer, SQLITE_LIMIT_LENGTH, previous) }
        let notifications = observe(store)
        XCTAssertNil(store.record([(URL(string: "https://example.com/first")!, "First", Date.now),
                                  (URL(string: "https://example.com/long")!, String(repeating: "x", count: 200), Date.now)]))
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(notifications.total, 0)
    }

    func testBrowserImportReportsDestinationFailureInsteadOfSourceCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var source: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("History").path, &source), SQLITE_OK)
        let sourceDB = try XCTUnwrap(source)
        execute("CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER); INSERT INTO urls VALUES ('https://example.com/import', 'Imported', 13300000000000000)", on: sourceDB)
        sqlite3_close(sourceDB)
        let profileID = UUID()
        let destination = Store.store(for: profileID)
        defer { Store.forget(profileID) }
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ProfileManager.dbURL(for: profileID, in: Store.directory).path, &blocker), SQLITE_OK)
        let db = try XCTUnwrap(blocker)
        defer { sqlite3_close(db) }
        execute("BEGIN IMMEDIATE", on: db)
        let profile = BrowserProfile(browser: "Chrome", profile: "Test", path: directory,
                                     hasHistory: true, hasBookmarks: false)
        XCTAssertThrowsError(try BrowserImport.importAll(from: profile, profileID: profileID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Could not save imported history"))
        }
        XCTAssertTrue(destination.history().isEmpty)
        execute("ROLLBACK", on: db)
        let result = try BrowserImport.importAll(from: profile, profileID: profileID)
        XCTAssertEqual(result.history, 1)
        XCTAssertEqual(destination.history().map(\.title), ["Imported"])
    }

    func testArcSummaryIncludesHistoryFailuresAlongsideSuccessfulImports() {
        var counts = ArcImport.Counts()
        counts.spaces = 1
        counts.historyImportFailures = ["History could not be imported: database is locked."]
        XCTAssertEqual(ArcImport.report(counts), "Imported 1 space. History could not be imported: database is locked.")
        counts.spaces = 0
        XCTAssertEqual(ArcImport.report(counts), "Nothing came across. History could not be imported: database is locked.")
    }
}
