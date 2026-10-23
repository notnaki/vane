import XCTest
@testable import vane

@MainActor final class AsyncProfileSpaceTransferTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }
    func testAsyncProfileTransferPreservesSidecarBeforeRetiringSource() async throws {
        let manager = try manager(), source = manager.active.id
        let destination = manager.create(name: "Destination").id
        var space = manager.createSpace(name: "Move", in: source)
        let url = URL(string: "https://transfer.example.test/")!
        space.tabURLs = [url]
        XCTAssertTrue(manager.updateSpace(space))
        let saved = await Suspension.SpaceState.saveAsync([url.absoluteString: Parked(title: "Saved", state: Data([1, 2, 3]))],
            space: space.id, profileID: source, in: manager.directory)
        XCTAssertTrue(saved)
        let moved = await manager.moveSpaceAsync(space.id, from: source, to: destination)
        XCTAssertEqual(moved?.profileID, destination)
        XCTAssertFalse(manager.spaces(for: source).contains { $0.id == space.id })
        XCTAssertEqual(manager.spaces(for: destination).first?.id, space.id)
        let target = Suspension.SpaceState.load(space: space.id, profileID: destination, in: manager.directory)
        XCTAssertEqual(target[url.absoluteString]?.title, "Saved")
        XCTAssertEqual(target[url.absoluteString]?.state, Data([1, 2, 3]))
        XCTAssertTrue(Suspension.SpaceState.load(space: space.id, profileID: source, in: manager.directory).isEmpty)
    }
    func testAsyncTransferWithUnwritableDestinationKeepsSourceInventoryAndState() async throws {
        let manager = try manager(), source = manager.active.id
        let destination = manager.create(name: "Destination").id
        let space = manager.createSpace(name: "Keep", in: source)
        let key = "https://transfer.example.test/keep"
        let saved = await Suspension.SpaceState.saveAsync([key: Parked(title: "Keep source")],
            space: space.id, profileID: source, in: manager.directory)
        XCTAssertTrue(saved)
        // A directory occupying the sidecar's file name makes its atomic save fail.
        let blocked = Suspension.SpaceState.url(for: destination, in: manager.directory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let moved = await manager.moveSpaceAsync(space.id, from: source, to: destination)
        XCTAssertNil(moved)
        XCTAssertTrue(manager.spaces(for: source).contains { $0.id == space.id })
        XCTAssertFalse(manager.spaces(for: destination).contains { $0.id == space.id })
        XCTAssertEqual(Suspension.SpaceState.load(space: space.id, profileID: source, in: manager.directory)[key]?.title, "Keep source")
        try FileManager.default.removeItem(at: blocked)
        // Clear the failed worker revision before the isolated fixture is removed.
        let cleared = await Suspension.SpaceState.removeAsync(space: space.id, profileID: destination, in: manager.directory)
        XCTAssertTrue(cleared)
    }
}
