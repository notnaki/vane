import XCTest
@testable import vane

@MainActor final class BackupWorkerTests: XCTestCase {
    private func fixture() throws -> BackupFixture {
        let fixture = try BackupFixture()
        _ = fixture.seed()
        addTeardownBlock { await MainActor.run { fixture.cleanup() } }
        return fixture
    }

    func testBlockedBackupWorkerLeavesMainActorResponsiveAndExportOrdered() async throws {
        let fixture = try fixture(), worker = BackupWorker()
        let entered = expectation(description: "backup worker entered")
        let release = DispatchSemaphore(value: 0)
        let blocking = Task {
            await worker.run {
                entered.fulfill()
                release.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        defer { release.signal() }
        let output = fixture.root.appendingPathComponent("export.vanebackup")
        let flushing = expectation(description: "export flushed current state")
        let controller = BackupController(library: fixture.library, flush: { flushing.fulfill(); return true }, restart: {}, worker: worker)
        let export = Task { await controller.export(to: output) }
        await fulfillment(of: [flushing], timeout: 3)
        XCTAssertTrue(controller.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        // Reaching here while disk work is blocked proves native UI work can execute.
        release.signal()
        await blocking.value
        await export.value
        XCTAssertNil(controller.error)
        XCTAssertEqual(try BackupCodec.read(output).reason, .manual)
    }

    func testStableCaptureRetriesAnAtomicFileReplacement() throws {
        let fixture = try fixture(), library = fixture.library
        let file = fixture.root.appendingPathComponent("spaces.json")
        try fixture.write([Space](), name: "spaces.json")
        var reads = 0
        let archive = try library.capture(reason: .manual, checkpoint: {
            reads += 1
            if reads == 1 { try Data("[ ]".utf8).write(to: file, options: .atomic) }
        })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(archive.files.first(where: { $0.name == "spaces.json" })?.data, Data("[ ]".utf8))
    }

    func testContinuousFileChangesRejectSnapshotAndLeaveOriginals() throws {
        let fixture = try fixture(), library = fixture.library
        let file = fixture.root.appendingPathComponent("spaces.json")
        try fixture.write([Space](), name: "spaces.json")
        var reads = 0
        XCTAssertThrowsError(try library.capture(reason: .manual, checkpoint: {
            reads += 1
            try Data((reads % 2 == 0 ? "[]" : "[ ]").utf8).write(to: file, options: .atomic)
        }))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(try Data(contentsOf: file), Data("[ ]".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Recovery").path))
    }

    func testStableCaptureRetriesChangedPreferences() throws {
        let fixture = try fixture(), library = fixture.library
        fixture.defaults.set("Before", forKey: "homepage")
        var reads = 0
        let archive = try library.capture(reason: .manual, checkpoint: {
            reads += 1
            if reads == 1 { fixture.defaults.set("After", forKey: "homepage") }
        })
        let preferences = try XCTUnwrap(PropertyListSerialization.propertyList(from: archive.preferences, format: nil) as? [String: Any])
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(preferences["homepage"] as? String, "After")
    }

    func testRestorePreservesChangesSavedAfterAsynchronousPreparation() throws {
        let source = try fixture(), target = try fixture()
        target.defaults.set("Before", forKey: "homepage")
        let restore = BackupRestore(library: target.library)
        try restore.prepare(source.library.capture(reason: .manual))
        target.defaults.set("Saved during preparation", forKey: "homepage")
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
        let points = try BackupRecovery(library: target.library).points()
        XCTAssertTrue(try points.contains { point in
            let archive = try BackupCodec.read(point.url)
            let values = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil) as? [String: Any]
            return values?["homepage"] as? String == "Saved during preparation"
        })
    }
}

extension BackupWorkerTests {
    func testBlockedBundleVerificationLeavesMainActorFreeAndKeepsRollbackUntilHealth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-update-worker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("incoming.app"), target = root.appendingPathComponent("Vane.app")
        for (url, value) in [(source, "new"), (target, "old")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url.appendingPathComponent("fixture"))
        }
        try BundleReplacement.install(source: source, at: target, keepPrevious: false,
                                      verify: { _ in true }, mayReplaceTarget: { _ in true })
        XCTAssertEqual(BundleReplacement.beginLaunch(at: target), .waitingForHealth)
        let entered = expectation(description: "signature verification entered")
        let release = DispatchSemaphore(value: 0), worker = BackupWorker()
        let health = Task {
            await worker.run {
                BundleReplacement.markHealthy(at: target, verifyRecovery: { _ in
                    entered.fulfill()
                    release.wait()
                    return true
                }, verifyPrevious: { _ in true })
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        // Verification has not authorized deletion, and the main actor can inspect UI.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(siblings.contains(where: { $0.hasPrefix(".Vane.app.vane-stage-") }))
        release.signal()
        await health.value
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("fixture")), Data("new".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".Vane.app.vane-stage-") }))
    }
}

extension BackupWorkerTests {
    func testRestoreFinalGateDrainsEaselEditAdmittedDuringPreparationAndRejectsNewEdits() async throws {
        TestEnvironment.prepare()
        let source = try fixture(), target = try fixture(), worker = BackupWorker()
        let file = source.root.appendingPathComponent("incoming.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        let saveGate = EaselWorkerGate("save")
        let easels = EaselStore(profileID: ProfileManager.defaultID, directory: target.root,
                                background: true, inspection: saveGate.inspect)
        await easels.waitUntilReady()
        let finalDrainEntered = expectation(description: "quiescent final drain")
        var restarted = false
        let controller = BackupController(library: target.library, flush: { true }, restart: {
            XCTAssertTrue(AppLifecycle.shared.persistenceExitInProgress)
            XCTAssertEqual(easels.boards.first?.title, "Accepted during preparation")
            restarted = true
        }, worker: worker, finalDrain: { _ in
            finalDrainEntered.fulfill()
            do { try await easels.flush(); return true } catch { return false }
        })
        await controller.previewRestore(from: file)
        let entered = expectation(description: "preparation worker blocked")
        let release = DispatchSemaphore(value: 0)
        let blocking = Task { await worker.run { entered.fulfill(); release.wait() } }
        await fulfillment(of: [entered], timeout: 3)
        let restore = Task { await controller.restorePreview() }
        // The edit is admitted while the preparation worker is occupied.
        let edit = Task { try await easels.createAsync(title: "Accepted during preparation") }
        await saveGate.waitForEntry()
        release.signal(); await blocking.value
        await fulfillment(of: [finalDrainEntered], timeout: 3)
        XCTAssertTrue(AppLifecycle.shared.persistenceExitInProgress)
        do { _ = try await easels.createAsync(title: "Too late"); XCTFail("new edit admitted during exit") }
        catch { XCTAssertEqual(error.localizedDescription, EaselStore.Failure.exiting.localizedDescription) }
        XCTAssertFalse(restarted)
        saveGate.resume()
        _ = try await edit.value
        await restore.value
        XCTAssertTrue(restarted)
        XCTAssertNil(controller.error)
        XCTAssertFalse(AppLifecycle.shared.persistenceExitInProgress)
        let points = try BackupRecovery(library: target.library).points()
        let preserved = try points.contains { point in
            let archive = try BackupCodec.read(point.url)
            let name = "easels-\(ProfileManager.defaultID.uuidString).json"
            guard let bytes = archive.files.first(where: { $0.name == name })?.data else { return false }
            return try JSONDecoder().decode(EaselStore.Archive.self, from: bytes).boards
                .contains(where: { $0.title == "Accepted during preparation" })
        }
        XCTAssertTrue(preserved)
    }

    func testRestoreFinalWriteFailureCancelsPendingBeforeReleasingQueuedIngress() async throws {
        TestEnvironment.prepare()
        let source = try fixture(), target = try fixture(), worker = BackupWorker()
        let file = source.root.appendingPathComponent("incoming.vanebackup")
        try BackupCodec.write(source.library.capture(reason: .manual), to: file)
        let saveEntered = expectation(description: "accepted write blocked")
        let releaseSave = DispatchSemaphore(value: 0)
        let easels = EaselStore(profileID: ProfileManager.defaultID, directory: target.root, background: true,
            inspection: { stage in
                if stage == "save" {
                    saveEntered.fulfill(); releaseSave.wait()
                    throw CocoaError(.fileWriteNoPermission)
                }
            })
        await easels.waitUntilReady()
        let finalDrainEntered = expectation(description: "final drain waits failed write")
        var restarted = false, replayed = false
        let controller = BackupController(library: target.library, flush: { true }, restart: { restarted = true },
            worker: worker, finalDrain: { _ in
                finalDrainEntered.fulfill()
                AppLifecycle.shared.afterBootstrap {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: target.root.appendingPathComponent("Recovery/Pending").path))
                    replayed = true
                }
                do { try await easels.flush(); return true } catch { return false }
            })
        await controller.previewRestore(from: file)
        let entered = expectation(description: "preparation worker blocked")
        let release = DispatchSemaphore(value: 0)
        let blocking = Task { await worker.run { entered.fulfill(); release.wait() } }
        await fulfillment(of: [entered], timeout: 3)
        let restore = Task { await controller.restorePreview() }
        let edit = Task { try await easels.createAsync(title: "Cannot persist") }
        await fulfillment(of: [saveEntered], timeout: 3)
        release.signal(); await blocking.value
        await fulfillment(of: [finalDrainEntered], timeout: 3)
        XCTAssertTrue(AppLifecycle.shared.persistenceExitInProgress)
        XCTAssertFalse(replayed)
        releaseSave.signal()
        do { _ = try await edit.value; XCTFail("write failure lost") } catch {}
        await restore.value
        XCTAssertFalse(restarted)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(replayed)
        XCTAssertFalse(AppLifecycle.shared.persistenceExitInProgress)
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .none)
    }
}

extension BackupWorkerTests {
    func testDamagedEvidenceCaptureDoesNotRebuildOriginalSHMAndRefreshKeepsRawProof() throws {
        let fixture = try fixture()
        let originals = ["vane.db": Data("broken db".utf8),
                         "vane.db-wal": Data("original wal".utf8),
                         "vane.db-shm": Data("original shm".utf8)]
        for (name, bytes) in originals { try bytes.write(to: fixture.root.appendingPathComponent(name)) }
        // Preview's ordinary healthy-only capture must not destroy proof before
        // restore preparation gets the chance to preserve it.
        XCTAssertThrowsError(try fixture.library.capture(reason: .manual))
        let captured = try fixture.library.capture(reason: .beforeRestore, allowDamaged: true)
        XCTAssertNotNil(captured.damage)
        for (name, bytes) in originals {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(name)), bytes, name)
            XCTAssertEqual(captured.files.first(where: { $0.name == name })?.data, bytes, name)
        }
        let recovery = BackupRecovery(library: fixture.library)
        try recovery.save(captured)
        // Older read-only SQLite inspection can rebuild SHM without changing data.
        try Data(repeating: 0, count: 32768).write(to: fixture.root.appendingPathComponent("vane.db-shm"))
        let refreshed = try fixture.library.capture(reason: .beforeRestore, allowDamaged: true)
        XCTAssertNil(try recovery.beforeRestorePointIfChanged(refreshed))
        XCTAssertEqual(try recovery.points().count, 1)
        let preserved = try BackupCodec.read(XCTUnwrap(recovery.points().first?.url))
        XCTAssertEqual(preserved.files.first(where: { $0.name == "vane.db-shm" })?.data, originals["vane.db-shm"])
        // A real preference change still gets a distinct point; initial proof survives.
        fixture.defaults.set("new saved setting", forKey: "homepage")
        let changed = try fixture.library.capture(reason: .beforeRestore, allowDamaged: true)
        XCTAssertNotNil(try recovery.beforeRestorePointIfChanged(changed))
        XCTAssertEqual(try recovery.points().count, 2)
        XCTAssertTrue(try recovery.points().contains { point in
            try BackupCodec.read(point.url).files.first(where: { $0.name == "vane.db-shm" })?.data == originals["vane.db-shm"]
        })
    }
}
