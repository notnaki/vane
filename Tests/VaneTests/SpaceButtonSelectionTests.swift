import AppKit
import XCTest
@testable import vane

@MainActor final class SpaceButtonSelectionTests: XCTestCase {
    private func fixture() -> (TabStore, [Space]) {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Button selection fixture")
        let spaces = (1...3).map { Space(name: "Space \($0)", profileID: profile.id) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile.id))
        let store = TabStore(profileID: profile.id, space: spaces[0], session: [])
        addTeardownBlock { @MainActor in
            store.spaceSwiping = false
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            _ = ProfileManager.shared.delete(profile.id)
        }
        return (store, spaces)
    }

    func testClickPreviewsTheChosenSpaceWithoutSwitchingEarly() {
        let (store, spaces) = fixture()
        XCTAssertEqual(store.beginSpaceSelection(spaces[2]), 1)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertEqual(store.spaceGesture.neighbour?.id, spaces[2].id,
                       "Skipping a dot must preview the clicked Space, not the adjacent one")
        XCTAssertEqual(store.spaceGesture.previewDirection, 1)
        XCTAssertFalse(store.spaceGesture.travelsFavorites)
        XCTAssertNotNil(store.spaceGesture.previews[spaces[2].id])
        XCTAssertNil(store.beginSpaceSelection(spaces[1]), "Do not overwrite a landing in progress")
    }

    func testEarlierSpaceArrivesFromTheLeft() {
        let (store, spaces) = fixture()
        store.switchTo(space: spaces[2])
        XCTAssertEqual(store.beginSpaceSelection(spaces[0]), -1)
        XCTAssertEqual(store.spaceGesture.previewDirection, -1)
        XCTAssertEqual(store.spaceGesture.neighbour?.id, spaces[0].id)
    }

    func testCurrentOrDeletedSpaceDoesNotStartAnAnimation() {
        let (store, spaces) = fixture()
        XCTAssertNil(store.beginSpaceSelection(spaces[0]))
        XCTAssertTrue(ProfileManager.shared.saveSpaces(Array(spaces.prefix(2)), for: store.profileID))
        XCTAssertNil(store.beginSpaceSelection(spaces[2]))
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testClickWithoutAnOutgoingSpaceStillSelectsTheDestination() {
        let (store, spaces) = fixture()
        let window = NSWindow()
        store.window = window
        defer { store.window = nil }
        for space in spaces { XCTAssertTrue(Spaces.delete(space.id, in: store.profileID)) }
        XCTAssertNil(store.currentSpaceID)
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: store.profileID))
        store.spaceGesture.monitor.select(spaces[1], in: store)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testSidebarCancellationCannotReleaseAnOwnedClickLandingForAnotherSelection() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "This test exercises an animated click landing")
        let (store, spaces) = fixture()
        let window = NSWindow()
        store.window = window
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        defer {
            monitor.remove()
            store.window = nil
        }
        monitor.select(spaces[2], in: store)
        monitor.abort()
        monitor.abort()
        XCTAssertTrue(store.spaceSwiping, "A committed click, like a swipe landing, must finish")
        monitor.select(spaces[1], in: store)
        XCTAssertEqual(store.spaceGesture.neighbour?.id, spaces[2].id)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testAnotherSwitchDuringPreviewMountDoesNotLeaveTheSidebarStuck() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "This test exercises deferred preview mounting")
        let (store, spaces) = fixture()
        let window = NSWindow()
        store.window = window
        defer { store.window = nil }
        let monitor = store.spaceGesture.monitor
        monitor.select(spaces[2], in: store)
        store.switchTo(space: spaces[1])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        monitor.select(spaces[2], in: store)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testCrossProfileSelectionIncludesThatProfilesFavorites() {
        let (store, _) = fixture()
        let profile = ProfileManager.shared.create(name: "Other button fixture")
        defer { _ = ProfileManager.shared.delete(profile.id) }
        let target = ProfileManager.shared.createSpace(name: "Other Space", in: profile.id)
        XCTAssertEqual(store.beginSpaceSelection(target), 1)
        XCTAssertTrue(store.spaceGesture.travelsFavorites)
        XCTAssertTrue(store.spaceGesture.previews[target.id]?.includingFavorites == true)
        XCTAssertTrue(store.spaceGesture.strip?.contains { $0.id == target.id } == true)
    }
}
