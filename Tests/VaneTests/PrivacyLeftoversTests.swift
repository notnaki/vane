import AppKit
import SQLite3
import XCTest
@testable import vane

@MainActor final class PrivacyLeftoversTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    func testPrivateLibraryQueryIsWindowScopedAndClearedOnClose() {
        let normal = TabStore(profileID: UUID(), session: [])
        let first = TabStore(isPrivate: true, session: [])
        let second = TabStore(isPrivate: true, session: [])
        let library = Library.shared
        let old = library.query
        defer {
            library.query = old
            for store in [normal, first, second] {
                Library.close(store)
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.everyTab)
                if !store.isPrivate { Store.forget(store.profileID) }
            }
        }
        library.query = "normal search"
        library.setQuery("private search", in: first)
        XCTAssertEqual(library.query(in: normal), "normal search")
        XCTAssertEqual(library.query(in: first), "private search")
        XCTAssertEqual(library.query(in: second), "")
        first.libraryOpen = true
        Library.close(first)
        XCTAssertEqual(library.query(in: first), "")
        XCTAssertEqual(library.query(in: normal), "normal search")
    }

    private func history() throws -> (Store, String, OpaquePointer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.db").path
        let store = Store(path: path)
        let db = try StoreSQLiteFixture.writer(store)
        addTeardownBlock { @MainActor in
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        return (store, path, db)
    }

    func testHistoryDeletionScrubsFreedPages() throws {
        let (store, path, db) = try history()
        let marker = "deleted-history-secret-" + UUID().uuidString
        let url = URL(string: "https://example.invalid/" + marker)!
        XCTAssertEqual(store.record([(url, String(repeating: marker, count: 30), .now)]), 1)
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        XCTAssertNotNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data(marker.utf8)))
        let visit = try XCTUnwrap(store.history().first)
        XCTAssertTrue(store.deleteVisit(visit.id))
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data(marker.utf8)))
        XCTAssertEqual(store.record([(url, marker, .now)]), 1)
        XCTAssertTrue(store.forget(url: url.absoluteString))
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data(marker.utf8)))
    }

    func testFullClearTruncatesWALAndReportsBlockedCheckpoint() throws {
        let (store, path, _) = try history()
        let url = URL(string: "https://example.invalid/private-history")!
        XCTAssertEqual(store.record([(url, "Sensitive title", .now)]), 1)
        let wal = URL(fileURLWithPath: path + "-wal")
        XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &reader), SQLITE_OK)
        let db = try XCTUnwrap(reader)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN; SELECT * FROM visits", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store.clearHistory(), "A busy checkpoint must not be reported as a successful clear")
        XCTAssertNotNil(store.lastHistoryError)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store.clearHistory())
        XCTAssertNil(store.lastHistoryError)
        XCTAssertEqual(try Data(contentsOf: wal).count, 0)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testProfileDeletionPurgesArchiveAndEveryShapeIncludingOrphans() async throws {
        for asynchronous in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = ProfileManager(directory: directory, sandboxed: true)
            // Exercise deletion of the default profile too: its preference keys have no suffix.
            let victim = asynchronous ? manager.active.id : manager.create(name: "Victim").id
            let survivor = asynchronous ? manager.create(name: "Survivor").id : manager.active.id
            let space = Space(name: "Victim space", profileID: victim)
            XCTAssertTrue(manager.saveSpaces([space], for: victim))
            let orphan = UUID()
            let archive = Archive.shared(for: victim)
            archive.add(url: URL(string: "https://example.invalid/deleted")!, title: "Secret archive")
            var removed = [ProfileManager.defaultsKey("archivedTabs", victim)]
            var kept: [String] = []
            for profile in [victim, survivor] {
                for spaceID in [nil, space.id, orphan] as [UUID?] {
                    for kind in [TabKind.pinned, .today] {
                        let key = TabStore.shapeKey(kind, space: spaceID, profileID: profile)
                        UserDefaults.vane.set(Data("Secret folder".utf8), forKey: key)
                        if profile == victim { removed.append(key) } else { kept.append(key) }
                    }
                }
            }
            defer { for key in removed + kept { UserDefaults.vane.removeObject(forKey: key) } }
            let deleted = asynchronous ? await manager.deleteAsync(victim) : manager.delete(victim)
            XCTAssertTrue(deleted)
            for key in removed { XCTAssertNil(UserDefaults.vane.object(forKey: key), key) }
            for key in kept { XCTAssertNotNil(UserDefaults.vane.object(forKey: key), key) }
            XCTAssertTrue(archive.entries.isEmpty, "An existing archive reader must release deleted rows")
            XCTAssertTrue(Archive.shared(for: victim).entries.isEmpty)
        }
    }
}
