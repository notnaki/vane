import XCTest
import SQLite3
@testable import vane

@MainActor final class ImportWorkerTests: XCTestCase {
    func testRepeatedUnclosedAnchorsRejectWithoutRepeatedSuffixScanning() throws {
        let input = String(repeating: "<A HREF=x>title", count: 10_000)
        let start = ContinuousClock.now
        XCTAssertThrowsError(try Export.checkedNetscapeEntries(input))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testUnclosedQuotedAttributeRejectsWithoutRepeatedSuffixScanning() throws {
        let input = String(repeating: "<A HREF=\"unfinished", count: 10_000)
        let start = ContinuousClock.now
        XCTAssertThrowsError(try Export.checkedNetscapeEntries(input))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testCommentAndQuotedMarkupDoNotCreateFalseBookmarkTokens() throws {
        let entries = try Export.checkedNetscapeEntries("""
        <!-- <A HREF=broken> -->
        <DL><A HREF="https://example.invalid/?x=<A>&amp;y=>">雪 &amp;lt;</A></DL>
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].row.title, "雪 &lt;")
        XCTAssertEqual(entries[0].row.url, "https://example.invalid/?x=<A>&y=>")
    }
    private func fixture() throws -> (Store, URL) {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-import-worker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("vane.db")
        return (Store(path: file.path), file)
    }

    private func open(_ file: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        return try XCTUnwrap(db)
    }

    private func sql(_ db: OpaquePointer, _ sql: String) throws {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func waitForGate(_ store: Store) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !store.hasPendingWrites, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(store.hasPendingWrites, "The asynchronous import must admit work before it waits on SQLite")
    }

    func testWorkerLockWaitLeavesActorAvailableAndReplaysNavigationAndBookmarkEdits() async throws {
        let (store, file) = try fixture()
        let lock = try open(file)
        defer { sqlite3_close(lock) }
        let page = URL(string: "https://ordinary.invalid/")!
        let imported = URL(string: "https://imported.invalid/")!
        try sql(lock, "BEGIN IMMEDIATE")
        let task = Task { try await store.importBrowserDataAsync(
            visits: [(imported, "Imported", Date(timeIntervalSince1970: 100))], bookmarks: []) }
        await waitForGate(store)
        // Keep the external destination lock held across an input-actor timer turn.
        // The worker's busy timeout and transaction cannot occupy that actor.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.hasPendingWrites)
        // These calls execute on MainActor while the destination remains locked.
        XCTAssertTrue(store.record(page, title: "Before title"))
        XCTAssertTrue(store.retitle(page, title: "After title"))
        let folder = try XCTUnwrap(store.createBookmarkFolder(named: "Queued"))
        XCTAssertEqual(store.addBookmarks([(page, "Queued page")], to: folder.id), 0)
        XCTAssertTrue(store.toggleBookmark(imported, title: "Temporary"))
        XCTAssertFalse(store.toggleBookmark(imported, title: "Temporary"))
        try sql(lock, "COMMIT")
        let result = try await task.value
        XCTAssertEqual(result.history, 1)
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertEqual(store.history(limit: 20).count, 2)
        XCTAssertEqual(store.history(limit: 20).first { $0.url == page.absoluteString }?.title, "After title")
        XCTAssertEqual(store.managedBookmarks().first?.folderID, folder.id)
        XCTAssertFalse(store.isBookmarked(imported))
    }

    func testFailedAtomicImportRollsBackBothCategoriesAndStillReplaysNavigation() async throws {
        let (store, file) = try fixture()
        let db = try open(file)
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TRIGGER reject_import BEFORE INSERT ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic bookmark failure'); END; BEGIN IMMEDIATE")
        let imported = URL(string: "https://rollback.invalid/")!
        let normal = URL(string: "https://kept.invalid/")!
        let task = Task { try await store.importBrowserDataAsync(
            visits: [(imported, "Imported", Date(timeIntervalSince1970: 100))],
            bookmarks: [BookmarkImportItem(url: imported, title: "Imported", folder: "Rolled back")]) }
        await waitForGate(store)
        XCTAssertTrue(store.record(normal, title: "Keep navigation"))
        try sql(db, "COMMIT")
        do { _ = try await task.value; XCTFail("Expected atomic import failure") }
        catch { }
        XCTAssertEqual(store.history(limit: 20).map(\.url), [normal.absoluteString])
        XCTAssertTrue(store.managedBookmarks().isEmpty)
        XCTAssertTrue(store.bookmarkFolders().isEmpty)
        XCTAssertFalse(store.hasPendingWrites)
    }

    func testCancellationRollsBackAndRetainsConcurrentNormalNavigation() async throws {
        let (store, file) = try fixture()
        let db = try open(file)
        defer { sqlite3_close(db) }
        try sql(db, "BEGIN IMMEDIATE")
        let imported = URL(string: "https://cancelled.invalid/")!
        let normal = URL(string: "https://survives.invalid/")!
        let task = Task { try await store.importBrowserDataAsync(
            visits: [(imported, "Cancelled", Date(timeIntervalSince1970: 100))], bookmarks: []) }
        await waitForGate(store)
        XCTAssertTrue(store.record(normal, title: "Survives"))
        task.cancel()
        try sql(db, "COMMIT")
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(store.history(limit: 20).map(\.url), [normal.absoluteString])
        XCTAssertFalse(store.hasPendingWrites)
    }

    func testFailedReplayRetainsUncommittedSuffixForRetryWithoutDuplicatingPrefix() async throws {
        let (store, file) = try fixture()
        let db = try open(file)
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TRIGGER fail_pending BEFORE INSERT ON visits WHEN NEW.title = 'Retry' BEGIN SELECT RAISE(ABORT, 'synthetic pending failure'); END; BEGIN IMMEDIATE")
        let first = URL(string: "https://first.invalid/")!
        let retry = URL(string: "https://retry.invalid/")!
        let task = Task { try await store.importBrowserDataAsync(visits: [], bookmarks: []) }
        await waitForGate(store)
        XCTAssertTrue(store.record(first, title: "Committed prefix"))
        XCTAssertTrue(store.record(retry, title: "Retry"))
        try sql(db, "COMMIT")
        _ = try await task.value
        XCTAssertTrue(store.hasPendingWrites)
        XCTAssertNotNil(store.lastHistoryError)
        XCTAssertEqual(store.history(limit: 20).map(\.url), [first.absoluteString])
        try sql(db, "DROP TRIGGER fail_pending")
        let flushed = await store.flushPendingWrites()
        XCTAssertTrue(flushed)
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertNil(store.lastHistoryError)
        XCTAssertEqual(Set(store.history(limit: 20).map(\.url)), [first.absoluteString, retry.absoluteString])
        XCTAssertEqual(store.history(limit: 20).count, 2)
    }

    func testPasswordCSVReadParseAndInjectedCredentialBatchRunAwayFromUIActor() async throws {
        let (_, database) = try fixture()
        let file = database.deletingLastPathComponent().appendingPathComponent("synthetic-passwords.csv")
        try Data("url,username,password\nhttps://example.invalid,synthetic,example-only\n".utf8).write(to: file)
        let result = try await ImportWork.run {
            try PasswordImport.importFile(file, save: { entry in
                XCTAssertFalse(Thread.isMainThread)
                return entry.account == "synthetic" && entry.password == "example-only"
            })
        }
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testHistoryExportReturnsSnapshotCountAndWritesEveryVisit() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let store = Store.store(for: profile)
        addTeardownBlock { await MainActor.run { Store.forget(profile) } }
        let (_, database) = try fixture()
        let file = database.deletingLastPathComponent().appendingPathComponent("history.json")
        let entries = (0..<25).map { index in
            (URL(string: "https://export.invalid/\(index % 3)")!, "Visit \(index)", Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.record(entries), 25)
        let count = try await Export.exportFile(.historyJSON, profileID: profile, to: file)
        XCTAssertEqual(count, 25)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(rows.first?["title"] as? String, "Visit 24")
    }

    func testBoundedSourceReadRejectsBeforeParsingOrCredentialWrites() throws {
        let (_, database) = try fixture()
        let file = database.deletingLastPathComponent().appendingPathComponent("too-large.csv")
        try Data(repeating: 65, count: 1_025).write(to: file)
        XCTAssertThrowsError(try ImportWork.readText(file, maximumBytes: 1_024))
    }

    func testQueuedClearAndFolderEditsKeepOrderWhenImportCreatesTheSameFolderName() async throws {
        let (store, file) = try fixture()
        let first = URL(string: "https://move.invalid/")!
        let second = URL(string: "https://delete.invalid/")!
        let oldFolder = try XCTUnwrap(store.createBookmarkFolder(named: "Old folder"))
        XCTAssertEqual(store.addBookmarks([(first, "Move"), (second, "Delete")], to: oldFolder.id), 2)
        let bookmarks = store.managedBookmarks()
        let moved = try XCTUnwrap(bookmarks.first { $0.url == first.absoluteString })
        let removed = try XCTUnwrap(bookmarks.first { $0.url == second.absoluteString })
        let db = try open(file)
        defer { sqlite3_close(db) }
        try sql(db, "BEGIN IMMEDIATE")
        let imported = URL(string: "https://folder-import.invalid/")!
        let task = Task { try await store.importBrowserDataAsync(
            visits: [(imported, "Imported", Date(timeIntervalSince1970: 100))],
            bookmarks: [BookmarkImportItem(url: imported, title: "Imported", folder: "Same folder")]) }
        await waitForGate(store)
        let queuedFolder = try XCTUnwrap(store.createBookmarkFolder(named: "Same folder"))
        XCTAssertTrue(store.moveBookmarks([moved.id], to: queuedFolder.id))
        XCTAssertTrue(store.renameBookmarkFolder(queuedFolder.id, to: "Renamed"))
        XCTAssertTrue(store.updateBookmark(moved.id, url: first, title: "Edited", folderID: queuedFolder.id))
        XCTAssertTrue(store.deleteBookmarks([removed.id]))
        XCTAssertTrue(store.deleteBookmarkFolder(oldFolder.id))
        XCTAssertTrue(store.record(second, title: "Before clear"))
        XCTAssertTrue(store.clearHistory())
        XCTAssertTrue(store.record(first, title: "After clear"))
        try sql(db, "COMMIT")
        _ = try await task.value
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertEqual(store.history(limit: 20).map(\.title), ["After clear"])
        XCTAssertEqual(store.bookmarkFolders().map(\.name), ["Renamed"])
        let folder = try XCTUnwrap(store.bookmarkFolders().first)
        XCTAssertEqual(store.managedBookmarks().first { $0.id == moved.id }?.title, "Edited")
        XCTAssertEqual(store.managedBookmarks().first { $0.id == moved.id }?.folderID, folder.id)
        XCTAssertFalse(store.managedBookmarks().contains { $0.id == removed.id })
    }

    func testForgettingProfileWaitsForCancelledWorkerBeforeRemovingFiles() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let store = Store.store(for: profile)
        let file = ProfileManager.dbURL(for: profile, in: Store.directory)
        let db = try open(file)
        defer { sqlite3_close(db); Store.forget(profile) }
        try sql(db, "BEGIN IMMEDIATE")
        let page = URL(string: "https://deleted-profile.invalid/")!
        let task = Task { try await store.importBrowserDataAsync(
            visits: [(page, "Cancelled by deletion", Date(timeIntervalSince1970: 100))], bookmarks: []) }
        await waitForGate(store)
        Store.forget(profile)
        try sql(db, "COMMIT")
        do { _ = try await task.value; XCTFail("Expected deleted profile import cancellation") }
        catch is CancellationError { }
        let deadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLifecyclePauseRejectsNewImportAndDrainsLateAcceptedWrites() async throws {
        let (store, _) = try fixture()
        Store.setAdmissionPaused(true)
        defer { Store.setAdmissionPaused(false) }
        let page = URL(string: "https://late-visit.invalid/")!
        XCTAssertTrue(store.record(page, title: "Late accepted navigation"))
        XCTAssertTrue(store.hasPendingWrites)
        XCTAssertTrue(store.history(limit: 20).isEmpty)
        do {
            _ = try await store.importBrowserDataAsync(visits: [], bookmarks: [])
            XCTFail("New imports must not start during the final quit/restore flush")
        } catch { }
        let saved = await store.flushPendingWrites()
        XCTAssertTrue(saved)
        XCTAssertFalse(store.hasPendingWrites)
        XCTAssertEqual(store.history(limit: 20).map(\.title), ["Late accepted navigation"])
    }

    func testCSVParserHonorsWorkerCancellationBeforeAnyCredentialSave() throws {
        let (_, database) = try fixture()
        let file = database.deletingLastPathComponent().appendingPathComponent("cancelled.csv")
        try Data("url,username,password\nhttps://example.invalid,synthetic,example-only\n".utf8).write(to: file)
        var writes = 0
        XCTAssertThrowsError(try PasswordImport.importFile(file, checkCancellation: { throw CancellationError() }, save: { _ in
            writes += 1; return true
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(writes, 0)
        var checks = 0
        XCTAssertThrowsError(try CSV.parse(String(repeating: "valid,field\n", count: 2_000), checkCancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 2)
    }

}
