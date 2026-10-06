import AppKit
import XCTest
@testable import vane

final class FavouriteLandingTests: XCTestCase {
    @MainActor func testLeavingSourceWindowDoesNotClearAnotherWindowsTileShape() {
        let source = SidebarDragPreview(), destination = SidebarDragPreview()
        source.setDestination(.init(index: 0, width: 100))
        destination.setDestination(.init(index: 1, width: 64))
        source.setDestination(nil)
        XCTAssertEqual(Dragging.shared.favouriteGhostWidth, 64)
        destination.setDestination(nil)
        XCTAssertNil(Dragging.shared.favouriteGhostWidth)
    }
    func testProximityAndInsertionUseDestinationTileGeometry() {
        let frame = CGRect(x: 8, y: 90, width: 212, height: 46)
        XCTAssertTrue(FavouriteLanding.isNear(CGPoint(x: 100, y: 145), frame: frame))
        XCTAssertFalse(FavouriteLanding.isNear(CGPoint(x: 100, y: 170), frame: frame))
        XCTAssertEqual(FavouriteLanding.index(at: CGPoint(x: 10, y: 110), frame: frame,
                                              count: 3, columns: 3), 0)
        XCTAssertEqual(FavouriteLanding.index(at: CGPoint(x: 100, y: 110), frame: frame,
                                              count: 3, columns: 3), 1)
        XCTAssertEqual(FavouriteLanding.index(at: CGPoint(x: 215, y: 110), frame: frame,
                                              count: 3, columns: 3), 3)
    }

    func testWrappedRowsAndEmptyGridHaveStableSlots() {
        let frame = CGRect(x: 8, y: 90, width: 212, height: 100)
        XCTAssertEqual(FavouriteLanding.index(at: CGPoint(x: 215, y: 185), frame: frame,
                                              count: 4, columns: 3), 4)
        XCTAssertEqual(FavouriteLanding.index(at: .zero, frame: frame, count: 0, columns: 1), 0)
        XCTAssertEqual(FavouriteLanding.tileWidth(width: 212, columns: 3), 196.0 / 3, accuracy: 0.01)
    }
}
