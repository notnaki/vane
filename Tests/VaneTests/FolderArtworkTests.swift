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
        }
    }

    func testIntermediateFlapRotationMatchesRecording() {
        for (openness, expectedDegrees) in [(CGFloat(0), 0.0), (0.5, 1.75), (1, 0)] {
            let bounds = FolderFace.panelBounds(openness)
            let transform = FolderFace.projection(openness)
            let left = CGPoint(x: bounds.midX - 2, y: bounds.minY).applying(transform)
            let right = CGPoint(x: bounds.midX + 2, y: bounds.minY).applying(transform)
            let angle = atan2(right.y - left.y, right.x - left.x) * 180 / .pi
            XCTAssertEqual(angle, expectedDegrees, accuracy: 0.2,
                           "The flap should rotate during the transition and settle level at each endpoint")
        }
    }

    func testOpeningAndClosingTimingTracksRecordedSamples() {
        // Seconds and pose progress measured from the supplied Arc recording.
        let opening: [(Double, Double)] = [(0.047, 0.303), (0.089, 0.578), (0.147, 0.892), (0.197, 0.983)]
        let closing: [(Double, Double)] = [(0.039, 0.261), (0.081, 0.631), (0.123, 0.838), (0.189, 0.990)]
        for (curve, samples) in [(FolderMotion.opening, opening), (FolderMotion.closing, closing)] {
            for (time, expected) in samples {
                XCTAssertEqual(progress(curve, at: time), expected, accuracy: 0.065)
            }
        }
    }

    private func progress(_ curve: FolderMotion.Curve, at time: Double) -> Double {
        let x = min(1, max(0, time / curve.duration))
        var lower = 0.0, upper = 1.0
        for _ in 0..<40 {
            let t = (lower + upper) / 2
            let position = 3 * pow(1 - t, 2) * t * curve.x1
                + 3 * (1 - t) * t * t * curve.x2 + t * t * t
            if position < x { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        return 3 * pow(1 - t, 2) * t * curve.y1
            + 3 * (1 - t) * t * t * curve.y2 + t * t * t
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
