import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarHoverLayoutTests: XCTestCase {
    func testMountedRowStillUpdatesSelectionAndRenameAfterObservationSplit() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        let tab = store.makeBlankTab(as: .today)
        tab.park(url: URL(string: "about:blank#row-observation")!, Parked(title: "A live row"))
        store.current = nil
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: Look.rowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:
            SidebarTabSurface(store: store, tab: tab, returnHovering: .constant(false), action: {})
                .transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            store.dropStashes()
            tab.tearDown()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release([tab])
        }
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func editableFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { $0.isEditable ? [$0] : [] }
                ?? view.subviews.flatMap { editableFields(in: $0) }
        }
        try await Task.sleep(for: .milliseconds(60))
        let unselected = try pixels()
        store.current = tab.id
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(try pixels(), unselected, "Selection must still reach the rendered row")
        store.renamingTab = tab.id
        try await compatibilityWait { !editableFields(in: host).isEmpty }
        XCTAssertEqual(editableFields(in: host).first?.stringValue, "A live row")
        store.renamingTab = nil
        try await compatibilityWait { editableFields(in: host).isEmpty }
    }

    func testHoverKeepsLongTabTitleAndSubtitleInPlace() throws {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        let tab = Tab(isPrivate: true, profileID: store.profileID)
        tab.park(url: URL(string: "about:blank")!,
                 Parked(title: "prepare Closet Dashboard with a very long title", needsRecovery: true))
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        defer {
            saver.setMode(previousMode)
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }

        // Compare only the title area of a selected row, whose fill does not change on
        // hover. Revealing the trailing button must not move or retruncate this text.
        for mode: BatterySaver.Mode in [.off, .alwaysOn] {
            saver.setMode(mode)
            func titlePixels(held: Bool) throws -> Data {
                let renderer = ImageRenderer(content:
                    SidebarTabSurface(store: store, tab: tab, held: held,
                        returnHovering: .constant(false),
                        pr: GitHub.Row(author: "notnaki", state: .open),
                        action: {}, previewSelected: true)
                    .frame(width: 250, height: Look.rowHeight)
                    .transaction { $0.disablesAnimations = true })
                let image = try XCTUnwrap(renderer.cgImage)
                let context = try XCTUnwrap(CGContext(data: nil, width: 180,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: 180 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0,
                    width: image.width, height: image.height))
                return Data(bytes: try XCTUnwrap(context.data),
                            count: context.bytesPerRow * context.height)
            }
            XCTAssertTrue(try titlePixels(held: false) == titlePixels(held: true),
                           "Hover must keep the title stable (\(mode))")
        }
    }
}
