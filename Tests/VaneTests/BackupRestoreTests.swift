import XCTest
@testable import vane

@MainActor final class BackupRestoreTests: XCTestCase {
    private enum Interrupted: Error { case now }
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        _ = f.seed()
        return f
    }
    func testRestoreReplacesOwnedDataRemovesAbsentFilesAndPreservesUnrelatedData() throws {
        let source = try fixture(), target = try fixture()
        let manager = source.seed(), work = manager.create(name: "Work")
        let board = try EaselStore(profileID: work.id, directory: source.root).create(title: "Ideas")
        source.defaults.set("new", forKey: "homepage")
        target.defaults.set("old", forKey: "homepage")
        target.defaults.set("device-local", forKey: "backup.lastPoint")
        try Data("unrelated".utf8).write(to: target.root.appendingPathComponent("keep.txt"))
        try target.write([Space](), name: "spaces.json")
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "old")
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "new")
        XCTAssertEqual(target.defaults.string(forKey: "backup.lastPoint"), "device-local")
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("keep.txt")), Data("unrelated".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("spaces.json").path))
        XCTAssertEqual(EaselStore(profileID: work.id, directory: target.root).boards.first?.id, board.id)
        XCTAssertEqual(try restore.recoverAtLaunch(), .none)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.root.appendingPathComponent("Recovery/Points").path).filter { $0.hasSuffix(".vanebackup") }.count, 1)
    }
    func testRestoreInvalidatesOldFallbacksAndInterruptedRestoreRollsThemBack() throws {
        for interrupted in [false, true] {
            let source = try fixture(), target = try fixture()
            let session = target.root.appendingPathComponent("session.json")
            let sidecar = target.root.appendingPathComponent("spacestate.json")
            let bytes = try XCTUnwrap(Session.encode([[.init(url: "https://recovery.invalid/pre-restore")]]))
            try bytes.write(to: session.appendingPathExtension("previous"))
            try Data("{}".utf8).write(to: sidecar.appendingPathExtension("previous"))
            let restore = BackupRestore(library: target.library, checkpoint: { name in
                if interrupted && name == "preferences" { throw Interrupted.now }
            })
            try restore.prepare(source.library.capture(reason: .manual))
            if interrupted {
                XCTAssertThrowsError(try restore.recoverAtLaunch())
                XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .rolledBack)
                XCTAssertEqual(try Data(contentsOf: session.appendingPathExtension("previous")), bytes)
                XCTAssertEqual(try Data(contentsOf: sidecar.appendingPathExtension("previous")), Data("{}".utf8))
            } else {
                XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
                XCTAssertNil(RecoverySnapshots.read(session, valid: Session.readable))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.appendingPathExtension("previous").path))
            }
        }
    }

    func testEveryInterruptedMutationRollsBackOnNextLaunch() throws {
        let source = try fixture()
        source.defaults.set("new", forKey: "homepage")
        try source.write([Space(name: "New", profileID: ProfileManager.defaultID)], name: "spaces.json")
        let incoming = try source.library.capture(reason: .manual)
        for stop in 0..<8 {
            let target = try fixture()
            target.defaults.set("old", forKey: "homepage")
            try target.write([Space](), name: "spaces.json")
            let before = try target.library.capture(reason: .manual)
            var mutations = 0
            let restore = BackupRestore(library: target.library, checkpoint: { _ in
                defer { mutations += 1 }
                if mutations == stop { throw Interrupted.now }
            })
            try restore.prepare(incoming)
            do { _ = try restore.recoverAtLaunch() } catch Interrupted.now {}
            let result = try BackupRestore(library: target.library).recoverAtLaunch()
            if result == .rolledBack {
                XCTAssertEqual(target.defaults.string(forKey: "homepage"), "old")
                let after = try target.library.capture(reason: .manual)
                XCTAssertEqual(after.files, before.files)
            } else {
                XCTAssertEqual(target.defaults.string(forKey: "homepage"), "new")
                XCTAssertTrue(result == .restored || result == .none)
            }
        }
    }
    func testDamagedCurrentLibraryCanBeReplacedAndItsOriginalsKept() throws {
        let source = try fixture(), target = try fixture()
        try Data("damaged-original".utf8).write(to: target.root.appendingPathComponent("profiles.json"))
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
        XCTAssertNoThrow(try target.library.capture(reason: .manual))
        let points = try FileManager.default.contentsOfDirectory(at: target.root.appendingPathComponent("Recovery/Points"), includingPropertiesForKeys: nil)
        let point = try BackupCodec.read(XCTUnwrap(points.first { $0.pathExtension == "vanebackup" }))
        XCTAssertNotNil(point.damage)
        XCTAssertEqual(point.files.first { $0.name == "profiles.json" }?.data, Data("damaged-original".utf8))
    }
    func testSuccessfulDamagedRestoreRetainsRawDatabaseJournalsInRecoveryPoint() throws {
        let source = try fixture(), target = try fixture()
        let originals = ["vane.db": Data("broken db".utf8),
                         "vane.db-wal": Data("original wal".utf8),
                         "vane.db-shm": Data("original shm".utf8)]
        for (name, data) in originals { try data.write(to: target.root.appendingPathComponent(name)) }
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
        let point = try BackupCodec.read(XCTUnwrap(BackupRecovery(library: target.library).points().first?.url))
        XCTAssertNotNil(point.damage)
        for (name, data) in originals { XCTAssertEqual(point.files.first { $0.name == name }?.data, data, name) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Recovery/Pending").path))
        XCTAssertThrowsError(try target.library.validate(point))
        var disguised = point; disguised.damage = nil
        XCTAssertThrowsError(try BackupCodec.validate(disguised))
    }
    func testDamagedDatabaseAndWALRollBackExactly() throws {
        let source = try fixture(), target = try fixture()
        try Data("broken db".utf8).write(to: target.root.appendingPathComponent("vane.db"))
        try Data("original wal".utf8).write(to: target.root.appendingPathComponent("vane.db-wal"))
        let restore = BackupRestore(library: target.library, checkpoint: { name in
            if name == "preferences" { throw Interrupted.now }
        })
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertThrowsError(try restore.recoverAtLaunch())
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .rolledBack)
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("vane.db")), Data("broken db".utf8))
        XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent("vane.db-wal")), Data("original wal".utf8))
    }
    func testCancellationAndInvalidIncomingNeverChangeTheLibrary() throws {
        let source = try fixture(), target = try fixture()
        let before = try target.library.capture(reason: .manual)
        let restore = BackupRestore(library: target.library)
        var bad = try source.library.capture(reason: .manual); bad.files[0].data.append(1)
        XCTAssertThrowsError(try restore.prepare(bad))
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertThrowsError(try restore.prepare(source.library.capture(reason: .manual)))
        try restore.cancelPending()
        XCTAssertEqual(try restore.recoverAtLaunch(), .none)
        XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files)
    }
    func testSymlinkRecoveryAndStagingFailureDoNotTouchOriginals() throws {
        let source = try fixture(), target = try fixture()
        try FileManager.default.createSymbolicLink(at: target.root.appendingPathComponent("Recovery"), withDestinationURL: source.root)
        XCTAssertThrowsError(try BackupRestore(library: target.library).prepare(source.library.capture(reason: .manual)))
        XCTAssertNoThrow(try target.library.capture(reason: .manual))
    }
    func testRollbackFailureRetainsJournalAndOriginals() throws {
        let source = try fixture(), target = try fixture()
        let restore = BackupRestore(library: target.library, checkpoint: { name in
            if name == "preferences" { throw Interrupted.now }
        })
        try restore.prepare(source.library.capture(reason: .manual))
        XCTAssertThrowsError(try restore.recoverAtLaunch())
        try FileManager.default.removeItem(at: target.root.appendingPathComponent("profiles.json"))
        try FileManager.default.createDirectory(at: target.root.appendingPathComponent("profiles.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try BackupRestore(library: target.library).recoverAtLaunch())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Recovery/Pending/journal.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Recovery/Pending/originals.plist").path))
    }
    func testInterruptedPreparationNeverPublishesPendingTransaction() throws {
        let source = try fixture(), target = try fixture()
        let before = try target.library.capture(reason: .manual)
        let restore = BackupRestore(library: target.library, stageCheckpoint: { throw Interrupted.now })
        XCTAssertThrowsError(try restore.prepare(source.library.capture(reason: .manual)))
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .none)
        XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files)
    }
    func testCorruptedStagedBytesNeverTouchCurrentLibrary() throws {
        let source = try fixture(), target = try fixture()
        let before = try target.library.capture(reason: .manual)
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        try Data("changed".utf8).write(to: target.root.appendingPathComponent("Recovery/Pending/incoming.vanebackup"))
        XCTAssertThrowsError(try restore.recoverAtLaunch())
        XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files)
    }
}
