import Foundation
import XCTest
@testable import vane

@MainActor final class SessionConditionalRepairTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testSidecarRepairRestoresExactGenerationsAndDecodedOpaqueState() async throws {
        let directory = try directory(), profile = UUID(), space = UUID()
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: directory)
        let old = ["https://repair.example": Parked(title: "old", state: Data([1]))]
        let current = ["https://repair.example": Parked(title: "current", state: Data([1, 2, 3]))]
        XCTAssertTrue(Suspension.SpaceState.save(old, space: space, profileID: profile, in: directory))
        XCTAssertTrue(Suspension.SpaceState.save(current, space: space, profileID: profile, in: directory))
        let file = Suspension.SpaceState.url(for: profile, in: directory)
        let before = try RecoverySnapshots.Generations.capture(file)
        let edit = await Suspension.SpaceState.stageSave([:], space: space, profileID: profile, in: directory)
        XCTAssertTrue(edit.succeeded)
        let receipt = try XCTUnwrap(edit.change)
        let repaired = await Suspension.SpaceState.repair(receipt)
        XCTAssertTrue(repaired)
        XCTAssertEqual(try RecoverySnapshots.Generations.capture(file), before)
        XCTAssertEqual(Suspension.SpaceState.load(space: space, profileID: profile, in: directory), current)
    }
    func testSidecarRepairMergesAroundNewerUnrelatedSpaceButKeepsNewerSameSpaceWriter() async throws {
        let directory = try directory(), profile = UUID(), a = UUID(), b = UUID()
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: directory)
        let original = ["https://a.example": Parked(title: "A", state: Data([9]))]
        XCTAssertTrue(Suspension.SpaceState.save(original, space: a, profileID: profile, in: directory))
        let staged = await Suspension.SpaceState.stageSave([:], space: a, profileID: profile, in: directory)
        let receipt = try XCTUnwrap(staged.change)
        let newerB = ["https://b.example": Parked(title: "new B")]
        let wroteB = await Suspension.SpaceState.saveAsync(newerB, space: b, profileID: profile, in: directory)
        XCTAssertTrue(wroteB)
        let repaired = await Suspension.SpaceState.repair(receipt)
        XCTAssertTrue(repaired)
        XCTAssertEqual(Suspension.SpaceState.load(space: a, profileID: profile, in: directory), original)
        XCTAssertEqual(Suspension.SpaceState.load(space: b, profileID: profile, in: directory), newerB)
        let next = await Suspension.SpaceState.stageSave([:], space: a, profileID: profile, in: directory)
        let nextReceipt = try XCTUnwrap(next.change)
        let newerA = ["https://a.example": Parked(title: "new A", state: Data([10]))]
        let wroteA = await Suspension.SpaceState.saveAsync(newerA, space: a, profileID: profile, in: directory)
        XCTAssertTrue(wroteA)
        let keptNewer = await Suspension.SpaceState.repair(nextReceipt)
        XCTAssertTrue(keptNewer)
        XCTAssertEqual(Suspension.SpaceState.load(space: a, profileID: profile, in: directory), newerA)
    }
    func testSessionRepairRestoresBothGenerationsAndPreservesNewerWrite() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), space = UUID()
        let file = ProfileManager.sessionURL(for: profile, in: Store.directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
        }
        let old = try XCTUnwrap(Session.encode([[Session.Entry(url: "https://old.example")]], spaces: [space.uuidString]))
        let original = try XCTUnwrap(Session.encode([[Session.Entry(url: "https://current.example")]], spaces: [space.uuidString]))
        XCTAssertTrue(RecoverySnapshots.write(old, to: file, valid: Session.readable))
        XCTAssertTrue(RecoverySnapshots.write(original, to: file, valid: Session.readable))
        let before = try RecoverySnapshots.Generations.capture(file)
        let first = await Session.stageForget(space: space, in: profile)
        XCTAssertTrue(first.succeeded)
        let firstReceipt = try XCTUnwrap(first.change)
        let restored = await Session.repair(firstReceipt)
        XCTAssertTrue(restored)
        XCTAssertEqual(try RecoverySnapshots.Generations.capture(file), before)
        let second = await Session.stageForget(space: space, in: profile)
        let secondReceipt = try XCTUnwrap(second.change)
        let newer = try XCTUnwrap(Session.encode([[Session.Entry(url: "https://newer.example")]], spaces: [space.uuidString]))
        SessionPersistence.shared.enqueue(file: file) { RecoverySnapshots.write(newer, to: file, valid: Session.readable) }
        let saved = await SessionPersistence.shared.flush()
        XCTAssertTrue(saved)
        let retained = await Session.repair(secondReceipt)
        XCTAssertTrue(retained)
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }
}
