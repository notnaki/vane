import AppKit
import XCTest
@testable import vane

@MainActor final class DockMenuTests: XCTestCase {
    private func window(isLittle: Bool, isPrivate: Bool = false) -> NSWindow {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: isPrivate, isLittle: isLittle, session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.close()
            store.window = nil
            store.clearSuggestions()
            store.palette = nil
            TabStore.all.removeAll { $0 === store }
        }
        return window
    }

    private func menu() throws -> NSMenu {
        TestEnvironment.prepare()
        return try XCTUnwrap(AppLifecycle.shared.applicationDockMenu(NSApplication.shared))
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
        XCTAssertTrue(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
    }

    func testLittleWindowCommandsStayDisabledAfterMenuValidationWithoutLittleWindows() throws {
        let ordinary = window(isLittle: false)
        let menu = try menu()
        menu.update()
        for title in ["Show Little Vane Windows", "Close Little Vane Windows"] {
            XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: title)).isEnabled)
        }
        XCTAssertTrue(ordinary.isVisible)
    }

    func testShowRestoresHiddenAndMinimizedLittleWindowsAndNeverHidesThem() async throws {
        let visible = window(isLittle: true)
        let hidden = window(isLittle: true, isPrivate: true)
        let minimized = window(isLittle: true)
        hidden.orderOut(nil)
        minimized.miniaturize(nil)
        let deadline = Date.now.addingTimeInterval(3)
        while !minimized.isMiniaturized && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(minimized.isMiniaturized, "Admit the minimized state before invoking Show")

        let menu = try menu()
        try perform("Show Little Vane Windows", in: menu)
        for window in [visible, hidden, minimized] {
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(window.isMiniaturized)
        }
        try perform("Show Little Vane Windows", in: menu)
        for window in [visible, hidden, minimized] {
            XCTAssertTrue(window.isVisible, "Show must never toggle visible windows off")
            XCTAssertFalse(window.isMiniaturized)
        }
    }

    func testCloseClosesNormalAndPrivateLittleWindowsButLeavesBrowserWindowsOpen() throws {
        let ordinary = window(isLittle: false)
        let little = window(isLittle: true)
        let privateLittle = window(isLittle: true, isPrivate: true)

        try perform("Close Little Vane Windows", in: menu())

        XCTAssertFalse(little.isVisible)
        XCTAssertFalse(privateLittle.isVisible)
        XCTAssertTrue(ordinary.isVisible)
    }
}
