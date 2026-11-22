import AppKit
import SwiftUI
import XCTest
@testable import vane

/// View › Show Toolbar: the bar takes room above the page card, never covers it, in either
/// sidebar presentation, and a second toggle gives the room back.
@MainActor final class MainToolbarTests: XCTestCase {
    func testToolbarPushesThePageDownAndTogglesBack() async throws {
        TestEnvironment.prepare()
        let was = MainToolbar.shown
        if was { MainToolbar.toggle() }
        let profile = ProfileManager.shared.create(name: "Toolbar fixture")
        let store = TabStore(profileID: profile.id, session: [])
        let tab = store.newBlankTab()
        _ = tab.web
        store.palette = nil
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = NSHostingView(rootView: BrowserWindow()
            .environmentObject(store).environmentObject(ProfileManager.shared)
            .transaction { $0.disablesAnimations = true })
        window.orderFront(nil)
        defer {
            if MainToolbar.shown != was { MainToolbar.toggle() }
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            _ = ProfileManager.shared.delete(profile.id)
        }

        func settle() async throws {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func page() throws -> CGRect {
            let view = try XCTUnwrap(tab.existingWeb?.superview)
            return try XCTUnwrap(view.window).convertToScreen(view.convert(view.bounds, to: nil))
        }
        let room = Look.pillHeight + Look.cardGap

        for sidebar in [true, false] {
            store.sidebarShown = sidebar
            try await settle()
            let without = try page()
            MainToolbar.toggle()
            XCTAssertTrue(MainToolbar.shown)
            try await settle()
            let with = try page()
            capture(window, sidebar: sidebar)
            // Screen coordinates: the top edge is maxY.
            XCTAssertEqual(without.maxY - with.maxY, room, accuracy: 1, "sidebar shown: \(sidebar)")
            XCTAssertEqual(without.minY, with.minY, accuracy: 1)
            XCTAssertEqual(without.width, with.width, accuracy: 1)
            MainToolbar.toggle()
            XCTAssertFalse(MainToolbar.shown)
            try await settle()
            XCTAssertEqual(try page().maxY, without.maxY, accuracy: 1)
        }
    }

    /// `VANE_MAIN_TOOLBAR_CAPTURE=<dir>` writes what the window drew, for a visual check.
    private func capture(_ window: NSWindow, sidebar: Bool) {
        guard let dir = ProcessInfo.processInfo.environment["VANE_MAIN_TOOLBAR_CAPTURE"],
              let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("toolbar-sidebar-\(sidebar ? "shown" : "hidden").png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
