import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LittleArcAddressLayoutTests: XCTestCase {
    func testNarrowProposalsKeepBothSideControlsInsideTheField() throws {
        let renderer = ImageRenderer(content: LittleArcAddressLayout {
            Color(red: 1, green: 0, blue: 0).frame(width: 80, height: 24)
            Color(red: 0, green: 1, blue: 0).frame(width: 16, height: 16)
            Color(red: 0, green: 0, blue: 1).frame(width: 120, height: 24)
        })
        renderer.proposedSize = ProposedViewSize(width: 0, height: 24)

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThanOrEqual(image.width, 240,
            "The field must reserve both sides before accepting a narrow proposal")
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 12)).redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: image.width - 1, y: 12)).blueComponent, 1, accuracy: 0.01)
    }

    func testUnequalSideControlsDoNotMoveTheHostAwayFromTheFieldCenter() throws {
        for trailingWidth in [40.0, 120.0, 180.0] {
            let renderer = ImageRenderer(content: LittleArcAddressLayout {
                Color(red: 1, green: 0, blue: 0).frame(width: 80, height: 24)
                Color(red: 0, green: 1, blue: 0).frame(width: 16, height: 16)
                Color(red: 0, green: 0, blue: 1).frame(width: trailingWidth, height: 24)
            })
            renderer.proposedSize = ProposedViewSize(width: 600, height: 24)

            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let center = try XCTUnwrap(bitmap.colorAt(x: 300, y: 12))
            XCTAssertGreaterThan(center.greenComponent, 0.4)
            XCTAssertLessThan(center.redComponent, 0.1)
            XCTAssertLessThan(center.blueComponent, 0.1)
        }
    }
}
