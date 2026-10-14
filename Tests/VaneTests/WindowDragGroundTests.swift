import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class WindowDragGroundTests: XCTestCase {
    func testDetachedHoveredGroundDoesNotStealClicksFromAnotherProfile() {
        _ = NSApplication.shared
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let ground = WindowDragGround()
        let patch = WindowDragPatch(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView!.addSubview(patch)
        ground.hover(true, patch: patch)
        XCTAssertTrue(ground.over(in: window, at: NSPoint(x: 100, y: 100)))
        patch.removeFromSuperview()
        XCTAssertFalse(ground.over(in: window, at: NSPoint(x: 100, y: 100)), "A cached profile's detached ground must stop claiming clicks")
        ground.hover(false, patch: patch)
    }
    func testGroundIsScopedToItsWindowAndVisibleRegion() {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let ground = WindowDragGround()
        let patch = WindowDragPatch(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        first.contentView!.addSubview(patch)
        ground.hover(true, patch: patch)
        ground.hover(true, patch: patch)
        XCTAssertFalse(ground.over(in: second, at: NSPoint(x: 100, y: 100)))
        XCTAssertFalse(ground.over(in: first, at: NSPoint(x: 500, y: 100)), "frame=\(patch.frame) bounds=\(patch.bounds) visible=\(patch.visibleRect) point=\(patch.convert(NSPoint(x: 500, y: 100), from: nil))")
        patch.isHidden = true
        XCTAssertFalse(ground.over(in: first, at: NSPoint(x: 100, y: 100)))
        patch.isHidden = false
        ground.hover(false, patch: patch)
        XCTAssertFalse(ground.over(in: first, at: NSPoint(x: 100, y: 100)),
                       "Duplicate enter callbacks must not leave a leaked count")
    }

    func testSwiftUIGroundAnchorHasWindowAndBoundsAndClearsOnParking() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WindowDragArea().frame(width: 240, height: 600))
        window.contentView!.addSubview(host)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WindowDragPatch? {
            if let patch = view as? WindowDragPatch { return patch }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let patch = find(host) else { XCTFail("Ground anchor must mount"); return }
        let ground = WindowDragGround()
        ground.hover(true, patch: patch)
        XCTAssertTrue(ground.over(in: window, at: NSPoint(x: 100, y: 100)))
        host.removeFromSuperview()
        XCTAssertFalse(ground.over(in: window, at: NSPoint(x: 100, y: 100)))
        window.contentView!.addSubview(host)
        XCTAssertFalse(ground.over(in: window, at: NSPoint(x: 100, y: 100)),
                       "Reattached cached content needs fresh hover before claiming input")
    }

}
