import Foundation
import XCTest
@testable import vane

private final class RetryWritePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    func allow() { lock.withLock { allowed = true } }
    func permits() -> Bool { lock.withLock { allowed } }
}

@MainActor final class SessionRetryOwnershipTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testSuccessfulStagedMutationSupersedesOlderRejectedSnapshot() async throws {
        let lane = SessionPersistence(), directory = try directory(), permission = RetryWritePermission()
        let file = directory.appendingPathComponent("session.json")
        lane.enqueue(file: file) {
            permission.permits() && SnapshotPersistence.write(Data("older rejected snapshot".utf8), to: file)
        }
        let rejected = await lane.flush()
        XCTAssertFalse(rejected)
        permission.allow()
        let staged = await lane.mutate(file: file) { SnapshotPersistence.write(Data("accepted staged snapshot".utf8), to: file) }
        XCTAssertEqual(staged?.value, true)
        let flushed = await lane.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "accepted staged snapshot")
    }
    func testSuccessfulKeyedOperationSupersedesOlderRejectedCapture() async throws {
        let lane = SessionPersistence(), directory = try directory(), permission = RetryWritePermission()
        let file = directory.appendingPathComponent("session.json")
        lane.enqueue(file: file) {
            permission.permits() && SnapshotPersistence.write(Data("older capture".utf8), to: file)
        }
        let rejected = await lane.flush()
        XCTAssertFalse(rejected)
        permission.allow()
        let forgot = await lane.perform(file: file) { SnapshotPersistence.write(Data("successful forget".utf8), to: file) }
        XCTAssertTrue(forgot)
        let flushed = await lane.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "successful forget")
    }
    func testForgetPublishesPendingClosedWindowSnapshotBeforeFilteringDisk() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), removed = UUID(), kept = UUID(), permission = RetryWritePermission()
        let file = ProfileManager.sessionURL(for: profile, in: Store.directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
        }
        let old = try XCTUnwrap(Session.encode([[Session.Entry(url: "https://old.example")]], spaces: [removed.uuidString]))
        let pending = try XCTUnwrap(Session.encode([
            [Session.Entry(url: "https://remove.example")], [Session.Entry(url: "https://accepted-closed-window.example")]
        ], spaces: [removed.uuidString, kept.uuidString]))
        XCTAssertTrue(RecoverySnapshots.write(old, to: file, valid: Session.readable))
        SessionPersistence.shared.enqueue(file: file) {
            permission.permits() && RecoverySnapshots.write(pending, to: file, valid: Session.readable)
        }
        let rejected = await SessionPersistence.shared.flush()
        XCTAssertFalse(rejected)
        let blocked = await Session.stageForget(space: removed, in: profile)
        XCTAssertFalse(blocked.succeeded)
        XCTAssertNil(blocked.change)
        XCTAssertEqual(try Data(contentsOf: file), old)
        permission.allow()
        let staged = await Session.stageForget(space: removed, in: profile)
        XCTAssertTrue(staged.succeeded)
        XCTAssertEqual(Session.decode(try Data(contentsOf: file)).flatMap { $0.map(\.url) }, ["https://accepted-closed-window.example"])
        let repaired = await Session.repair(try XCTUnwrap(staged.change))
        XCTAssertTrue(repaired)
        let flushed = await SessionPersistence.shared.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try Data(contentsOf: file), pending)
        let forgotten = await Session.forgetAsync(space: removed, in: profile)
        XCTAssertTrue(forgotten)
        XCTAssertEqual(Session.decode(try Data(contentsOf: file)).flatMap { $0.map(\.url) }, ["https://accepted-closed-window.example"])
    }
    func testNewerKeyedWriteSupersedesEarlierRetryAndStagedRepair() async throws {
        let lane = SessionPersistence(), directory = try directory(), permission = RetryWritePermission()
        let file = directory.appendingPathComponent("session.json")
        lane.enqueue(file: file) { permission.permits() && SnapshotPersistence.write(Data("old rejected".utf8), to: file) }
        let rejected = await lane.flush()
        XCTAssertFalse(rejected)
        let staged = await lane.mutate(file: file) { SnapshotPersistence.write(Data("staged".utf8), to: file) }
        let flushedWhileStaged = await lane.flush()
        XCTAssertTrue(flushedWhileStaged)
        permission.allow()
        let newer = await lane.perform(file: file) { SnapshotPersistence.write(Data("newer".utf8), to: file) }
        XCTAssertTrue(newer)
        let repaired = await lane.repair(try XCTUnwrap(staged).ownership) { ownsFile in
            if ownsFile { return (SnapshotPersistence.write(Data("rollback".utf8), to: file), .rolledBack) }
            return (true, .unchanged)
        }
        XCTAssertEqual(repaired, true)
        let flushed = await lane.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
    }
    func testRepairRestoresEarlierPendingSidecarWrite() async throws {
        let directory = try directory(), profile = UUID(), space = UUID()
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: directory)
        let first = ["https://pending.example": Parked(title: "first")]
        XCTAssertTrue(Suspension.SpaceState.save(first, space: space, profileID: profile, in: directory))
        let file = Suspension.SpaceState.url(for: profile, in: directory)
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let pending = ["https://pending.example": Parked(title: "accepted before storage failure", state: Data([1, 2, 3]))]
        Suspension.SpaceState.enqueueSave(pending, space: space, profileID: profile, in: directory)
        let rejected = await SessionPersistence.shared.flush()
        XCTAssertFalse(rejected)
        try FileManager.default.removeItem(at: file)
        try original.write(to: file)
        let staged = await Suspension.SpaceState.stageSave([:], space: space, profileID: profile, in: directory)
        XCTAssertTrue(staged.succeeded)
        let receipt = try XCTUnwrap(staged.change)
        let stagedFlush = await SessionPersistence.shared.flush()
        XCTAssertTrue(stagedFlush)
        let repaired = await Suspension.SpaceState.repair(receipt)
        XCTAssertTrue(repaired)
        let flushed = await SessionPersistence.shared.flush()
        XCTAssertTrue(flushed)
        await Suspension.SpaceState.invalidateCache()
        await Suspension.SpaceState.prepare(profiles: [profile], in: directory)
        XCTAssertEqual(Suspension.SpaceState.load(space: space, profileID: profile, in: directory), pending)
    }
}
