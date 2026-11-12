import AppKit
import QuartzCore
import XCTest
@testable import vane

@MainActor final class CaptureSelectionLayersTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 700, height: 500)
    private let first = CGRect(x: 20, y: 30, width: 100, height: 80)
    private let second = CGRect(x: 250, y: 120, width: 220, height: 160)

    func testOutlineAndCutoutAnimateTogetherWhileTargetUpdatesImmediately() throws {
        let highlight = CaptureSelectionLayers()
        highlight.update(first, in: bounds, animated: false)
        let originalOutline = try XCTUnwrap(highlight.outline.path)
        let originalMask = try XCTUnwrap(highlight.dimming.path)
        highlight.update(second, in: bounds, animated: true)
        let border = try XCTUnwrap(highlight.outline.animation(forKey: CaptureSelectionLayers.transitionKey) as? CABasicAnimation)
        let mask = try XCTUnwrap(highlight.dimming.animation(forKey: CaptureSelectionLayers.transitionKey) as? CABasicAnimation)
        XCTAssertEqual(highlight.target, second, "Selection must use the latest element while its outline is moving")
        XCTAssertEqual(highlight.outline.path?.boundingBoxOfPath, second.insetBy(dx: -0.5, dy: -0.5))
        XCTAssertEqual((border.fromValue as! CGPath).boundingBoxOfPath, originalOutline.boundingBoxOfPath)
        XCTAssertEqual((mask.fromValue as! CGPath), originalMask)
        XCTAssertEqual(border.duration, mask.duration)
        XCTAssertGreaterThan(border.duration, 0)
        XCTAssertLessThanOrEqual(border.duration, 0.18)
        XCTAssertFalse(try XCTUnwrap(highlight.dimming.path).contains(CGPoint(x: second.midX, y: second.midY), using: .evenOdd))
    }

    func testRapidRetargetStartsAtTheCurrentVisualPathInsteadOfJumpingToOldDestination() throws {
        let highlight = CaptureSelectionLayers()
        highlight.update(first, in: bounds, animated: false)
        highlight.update(second, in: bounds, animated: true)
        let third = CGRect(x: 500, y: 40, width: 90, height: 60)
        highlight.update(third, in: bounds, animated: true)
        let border = try XCTUnwrap(highlight.outline.animation(forKey: CaptureSelectionLayers.transitionKey) as? CABasicAnimation)
        XCTAssertEqual((border.fromValue as! CGPath).boundingBoxOfPath, first.insetBy(dx: -0.5, dy: -0.5))
        XCTAssertEqual(highlight.target, third)
        XCTAssertEqual(highlight.outline.path?.boundingBoxOfPath, third.insetBy(dx: -0.5, dy: -0.5))
    }

    func testDraggingAndReducedMotionSettleImmediatelyAndClearingRemovesOldInk() throws {
        let highlight = CaptureSelectionLayers()
        highlight.update(first, in: bounds, animated: false)
        highlight.update(second, in: bounds, animated: true)
        highlight.settle()
        XCTAssertNil(highlight.outline.animation(forKey: CaptureSelectionLayers.transitionKey))
        XCTAssertNil(highlight.dimming.animation(forKey: CaptureSelectionLayers.transitionKey))
        XCTAssertEqual(highlight.target, second)
        highlight.update(first, in: bounds, animated: false)
        XCTAssertNil(highlight.outline.animation(forKey: CaptureSelectionLayers.transitionKey))
        XCTAssertEqual(highlight.outline.path?.boundingBoxOfPath, first.insetBy(dx: -0.5, dy: -0.5))
        highlight.update(nil, in: bounds, animated: true)
        XCTAssertEqual(highlight.outline.opacity, 0)
        XCTAssertNil(highlight.outline.animation(forKey: CaptureSelectionLayers.transitionKey))
        XCTAssertTrue(try XCTUnwrap(highlight.dimming.path).contains(CGPoint(x: first.midX, y: first.midY), using: .evenOdd))
    }

    func testVerySmallAndLargeSelectionsHaveMatchingPathTopologyForSmoothMorphs() throws {
        let highlight = CaptureSelectionLayers()
        highlight.update(CGRect(x: 10, y: 10, width: 3, height: 3), in: bounds, animated: false)
        let small = try XCTUnwrap(highlight.outline.path)
        highlight.update(second, in: bounds, animated: true)
        let large = try XCTUnwrap(highlight.outline.path)
        func topology(_ path: CGPath) -> [CGPathElementType] {
            var elements: [CGPathElementType] = []
            path.applyWithBlock { elements.append($0.pointee.type) }
            return elements
        }
        XCTAssertEqual(topology(small), topology(large))
    }
}
