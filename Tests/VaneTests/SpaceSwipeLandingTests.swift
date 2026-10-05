import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSwipeLandingTests: XCTestCase {
    func testCommittedSwipeFocusesRememberedTabWithinThirdSecond() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "Focus timing requires the animated landing path")
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let monitor = SwipeMonitor()
        defer {
            monitor.abort()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        store.switchTo(space: second)
        let other = store.newBlankTab(focus: false)
        other.park(url: URL(string: "https://other.example/")!, Parked(title: "Other"))
        let remembered = store.newBlankTab(focus: false)
        remembered.park(url: URL(string: "https://remembered.example/")!, Parked(title: "Remembered"))
        store.current = remembered.id
        store.switchTo(space: first)
        store.palette = nil
        window.contentView = NSHostingView(rootView: LandingStrip(store: store))
        window.orderFront(nil)
        store.spaceSwiping = true
        store.spaceDrag = -90
        // Mount the actual sliding modifier before measuring its completion.
        try await Task.sleep(for: .milliseconds(50))

        let start = ProcessInfo.processInfo.systemUptime
        monitor.land(1, to: second, width: 250, store: store)
        while store.currentSpaceID != second.id,
              ProcessInfo.processInfo.systemUptime - start < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("COMMITTED_SPACE_FOCUS_SECONDS: \(elapsed)")
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertEqual(store.current, remembered.id)
        // Leave several frames for scheduling and disk work in the full suite while still
        // rejecting the previous 350 ms landing spring.
        XCTAssertLessThan(elapsed, 0.33, "The focused tab must not wait for a long landing spring")
        XCTAssertEqual(store.spaceDrag, 0)
    }
}

private struct LandingStrip: View {
    @ObservedObject var store: TabStore

    var body: some View {
        SpaceSidebarStrip(store: store, favorites: EmptyView(),
                          sections: Text(store.currentSpaceID?.uuidString ?? "Empty"))
            .frame(width: 250, height: 300)
    }
}
