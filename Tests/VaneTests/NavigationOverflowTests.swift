import XCTest
@testable import vane

@MainActor final class NavigationOverflowTests: XCTestCase {
    func testSidebarRemainsAvailableWithoutAnActivePage() throws {
        TestEnvironment.prepare()
        var toggles = 0
        let items = NavigationOverflow.items(tab: nil) { toggles += 1 }
        XCTAssertEqual(items.map(\.title), ["Toggle Sidebar"])
        try XCTUnwrap(items.last).action()
        XCTAssertEqual(toggles, 1)
    }

    func testLoadingOffersStopAndThenReturnsToReload() throws {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        tab.loading = true
        let loading = NavigationOverflow.items(tab: tab) {}
        XCTAssertEqual(loading.map(\.title), ["Stop Loading", "Toggle Sidebar"])
        XCTAssertEqual(loading.first?.symbol, "xmark")
        XCTAssertEqual(loading.first?.shortcut, "")
        try XCTUnwrap(loading.first).action()
        XCTAssertFalse(tab.loading)
        let idle = NavigationOverflow.items(tab: tab) {}
        XCTAssertEqual(idle.map(\.title), ["Reload", "Toggle Sidebar"])
        XCTAssertEqual(idle.first?.symbol, "arrow.clockwise")
    }

    func testMenuReadsCurrentShortcutBindings() throws {
        TestEnvironment.prepare()
        try XCTUnwrap(Keybindings.withScratchDefaults("navigation-overflow") {
            Keybindings.set(Keybinding("r", [.command, .shift]), for: .reload)
            Keybindings.set(Keybinding("s", [.command, .option]), for: .toggleSidebar)
            let items = NavigationOverflow.items(tab: Tab(isPrivate: true)) {}
            XCTAssertEqual(items.map(\.shortcut), ["⇧⌘R", "⌥⌘S"])
            Keybindings.set(.unassigned, for: .toggleSidebar)
            XCTAssertEqual(NavigationOverflow.items(tab: nil) {}.first?.shortcut, "")
        })
    }
}
