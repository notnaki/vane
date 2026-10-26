import Combine
import XCTest
@testable import vane

@MainActor final class SpaceSavePublicationTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }

    func testUnchangedOwnedSnapshotWritesWithoutPublishing() throws {
        let manager = try manager(), profile = manager.active.id
        let space = Space(name: "Work", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        let revision = manager.spacesRevision
        var revisions = 0, failures = 0, changes = 0
        let a = manager.$spacesRevision.dropFirst().sink { _ in revisions += 1 }
        let b = manager.$saveFailures.dropFirst().sink { _ in failures += 1 }
        let c = manager.objectWillChange.sink { changes += 1 }
        defer { a.cancel(); b.cancel(); c.cancel() }
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        // Different encoding of identical data must still be replaced by the save.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([space]).write(to: file)
        let before = try Data(contentsOf: file)
        let foreign = Space(name: "Excluded", profileID: UUID())
        XCTAssertTrue(manager.saveSpaces([space, foreign], for: profile))
        XCTAssertNotEqual(try Data(contentsOf: file), before, "No-op publication suppression must not skip durable writes")
        XCTAssertEqual(manager.spaces(for: profile), [space])
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertEqual(revisions, 0)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(changes, 0)
        manager.dismissSaveFailure(.spaces(profile))
        XCTAssertEqual(failures, 0, "Clearing an absent failure must not publish")
    }

    func testRealMetadataOrderAndDeletionChangesPublish() throws {
        let manager = try manager(), profile = manager.active.id
        var first = Space(name: "One", profileID: profile)
        let second = Space(name: "Two", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([first, second], for: profile))
        var revisions = 0
        let subscription = manager.$spacesRevision.dropFirst().sink { _ in revisions += 1 }
        defer { subscription.cancel() }
        first.name = "Renamed"
        XCTAssertTrue(manager.saveSpaces([first, second], for: profile))
        XCTAssertTrue(manager.saveSpaces([second, first], for: profile))
        XCTAssertTrue(manager.saveSpaces([second], for: profile))
        XCTAssertEqual(revisions, 3)
        XCTAssertEqual(manager.spaces(for: profile), [second])
    }

    func testMissingAndMalformedEmptyFilesPublishSuccessfulRepair() throws {
        let manager = try manager(), profile = manager.active.id
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        var revisions = 0
        let subscription = manager.$spacesRevision.dropFirst().sink { _ in revisions += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(manager.saveSpaces([], for: profile))
        XCTAssertEqual(revisions, 1)
        try Data("malformed".utf8).write(to: file)
        XCTAssertTrue(manager.saveSpaces([], for: profile))
        XCTAssertEqual(revisions, 2)
        XCTAssertEqual(try JSONDecoder().decode([Space].self, from: Data(contentsOf: file)), [])
        XCTAssertTrue(manager.saveSpaces([], for: profile))
        XCTAssertEqual(revisions, 2)
    }

    func testFailureAndRecoveryPublishOnlyActualFailureTransition() throws {
        let manager = try manager(), profile = manager.active.id
        let space = Space(name: "Saved", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        let revision = manager.spacesRevision
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        let original = try Data(contentsOf: file)
        var failures = 0, revisions = 0
        let a = manager.$saveFailures.dropFirst().sink { _ in failures += 1 }
        let b = manager.$spacesRevision.dropFirst().sink { _ in revisions += 1 }
        defer { a.cancel(); b.cancel() }
        var invalid = space; invalid.tint = .nan
        XCTAssertFalse(manager.saveSpaces([invalid], for: profile))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        XCTAssertEqual(failures, 2)
        XCTAssertTrue(manager.saveFailures.isEmpty)
        XCTAssertEqual(revisions, 0)
        // An unavailable destination must still report a failed write.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertFalse(manager.saveSpaces([space], for: profile))
        XCTAssertFalse(manager.saveFailures.isEmpty)
        XCTAssertEqual(revisions, 0)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        XCTAssertTrue(manager.saveFailures.isEmpty)
        XCTAssertEqual(revisions, 1)
    }
    func testCommittedStaleLayoutAndForeignRecordRepairsPublish() throws {
        let manager = try manager(), profile = manager.active.id
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        var space = Space(name: "Repair", profileID: profile, tabURLs: [URL(string: "https://example.com/new")!])
        space.layout = SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil)
        try space.layout!.validate()
        XCTAssertFalse(space.layout!.matches(space))
        try JSONEncoder().encode([space]).write(to: file)
        var revisions = 0
        let subscription = manager.$spacesRevision.dropFirst().sink { _ in revisions += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        XCTAssertEqual(revisions, 1)
        let repaired = try XCTUnwrap(manager.spaces(for: profile).first)
        XCTAssertTrue(try XCTUnwrap(repaired.layout).matches(repaired))
        XCTAssertTrue(manager.saveSpaces([repaired], for: profile))
        XCTAssertEqual(revisions, 1)
        try JSONEncoder().encode([repaired, Space(name: "Foreign", profileID: UUID())]).write(to: file)
        XCTAssertTrue(manager.saveSpaces([repaired], for: profile))
        XCTAssertEqual(revisions, 2)
        XCTAssertEqual(try JSONDecoder().decode([Space].self, from: Data(contentsOf: file)), [repaired])
    }

    func testDeletedProfileCannotBeRecreatedByStaleSave() throws {
        let manager = try manager()
        let victim = manager.create(name: "Removed")
        let space = Space(name: "Stale", profileID: victim.id)
        XCTAssertTrue(manager.saveSpaces([space], for: victim.id))
        XCTAssertTrue(manager.delete(victim.id))
        let file = ProfileManager.spacesURL(for: victim.id, in: manager.directory)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let revision = manager.spacesRevision
        var changes = 0
        let subscription = manager.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        XCTAssertFalse(manager.saveSpaces([space], for: victim.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertEqual(changes, 0)
    }

}
