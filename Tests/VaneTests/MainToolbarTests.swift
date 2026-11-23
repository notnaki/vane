import AppKit
import ScreenCaptureKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

/// View › Show Toolbar: a strip inside the page card's top edge. The card keeps its margins
/// and the page below the strip gives up exactly its height, in either sidebar presentation;
/// a second toggle gives it back.
@MainActor final class MainToolbarTests: XCTestCase {
    func testToolbarPushesThePageDownAndTogglesBack() async throws {
        TestEnvironment.prepare()
        // Straight to the setting: a front window's toggle would wait for its paint.
        let was = MainToolbar.shown
        UserDefaults.vane.set(false, forKey: MainToolbar.prefKey)
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
            UserDefaults.vane.set(was, forKey: MainToolbar.prefKey)
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
        let room = MainToolbar.height
        XCTAssertEqual(Look.lightsCentre + MainToolbar.lightsShift.height, Look.cardGap + MainToolbar.height / 2,
                       "lights that step into the strip sit on its centre line")
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
    /// hidden the card's strip leads with the lights and the sidebar toggle, on the strip's
    /// centre line, and the toggle brings the sidebar back. The page is painted at its new height
    /// before the bar slides, and keeps that height (and its scroll) through the slide.
    func testSidebarHiddenRowAndBufferedResize() async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.off)
        // Straight to the setting: a front window's toggle would wait for its paint.
        let was = MainToolbar.shown
        UserDefaults.vane.set(false, forKey: MainToolbar.prefKey)
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
            UserDefaults.vane.set(was, forKey: MainToolbar.prefKey)
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
        // A peek's spring leaves a sub-point tail for a while after it has visibly landed.
        func assertLight(_ rect: NSRect, _ message: String = "") {
            XCTAssertEqual(rect.minX, docked.minX, accuracy: 0.5, message)
            XCTAssertEqual(rect.minY, docked.minY, accuracy: 0.5, message)
        }

        // Hiding is buffered, as a sidebar close is; showing is not, as a sidebar open is not,
        // since a page painted shorter than its card would leave the card's foot bare.
        _ = try await tab.web.evaluateJavaScript("window.scrollTo(0, 600)")
        try await Task.sleep(for: .milliseconds(100))
        let web = tab.web
        func assertFilled(_ message: String) throws {
            let host = try XCTUnwrap(web.superview)
            XCTAssertLessThanOrEqual(web.frame.minY, host.bounds.minY + 0.5, "no bare strip under the page: \(message)")
            XCTAssertGreaterThanOrEqual(web.frame.maxY, host.bounds.maxY - 0.5, "no bare strip over the page: \(message)")
        }
        for showing in [true, false] {
            let start = web.frame.height
            let target = start + (showing ? -MainToolbar.height : MainToolbar.height)
            MainToolbar.toggle(in: store)
            if showing {
                XCTAssertTrue(MainToolbar.shown, "showing flips at once")
            } else {
                XCTAssertTrue(MainToolbar.shown, "the setting waits for the prepared paint")
                XCTAssertEqual(web.frame.height, target, accuracy: 0.5, "painted at its final height first")
            }
            var hostHeights: Set<Int> = []
            var captured = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(16))
                window.contentView?.layoutSubtreeIfNeeded()
                if let host = web.superview { hostHeights.insert(Int(host.bounds.height.rounded())) }
                try assertFilled("showing: \(showing)")
                if !showing {
                    XCTAssertEqual(web.frame.height, target, accuracy: 0.5,
                                   "no per-frame reflow while the bar slides")
                }
                if !captured, MainToolbar.shown == showing {
                    captured = true
                    await captureScreen(window, "mid-slide-\(showing ? "show" : "hide")")
                }
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

        // A second ⇧⌘D while the hide waits for paint cancels it; the page goes back.
        MainToolbar.toggle(in: store)
        try await settle()
        let shownHeight = web.frame.height
        MainToolbar.toggle(in: store)
        XCTAssertEqual(web.frame.height, shownHeight + MainToolbar.height, accuracy: 0.5)
        MainToolbar.toggle(in: store)
        XCTAssertTrue(MainToolbar.shown)
        XCTAssertEqual(web.frame.height, shownHeight, accuracy: 0.5, "cancelled")
        try await settle()
        XCTAssertTrue(MainToolbar.shown, "a cancelled hide stays cancelled")
        // Anything else that ends the wait still hides the bar: here ⌘S right after ⇧⌘D.
        MainToolbar.toggle(in: store)
        XCTAssertTrue(MainToolbar.shown)
        store.toggleSidebar()
        try await settle()
        XCTAssertFalse(MainToolbar.shown, "⇧⌘D is not lost to the sidebar's resize")
        XCTAssertFalse(store.sidebarShown)
        try assertFilled("after an interrupted hide")
        store.sidebarShown = true
        try await settle()
        // A second ⇧⌘D during the show's slide flips at once instead of preparing a height
        // from a card that is still moving.
        MainToolbar.toggle(in: store)
        XCTAssertTrue(MainToolbar.shown)
        try await Task.sleep(for: .milliseconds(30))
        MainToolbar.toggle(in: store)
        XCTAssertFalse(MainToolbar.shown, "mid-slide, the toggle is immediate")
        try await settle()
        try assertFilled("after toggling mid-slide")
        XCTAssertEqual(web.frame.height, try XCTUnwrap(web.superview).bounds.height, accuracy: 0.5)

        // Sidebar hidden, toolbar on: the lights step into the card's strip.
        func assertInStrip(_ rect: NSRect, _ message: String) {
            XCTAssertEqual(rect.minX, docked.minX + MainToolbar.lightsShift.width, accuracy: 0.5, message)
            XCTAssertEqual(rect.minY, docked.minY - MainToolbar.lightsShift.height, accuracy: 0.5, message)
        }
        // A real page for the captures, e.g. a loopback server's, so the strip shows a host.
        if let page = ProcessInfo.processInfo.environment["VANE_MAIN_TOOLBAR_PAGE"].flatMap(URL.init(string:)) {
            tab.web.load(URLRequest(url: page))
            try await compatibilityWait { !tab.web.isLoading && !tab.address.isEmpty }
        }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            store.sidebarShown = true
            try await settle()
            await captureScreen(window, "\(dark ? "dark" : "light")-toolbar-off-sidebar-shown")
            MainToolbar.toggle(in: store)
            try await settle()
            await captureScreen(window, "\(dark ? "dark" : "light")-sidebar-shown")
            assertLight(try light(), "with the sidebar shown the lights stay where they always are")
            store.sidebarShown = false
            try await settle()
            assertInStrip(try light(), "the lights lead the strip when the sidebar goes")
            await captureScreen(window, "\(dark ? "dark" : "light")-sidebar-hidden")
            // A peek floats the lights out with the panel and brings them home after it.
            store.sidebarPeeking = true
            try await settle()
            XCTAssertEqual(try light().minX, docked.minX + Look.floatingSidebarGap, accuracy: 0.5,
                           "the lights ride the peeking panel")
            store.sidebarPeeking = false
            try await settle()
            assertInStrip(try light(), "back in the strip after a peek")
            await captureScreen(window, "\(dark ? "dark" : "light")-after-peek")
            // The strip's toggle, beside the lights as in the sidebar's row, brings it back.
            let x = Look.cardGap + Look.inset + Look.trafficLights
                + SidebarChromeLayout(width: SidebarWidth.inWindow(store)).headerSpacing + Look.control / 2
            let y = window.contentView!.bounds.height - (Look.cardGap + MainToolbar.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
            try await settle()
            XCTAssertTrue(store.sidebarShown, "the toolbar's toggle reopens the sidebar")
            assertLight(try light())
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
