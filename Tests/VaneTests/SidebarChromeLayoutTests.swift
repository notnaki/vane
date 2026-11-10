import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SidebarChromeLayoutTests: XCTestCase {
    func testOverflowWaitsUntilFullSizeTargetsTouch() {
        // 16pt outer insets + 62pt lights + four 24pt targets = 174pt.
        XCTAssertFalse(SidebarChromeLayout(width: 174).usesOverflow)
        XCTAssertEqual(SidebarChromeLayout(width: 174).navigationSpacing, 0)
        XCTAssertTrue(SidebarChromeLayout(width: 173.5).usesOverflow)
        XCTAssertTrue(SidebarChromeLayout(width: 164).usesOverflow)
        XCTAssertFalse(SidebarChromeLayout(width: 200).usesOverflow)
        XCTAssertEqual(SidebarChromeLayout(width: 228).navigationSpacing, 6)
        XCTAssertEqual(SidebarChromeLayout(width: 228).headerSpacing, 12)
    }

    func testFullSizeControlsFitAcrossTheEntireResizeRange() {
        for width in stride(from: 164.0, through: 500, by: 0.5) {
            let layout = SidebarChromeLayout(width: width)
            let buttonCount = layout.usesOverflow ? 3.0 : 4.0
            let headerGaps = layout.usesOverflow ? 2.0 : 3.0
            let occupied = 16 + 62 + buttonCount * 24
                + headerGaps * layout.headerSpacing + 2 * layout.navigationSpacing
            XCTAssertLessThanOrEqual(occupied, width + 0.001, "Width: \(width)")
            XCTAssertGreaterThanOrEqual(layout.navigationSpacing, 0)
        }
    }

    func testNarrowingTheSidebarKeepsTheAddressPillOnTheSameRow() {
        for width in [164.0, 173, 174, 180, 200, 228, 500] {
            let layout = SidebarChromeLayout(width: width)
            XCTAssertEqual(layout.headerHeight, 28, "Width: \(width)")
            XCTAssertEqual(layout.addressTop, 45, "Width: \(width)")
        }
    }

    @MainActor func testRenderedHeaderKeepsGlyphSizesUntilOverflow() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let sidebar = SidebarWidth.shared
            let previousWidth = sidebar.width
            let saver = BatterySaver.shared
            let previousMode = saver.mode
            saver.setMode(.alwaysOn)
            let store = TabStore(isPrivate: true, session: [])
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 228, height: 44),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.orderOut(nil); window.contentView = nil; window.close()
                sidebar.setLiveWidth(previousWidth)
                saver.setMode(previousMode)
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
            }
            var normalWidths: [Int] = []
            for width in [228.0, 220, 200, 180, 174, 173, 164] {
                sidebar.setLiveWidth(width)
                let host = NSHostingView(rootView: TopRow().environmentObject(store)
                    .frame(width: width - 16).padding(8)
                    .background(.black).environment(\.colorScheme, .dark))
                window.setContentSize(NSSize(width: width, height: 44))
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try await compatibilityWait {
                    host.layoutSubtreeIfNeeded()
                    return app.isRunning && app.isActive && window.isKeyWindow
                        && window.occlusionState.contains(.visible) && host.window === window
                        && host.bounds.size == NSSize(width: width, height: 44)
                        && app.modalWindow == nil && window.attachedSheet == nil
                }
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var ranges: [ClosedRange<Int>] = []
                for x in 0..<bitmap.pixelsWide {
                    let painted = (0..<bitmap.pixelsHigh).contains { y in
                        (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.1
                    }
                    guard painted else { continue }
                    if let last = ranges.last, x - last.upperBound <= 2 {
                        ranges[ranges.count - 1] = last.lowerBound...x
                    } else { ranges.append(x...x) }
                }
                // Ellipsis paints three separate dots beside the two arrow glyphs.
                XCTAssertEqual(ranges.count, width < 174 ? 5 : 4, "Width: \(width), ranges: \(ranges)")
                if width == 228 { normalWidths = ranges.map(\.count) }
                if width >= 174, ranges.count == normalWidths.count {
                    for (actual, normal) in zip(ranges.map(\.count), normalWidths) {
                        XCTAssertLessThanOrEqual(abs(actual - normal), 2, "Shrinking gaps must not shrink glyphs")
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["VANE_HEADER_CAPTURE_DIR"] {
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("header-\(Int(width)).png"))
                }
            }
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Header AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }
}
