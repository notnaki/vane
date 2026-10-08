import XCTest
@testable import vane

@MainActor final class BackupControllerTests: XCTestCase {
    private final class FlushFlag { var saved = true }
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture(); _ = f.seed()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        return f
    }
    func testFlushFailureDoesNotExportStaleData() async throws {
        let f = try fixture(), output = f.root.appendingPathComponent("export.vanebackup")
        let controller = BackupController(library: f.library, flush: { false }, restart: {})
        await controller.export(to: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.busy)
    }
    func testExportUsesOwnDomainAndPublishesCompletedStatus() async throws {
        let f = try fixture(), output = f.root.appendingPathComponent("export.vanebackup")
        f.defaults.set("Saved", forKey: "homepage")
        let controller = BackupController(library: f.library, flush: { true }, restart: {})
        await controller.export(to: output)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.busy)
        let archive = try BackupCodec.read(output)
        XCTAssertEqual(try f.library.validate(archive).profiles.count, 1)
        XCTAssertNotNil(controller.status)
    }
    func testPreviewCancelAndChangedSourceDoNotAffectStagedSnapshot() async throws {
        let source = try fixture(), target = try fixture()
        source.defaults.set("Incoming", forKey: "homepage")
        target.defaults.set("Current", forKey: "homepage")
        let file = source.root.appendingPathComponent("backup.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        var restarted = false
        let controller = BackupController(library: target.library, flush: { true }, restart: { restarted = true })
        await controller.previewRestore(from: file)
        XCTAssertNotNil(controller.preview)
        controller.cancelPreview()
        XCTAssertNil(controller.preview)
        XCTAssertFalse(restarted)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Current")
        await controller.previewRestore(from: file)
        try Data("different".utf8).write(to: file)
        await controller.restorePreview()
        XCTAssertTrue(restarted)
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .restored)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Incoming")
    }
    func testRestartFailureCancelsPendingAndPreservesCurrentData() async throws {
        let source = try fixture(), target = try fixture()
        let file = source.root.appendingPathComponent("backup.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        let controller = BackupController(library: target.library, flush: { true }, restart: { throw CocoaError(.executableNotLoadable) })
        await controller.previewRestore(from: file)
        await controller.restorePreview()
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .none)
    }
    func testAutomaticRecoveryKeepsStatusHonestAfterFailure() async throws {
        let f = try fixture()
        let flag = FlushFlag()
        let controller = BackupController(library: f.library, flush: { flag.saved }, restart: {})
        await controller.retryRecovery()
        XCTAssertEqual(controller.points.count, 1)
        let good = controller.points.first?.id
        flag.saved = false
        await controller.retryRecovery()
        XCTAssertNotNil(controller.recoveryError)
        XCTAssertEqual(controller.points.first?.id, good)
        XCTAssertNil(controller.error)
    }
    func testDamagedCurrentLibraryStillOffersAndAppliesValidRestore() async throws {
        let source = try fixture(), target = try fixture()
        let file = source.root.appendingPathComponent("backup.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        try Data("damaged".utf8).write(to: target.root.appendingPathComponent("profiles.json"))
        var restarted = false
        let controller = BackupController(library: target.library, flush: { false }, restart: { restarted = true })
        await controller.previewRestore(from: file)
        XCTAssertNotNil(controller.preview)
        XCTAssertNotNil(controller.preview?.currentError)
        await controller.restorePreview()
        XCTAssertTrue(restarted)
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .restored)
    }
    func testPendingRestoreBlocksAutomaticRecoveryAndOverlappingActions() async throws {
        let source = try fixture(), target = try fixture()
        let file = source.root.appendingPathComponent("backup.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        let controller = BackupController(library: target.library, flush: { true }, restart: {})
        await controller.previewRestore(from: file)
        await controller.restorePreview()
        await controller.retryRecovery()
        XCTAssertEqual(try BackupRecovery(library: target.library).points().count, 1)
        let export = target.root.appendingPathComponent("export.vanebackup")
        await controller.export(to: export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }
}
