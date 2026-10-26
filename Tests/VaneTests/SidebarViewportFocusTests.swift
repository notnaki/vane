import AppKit
import XCTest
@testable import vane

@MainActor final class SidebarViewportFocusTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func testFocusRevealWaitsForTheFirstUsableViewportGeometry() async throws {
        TestEnvironment.prepare()
        let viewport = SidebarRowsViewport()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 4000))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        let rows = (0..<100).map(String.init)
        viewport.configure(rows: rows, anchor: document)
        viewport.setFocus(true, row: rows[1], owner: UUID())
        // Focus can arrive in layout before the representable reports its clip view.
        try await compatibilityWait { viewport.focusedRows == [rows[1]] }
        XCTAssertEqual(scroll.contentView.bounds.minY, 2000, accuracy: 1)
        viewport.receive(count: rows.count, visible: scroll.contentView.bounds, clip: scroll.contentView)
        try await compatibilityWait { scroll.contentView.bounds.minY < 100 }
        let revealed = scroll.contentView.bounds.minY
        // The completed reveal must not keep pulling a later wheel gesture back.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        viewport.receive(count: rows.count, visible: scroll.contentView.bounds, clip: scroll.contentView)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertLessThan(revealed, 100)
        XCTAssertEqual(scroll.contentView.bounds.minY, 2000, accuracy: 1)
    }
}
