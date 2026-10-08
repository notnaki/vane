import XCTest
import SQLite3
@testable import vane

@MainActor final class BackupLibraryTests: XCTestCase {
    private func fixture() throws -> BackupFixture {
        let fixture = try BackupFixture()
        addTeardownBlock { await MainActor.run { fixture.cleanup() } }
        return fixture
    }
    func testClosedProfilesSettingsAndEaselIdentitySurviveCapture() throws {
        let f = try fixture(), manager = f.seed()
        let work = manager.create(name: "Work")
        let board = try EaselStore(profileID: work.id, directory: f.root).create(title: "Ideas")
        f.defaults.set("https://example.com", forKey: "homepage")
        f.defaults.set(Data([1, 2, 3]), forKey: "archivedTabs")
        let capture = try f.library.capture(reason: .manual)
        let preview = try f.library.validate(capture)
        XCTAssertEqual(preview.profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(preview.profiles.last?.easels, 1)
        let stored = try XCTUnwrap(capture.files.first { $0.name == "easels-\(work.id.uuidString).json" })
        XCTAssertEqual(try JSONDecoder().decode(EaselStore.Archive.self, from: stored.data).boards.first?.id, board.id)
        let prefs = try XCTUnwrap(PropertyListSerialization.propertyList(from: capture.preferences, format: nil) as? [String: Any])
        XCTAssertEqual(prefs["homepage"] as? String, "https://example.com")
        XCTAssertEqual(prefs["archivedTabs"] as? Data, Data([1, 2, 3]))
        XCTAssertFalse(capture.files.contains { $0.name.hasSuffix(".db") })
    }
    func testSQLiteSnapshotIncludesUncheckpointedWAL() throws {
        let f = try fixture(), manager = f.seed(), store = f.database(manager.active.id)
        _ = store.addBookmarks([(URL(string: "https://wal.example")!, "WAL")])
        store.record(URL(string: "https://history.example")!, title: "History")
        let data = try BackupSQLite.snapshot(at: ProfileManager.dbURL(for: manager.active.id, in: f.root))
        let counts = try BackupSQLite.counts(data)
        XCTAssertEqual(counts.bookmarks, 1)
        XCTAssertEqual(counts.history, 1)
        let preview = try f.library.validate(f.library.capture(reason: .manual))
        XCTAssertEqual(preview.profiles.first?.bookmarks, 1)
        XCTAssertEqual(preview.profiles.first?.history, 1)
    }
    func testPreviewCountsSpaceAndSharedSessionTabsWithoutInflation() throws {
        let f = try fixture(), manager = f.seed(), id = manager.active.id
        let a = URL(string: "https://a.example")!, b = URL(string: "https://b.example")!
        let space = Space(name: "Here", profileID: id, tabURLs: [a, a], pinnedURLs: [b], pinnedTabURLs: [a])
        XCTAssertTrue(manager.saveSpaces([space], for: id))
        let entries = [Session.Entry(id: UUID().uuidString, url: a.absoluteString),
                       Session.Entry(id: UUID().uuidString, url: a.absoluteString),
                       Session.Entry(id: UUID().uuidString, url: a.absoluteString, kind: .pinned),
                       Session.Entry(id: UUID().uuidString, url: b.absoluteString, kind: .favourite)]
        try XCTUnwrap(Session.encode([entries, entries], spaces: [space.id.uuidString, space.id.uuidString]))
            .write(to: ProfileManager.sessionURL(for: id, in: f.root))
        let preview = try f.library.validate(f.library.capture(reason: .manual))
        XCTAssertEqual(preview.profiles.first?.tabs, 4)
        XCTAssertEqual(preview.profiles.first?.spaces, 1)
    }
    func testEmbeddedImageBytesAndSidecarArePreserved() throws {
        let f = try fixture(), manager = f.seed(), id = manager.active.id
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII=")!
        let board = EaselBoard(items: [EaselItem(kind: .image, image: png)])
        try f.write(EaselStore.Archive(boards: [board]), name: "easels-\(id.uuidString).json")
        try f.write([String: [String: String]](), name: "spacestate.json")
        let capture = try f.library.capture(reason: .manual)
        _ = try f.library.validate(capture)
        let bytes = try XCTUnwrap(capture.files.first { $0.name.hasPrefix("easels-") }?.data)
        XCTAssertEqual(try JSONDecoder().decode(EaselStore.Archive.self, from: bytes).boards[0].items[0].image, png)
        XCTAssertTrue(capture.files.contains { $0.name == "spacestate.json" })
    }
    func testMalformedPresentFilesAndOrphanProfilesAreRejected() throws {
        for name in ["profiles.json", "spaces.json", "session.json", "spacestate.json", "vane.db"] {
            let f = try fixture(); _ = f.seed()
            try Data("broken".utf8).write(to: f.root.appendingPathComponent(name))
            XCTAssertThrowsError(try f.library.capture(reason: .manual), name)
        }
        let f = try fixture(); _ = f.seed()
        try f.write([Space(name: "Orphan", profileID: UUID())], name: "spaces.json")
        XCTAssertThrowsError(try f.library.capture(reason: .manual))
    }
    func testGlobalDefaultsAndLocalBookkeepingAreExcluded() throws {
        let f = try fixture(); _ = f.seed()
        f.defaults.register(defaults: ["notSaved": true])
        f.defaults.set("local", forKey: "backup.lastPoint")
        f.defaults.set("compiled-cache", forKey: "blockerLastGoodList")
        f.defaults.set(false, forKey: "restoreSession")
        let capture = try f.library.capture(reason: .manual)
        let prefs = try XCTUnwrap(PropertyListSerialization.propertyList(from: capture.preferences, format: nil) as? [String: Any])
        XCTAssertNil(prefs["notSaved"])
        XCTAssertNil(prefs["backup.lastPoint"])
        XCTAssertNil(prefs["blockerLastGoodList"])
        XCTAssertEqual(prefs["restoreSession"] as? Bool, false)
    }
    func testImportedListsAndPreferenceReferencesAreIncluded() throws {
        let f = try fixture(); _ = f.seed()
        let name = try BlockerFiles.importList("||ads.example^", into: f.root.appendingPathComponent("FilterLists"))
        f.defaults.set([name], forKey: "blockerImportedLists")
        let capture = try f.library.capture(reason: .manual)
        XCTAssertEqual(capture.files.first { $0.name == "FilterLists/" + name }?.data, Data("||ads.example^".utf8))
        _ = try f.library.validate(capture)
    }
    func testSourceSymlinkIsRejectedAndDamagedOriginalsCanBePreserved() throws {
        let f = try fixture(); _ = f.seed()
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("spaces.json"),
                                                   withDestinationURL: f.root.appendingPathComponent("profiles.json"))
        XCTAssertThrowsError(try f.library.capture(reason: .manual))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("spaces.json"))
        try Data("damaged".utf8).write(to: f.root.appendingPathComponent("profiles.json"))
        let original = try f.library.capture(reason: .beforeRestore, allowDamaged: true)
        XCTAssertNotNil(original.damage)
        XCTAssertEqual(original.files.first { $0.name == "profiles.json" }?.data, Data("damaged".utf8))
        XCTAssertThrowsError(try f.library.validate(original))
    }
}
