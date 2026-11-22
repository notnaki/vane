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
        // The row starts above the card's usual top gap, centred on the traffic lights.
        let room = MainToolbar.top + Look.pillHeight
        XCTAssertEqual(MainToolbar.top + Look.pillHeight / 2, Look.topInset + Look.topRow / 2,
                       "the toolbar row is centred on the sidebar's top row")
        // What the sidebar draws, sampled where its buttons and pill stand. The test host
        // exposes no accessibility tree, so the check reads pixels: the share of a strip that
        // differs from the bare sidebar just left of it, in the same row.
        func ink(_ strip: CGRect) throws -> CGFloat {
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            func colour(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
                let c = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
                return [c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0]
            }
            let ground = colour(2, strip.midY)
            var marked = 0, total = 0
            for y in stride(from: strip.minY, to: strip.maxY, by: 1) {
                for x in stride(from: strip.minX, to: strip.maxX, by: 1) {
                    total += 1
                    if zip(colour(x, y), ground).contains(where: { abs($0 - $1) > 0.03 }) { marked += 1 }
                }
            }
            return CGFloat(marked) / CGFloat(max(1, total))
        }
        // From the window's top-left, in points.
        let navStrip = CGRect(x: Look.sidebarWidth * 0.6, y: Look.topInset,
                              width: Look.sidebarWidth * 0.4 - Look.inset, height: Look.topRow)
        let toggleStrip = CGRect(x: Look.trafficLights, y: Look.topInset, width: 50, height: Look.topRow)
        let addressTop = Look.topInset + Look.topRow + Look.inset
        let pillStrip = CGRect(x: Look.inset + 24, y: addressTop + 1,
                               width: Look.sidebarWidth - 2 * Look.inset - 48, height: 3)
        func assertSidebarChrome(_ shown: Bool, _ message: String) throws {
            let nav = try ink(navStrip), pill = try ink(pillStrip)
            if shown {
                XCTAssertGreaterThan(nav, 0.02, "nav buttons: \(message)")
                XCTAssertGreaterThan(pill, 0.5, "pill: \(message)")
            } else {
                XCTAssertLessThan(nav, 0.005, "nav buttons: \(message)")
                XCTAssertLessThan(pill, 0.05, "pill: \(message)")
            }
            XCTAssertGreaterThan(try ink(toggleStrip), 0.02, "the sidebar keeps its toggle: \(message)")
        }

        for sidebar in [true, false] {
            store.sidebarShown = sidebar
            try await settle()
            let without = try page()
            if sidebar { try assertSidebarChrome(true, "toolbar off") }
            MainToolbar.toggle()
            XCTAssertTrue(MainToolbar.shown)
            try await settle()
            let with = try page()
            capture(window, sidebar: sidebar)
            if sidebar { try assertSidebarChrome(false, "the toolbar has them") }
            // Screen coordinates: the top edge is maxY.
            XCTAssertEqual(without.maxY - with.maxY, room, accuracy: 1, "sidebar shown: \(sidebar)")
            XCTAssertEqual(without.minY, with.minY, accuracy: 1)
            XCTAssertEqual(without.width, with.width, accuracy: 1)
            MainToolbar.toggle()
            XCTAssertFalse(MainToolbar.shown)
            try await settle()
            XCTAssertEqual(try page().maxY, without.maxY, accuracy: 1)
            if sidebar { try assertSidebarChrome(true, "toolbar off again") }
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
