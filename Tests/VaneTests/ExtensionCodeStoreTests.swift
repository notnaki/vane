import Foundation
import Darwin
import XCTest
@testable import vane

final class ExtensionCodeStoreTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var store: ExtensionCodeStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("extension-code-store-\(UUID())")
        source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        store = ExtensionCodeStore(profileID: UUID(), directory: directory)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testSnapshotContainsSeparateRegularFilesAndProfileStorage() throws {
        let file = source.appendingPathComponent("file.js")
        try Data("accepted".utf8).write(to: file)
        let stage = try store.stage(source)
        try Data("changed".utf8).write(to: file)
        XCTAssertEqual(try String(contentsOf: stage.url.appendingPathComponent("file.js"), encoding: .utf8), "accepted")
        let other = ExtensionCodeStore(profileID: UUID(), directory: directory)
        XCTAssertNotEqual(stage.url.deletingLastPathComponent(), other.root.appendingPathComponent("revisions"))
        store.discard(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.url.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    func testRejectsInternalFileAndDirectorySymlinksWithoutKeepingPartialCopy() throws {
        for directoryLink in [false, true] {
            let target = directoryLink ? directory! : directory.appendingPathComponent("outside.js")
            if !directoryLink { try Data("outside".utf8).write(to: target) }
            let link = source.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try store.stage(source))
            let revisions = store.root.appendingPathComponent("revisions")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: revisions.path).isEmpty)
            try FileManager.default.removeItem(at: link)
        }
    }

    func testRejectsFIFOWithoutBlockingAndOversizedSparseFile() throws {
        let fifo = source.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try store.stage(source))
        try FileManager.default.removeItem(at: fifo)
        let huge = source.appendingPathComponent("huge")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(ExtensionCodeStore.fileLimit + 1))
        try handle.close()
        XCTAssertThrowsError(try store.stage(source))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("revisions").path).isEmpty)
    }

    func testRejectsSymlinkedManagedStorageAndCorruptRecords() throws {
        let storage = directory.appendingPathComponent("Extensions")
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: source)
        XCTAssertThrowsError(try store.stage(source))
        try FileManager.default.removeItem(at: storage)
        _ = try store.stage(source)
        try Data("corrupt".utf8).write(to: store.root.appendingPathComponent("installations.json"))
        XCTAssertThrowsError(try store.records())
    }
    func testWriterRejectsUnreadableIndexBeforeCommit() throws {
        try store.save([:])
        var records: [String: ExtensionCodeStore.Record] = [:]
        for number in 0...1000 {
            records[String(number)] = .init(identity: UUID().uuidString, revision: UUID().uuidString,
                sourcePath: source.path, name: "Fixture", version: "1.0", summary: "",
                required: .init(permissions: [], sites: []), optional: .init(permissions: [], sites: []), compatibility: [])
        }
        XCTAssertThrowsError(try store.save(records))
        XCTAssertTrue(try store.records().isEmpty)
        var invalid = try XCTUnwrap(records["0"])
        invalid.revision = "../outside"
        XCTAssertThrowsError(try store.save(["fixture": invalid]))
        XCTAssertTrue(try store.records().isEmpty)
    }

}
