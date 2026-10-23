import Foundation
import XCTest
@testable import vane

@MainActor final class SessionWorkerRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-session-worker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testUnchangedSidecarSaveKeepsPreviousGoodGeneration() async throws {
        let directory = try directory(), profile = UUID(), space = UUID()
        await Suspension.SpaceState.prepare(profiles: [profile], in: directory)
        let first = ["https://a.example": Parked(title: "first", state: Data("one".utf8))]
        let second = ["https://a.example": Parked(title: "second", state: Data("two".utf8))]
        XCTAssertTrue(Suspension.SpaceState.save(first, space: space, profileID: profile, in: directory))
        XCTAssertTrue(Suspension.SpaceState.save(second, space: space, profileID: profile, in: directory))
        let file = Suspension.SpaceState.url(for: profile, in: directory)
        let previous = file.appendingPathExtension("previous")
        let knownGood = try Data(contentsOf: previous)
        for _ in 0..<10 {
            Suspension.SpaceState.enqueueSave(second, space: space, profileID: profile, in: directory)
        }
        let succeeded = await SessionPersistence.shared.flush()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: previous), knownGood)
        XCTAssertEqual(Suspension.SpaceState.load(space: space, profileID: profile, in: directory), second)
    }

    func testQueuedSpaceUpdatesMergeInOrderAndRecoverOpaqueStateConservatively() async throws {
        let directory = try directory(), profile = UUID(), a = UUID(), b = UUID()
        await Suspension.SpaceState.prepare(profiles: [profile], in: directory)
        for index in 0..<25 {
            Suspension.SpaceState.enqueueSave(["https://a.example": Parked(title: "\(index)")],
                space: a, profileID: profile, in: directory)
            Suspension.SpaceState.enqueueSave(["https://b.example": Parked(title: "other", state: Data([42]))],
                space: b, profileID: profile, in: directory)
        }
        let saved = await SessionPersistence.shared.flush()
        XCTAssertTrue(saved)
        await Suspension.SpaceState.invalidateCache()
        await Suspension.SpaceState.prepare(profiles: [profile], in: directory)
        XCTAssertEqual(Suspension.SpaceState.load(space: a, profileID: profile, in: directory)["https://a.example"]?.title, "24")
        let file = Suspension.SpaceState.url(for: profile, in: directory)
        try Data("damaged primary".utf8).write(to: file)
        await Suspension.SpaceState.invalidateCache()
        await Suspension.SpaceState.prepare(profiles: [profile], in: directory)
        XCTAssertTrue(Suspension.SpaceState.load(space: b, profileID: profile, in: directory)["https://b.example"]?.needsRecovery == true)
        Suspension.SpaceState.enqueueSave([:], space: a, profileID: profile, in: directory)
        let repaired = await SessionPersistence.shared.flush()
        XCTAssertTrue(repaired)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".damaged-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), Data("damaged primary".utf8))
    }

    func testOrderedLaneFailureIsReportedUntilDestinationSucceeds() async throws {
        let lane = SessionPersistence(), directory = try directory()
        let file = directory.appendingPathComponent("missing/session.json")
        lane.enqueue(file: file) { SnapshotPersistence.write(Data("first".utf8), to: file) }
        let failed = await lane.flush()
        XCTAssertFalse(failed)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for index in 0..<50 {
            lane.enqueue(file: file) { SnapshotPersistence.write(Data("\(index)".utf8), to: file) }
        }
        let succeeded = await lane.flush()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "49")
    }

    func testBlockedWriterDoesNotOccupyMainActor() async throws {
        let lane = SessionPersistence(), release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "worker entered")
        let file = try directory().appendingPathComponent("session.json")
        lane.enqueue(file: file) {
            entered.fulfill()
            release.wait()
            return SnapshotPersistence.write(Data("complete".utf8), to: file)
        }
        await fulfillment(of: [entered], timeout: 2)
        // The main actor reached this point while the worker remains deliberately blocked.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        release.signal()
        let complete = await lane.flush()
        XCTAssertTrue(complete)
    }
}
