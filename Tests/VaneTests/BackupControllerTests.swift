import XCTest
@testable import vane

@MainActor final class BackupControllerTests: XCTestCase {
    private final class FlushFlag { var saved = true }
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture(); _ = f.seed()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        return f
    }
    func testHistoryClearFlushesLiveHistoryThenPurgesRecoveryPoints() async throws {
        let f = try fixture(), manager = f.seed(), history = f.database(manager.active.id)
        history.record(URL(string: "https://private-history.invalid")!, title: "private visit")
        let recovery = BackupRecovery(library: f.library)
        _ = try recovery.save(f.library.capture(reason: .automatic))
        let controller = BackupController(library: f.library, flush: { true }, restart: {})
        try await controller.clearHistory(history, since: nil)
        XCTAssertTrue(history.history().isEmpty)
        XCTAssertTrue(try recovery.points().isEmpty)
        XCTAssertFalse(controller.busy)
    }

    func testHistoryClearReportsRecoveryPurgeFailure() async throws {
        let f = try fixture(), history = f.database(f.seed().active.id)
        let recoveryRoot = f.root.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: recoveryRoot.appendingPathComponent("Points"))
        let controller = BackupController(library: f.library, flush: { true }, restart: {})
        do { try await controller.clearHistory(history, since: nil); XCTFail("Purge failure must reach the caller") }
        catch {}
        XCTAssertFalse(controller.busy)
    }

    func testHistoryClearRefusesToOverlapAnInFlightRecoveryCapture() async throws {
        let f = try fixture(), history = f.database(f.seed().active.id)
        history.record(URL(string: "https://keep-history.invalid")!, title: "keep")
        var release: CheckedContinuation<Bool, Never>?
        let controller = BackupController(library: f.library, flush: {
            await withCheckedContinuation { release = $0 }
        }, restart: {})
        let capture = Task { await controller.retryRecovery() }
        while release == nil { await Task.yield() }
        do { try await controller.clearHistory(history, since: nil); XCTFail("Wait for capture before clearing") }
        catch {}
        XCTAssertEqual(history.history().count, 1)
        release?.resume(returning: true)
        await capture.value
        try await controller.clearHistory(history, since: nil)
        XCTAssertTrue(try BackupRecovery(library: f.library).points().isEmpty)
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

    func testEncryptedExportRequiresPasswordBeforePreviewAndRestoresTheSnapshot() async throws {
        let source = try fixture(), target = try fixture()
        source.defaults.set("Incoming encrypted", forKey: "homepage")
        target.defaults.set("Current", forKey: "homepage")
        let file = source.root.appendingPathComponent("encrypted.vanebackup")
        let exporter = BackupController(library: source.library, flush: { true }, restart: {})
        await exporter.export(to: file, password: "secret backup password")
        XCTAssertNil(exporter.error)
        XCTAssertThrowsError(try BackupCodec.read(file))
        let controller = BackupController(library: target.library, flush: { true }, restart: {})
        await controller.previewRestore(from: file)
        XCTAssertNil(controller.preview)
        XCTAssertNotNil(controller.error)
        await controller.previewRestore(from: file, password: "incorrect")
        XCTAssertNil(controller.preview)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Current")
        await controller.previewRestore(from: file, password: "secret backup password")
        XCTAssertNotNil(controller.preview)
        XCTAssertNil(controller.error)
        await controller.restorePreview()
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .restored)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Incoming encrypted")
    }

    func testEmptyPasswordExportPreservesExistingDestination() async throws {
        let f = try fixture(), file = f.root.appendingPathComponent("keep.vanebackup")
        try Data("previous backup".utf8).write(to: file)
        let controller = BackupController(library: f.library, flush: { true }, restart: {})
        await controller.export(to: file, password: "")
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(try Data(contentsOf: file), Data("previous backup".utf8))
    }

    func testUnlockRetryUsesFrozenBytesAndCancelKeepsLibraryUntouched() async throws {
        let source = try fixture(), target = try fixture()
        let file = source.root.appendingPathComponent("encrypted.vanebackup")
        let archive = try source.library.capture(reason: .manual)
        try BackupCodec.write(archive, to: file, password: "backup password")
        target.defaults.set("Keep", forKey: "homepage")
        let controller = BackupController(library: target.library, flush: { true }, restart: {})
        var prompts = 0
        await controller.previewRestore(from: file, passwordPrompt: { message in
            prompts += 1
            XCTAssertNil(message)
            return nil
        })
        XCTAssertEqual(prompts, 1)
        XCTAssertNil(controller.preview)
        XCTAssertNil(controller.error)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Keep")
        prompts = 0
        await controller.previewRestore(from: file, passwordPrompt: { message in
            prompts += 1
            if prompts == 1 {
                XCTAssertNil(message)
                try? Data("replaced source".utf8).write(to: file)
                return "wrong password"
            }
            XCTAssertNotNil(message)
            return "backup password"
        })
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(controller.preview?.archive.id, archive.id)
        XCTAssertNil(controller.error)
        XCTAssertEqual(target.defaults.string(forKey: "homepage"), "Keep")
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
        let controller = BackupController(library: target.library, flush: { false }, restart: { restarted = true },
            finalDrain: { repairing in repairing })
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
