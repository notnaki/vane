import AppKit
import ScreenCaptureKit
import SwiftUI
import WebKit
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

        // Empty Favourites opens its drop tile under the pill. With the toolbar up the pill
        // anchor stays where the pill stood, so the tile lands under the top row instead.
        XCTAssertFalse(store.tabs.contains { $0.kind == .favourite })
        func landing() throws -> CGRect {
            let preview = try XCTUnwrap(store.sidebarDragPreview)
            let root = try XCTUnwrap(preview.root), pill = try XCTUnwrap(preview.pill)
            XCTAssertTrue(pill.window === window, "the pill anchor is mounted")
            return FavouriteLanding.emptyFrame(below: root.convert(pill.bounds, from: pill), revealed: true)
        }

        for sidebar in [true, false] {
            store.sidebarShown = sidebar
            try await settle()
            let without = try page()
            if sidebar { try assertSidebarChrome(true, "toolbar off") }
            let landingWithout = try sidebar ? landing() : .zero
            MainToolbar.toggle()
            XCTAssertTrue(MainToolbar.shown)
            try await settle()
            let with = try page()
            capture(window, sidebar: sidebar)
            if sidebar { try assertSidebarChrome(false, "the toolbar has them") }
            if sidebar {
                let tile = try landing()
                XCTAssertEqual(tile.minY, landingWithout.minY - Look.pillHeight - Look.inset, accuracy: 1,
                               "the drop tile moves up by the pill's row, no further")
                XCTAssertEqual(tile.minX, landingWithout.minX, accuracy: 1)
                XCTAssertEqual(tile.width, landingWithout.width, accuracy: 1)
            }
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

    /// A production-shaped window, on screen, with its own traffic lights: with the sidebar
    /// hidden the toolbar row leads with the lights and the sidebar toggle, in the sidebar's
    /// spot, and the toggle brings the sidebar back. The page is painted at its new height
    /// before the bar slides, and keeps that height (and its scroll) through the slide.
    func testSidebarHiddenRowAndBufferedResize() async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.off)
        let was = MainToolbar.shown
        if was { MainToolbar.toggle() }
        let profile = ProfileManager.shared.create(name: "Toolbar lights fixture")
        let store = TabStore(profileID: profile.id, session: [])
        let tab = store.newBlankTab()
        let rows = (0..<300).map { "<p>Row \($0)</p>" }.joined()
        tab.web.loadHTMLString("<body style='margin:0;font:16px sans-serif'>\(rows)</body>", baseURL: nil)
        store.palette = nil
        let window = VaneWindow(contentRect: .init(x: 120, y: 120, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "VaneEmpty")
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        store.window = window
        window.contentView = NSHostingView(rootView: BrowserWindow()
            .environmentObject(store).environmentObject(ProfileManager.shared))
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        window.orderFrontRegardless()
        defer {
            if MainToolbar.shown != was { MainToolbar.toggle() }
            saver.setMode(previousMode)
            window.orderOut(nil)
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
        try await compatibilityWait {
            reassertForeground(window, key: false)
            return window.isVisible && window.occlusionState.contains(.visible) && !tab.web.isLoading
                && (tab.existingWeb?.bounds.height ?? 0) > 100
        }
        func settle() async throws {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func scrollY() async throws -> Double {
            try await tab.web.evaluateJavaScript("window.scrollY") as? Double ?? -1
        }
        func light() throws -> NSRect {
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            XCTAssertFalse(close.isHidden, "the close button is on screen")
            return close.convert(close.bounds, to: nil)
        }
        try await settle()
        let docked = try light()

        // The buffered resize, both ways, with the sidebar shown.
        _ = try await tab.web.evaluateJavaScript("window.scrollTo(0, 600)")
        try await Task.sleep(for: .milliseconds(100))
        let web = tab.web
        for showing in [true, false] {
            let start = web.frame.height
            let target = start + (showing ? -MainToolbar.room : MainToolbar.room)
            MainToolbar.toggle(in: store)
            XCTAssertNotEqual(MainToolbar.shown, showing, "the setting waits for the prepared paint")
            XCTAssertEqual(web.frame.height, target, accuracy: 0.5, "painted at its final height first")
            var hostHeights: Set<Int> = []
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(16))
                window.contentView?.layoutSubtreeIfNeeded()
                if let host = web.superview { hostHeights.insert(Int(host.bounds.height.rounded())) }
                XCTAssertEqual(web.frame.height, target, accuracy: 0.5,
                               "no per-frame reflow while the bar slides (showing: \(showing))")
            }
            try await settle()
            XCTAssertEqual(MainToolbar.shown, showing)
            let host = try XCTUnwrap(web.superview)
            XCTAssertEqual(web.frame.height, host.bounds.height, accuracy: 0.5)
            XCTAssertEqual(web.frame.minY, host.bounds.minY, accuracy: 0.5)
            XCTAssertGreaterThan(hostHeights.count, 1, "the card itself still slid")
            let kept = try await scrollY()
            XCTAssertEqual(kept, 600, accuracy: 1, "scroll kept (showing: \(showing))")
        }

        // Sidebar hidden, toolbar on: lights and toggle stay where the sidebar had them.
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            store.sidebarShown = true
            try await settle()
            await captureScreen(window, "\(dark ? "dark" : "light")-toolbar-off-sidebar-shown")
            MainToolbar.toggle(in: store)
            try await settle()
            await captureScreen(window, "\(dark ? "dark" : "light")-sidebar-shown")
            store.sidebarShown = false
            try await settle()
            XCTAssertEqual(try light(), docked, "the lights do not move when the sidebar goes")
            await captureScreen(window, "\(dark ? "dark" : "light")-sidebar-hidden")
            // The toggle, where the sidebar's own row draws it, brings the sidebar back.
            let x = Look.inset + Look.trafficLights
                + SidebarChromeLayout(width: SidebarWidth.inWindow(store)).headerSpacing + Look.control / 2
            let y = window.contentView!.bounds.height - (Look.topInset + Look.topRow / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
            try await settle()
            XCTAssertTrue(store.sidebarShown, "the toolbar's toggle reopens the sidebar")
            XCTAssertEqual(try light(), docked)
            MainToolbar.toggle(in: store)
            try await settle()
        }
    }

    /// The window as the compositor shows it, traffic lights included, and its top-left
    /// corner, under `VANE_MAIN_TOOLBAR_CAPTURE`.
    private func captureScreen(_ window: NSWindow, _ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["VANE_MAIN_TOOLBAR_CAPTURE"],
              let content = try? await SCShareableContent.currentProcess,
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { return }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        else { return }
        let scale = window.backingScaleFactor
        let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 420 * scale, height: 110 * scale))
        for (suffix, picture) in [("", image), ("-corner", corner)] {
            guard let picture else { continue }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("window-\(name)\(suffix).png")
            try? NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])?.write(to: url)
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
