import CoreGraphics
import XCTest
@testable import vane

@MainActor final class SidebarDropMarkerTests: XCTestCase {
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
