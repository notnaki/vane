import XCTest
@testable import vane

@MainActor final class GlobalEaselLibraryTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }

    private func write(_ boards: [EaselBoard], profileID: UUID, manager: ProfileManager) throws {
        try JSONEncoder().encode(EaselStore.Archive(boards: boards))
            .write(to: EaselStore.file(profileID: profileID, directory: manager.directory))
    }

    func testAggregatesSavedProfilesWithDistinctOwnerIdentitiesAndGlobalOrdering() async throws {
        let manager = try manager()
        let personal = manager.active
        let work = manager.create(name: "Café work")
        let sharedID = UUID()
        let older = EaselBoard(id: sharedID, title: "Personal ideas", modified: Date(timeIntervalSince1970: 100))
        let newer = EaselBoard(id: sharedID, title: "Team sketch", modified: Date(timeIntervalSince1970: 200))
        try write([older], profileID: personal.id, manager: manager)
        try write([newer], profileID: work.id, manager: manager)
        try write([EaselBoard(title: "Orphaned profile")], profileID: UUID(), manager: manager)

        let library = GlobalEaselLibrary(manager: manager)
        await library.waitUntilReady()
        XCTAssertEqual(library.entries.map(\.board.title), ["Team sketch", "Personal ideas"])
        XCTAssertEqual(Set(library.entries.map(\.id)).count, 2, "The same board UUID can belong to two profiles")
        XCTAssertEqual(library.entries.filter { $0.matches("cafe") }.map(\.profileID), [work.id])
        XCTAssertEqual(library.entries.filter { $0.matches("PERSONAL IDEAS") }.map(\.profileID), [personal.id])
        XCTAssertTrue(library.entries.filter { $0.matches("orphaned") }.isEmpty)
    }

    func testObservesRepositoryEditsAndProfileCreationRenameAndDeletion() async throws {
        let manager = try manager()
        let library = GlobalEaselLibrary(manager: manager)
        await library.waitUntilReady()
        XCTAssertTrue(library.entries.isEmpty)
        let work = manager.create(name: "Work")
        let repository = try XCTUnwrap(library.repository(for: work.id))
        var board = try await repository.createAsync(title: "Draft")
        XCTAssertEqual(library.entries.map(\.board.id), [board.id])

        manager.rename(work.id, to: "Research")
        XCTAssertEqual(library.entries.first?.profileName, "Research")
        board.title = "Published sketch"
        try await repository.saveAsync(board)
        XCTAssertEqual(library.entries.first?.board.title, "Published sketch")
        let staleEntry = try XCTUnwrap(library.entries.first)
        XCTAssertTrue(manager.delete(work.id))
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertNil(library.repository(for: work.id))
        XCTAssertThrowsError(try library.delete(staleEntry))
        XCTAssertThrowsError(try library.board(for: staleEntry))
    }

    func testExistingBoardResolutionAndDeletionUseTheOwnerWithCollidingBoardIDs() async throws {
        let manager = try manager()
        let personal = manager.active
        let work = manager.create(name: "Work")
        let id = UUID()
        try write([EaselBoard(id: id, title: "Personal")], profileID: personal.id, manager: manager)
        try write([EaselBoard(id: id, title: "Work")], profileID: work.id, manager: manager)
        let library = GlobalEaselLibrary(manager: manager)
        await library.waitUntilReady()
        let entry = try XCTUnwrap(library.entries.first { $0.profileID == work.id })
        let owner = try XCTUnwrap(library.repository(for: work.id))
        var latest = try library.board(for: entry)
        latest.title = "Latest work"
        try await owner.saveAsync(latest)
        XCTAssertEqual(try library.board(for: entry).title, "Latest work", "Actions resolve the latest board through its owner")

        try await library.deleteAsync(entry)
        XCTAssertNil(owner.board(id))
        XCTAssertEqual(library.repository(for: personal.id)?.board(id)?.title, "Personal")
        XCTAssertEqual(library.entries.map(\.profileID), [personal.id])
    }

    func testReportsAndRetriesErrorsForOnlyTheAffectedProfile() async throws {
        let manager = try manager()
        let personal = manager.active
        let damaged = manager.create(name: "Damaged")
        let healthyBoard = EaselBoard(title: "Still available")
        try write([healthyBoard], profileID: personal.id, manager: manager)
        try Data("broken archive".utf8).write(to: EaselStore.file(profileID: damaged.id, directory: manager.directory))
        let library = GlobalEaselLibrary(manager: manager)
        await library.waitUntilReady()
        XCTAssertEqual(library.entries.map(\.board.id), [healthyBoard.id])
        XCTAssertEqual(library.failures.map(\.profileID), [damaged.id])
        XCTAssertEqual(library.failures.first?.profileName, "Damaged")

        let repairedBoard = EaselBoard(title: "Recovered")
        try write([repairedBoard], profileID: damaged.id, manager: manager)
        library.retry(damaged.id)
        await library.waitUntilReady()
        XCTAssertTrue(library.failures.isEmpty)
        XCTAssertEqual(Set(library.entries.map(\.board.id)), [healthyBoard.id, repairedBoard.id])
    }
}
