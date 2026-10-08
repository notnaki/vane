import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSelectionContinuityTests: XCTestCase {
    private func fixture() throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "Animated interruption requires motion")
        let profile = ProfileManager.shared.create(name: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = NSHostingView(rootView: ContinuityStrip(store: store))
        window.orderFront(nil)
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (store, spaces, window, monitor)
    }

    func testLatestClickReplacesAMountingSelection() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        monitor.select(spaces[2], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id, "The latest click must win")
        XCTAssertFalse(store.spaceSwiping)
    }

    func testClickingOriginReversesAnInFlightLanding() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(store.spaceSwiping)
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id, "A superseded completion cannot switch away")
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testLatestClickReplacesAnInFlightLanding() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        monitor.select(spaces[2], in: store)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id,
                       "Retargeting must not unmount an unfinished visual slide")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBatterySaverFinishesASelectionImmediately() throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        BatterySaver.shared.setMode(.alwaysOn)
        monitor.select(spaces[2], in: store)
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBatterySaverFinishesTheVisibleLandingWithoutMoreInput() async throws {
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        BatterySaver.shared.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
    }

    func testPolicyChangePreservesNewerNavigation() async throws {
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        store.switchTo(space: spaces[2])
        BatterySaver.shared.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
    }

    func testClickAfterNewerNavigationOwnsItsCompletion() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        store.switchTo(space: spaces[2])
        monitor.select(spaces[3], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[3].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testRepeatedOriginClickKeepsTheReturnMounted() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(100))
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(20))
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.spaceSwiping, "A repeated origin click must preserve the moving return")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
    }

}

private struct ContinuityStrip: View {
    @ObservedObject var store: TabStore
    var body: some View {
        SpaceSidebarStrip(store: store, favorites: EmptyView(), sections: Text(store.currentSpaceID?.uuidString ?? "Empty"))
            .frame(width: 250, height: 300)
            .spaceSwipe(store)
    }
}
