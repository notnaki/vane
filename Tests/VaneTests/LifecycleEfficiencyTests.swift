import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LifecycleEfficiencyTests: XCTestCase {
    func testClosedTabDropsItsWebViewEvenIfRowIsRetained() {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        _ = tab.web
        tab.tearDown()
        XCTAssertNil(tab.existingWeb, "Closed rows must release their page immediately")
    }

    func testReleaseRemovesPageFromHostsCacheWithoutAnotherRender() async throws {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        let host = WebHost(tab.web)
        weak var old = tab.existingWeb
        tab.tearDown()
        XCTAssertNil(host.web, "Detaching a closed page must also prune the host's strong cache")
        let deadline = ContinuousClock.now + .seconds(3)
        while old != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(old)
    }

    func testDiscardedSpaceMenuReleasesFloatingStore() {
        TestEnvironment.prepare()
        weak var old: TabStore?
        autoreleasepool {
            let store = TabStore(isLittle: true, session: [])
            old = store
            _ = LittleArc.spaceMenu(store)
            TabStore.all.removeAll { $0 === store }
        }
        XCTAssertNil(old, "Menu actions must live with the menu, not in a global array")
    }
    func testLastStoreRemovalStopsSuspensionWorkAndReopeningRestartsIt() {
        TestEnvironment.prepare()
        let original = TabStore.all
        TabStore.all = []
        defer { TabStore.all = original }
        let store = TabStore(isLittle: true, session: [])
        XCTAssertTrue(Suspension.isRunning)
        TabStore.all.removeAll { $0 === store }
        XCTAssertFalse(Suspension.isRunning, "An app with no tab owners needs no sweep timer or pressure source")
        let reopened = TabStore(isLittle: true, session: [])
        XCTAssertTrue(Suspension.isRunning)
        TabStore.all.removeAll { $0 === reopened }
    }

    func testClosingLittleVaneReleasesItsViewCallbacksAndStore() async throws {
        TestEnvironment.prepare()
        weak var old: TabStore?
        autoreleasepool {
            let store = LittleArc.open(nil)
            old = store
            store.window?.contentView?.layoutSubtreeIfNeeded()
            store.window?.close()
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while old != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(old, "View callbacks must not retain a closed Little Vane store")
    }

    func testDiscardedMainMenuReleasesClosureTargets() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        weak var old: NSObject?
        func action(in menu: NSMenu) -> NSObject? {
            for item in menu.items {
                if item.action == NSSelectorFromString("fire"), let target = item.target as? NSObject { return target }
                if let submenu = item.submenu, let target = action(in: submenu) { return target }
            }
            return nil
        }
        autoreleasepool { old = action(in: buildMenu()) }
        XCTAssertNil(old, "Rebuilding menus must not accumulate global action targets")
    }

    func testSuspensionDropsReportsForTheOldDocument() async throws {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        tab.web.loadHTMLString("<title>Media</title><audio></audio><script>navigator.mediaSession.metadata=new MediaMetadata({title:'Fixture'})</script>", baseURL: URL(string: "https://media.example.test"))
        let deadline = ContinuousClock.now + .seconds(8)
        while MediaState.shared.info(for: tab.id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(MediaState.shared.info(for: tab.id))
        tab.suspend()
        XCTAssertTrue(tab.suspended)
        XCTAssertNil(MediaState.shared.info(for: tab.id), "A suspended document must not retain its WKFrameInfo/media session")
    }
}
