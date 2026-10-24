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

extension ExtensionCodeStoreTests {
    func testSweepPreservesActiveStageAcrossStoreValuesThenCollectsReleasedStage() throws {
        var active: ExtensionCodeStore.Stage? = try store.stage(source)
        let revision = try XCTUnwrap(active?.url)
        let otherValue = ExtensionCodeStore(profileID: try XCTUnwrap(UUID(uuidString: store.root.lastPathComponent)), directory: directory)
        try otherValue.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: revision.path))
        active = nil
        try otherValue.sweepUnreferencedRevisions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: revision.path))
    }

    func testSweepUnlinksNestedSymlinksWithoutDeletingTheirTargets() throws {
        let outside = source.appendingPathComponent("keep.js")
        try Data("keep".utf8).write(to: outside)
        var orphan: URL!
        do {
            let stage = try store.stage(source)
            orphan = stage.url
            try FileManager.default.createSymbolicLink(at: stage.url.appendingPathComponent("external"), withDestinationURL: source)
        }
        try store.sweepUnreferencedRevisions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testSweepRefusesSymlinkedExtensionsParent() throws {
        var orphanName: String!
        do { orphanName = try store.stage(source).url.lastPathComponent }
        let extensions = directory.appendingPathComponent("Extensions")
        let protected = directory.appendingPathComponent("protected")
        try FileManager.default.moveItem(at: extensions, to: protected)
        try FileManager.default.createSymbolicLink(at: extensions, withDestinationURL: protected)
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.appendingPathComponent(store.root.lastPathComponent)
            .appendingPathComponent("revisions").appendingPathComponent(orphanName).path))
    }
}

extension ExtensionCodeStoreTests {
    private func leaseHolder(_ revision: String, committedIndex: URL? = nil) throws -> (Process, Pipe) {
        let ready = directory.appendingPathComponent("lease-ready-" + UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import fcntl, os, select, sys
            with open(sys.argv[1], 'r+') as lease:
                fcntl.flock(lease, fcntl.LOCK_EX)
                open(sys.argv[2], 'w').close()
                if not select.select([sys.stdin], [], [], 5)[0]: sys.exit(2)
                command = sys.stdin.buffer.read(1)
                if command == b'C': os.replace(sys.argv[3], sys.argv[4])
            """, store.root.appendingPathComponent(".revision-" + revision.lowercased() + ".lease").path,
            ready.path, committedIndex?.path ?? "", store.root.appendingPathComponent("installations.json").path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw ExtensionCodeStore.Problem("Child process did not acquire its revision lease")
        }
        return (process, input)
    }

    func testSweepPreservesRevisionLeasedByAnotherProcessThenCollectsAfterExit() throws {
        var revision: String!
        var code: URL!
        do { let stage = try store.stage(source); revision = stage.revision; code = stage.url }
        let (child, input) = try leaseHolder(revision)
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: code.path))
        try input.fileHandleForWriting.write(contentsOf: Data("R".utf8))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        try store.sweepUnreferencedRevisions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: code.path))
    }

    func testSweepRechecksAcceptedIndexAfterAnotherProcessCommitsAndReleasesLease() throws {
        var record: ExtensionCodeStore.Record!
        do {
            let stage = try store.stage(source)
            record = .init(identity: UUID().uuidString, revision: stage.revision, sourcePath: source.path,
                name: "Committed by child", version: "1", summary: "", required: .init(permissions: [], sites: []),
                optional: .init(permissions: [], sites: []), compatibility: [])
        }
        let committedIndex = directory.appendingPathComponent("child-index.json")
        try JSONEncoder().encode([source.path: record!]).write(to: committedIndex)
        let (child, input) = try leaseHolder(record.revision, committedIndex: committedIndex)
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(try store.records().isEmpty)
        try input.fileHandleForWriting.write(contentsOf: Data("C".utf8))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.code(for: record).path))
        XCTAssertEqual(try store.records()[source.path]?.revision, record.revision)
    }
}

extension ExtensionCodeStoreTests {
    func testSweepPreservesUnleasedRevisionFromAnOlderProcess() throws {
        try store.save([:])
        let legacy = store.root.appendingPathComponent("revisions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy code".utf8).write(to: legacy.appendingPathComponent("bg.js"))
        try store.sweepUnreferencedRevisions()
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("bg.js"), encoding: .utf8), "legacy code")
    }
}

extension ExtensionCodeStoreTests {
    func testSweepSkipsUnusableTransactionAndRevisionLocksWithoutBlocking() throws {
        var revision: String!
        var code: URL!
        do { let stage = try store.stage(source); revision = stage.revision; code = stage.url }
        let transaction = store.root.appendingPathComponent(".revisions.lock")
        try FileManager.default.removeItem(at: transaction)
        XCTAssertEqual(mkfifo(transaction.path, 0o600), 0)
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: code.path))
        try FileManager.default.removeItem(at: transaction)
        let lease = store.root.appendingPathComponent(".revision-" + revision + ".lease")
        try FileManager.default.removeItem(at: lease)
        XCTAssertEqual(mkfifo(lease.path, 0o600), 0)
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: code.path))
    }
}
