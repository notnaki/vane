import AppKit
import XCTest
@testable import vane

final class FavouriteLandingTests: XCTestCase {
    func testEmptyFavouritesRevealOnlyNearCollapsedSeam() {
        let pill = CGRect(x: 8, y: 40, width: 212, height: 36)
        let collapsed = FavouriteLanding.emptyFrame(below: pill, revealed: false)
        XCTAssertTrue(FavouriteLanding.isNear(CGPoint(x: 100, y: 88), frame: collapsed))
        XCTAssertFalse(FavouriteLanding.isNear(CGPoint(x: 100, y: 130), frame: collapsed))
        let revealed = FavouriteLanding.emptyFrame(below: pill, revealed: true)
        XCTAssertEqual(collapsed.minY, revealed.minY)
        XCTAssertTrue(FavouriteLanding.isNear(CGPoint(x: 100, y: 130), frame: revealed))
    }

    func testPreviewMakesRoomWithoutChangingCommittedFavourites() {
        let ids = (0..<3).map { _ in UUID() }, incoming = UUID()
        XCTAssertEqual(FavouriteLanding.previewIDs(favourites: ids, incoming: [incoming], index: nil), ids)
        XCTAssertEqual(FavouriteLanding.previewIDs(favourites: ids, incoming: [incoming], index: 1),
                       [ids[0], incoming, ids[1], ids[2]])
        XCTAssertEqual(FavouriteLanding.previewIDs(favourites: ids, incoming: [ids[0]], index: 2),
                       [ids[1], ids[2], ids[0]])
        let preview = FavouriteLanding.previewIDs(favourites: ids, incoming: [incoming], index: 1)
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 1, favourites: preview, moving: [incoming]), 1)
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 2, favourites: preview, moving: [incoming]), 1)
        XCTAssertEqual(ids.count, 3)
    }

    func testGhostMorphContinuouslyInterpolatesRowAndTileGeometry() {
        let row = GhostTileMorph(progress: 0, rowWidth: 212, tileWidth: 64)
        let mid = GhostTileMorph(progress: 0.5, rowWidth: 212, tileWidth: 64)
        let tile = GhostTileMorph(progress: 1, rowWidth: 212, tileWidth: 64)
        XCTAssertEqual(row.width, 212)
        XCTAssertEqual(tile.width, 64)
        XCTAssertEqual(mid.width, 138)
        XCTAssertEqual(row.height, Look.rowHeight)
        XCTAssertEqual(tile.height, Look.tileHeight)
        XCTAssertEqual(row.iconX, Look.rowInset + Look.rowIcon / 2)
        XCTAssertEqual(tile.iconX, 32)
        XCTAssertEqual(mid.iconX, (row.iconX + tile.iconX) / 2)
    }
    @MainActor func testLeavingSourceWindowDoesNotClearAnotherWindowsTileShape() {
        let source = SidebarDragPreview(), destination = SidebarDragPreview()
        source.setDestination(.init(index: 0, width: 100))
        destination.setDestination(.init(index: 1, width: 64))
        source.setDestination(nil)
        XCTAssertEqual(Dragging.shared.favouriteGhostWidth, 64)
        destination.setDestination(nil)
        XCTAssertNil(Dragging.shared.favouriteGhostWidth)
    }
    func testFixedGridGapAccountsForSourceTilesOnlyAfterRelease() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 0, favourites: ids, moving: [ids[0]]), 0)
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 3, favourites: ids, moving: [ids[0]]), 2)
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 1, favourites: ids, moving: [ids[3]]), 1)
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 4, favourites: ids, moving: [ids[0], ids[2]]), 2)
        // Incoming rows and split panes have no physical slot in the unchanged grid.
        XCTAssertEqual(FavouriteLanding.remainingIndex(gap: 3, favourites: ids, moving: [UUID(), UUID()]), 3)
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
