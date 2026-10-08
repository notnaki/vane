import XCTest
@testable import vane

final class BackupArchiveTests: XCTestCase {
    private func archive() -> BackupArchive {
        BackupArchive(preferences: Data("settings".utf8),
                      files: [.init(name: "profiles.json", data: Data("profiles".utf8))])
    }
    func testRoundTripPreservesPayloadAndIdentity() throws {
        let original = archive()
        let copy = try BackupCodec.decode(BackupCodec.encode(original))
        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.files, original.files)
        XCTAssertEqual(copy.preferences, original.preferences)
    }
    func testTraversalUnexpectedAndDuplicateEntriesAreRejected() throws {
        for names in [["../profiles.json"], ["/profiles.json"], ["profiles.json", "profiles.json"],
                      ["Recovery/file"], ["vane-other.db"], ["session-xyz.json"],
                      ["FilterLists/../profiles.json"], ["FilterLists/nested/a.txt"]] {
            let bad = BackupArchive(preferences: Data(), files: names.map { .init(name: $0, data: Data()) })
            XCTAssertThrowsError(try BackupCodec.decode(PropertyListEncoder().encode(bad)), names.description)
        }
    }
    func testTamperingAndFutureVersionAreRejected() throws {
        var bad = archive()
        bad.files[0].data.append(1)
        XCTAssertThrowsError(try BackupCodec.decode(PropertyListEncoder().encode(bad)))
        bad = archive(); bad.preferences.append(1)
        XCTAssertThrowsError(try BackupCodec.decode(PropertyListEncoder().encode(bad)))
        bad = archive(); bad.version += 1
        XCTAssertThrowsError(try BackupCodec.decode(PropertyListEncoder().encode(bad)))
        XCTAssertThrowsError(try BackupCodec.decode(Data("broken".utf8)))
    }
    func testSizeBoundaryDoesNotOverflow() {
        XCTAssertTrue(BackupCodec.withinLimit([BackupCodec.limit]))
        XCTAssertFalse(BackupCodec.withinLimit([BackupCodec.limit, 1]))
        XCTAssertFalse(BackupCodec.withinLimit([Int.max, Int.max]))
        XCTAssertFalse(BackupCodec.withinLimit([-1]))
    }
    func testOwnedNamesMatchActualStorageConventions() {
        let id = UUID()
        for name in ["profiles.json", "spaces.json", "session.json", "spacestate.json", "vane.db",
                     "spaces-\(id.uuidString.lowercased()).json", "easels-\(id.uuidString).json",
                     "FilterLists/\(id.uuidString).txt"] { XCTAssertTrue(BackupPaths.isOwned(name), name) }
        XCTAssertFalse(BackupPaths.isOwned("downloads.json"))
        XCTAssertFalse(BackupPaths.isOwned("vane.db-wal"))
        XCTAssertFalse(BackupPaths.isOwned("FilterLists/arbitrary.txt"))
    }
    func testSymlinkInputAndOutputAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.vanebackup"), link = root.appendingPathComponent("link.vanebackup")
        try BackupCodec.write(archive(), to: file)
        let before = try Data(contentsOf: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BackupCodec.read(link))
        XCTAssertThrowsError(try BackupCodec.write(archive(), to: link))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testFailedAtomicWritePreservesCompletedExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("backup.vanebackup")
        try BackupCodec.write(archive(), to: file)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try BackupCodec.write(archive(), to: file, writer: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
