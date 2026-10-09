import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSwipeLandingTests: XCTestCase {
    func testCommittedSwipeSwitchesPageAndAddressPromptlyAfterRelease() async throws {
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
        // Allow several frames for scheduling and disk work while rejecting the old
        // 160 ms response, which delayed the page and address by roughly 190 ms.
        XCTAssertLessThan(elapsed, 1.0 / 6, "The page and address must switch promptly after release")
        XCTAssertTrue(store.active === remembered)
        XCTAssertEqual(store.active?.currentURL, URL(string: "https://remembered.example/"))
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
