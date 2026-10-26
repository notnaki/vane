import CoreGraphics
import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarDropMarkerTests: XCTestCase {
    func testNativeRowsOnlyMountGeometryRelayDuringADrag() async throws {
        TestEnvironment.prepare()
        let dragging = Dragging.shared
        dragging.end()
        let marker = SidebarDropMarker()
        let host = NSHostingView(rootView: DropLine(on: true, axis: .vertical, target: "gap")
            .frame(width: 120).environment(\.sidebarDropMarker, marker))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 1000))
        host.frame = CGRect(x: 30, y: 80, width: 120, height: 2)
        document.addSubview(host)
        scroll.documentView = document
        window.contentView = scroll
        marker.registerNativeOverlay(scroll)
        defer { dragging.end(); window.contentView = nil; window.close() }
        func relays(in view: NSView) -> [NativeSidebarMarkerRelay.Anchor] {
            (view as? NativeSidebarMarkerRelay.Anchor).map { [$0] }
                ?? view.subviews.flatMap { relays(in: $0) }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(relays(in: host).isEmpty, "Idle row owners must not mount geometry or enqueue relay work")
        dragging.tab = UUID()
        marker.offer("gap", session: dragging.session)
        try await compatibilityWait { marker.frame != nil }
        XCTAssertEqual(relays(in: host).count, 1)
        XCTAssertEqual(try XCTUnwrap(marker.frame).width, 120, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(marker.frame).height, 2, accuracy: 0.5)
        let original = try XCTUnwrap(marker.frame)
        let offset = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: offset.x, y: offset.y + 50))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait { marker.frame != original }
        XCTAssertEqual(try XCTUnwrap(marker.frame).minX, original.minX, accuracy: 0.5)
        XCTAssertEqual(abs(try XCTUnwrap(marker.frame).minY - original.minY), 50, accuracy: 0.5,
                       "The active gap must follow a nested native viewport without preference propagation")
        dragging.end()
        try await compatibilityWait { relays(in: host).isEmpty }
    }

    func testGapHandoffKeepsTheMarkerVisibleUntilRelease() {
        let marker = SidebarDropMarker()
        let session = UUID()
        let first = CGRect(x: 8, y: 80, width: 220, height: 2)
        let second = CGRect(x: 24, y: 162, width: 204, height: 2)
        marker.offer("first", session: session)
        XCTAssertFalse(marker.visible(session: session, active: true))
        marker.remember(first)
        XCTAssertTrue(marker.visible(session: session, active: true))
        // The old target exits before the new target publishes its geometry.
        marker.remember(nil)
        XCTAssertEqual(marker.frame, first)
        marker.offer("second", session: session)
        XCTAssertTrue(marker.visible(session: session, active: true))
        marker.remember(second)
        XCTAssertEqual(marker.frame, second)
        XCTAssertTrue(marker.visible(session: session, active: true))
        XCTAssertFalse(marker.visible(session: session, active: false))
        // Keep the last frame so fading out does not also collapse the line.
        XCTAssertEqual(marker.frame, second)
    }

    func testNewDragsAndOtherSidebarsDoNotReuseStaleMarkers() {
        let marker = SidebarDropMarker()
        let old = UUID(), next = UUID()
        marker.offer("first", session: old)
        marker.remember(CGRect(x: 8, y: 80, width: 220, height: 2))
        XCTAssertFalse(marker.visible(session: next, active: true))
        marker.offer("second", session: next)
        XCTAssertNil(marker.frame)
        XCTAssertFalse(marker.visible(session: next, active: true))
        marker.remember(CGRect(x: 8, y: 121, width: 220, height: 2))
        XCTAssertTrue(marker.visible(session: next, active: true))
        // Folder interiors and explicit split targets use their own highlight instead.
        marker.offer(nil, session: next)
        XCTAssertFalse(marker.visible(session: next, active: true))
    }
}
