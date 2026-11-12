import SwiftUI
import XCTest
@testable import vane

final class FolderArtworkTests: XCTestCase {
    func testRearStrokeDoesNotEnterFrontInteriorThroughoutTransition() {
        for frame in 0...100 {
            let openness = CGFloat(frame) / 100
            let style = StrokeStyle(lineWidth: 1.5 - 0.25 * openness,
                                    lineCap: .round, lineJoin: .round)
            let ink = FolderArtwork(openness: openness)
                .path(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            let front = FolderFace.panel(openness)
            // The front border is allowed; a rear stroke past it is not.
            let border = front.strokedPath(StrokeStyle(lineWidth: style.lineWidth + 0.02,
                                                       lineCap: .round, lineJoin: .round))
            let intrusion = ink.intersection(front).subtracting(border)
            // Boolean Path expressions are lazy; inspect the resolved geometry.
            XCTAssertTrue(intrusion.cgPath.isEmpty, "Rear stroke enters front interior at openness \(openness)")
        }
    }

    func testFrontOpensAroundFixedLowerRightCorner() {
        let hinge = CGPoint(x: 17.25, y: 16.625)
        for frame in 0...100 {
            let openness = CGFloat(frame) / 100
            let bounds = FolderFace.panelBounds(openness)
            let corner = CGPoint(x: bounds.maxX, y: bounds.maxY)
                .applying(FolderFace.projection(openness))
            XCTAssertEqual(corner.x, hinge.x, accuracy: 0.00001,
                           "Hinge drifts horizontally at openness \(openness)")
            XCTAssertEqual(corner.y, hinge.y, accuracy: 0.00001,
                           "Hinge lifts at openness \(openness)")
            XCTAssertEqual(FolderFace.panel(openness).boundingRect.maxY, hinge.y, accuracy: 0.00001,
                           "Bottom edge lifts at openness \(openness)")
        }
    }

    func testOpenRearStrokeDoesNotProtrudeBelowRoundedCorner() {
        let ink = FolderArtwork(openness: 1)
            .path(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        // These pixels sit beyond the reference's rounded lower-left silhouette.
        for point in [CGPoint(x: 2.4, y: 15.7), CGPoint(x: 2.5, y: 15.8)] {
            XCTAssertFalse(ink.contains(point), "Rear cap protrudes at \(point)")
        }
    }
}
