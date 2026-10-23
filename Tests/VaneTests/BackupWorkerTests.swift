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
