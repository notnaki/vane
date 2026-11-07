import AppKit
import XCTest
@testable import vane

@MainActor final class SidebarToggleTests: XCTestCase {
    func testCommandClosesLibraryAndReopensNormalSidebar() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let oldMenu = NSApp.mainMenu
        let oldActions = Keybindings.actions
        defer {
            NSApp.mainMenu = oldMenu
            Keybindings.actions = oldActions
            store.librarySwipeMonitor.remove()
            store.window = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        rebuild()
        XCTAssertTrue(Windows.current === store)
        let toggle = try XCTUnwrap(Keybindings.actions[.toggleSidebar])
        for sidebarShown in [true, false] {
            store.sidebarShown = sidebarShown
            store.libraryOpen = true
            toggle()
            XCTAssertFalse(store.libraryOpen, "Cmd-S must dismiss Library with the sidebar")
            XCTAssertFalse(store.sidebarShown, "Library counts as visible even with the docked sidebar hidden")
            toggle()
            XCTAssertTrue(store.sidebarShown)
            XCTAssertFalse(store.libraryOpen, "Reopening returns to the normal sidebar")
            toggle()
            XCTAssertFalse(store.sidebarShown, "Normal sidebar toggling still closes")
        }
    }
}
