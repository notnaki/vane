import AppKit
import XCTest
@testable import vane

@MainActor final class AppLifecycleTests: XCTestCase {
    private func window() -> NSWindow {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    private func minimize(_ window: NSWindow) async throws {
        window.miniaturize(nil)
        let deadline = Date.now.addingTimeInterval(3)
        while !window.isMiniaturized && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(window.isMiniaturized)
    }

    private func reopen(_ lifecycle: AppLifecycle, restoring window: NSWindow) async throws {
        XCTAssertFalse(lifecycle.applicationShouldHandleReopen(NSApplication.shared,
                                                              hasVisibleWindows: true))
        let deadline = Date.now.addingTimeInterval(3)
        while window.isMiniaturized && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
    }

    func testDockClickRestoresAMinimizedWindowDespiteTheVisibleWindowsFlag() async throws {
        let lifecycle = AppLifecycle()
        let window = window()
        try await minimize(window)
        try await reopen(lifecycle, restoring: window)
    }

    func testDockClickRestoresOnlyTheLastMinimizedWindowRatherThanTheLastCreated() async throws {
        let lifecycle = AppLifecycle()
        let first = window(), second = window()
        try await minimize(second)
        try await minimize(first)
        try await reopen(lifecycle, restoring: first)
        XCTAssertTrue(second.isMiniaturized)
    }

    func testDockClickLeavesMinimizedWindowsAloneWhileAnotherWindowIsOpen() async throws {
        let lifecycle = AppLifecycle()
        let minimized = window()
        let visible = window()
        try await minimize(minimized)
        XCTAssertTrue(lifecycle.applicationShouldHandleReopen(NSApplication.shared,
                                                             hasVisibleWindows: true))
        XCTAssertTrue(minimized.isMiniaturized)
        XCTAssertTrue(visible.isVisible)
    }

    func testFloatingPanelDoesNotPreventRestoringAMinimizedWindow() async throws {
        let lifecycle = AppLifecycle()
        let minimized = window()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        addTeardownBlock { @MainActor in panel.close() }
        try await minimize(minimized)
        try await reopen(lifecycle, restoring: minimized)
    }

    func testClosingTheLastMinimizedWindowRestoresThePreviousOne() async throws {
        let lifecycle = AppLifecycle()
        let first = window(), second = window()
        try await minimize(first)
        try await minimize(second)
        second.close()
        try await reopen(lifecycle, restoring: first)
    }

    func testMinimizingARestoredWindowMakesItTheMostRecentAgain() async throws {
        let lifecycle = AppLifecycle()
        let first = window(), second = window()
        try await minimize(first)
        try await minimize(second)
        let restored = expectation(forNotification: NSWindow.didDeminiaturizeNotification,
                                   object: first)
        first.deminiaturize(nil)
        await fulfillment(of: [restored], timeout: 3)
        try await minimize(first)
        try await reopen(lifecycle, restoring: first)
        XCTAssertTrue(second.isMiniaturized)
    }
}
