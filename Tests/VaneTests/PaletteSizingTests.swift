import AppKit
import SwiftUI
import XCTest
@testable import vane

final class PaletteSizingTests: XCTestCase {
    func testBarFitsCompactWindowForEverySearchPositionAndScope() {
        for chrome in [Look.barRowHeight, Look.barFieldHeight,
                       Look.barFieldHeight + Look.control + Look.barRowGap] {
            for top in [0.05, 0.25, 0.5] {
                for anchor: CGFloat? in [nil, 70] {
                    let sizing = PaletteSizing(window: CGSize(width: 470, height: 380),
                        visibleRows: 12, rowCount: 20, chromeHeight: chrome,
                        topFraction: top, anchorTop: anchor)
                    XCTAssertEqual(sizing.width, 470 - Look.inset * 2)
                    XCTAssertLessThan(sizing.rowCap, 12)
                    XCTAssertGreaterThanOrEqual(sizing.top, Look.inset)
                    XCTAssertLessThanOrEqual(sizing.top + sizing.height, 380 - Look.inset)
                }
            }
        }
    }

    func testShrinkingAndGrowingRestoresPreferredWidthAndVisibleRows() {
        let sizing = PaletteSizing(window: CGSize(width: 1280, height: 1000),
                                   visibleRows: 12, rowCount: 20)
        XCTAssertEqual(sizing.width, Look.barWidth)
        XCTAssertEqual(sizing.rowCap, 12)
        let compact = PaletteSizing(window: CGSize(width: 470, height: 380),
                                    visibleRows: 12, rowCount: 20)
        XCTAssertLessThan(compact.width, sizing.width)
        XCTAssertLessThan(compact.rowCap, sizing.rowCap)
        let restored = PaletteSizing(window: sizing.window, visibleRows: 12, rowCount: 20)
        XCTAssertEqual(restored.width, sizing.width)
        XCTAssertEqual(restored.rowCap, sizing.rowCap)
    }

    func testEmptyResultsKeepTheInputPositionStable() {
        let empty = PaletteSizing(window: CGSize(width: 470, height: 380), rowCount: 0)
        let results = PaletteSizing(window: empty.window, rowCount: 20)
        XCTAssertEqual(empty.top, results.top)
        XCTAssertEqual(empty.height, Look.barFieldHeight)
    }
}

@MainActor final class CompactPalettePresentationTests: XCTestCase {
    func testNativeFieldAndResultsFitWhileWindowShrinksAndGrows() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        do { try await checkPresentation() }
        catch {
            try await loop.close()
            throw error
        }
        try await loop.close()
    }

    private func checkPresentation() async throws {
        let previousMotion = BatterySaver.shared.mode
        let previousWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = 500
        BatterySaver.shared.setMode(.alwaysOn)
        defer {
            BatterySaver.shared.setMode(previousMotion)
            SidebarWidth.shared.width = previousWidth
        }
        let store = Windows.open(isPrivate: true, focus: false, session: [])
        let window = try XCTUnwrap(store.window)
        let host = try XCTUnwrap(window.contentView)
        defer {
            store.librarySwipeMonitor.remove()
            store.spaceGesture.monitor.remove()
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            SharedTabs.release(store.tabs, excluding: store)
            TabStore.all.removeAll { $0 === store }
        }
        XCTAssertLessThanOrEqual(window.minSize.width, 470)
        XCTAssertLessThanOrEqual(window.minSize.height, 380)
        for index in 0..<8 {
            let tab = store.newBlankTab(focus: false)
            tab.title = "A long tab title that should truncate in a compact window \(index)"
        }
        store.sidebarShown = false
        store.palette = .newTab
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        let screen = try XCTUnwrap(window.screen).visibleFrame.size
        let large = CGSize(width: min(1280, screen.width), height: min(840, screen.height))
        let tall = CGSize(width: 470, height: min(880, screen.height))
        for size in [CGSize(width: 470, height: 380), large, tall, CGSize(width: 470, height: 380)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return NSApp.isRunning && window.isVisible && window.occlusionState.contains(.visible)
                    && host.bounds.size == size
                    && descendants(host, NSHostingView<AnyView>.self).contains {
                        !$0.isHiddenOrHasHiddenAncestor
                            && !descendants($0, CommandField.BarField.self).isEmpty
                            && !descendants($0, NSScrollView.self).isEmpty
                    }
            }
            let palette = try XCTUnwrap(descendants(host, NSHostingView<AnyView>.self)
                .first { !$0.isHiddenOrHasHiddenAncestor })
            XCTAssertLessThanOrEqual(window.minSize.width, 470)
            XCTAssertLessThanOrEqual(window.minSize.height, 380)
            XCTAssertEqual(SidebarWidth.shared.width, 500,
                           "Compact presentation must preserve the shared preferred width")
            XCTAssertEqual(SidebarWidth.inWindow(store), SidebarWidth.fitting(500, in: size.width))
            let field = try XCTUnwrap(descendants(palette, CommandField.BarField.self).first)
            let fieldFrame = host.convert(field.bounds, from: field)
            XCTAssertGreaterThan(fieldFrame.width, 100)
            XCTAssertGreaterThanOrEqual(fieldFrame.minX, 0)
            XCTAssertLessThanOrEqual(fieldFrame.maxX, host.bounds.maxX)
            XCTAssertGreaterThanOrEqual(fieldFrame.minY, 0)
            XCTAssertLessThanOrEqual(fieldFrame.maxY, host.bounds.maxY)
            let scroll = try XCTUnwrap(descendants(palette, NSScrollView.self).first)
            let resultsFrame = host.convert(scroll.bounds, from: scroll)
            XCTAssertGreaterThanOrEqual(resultsFrame.minX, 0)
            XCTAssertLessThanOrEqual(resultsFrame.maxX, host.bounds.maxX)
            XCTAssertGreaterThanOrEqual(resultsFrame.minY, 0)
            XCTAssertLessThanOrEqual(resultsFrame.maxY, host.bounds.maxY)
            if let directory = ProcessInfo.processInfo.environment["VANE_PALETTE_SNAPSHOT_DIR"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("palette-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
    }
}
