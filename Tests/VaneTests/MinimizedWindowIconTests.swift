import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class MinimizedWindowIconTests: XCTestCase {
    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

    private final class RedView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            bounds.fill()
        }
    }
    private func setupIcons() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        for (name, color) in [("AppIcon-Galaxy", blue), ("AppIcon-Candy", green)] {
            let image = NSImage(size: NSSize(width: 128, height: 128))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 128, height: 128).fill()
            image.unlockFocus()
            XCTAssertTrue(image.setName(name))
            addTeardownBlock { @MainActor in image.setName(nil) }
        }
        AppIcon.apply("Dark")
        addTeardownBlock { @MainActor in AppIcon.apply("Dark") }
    }

    private func window(content: NSView? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 400, height: 250),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let content { window.contentView = content }
        else {
            window.contentView = RedView(frame: window.contentView!.bounds)
        }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
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

    private func pixels(_ window: NSWindow, matching color: NSColor) throws -> Int {
        let view = try XCTUnwrap(window.dockTile.contentView,
                                 "The minimized tile must render the selected badge itself")
        view.setFrameSize(NSSize(width: 128, height: 128))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let target = try XCTUnwrap(color.usingColorSpace(.sRGB))
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Display color profiles can shift saturated primaries; still require
                // the fixture's distinctive hue, rather than exact device components.
                if abs(pixel.redComponent - target.redComponent) < 0.25,
                   abs(pixel.greenComponent - target.greenComponent) < 0.25,
                   abs(pixel.blueComponent - target.blueComponent) < 0.25,
                   pixel.alphaComponent > 0.9 { count += 1 }
            }
        }
        return count
    }

    func testMinimizedTileRendersThumbnailAndSelectedBadgeThenUpdatesWithoutRestoring() async throws {
        setupIcons()
        AppIcon.apply("Galaxy")
        let window = window()
        try await minimize(window)
        XCTAssertGreaterThan(try pixels(window, matching: red), 1_000)
        XCTAssertGreaterThan(try pixels(window, matching: blue), 100)
        AppIcon.apply("Candy")
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertGreaterThan(try pixels(window, matching: red), 1_000)
        XCTAssertGreaterThan(try pixels(window, matching: green), 100)
        XCTAssertEqual(try pixels(window, matching: blue), 0)
        AppIcon.apply("Dark")
        XCTAssertNil(window.dockTile.contentView)
    }

    func testChoosingAlternateAfterMinimizingDarkKeepsThumbnail() async throws {
        setupIcons()
        let window = window()
        try await minimize(window)
        XCTAssertNil(window.dockTile.contentView)
        AppIcon.apply("Galaxy")
        XCTAssertGreaterThan(try pixels(window, matching: red), 1_000)
        XCTAssertGreaterThan(try pixels(window, matching: blue), 100)
        window.deminiaturize(nil)
        let deadline = Date.now.addingTimeInterval(3)
        while window.isMiniaturized && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertNil(window.dockTile.contentView)
    }

    func testPaddedBadgeKeepsNativeVisualSizeAcrossDockScalesAndWindowShapes() async throws {
        setupIcons()
        // Bundled icon plates have transparent margins. The visible badge in the
        // native Dock occupies about a third of its square tile, including on wide windows.
        let icon = NSImage(size: NSSize(width: 128, height: 128))
        icon.lockFocus()
        blue.setFill()
        NSRect(x: 13, y: 13, width: 102, height: 102).fill()
        icon.unlockFocus()
        MinimizedWindowIcon.apply(icon)

        for thumbnailSize in [NSSize(width: 400, height: 250), NSSize(width: 250, height: 400)] {
            let window = window()
            window.setContentSize(thumbnailSize)
            window.displayIfNeeded()
            try await minimize(window)
            let view = try XCTUnwrap(window.dockTile.contentView)
            for side in [64.0, 128.0, 256.0] {
                view.setFrameSize(NSSize(width: side, height: side))
                let rendered = NSImage(size: view.bounds.size)
                rendered.lockFocus()
                view.draw(view.bounds)
                rendered.unlockFocus()
                let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
                var xs: [Int] = []
                var ys: [Int] = []
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              pixel.blueComponent > 0.75, pixel.redComponent < 0.25,
                              pixel.greenComponent < 0.25, pixel.alphaComponent > 0.9 else { continue }
                        xs.append(x)
                        ys.append(y)
                    }
                }
                let width = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1
                let height = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
                XCTAssertEqual(Double(width) / Double(rep.pixelsWide), 0.32, accuracy: 0.02,
                               "Transparent icon margins must not shrink the visible badge")
                XCTAssertEqual(Double(height) / Double(rep.pixelsHigh), 0.32, accuracy: 0.02)
            }
        }
    }

    func testDisabledBadgesAndExistingCustomTilesArePreserved() async throws {
        setupIcons()
        AppIcon.apply("Galaxy")
        let unbadged = window()
        unbadged.dockTile.showsApplicationBadge = false
        let customized = window()
        let customView = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        customized.dockTile.contentView = customView
        try await minimize(unbadged)
        try await minimize(customized)
        AppIcon.apply("Candy")
        XCTAssertNil(unbadged.dockTile.contentView)
        XCTAssertFalse(unbadged.dockTile.showsApplicationBadge)
        XCTAssertTrue(customized.dockTile.contentView === customView)
        AppIcon.apply("Dark")
        XCTAssertTrue(customized.dockTile.contentView === customView)
    }

    func testMinimizedWebPageKeepsItsRenderedPixels() async throws {
        setupIcons()
        AppIcon.apply("Galaxy")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        let container = NSView(frame: web.frame)
        container.addSubview(web)
        let foreground = RedView(frame: NSRect(x: 0, y: 150, width: 160, height: 100))
        container.addSubview(foreground)
        let window = window(content: container)
        web.loadHTMLString("<body style='margin:0;background:rgb(0,255,0)'></body>", baseURL: nil)
        let deadline = Date.now.addingTimeInterval(5)
        while web.isLoading && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // A WebKit snapshot flushes the fixture's rendered content before minimizing.
        _ = try await web.takeSnapshot(configuration: nil)
        let originalSubviews = web.subviews.map(ObjectIdentifier.init)
        try await minimize(window)
        let snapshotDeadline = Date.now.addingTimeInterval(3)
        while try pixels(window, matching: green) <= 1_000 && Date.now < snapshotDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(try pixels(window, matching: green), 1_000,
                             "The minimized thumbnail must include the out-of-process page")
        XCTAssertGreaterThan(try pixels(window, matching: red), 100,
                             "Foreground controls must remain above the page snapshot")
        XCTAssertEqual(web.subviews.map(ObjectIdentifier.init), originalSubviews,
                       "Temporary snapshot views must leave the live page")
        XCTAssertGreaterThan(try pixels(window, matching: blue), 100)
    }
}
