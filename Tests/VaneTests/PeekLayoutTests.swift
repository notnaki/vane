import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class PeekLayoutTests: XCTestCase {
    func testPeekTracksContentWhenSidebarChangesAndWindowResizes() async throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Peek layout fixture")
        let store = TabStore(profileID: profile.id, session: [])
        let source = store.newBlankTab()
        _ = source.web
        store.palette = nil
        let oldWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = SidebarWidth.standard
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 740),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = NSHostingView(rootView: BrowserWindow()
            .environmentObject(store).environmentObject(ProfileManager.shared)
            .transaction { $0.disablesAnimations = true })
        window.orderFront(nil)
        defer {
            Peek.close(animated: false)
            SidebarWidth.shared.width = oldWidth
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
            Peek.live?.window.contentView?.layoutSubtreeIfNeeded()
        }
        func screenBounds(_ view: NSView) throws -> CGRect {
            try XCTUnwrap(view.window).convertToScreen(view.convert(view.bounds, to: nil))
        }
        func assertCentered() throws {
            let content = try screenBounds(XCTUnwrap(source.existingWeb?.superview))
            let peek = try screenBounds(XCTUnwrap(Peek.live?.store.active?.existingWeb?.superview))
            XCTAssertEqual(peek.midX, content.midX, accuracy: 1)
            XCTAssertEqual(peek.midY, content.midY, accuracy: 1)
            XCTAssertTrue(content.contains(peek))
        }

        try await settle()
        Peek.open(URL(string: "about:blank")!, from: source, in: store)
        try await settle()
        try assertCentered()
        SidebarWidth.shared.width = 360
        try await settle()
        try assertCentered()
        store.libraryOpen = true
        try await settle()
        try assertCentered()
        store.libraryOpen = false
        store.sidebarShown = false
        try await settle()
        try assertCentered()
        window.setContentSize(.init(width: 620, height: 500))
        try await settle()
        try assertCentered()

        if let path = ProcessInfo.processInfo.environment["VANE_PEEK_LAYOUT_CAPTURE"],
           let host = Peek.live?.window.contentView,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.lockFocus()
            NSColor(white: 0.5, alpha: 1).setFill()
            NSRect(origin: .zero, size: image.size).fill()
            NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size)
                .draw(in: NSRect(origin: .zero, size: image.size))
            image.unlockFocus()
            let output = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        let before = store.tabs.count
        Peek.openAsTab(inSplit: true)
        XCTAssertNil(Peek.live)
        XCTAssertEqual(store.tabs.count, before + 1)
        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(split.tabs, [source.id, try XCTUnwrap(store.current)])
        XCTAssertEqual(store.active?.currentURL?.absoluteString, "about:blank")

        // A full split keeps the Peek available instead of losing it or creating a stray tab.
        for _ in 0..<2 {
            let pane = store.newBlankTab()
            store.addPane(pane.id, beside: source.id)
        }
        Peek.open(URL(string: "about:blank")!, from: source, in: store)
        try await settle()
        let fullCount = store.tabs.count
        Peek.openAsTab(inSplit: true)
        XCTAssertNotNil(Peek.live)
        XCTAssertEqual(store.tabs.count, fullCount)
        XCTAssertEqual(store.split(containing: source.id)?.tabs.count, Split.maxPanes)
    }
}
