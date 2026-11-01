import XCTest
@testable import vane

final class SpaceSwipeCommitTests: XCTestCase {
    func testDistanceThresholdRemainsInteractiveUntilFingerRelease() {
        for direction: CGFloat in [-1, 1] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 1)
            let held = swipe.feed(dx: direction * 130, dt: 1, phase: .changed,
                                  width: 250, count: 3, index: 1)
            XCTAssertNil(held.commit, "Keep ownership while the fingers hold between Spaces")
            XCTAssertEqual(held.offset, direction * 130)
            XCTAssertTrue(swipe.armed)
            XCTAssertNil(swipe.feed(dx: -direction * 20, dt: 1, phase: .changed,
                                   width: 250, count: 3, index: 1).commit)
            XCTAssertEqual(swipe.feed(dx: 0, dt: 1, phase: .ended,
                                     width: 250, count: 3, index: 1).commit, direction < 0 ? 1 : -1)
            XCTAssertNil(swipe.feed(dx: direction * 250, dt: 1, phase: .momentum,
                                   width: 250, count: 3, index: 1).commit)
        }
    }

    func testShortFastSwipeWaitsForReleaseAndCanReverse() {
        var swipe = Spaces.Swipe()
        _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 1)
        XCTAssertNil(swipe.feed(dx: -40, dt: 0.01, phase: .changed,
                               width: 250, count: 3, index: 1).commit)
        _ = swipe.feed(dx: 30, dt: 0.01, phase: .changed, width: 250, count: 3, index: 1)
        XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended,
                               width: 250, count: 3, index: 1).commit)
    }

    func testDragCanReverseBackBelowThresholdBeforeRelease() {
        var swipe = Spaces.Swipe()
        _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 1)
        _ = swipe.feed(dx: -130, dt: 1, phase: .changed, width: 250, count: 3, index: 1)
        let reversed = swipe.feed(dx: 100, dt: 1, phase: .changed, width: 250, count: 3, index: 1)
        XCTAssertEqual(reversed.offset, -30)
        XCTAssertNil(swipe.feed(dx: 0, dt: 1, phase: .ended,
                               width: 250, count: 3, index: 1).commit)
    }

    func testQuarterWidthSlowSwipeSwitchesButShortNoiseDoesNot() {
        for direction: CGFloat in [-1, 1] {
            XCTAssertEqual(Spaces.Swipe.commit(travel: direction * 62.5, speed: 0,
                                               width: 250, count: 3, index: 1), direction < 0 ? 1 : -1)
            XCTAssertNil(Spaces.Swipe.commit(travel: direction * 20, speed: 0,
                                            width: 250, count: 3, index: 1))
        }
    }

    func testTinyFastEdgeMovementDoesNotSwitchSpaces() {
        XCTAssertNil(Spaces.Swipe.commit(travel: 4, speed: 1100, width: 250, count: 3, index: 1))
        XCTAssertNil(Spaces.Swipe.commit(travel: -4, speed: -1100, width: 250, count: 3, index: 1))
        XCTAssertEqual(Spaces.Swipe.commit(travel: -40, speed: -1100, width: 250, count: 3, index: 1), 1)
    }

    func testDeliberatePullAtTheLastSpaceOpensCreateOnRelease() {
        var swipe = Spaces.Swipe()
        _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 2, create: true)
        _ = swipe.feed(dx: -230, dt: 0.5, phase: .changed, width: 250, count: 3, index: 2, create: true)
        XCTAssertEqual(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: 3, index: 2, create: true).commit, 1)
        XCTAssertNil(swipe.feed(dx: -100, dt: 0.01, phase: .momentum, width: 250, count: 3, index: 2, create: true).commit)
    }
    func testQuickLongPullNeverOpensCreationEvenOnRelease() {
        for count in [1, 3] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: count, index: count - 1, create: true)
            let held = swipe.feed(dx: -300, dt: 0.04, phase: .changed, width: 250, count: count, index: count - 1, create: true)
            XCTAssertNil(held.commit, "A fast overswipe must not open the form under the fingers")
            XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: count, index: count - 1, create: true).commit)
        }
    }

    func testFullDeliberatePullCanReverseBeforeRelease() {
        var swipe = Spaces.Swipe()
        _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 2, create: true)
        XCTAssertNil(swipe.feed(dx: -230, dt: 0.5, phase: .changed, width: 250, count: 3, index: 2, create: true).commit)
        _ = swipe.feed(dx: 170, dt: 0.3, phase: .changed, width: 250, count: 3, index: 2, create: true)
        XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: 3, index: 2, create: true).commit)
    }

    func testOldCreationDistanceAndFullRingOnlySpringBack() {
        for distance: CGFloat in [80, 100, 150] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 2, create: true)
            XCTAssertNil(swipe.feed(dx: -distance, dt: 0.5, phase: .changed, width: 250, count: 3, index: 2, create: true).commit)
            XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: 3, index: 2, create: true).commit)
        }
    }

    func testCancelledSwipeDoesNotSwitchOrOpenCreate() {
        for index in [1, 2] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: index, create: true)
            _ = swipe.feed(dx: index == 1 ? -50 : -230, dt: 0.5, phase: .changed,
                           width: 250, count: 3, index: index, create: true)
            XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .cancelled, width: 250, count: 3, index: index, create: true).commit)
            XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: 3, index: index, create: true).commit)
        }
    }

    func testShortPullAtLastSpaceSpringsBackAndOneSpaceCanCreate() {
        for count in [1, 3] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: count, index: count - 1, create: true)
            _ = swipe.feed(dx: -20, dt: 0.01, phase: .changed, width: 250, count: count, index: count - 1, create: true)
            XCTAssertNil(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: count, index: count - 1, create: true).commit)
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: count, index: count - 1, create: true)
            _ = swipe.feed(dx: -230, dt: 0.5, phase: .changed, width: 250, count: count, index: count - 1, create: true)
            XCTAssertEqual(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: count, index: count - 1, create: true).commit, 1)
        }
    }
}
