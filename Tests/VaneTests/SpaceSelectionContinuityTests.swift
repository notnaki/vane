import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSelectionContinuityTests: XCTestCase {
    private func fixture() throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Animated interruption requires motion")
        let profile = ProfileManager.shared.create(name: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = NSHostingView(rootView: ContinuityStrip(store: store).vaneMotionPolicy())
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

    func testBatterySaverKeepsTheLatestSelectionAnimated() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        BatterySaver.shared.setMode(.alwaysOn)
        monitor.select(spaces[2], in: store)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertTrue(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBatterySaverKeepsTheVisibleLandingAnimatedWithoutMoreInput() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        BatterySaver.shared.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertTrue(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testPolicyChangePreservesNewerNavigation() async throws {
        TestEnvironment.prepare()
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
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testReduceMotionFinishesAnOwnedSelectionImmediately() throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        monitor.finishForReducedMotion()
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testBatterySaverKeepsTheReturnToOriginMounted() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        monitor.select(spaces[0], in: store)
        XCTAssertTrue(store.spaceSwiping, "The returning preview must remain mounted")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
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
        let (store, spaces, window, monitor) = try fixture()
        enum AdmissionError: Error { case noPresentation(String) }
        func position(_ stage: String, moving: Bool = true,
                      matching predicate: (CGFloat) -> Bool) async throws -> CGFloat {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            var lastPosition: CGFloat?
            repeat {
                if moving, !store.spaceSwiping { break }
                let anchor = moving ? store.spaceGesture.outgoingView : store.spaceGesture.sectionsView
                if let source = anchor?.layer?.presentation(),
                   let root = window.contentView?.layer?.presentation() {
                    let x = source.convert(.zero, to: root).x
                    lastPosition = x
                    if predicate(x) { return x }
                }
                try await Task.sleep(for: .milliseconds(5))
            } while ProcessInfo.processInfo.systemUptime < deadline
            XCTFail("\(stage) must have an admitted presentation; last=\(String(describing: lastPosition)), swiping=\(store.spaceSwiping)")
            throw AdmissionError.noPresentation(stage)
        }

        // Admit the initial tree before starting its click animation. A newly ordered
        // NSHostingView can otherwise coalesce the outbound and return endpoints.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let origin = try await position("Resting sidebar", moving: false) { _ in true }
        let width = SidebarWidth.shared.width
        monitor.select(spaces[1], in: store)
        let outbound = try await position("Outbound travel") {
            $0 < origin - width * 0.25 && $0 > origin - width * 0.9
        }
        monitor.select(spaces[0], in: store)
        let returning = try await position("Return travel") {
            $0 > outbound + 2 && $0 < origin - 2
        }
        monitor.select(spaces[0], in: store)
        XCTAssertTrue(store.spaceSwiping, "A repeated origin click must preserve the moving return")
        _ = try await position("Return after the repeated click") {
            $0 > returning + 2 && $0 < origin - 1
        }
        XCTAssertTrue(store.spaceSwiping, "The preview must stay mounted while it visibly returns")
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while store.spaceSwiping, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertEqual(store.spaceDrag, 0)
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
