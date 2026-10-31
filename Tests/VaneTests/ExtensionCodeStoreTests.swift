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

    func testNativeErrorApprovalMetadataRoundTripsOnlyInItsProfile() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "identity": UUID().uuidString, "revision": UUID().uuidString,
            "sourcePath": source.path, "name": "Native error fixture", "version": "1", "summary": "",
            "required": ["permissions": ["nativeMessaging"], "sites": []],
            "optional": ["permissions": [], "sites": []], "compatibility": [],
            "nativeMessagingErrorCompatibilityVersion": 1
        ])
        let approved = try JSONDecoder().decode(ExtensionCodeStore.Record.self, from: data)
        try store.save([source.path: approved])
        let restored = try XCTUnwrap(store.records()[source.path])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(encoded["nativeMessagingErrorCompatibilityVersion"] as? Int, 1,
                       "Separate error-only approval must survive the accepted-record commit point")
        let other = ExtensionCodeStore(profileID: UUID(), directory: directory)
        XCTAssertTrue(try other.records().isEmpty, "Another profile must not inherit this approval")
    }

    func testNativeErrorModeRequiresKnownApprovalAndDeclaredPermission() {
        let native = ExtensionAccess(permissions: ["nativeMessaging"], sites: [])
        let empty = ExtensionAccess(permissions: [], sites: [])
        for version: Int? in [nil, -1, 0, 2] {
            XCTAssertFalse(ExtensionNativeMessagingErrors.isApproved(version: version, required: native, optional: empty))
        }
        XCTAssertTrue(ExtensionNativeMessagingErrors.isApproved(version: 1, required: native, optional: empty))
        XCTAssertTrue(ExtensionNativeMessagingErrors.isApproved(version: 1, required: empty, optional: native))
        XCTAssertFalse(ExtensionNativeMessagingErrors.isApproved(version: 1, required: empty, optional: empty))
    }

    func testRemovingThenReaddingNativeDeclarationRequiresNewApproval() {
        let native = ExtensionAccess(permissions: ["nativeMessaging"], sites: [])
        let empty = ExtensionAccess(permissions: [], sites: [])
        var old = ExtensionCodeStore.Record(identity: UUID().uuidString, revision: UUID().uuidString,
            sourcePath: source.path, name: "Native fixture", version: "1", summary: "", required: native,
            optional: empty, compatibility: [], nativeMessagingErrorCompatibilityVersion: 1)
        XCTAssertEqual(ExtensionNativeMessagingErrors.retainedVersion(from: old, for: native, optional: empty), 1)
        old.nativeMessagingErrorCompatibilityVersion = ExtensionNativeMessagingErrors.retainedVersion(from: old, for: empty, optional: empty)
        old.required = empty
        XCTAssertNil(old.nativeMessagingErrorCompatibilityVersion)
        XCTAssertNil(ExtensionNativeMessagingErrors.retainedVersion(from: old, for: native, optional: empty))
        old.required = native
        old.nativeMessagingErrorCompatibilityVersion = 2
        XCTAssertNil(ExtensionNativeMessagingErrors.retainedVersion(from: old, for: native, optional: empty))
        XCTAssertNil(ExtensionNativeMessagingErrors.retainedVersion(from: nil, for: native, optional: empty))
    }

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
    private struct LeaseHolderFailure: LocalizedError {
        enum Phase: String, Sendable { case bootstrap; case leaseReadiness = "lease-readiness" }
        let phase: Phase
        let phaseElapsed: Duration
        let errorDescription: String?
    }

    private func leaseDiagnosticTail(_ url: URL) -> String {
        let limit = 4096
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
            let data = try file.read(upToCount: limit) ?? Data()
            return "bytes=\(size); tail=" + String(reflecting: String(decoding: data, as: UTF8.self))
        } catch {
            return "unreadable=" + String(String(describing: error).prefix(512))
        }
    }

    private func leaseHolder(_ revision: String, committedIndex: URL? = nil,
                             bootstrapDelay: TimeInterval = 0, startupTimeout: Duration = .seconds(10),
                             environmentOverrides: [String: String]? = nil) throws -> (Process, Pipe) {
        let diagnosticID = UUID().uuidString
        let ready = directory.appendingPathComponent("lease-ready-" + diagnosticID)
        let stderrURL = directory.appendingPathComponent("lease-stderr-" + diagnosticID)
        let milestonesURL = directory.appendingPathComponent("lease-milestones-" + diagnosticID)
        let startupReady = directory.appendingPathComponent("lease-bootstrap-ready-" + diagnosticID)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        let process = Process()
        if let environmentOverrides {
            process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, override in override }
        }
        process.executableURL = Bundle(for: ExtensionCodeStoreTests.self).bundleURL
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("NativeLeaseHolder")
        process.arguments = [store.root.appendingPathComponent(".revision-" + revision.lowercased() + ".lease").path,
            ready.path, committedIndex?.path ?? "", store.root.appendingPathComponent("installations.json").path,
            milestonesURL.path, startupReady.path, String(bootstrapDelay)]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let launchStarted = ContinuousClock.now
        try process.run()
        let startupStarted = ContinuousClock.now
        let startupDeadline = startupStarted + startupTimeout
        while !FileManager.default.fileExists(atPath: startupReady.path), process.isRunning,
              ContinuousClock.now < startupDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let startupCompleted = FileManager.default.fileExists(atPath: startupReady.path)
        let startupElapsed = startupStarted.duration(to: .now)
        let readinessStarted = ContinuousClock.now
        let deadline = readinessStarted + .seconds(3)
        while startupCompleted, !FileManager.default.fileExists(atPath: ready.path), process.isRunning,
              ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard startupCompleted, FileManager.default.fileExists(atPath: ready.path) else {
            let runningBeforeCleanup = process.isRunning
            let readinessElapsed = readinessStarted.duration(to: .now)
            if runningBeforeCleanup { process.terminate() }
            process.waitUntilExit()
            // Read regular files only after reaping; no diagnostic pipe or reader lifetime.
            try? stderr.close()
            let phase: LeaseHolderFailure.Phase = startupCompleted ? .leaseReadiness : .bootstrap
            let message = startupCompleted ? "Child process did not acquire its revision lease"
                : "Child process did not complete its native bootstrap phase"
            throw LeaseHolderFailure(phase: phase,
                phaseElapsed: startupCompleted ? readinessElapsed : startupElapsed,
                errorDescription: message
                + "; phase=" + phase.rawValue
                + "; pid=\(process.processIdentifier)"
                + "; launchElapsed=\(launchStarted.duration(to: startupStarted))"
                + "; startupElapsed=\(startupElapsed)"
                + "; readinessElapsed=\(readinessElapsed)"
                + "; runningBeforeCleanup=\(runningBeforeCleanup)"
                + "; terminationReason=\(process.terminationReason.rawValue)"
                + "; terminationStatus=\(process.terminationStatus)"
                + "; milestones: " + leaseDiagnosticTail(milestonesURL)
                + "; stderr: " + leaseDiagnosticTail(stderrURL))
        }
        print("Lease child ready; pid=\(process.processIdentifier)"
            + "; launchElapsed=\(launchStarted.duration(to: startupStarted))"
            + "; startupElapsed=\(startupElapsed)"
            + "; readinessElapsed=\(readinessStarted.duration(to: .now))"
            + "; milestones: " + leaseDiagnosticTail(milestonesURL))
        return (process, input)
    }

    func testLeaseHolderBootstrapDelayDoesNotConsumeAcquisitionBudget() throws {
        var revision: String!
        var code: URL!
        do { let stage = try store.stage(source); revision = stage.revision; code = stage.url }
        let began = ContinuousClock.now
        let (child, input) = try leaseHolder(revision, bootstrapDelay: 4)
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        XCTAssertGreaterThanOrEqual(began.duration(to: .now), .seconds(4))
        try store.sweepUnreferencedRevisions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: code.path))
        try input.fileHandleForWriting.write(contentsOf: Data("R".utf8))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        try store.sweepUnreferencedRevisions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: code.path))
    }

    func testLeaseHolderDoesNotDependOnPythonRuntimeEnvironment() throws {
        var revision: String!
        var code: URL!
        do { let stage = try store.stage(source); revision = stage.revision; code = stage.url }
        // Contaminate only the child's interpreter configuration. This controls the
        // external-runtime dependency, not the historical cause of a CI bootstrap stall.
        let missingPythonHome = directory.appendingPathComponent("unavailable-python-runtime")
        do {
            let (child, input) = try leaseHolder(revision, environmentOverrides: ["PYTHONHOME": missingPythonHome.path])
            defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
            try store.sweepUnreferencedRevisions()
            XCTAssertTrue(FileManager.default.fileExists(atPath: code.path))
            try input.fileHandleForWriting.write(contentsOf: Data("R".utf8))
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            try store.sweepUnreferencedRevisions()
            XCTAssertFalse(FileManager.default.fileExists(atPath: code.path))
        } catch {
            XCTFail("The cross-process lease lifecycle must not depend on Python runtime configuration: \(error)")
        }
    }

    func testLeaseHolderHeldParentLeaseStillExhaustsAcquisitionBudget() throws {
        let stage = try store.stage(source)
        withExtendedLifetime(stage) {
            do {
                let (child, _) = try leaseHolder(stage.revision)
                defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
                XCTFail("The child must not acquire the parent's still-live revision lease")
            } catch {
                guard let failure = error as? LeaseHolderFailure else {
                    return XCTFail("Expected phase failure, received \(error)")
                }
                let detail = failure.localizedDescription
                XCTAssertEqual(failure.phase, .leaseReadiness, detail)
                XCTAssertGreaterThanOrEqual(failure.phaseElapsed, .seconds(3))
                // Allow scheduler overshoot, while rejecting use of the 10s startup budget here.
                XCTAssertLessThan(failure.phaseElapsed, .seconds(6))
                XCTAssertTrue(detail.contains("lease-opened"), detail)
                XCTAssertFalse(detail.contains("lease-acquired"), detail)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.url.path))
    }

    func testLeaseHolderReportsBootstrapBudgetExceeded() throws {
        var revision: String!
        do { revision = try store.stage(source).revision }
        do {
            let (child, _) = try leaseHolder(revision, bootstrapDelay: 60, startupTimeout: .milliseconds(100))
            defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
            XCTFail("A child still bootstrapping must exhaust the explicitly shortened startup budget")
        } catch {
            let failure = try XCTUnwrap(error as? LeaseHolderFailure)
            let detail = failure.localizedDescription
            XCTAssertEqual(failure.phase, .bootstrap, detail)
            XCTAssertGreaterThanOrEqual(failure.phaseElapsed, .milliseconds(100))
            XCTAssertLessThan(failure.phaseElapsed, .seconds(3))
            XCTAssertFalse(detail.contains("lease-opened"), detail)
        }
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

