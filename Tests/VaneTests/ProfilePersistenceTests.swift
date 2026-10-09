import XCTest
@testable import vane

@MainActor final class ProfilePersistenceTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }

    private func blockList(_ manager: ProfileManager) throws -> URL {
        let file = manager.directory.appendingPathComponent("profiles.json")
        let backup = manager.directory.appendingPathComponent("profiles.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        return backup
    }

    private func unblockList(_ manager: ProfileManager, backup: URL) throws {
        let file = manager.directory.appendingPathComponent("profiles.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
    }

    func testFailedProfileEditsRemainVisibleAndRetrySavesTheLatestState() throws {
        let manager = try manager()
        let backup = try blockList(manager)
        let committed = try Data(contentsOf: backup)
        let profile = manager.create(name: "Draft")
        manager.rename(profile.id, to: "Latest name")
        manager.setColor("#123456", for: profile.id)
        manager.active = profile
        XCTAssertTrue(manager.hasUnsavedProfileChanges)
        XCTAssertEqual(manager.saveFailures.count, 1)
        XCTAssertEqual(manager.saveFailures.first?.canRetry, true)
        XCTAssertNotNil(manager.saveFailures.first?.details)
        manager.dismissSaveFailure(.profiles)
        XCTAssertEqual(manager.saveFailures.count, 1)
        XCTAssertFalse(manager.retryProfileSave())
        XCTAssertTrue(manager.hasUnsavedProfileChanges)
        XCTAssertEqual(try Data(contentsOf: backup), committed)

        try unblockList(manager, backup: backup)
        XCTAssertTrue(manager.retryProfileSave())
        XCTAssertFalse(manager.hasUnsavedProfileChanges)
        XCTAssertTrue(manager.saveFailures.isEmpty)
        let reloaded = ProfileManager(directory: manager.directory, sandboxed: true)
        XCTAssertEqual(reloaded.active.id, profile.id)
        XCTAssertEqual(reloaded.active.name, "Latest name")
        XCTAssertEqual(reloaded.active.colorHex, "#123456")
    }

    func testFailedDeletionDoesNotBecomeAPendingDeleteOnRetry() throws {
        let manager = try manager()
        let victim = manager.create(name: "Keep me")
        let database = ProfileManager.dbURL(for: victim.id, in: manager.directory)
        try Data("keep database".utf8).write(to: database)
        let backup = try blockList(manager)
        XCTAssertFalse(manager.delete(victim.id))
        XCTAssertFalse(manager.hasUnsavedProfileChanges)
        XCTAssertFalse(manager.saveFailures.isEmpty)
        XCTAssertEqual(manager.saveFailures.first?.canRetry, false)
        try unblockList(manager, backup: backup)
        XCTAssertTrue(manager.retryProfileSave())
        XCTAssertTrue(manager.profiles.contains { $0.id == victim.id })
        XCTAssertEqual(try Data(contentsOf: database), Data("keep database".utf8))
        XCTAssertTrue(manager.delete(victim.id))
        XCTAssertTrue(manager.saveFailures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testExplicitDeletionRemovesOnlyThatProfilesRecoveryCopies() throws {
        let manager = try manager()
        let victim = manager.create(name: "Delete recovered data")
        let survivor = manager.active.id
        let archive = manager.directory.appendingPathComponent("Session Recovery/launch")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var removed: [URL] = []
        for id in [victim.id, survivor] {
            for primary in [ProfileManager.sessionURL(for: id, in: manager.directory),
                            ProfileManager.spacesURL(for: id, in: manager.directory),
                            Suspension.SpaceState.url(for: id, in: manager.directory)] {
                for file in [primary, primary.appendingPathExtension("previous"),
                             primary.appendingPathExtension("damaged-" + UUID().uuidString),
                             archive.appendingPathComponent(primary.lastPathComponent),
                             archive.appendingPathComponent(primary.lastPathComponent + ".previous")] {
                    try Data("private profile history".utf8).write(to: file)
                    if id == victim.id { removed.append(file) }
                }
            }
        }
        XCTAssertTrue(manager.delete(victim.id))
        for file in removed { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.path) }
        let kept = ProfileManager.sessionURL(for: survivor, in: manager.directory).appendingPathExtension("previous")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent(kept.lastPathComponent).path))
    }

    func testUnreadableProfileListIsVisibleAndRetryCannotOverwriteIt() throws {
        let manager = try manager()
        let file = manager.directory.appendingPathComponent("profiles.json")
        let damaged = Data("damaged profile list".utf8)
        try damaged.write(to: file)
        let reopened = ProfileManager(directory: manager.directory, sandboxed: true)
        XCTAssertFalse(reopened.saveFailures.isEmpty)
        XCTAssertEqual(reopened.saveFailures.first?.canRetry, false)
        _ = reopened.create(name: "Uncommitted")
        XCTAssertFalse(reopened.retryProfileSave())
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testLaterSuccessfulEditClearsThePendingWarning() throws {
        let manager = try manager()
        let id = manager.active.id
        let backup = try blockList(manager)
        manager.rename(id, to: "Draft")
        XCTAssertTrue(manager.hasUnsavedProfileChanges)
        try unblockList(manager, backup: backup)
        manager.rename(id, to: "Saved")
        XCTAssertFalse(manager.hasUnsavedProfileChanges)
        XCTAssertTrue(manager.saveFailures.isEmpty)
        XCTAssertEqual(ProfileManager(directory: manager.directory, sandboxed: true).active.name, "Saved")
    }

    func testQuitRetriesAndRequiresExplicitDiscardOnlyWhileSaveStillFails() throws {
        let manager = try manager()
        var discardPrompts = 0
        XCTAssertTrue(manager.prepareToQuit { discardPrompts += 1; return false })
        XCTAssertEqual(discardPrompts, 0)
        let backup = try blockList(manager)
        manager.rename(manager.active.id, to: "Pending at quit")
        XCTAssertFalse(manager.prepareToQuit { discardPrompts += 1; return false })
        XCTAssertTrue(manager.hasUnsavedProfileChanges)
        XCTAssertEqual(discardPrompts, 1)
        XCTAssertTrue(manager.prepareToQuit { discardPrompts += 1; return true })
        XCTAssertEqual(discardPrompts, 2)
        try unblockList(manager, backup: backup)
        XCTAssertTrue(manager.prepareToQuit { discardPrompts += 1; return false })
        XCTAssertEqual(discardPrompts, 2)
        XCTAssertFalse(manager.hasUnsavedProfileChanges)
        XCTAssertEqual(ProfileManager(directory: manager.directory, sandboxed: true).active.name, "Pending at quit")
    }

    func testEncodingFailureIsVisibleAndPreservesTheLastSpacesSnapshot() throws {
        let manager = try manager()
        let profile = manager.active.id
        let space = Space(name: "Saved", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        let committed = try Data(contentsOf: file)
        var invalid = space
        invalid.tint = .nan
        XCTAssertFalse(manager.saveSpaces([invalid], for: profile))
        XCTAssertFalse(manager.saveFailures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), committed)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        XCTAssertTrue(manager.saveFailures.isEmpty)
    }

    func testFailedSpacesSaveIsVisibleWithoutClearingAnUnsavedProfile() throws {
        let manager = try manager()
        let profile = manager.active.id
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let space = Space(name: "Work", profileID: profile)
        XCTAssertFalse(manager.saveSpaces([space], for: profile))
        XCTAssertFalse(manager.saveFailures.isEmpty)
        let backup = try blockList(manager)
        manager.rename(profile, to: "Unsaved name")
        XCTAssertEqual(manager.saveFailures.count, 2)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        XCTAssertTrue(manager.hasUnsavedProfileChanges)
        XCTAssertEqual(manager.saveFailures.count, 1)
        try unblockList(manager, backup: backup)
        XCTAssertTrue(manager.retryProfileSave())
        XCTAssertTrue(manager.saveFailures.isEmpty)
    }
}
