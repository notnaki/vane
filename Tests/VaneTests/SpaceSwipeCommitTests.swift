import XCTest
@testable import vane

final class SpaceSwipeCommitTests: XCTestCase {
    func testCrossingDistanceThresholdCommitsBeforeFingerReleaseInEitherDirection() {
        for direction: CGFloat in [-1, 1] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 1)
            XCTAssertNil(swipe.feed(dx: direction * 74, dt: 1, phase: .changed,
                                   width: 250, count: 3, index: 1).commit)
            XCTAssertEqual(swipe.feed(dx: direction, dt: 1, phase: .changed,
                                     width: 250, count: 3, index: 1).commit, direction < 0 ? 1 : -1)
            XCTAssertFalse(swipe.armed)
            for phase in [Spaces.Swipe.Phase.changed, .ended, .momentum, .cancelled] {
                let result = swipe.feed(dx: direction * 250, dt: 1, phase: phase,
                                        width: 250, count: 3, index: 1)
                XCTAssertNil(result.commit, "One gesture must only switch once")
                XCTAssertNil(result.offset, "The gesture tail cannot move the landed sidebar")
            }
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

    func testTinyFastEdgeMovementDoesNotSwitchSpaces() {
        XCTAssertNil(Spaces.Swipe.commit(travel: 4, speed: 1100, width: 250, count: 3, index: 1))
        XCTAssertNil(Spaces.Swipe.commit(travel: -4, speed: -1100, width: 250, count: 3, index: 1))
        XCTAssertEqual(Spaces.Swipe.commit(travel: -40, speed: -1100, width: 250, count: 3, index: 1), 1)
    }

    func testReleasingAFullRingAtTheLastSpaceOpensCreate() {
        var swipe = Spaces.Swipe()
        _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: 2, create: true)
        _ = swipe.feed(dx: -100, dt: 0.5, phase: .changed, width: 250, count: 3, index: 2, create: true)
        XCTAssertEqual(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: 3, index: 2, create: true).commit, 1)
        XCTAssertNil(swipe.feed(dx: -100, dt: 0.01, phase: .momentum, width: 250, count: 3, index: 2, create: true).commit)
    }
    func testCancelledSwipeDoesNotSwitchOrOpenCreate() {
        for index in [1, 2] {
            var swipe = Spaces.Swipe()
            _ = swipe.feed(dx: 0, dt: 0, phase: .began, width: 250, count: 3, index: index, create: true)
            _ = swipe.feed(dx: index == 1 ? -50 : -100, dt: 0.5, phase: .changed,
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
            _ = swipe.feed(dx: -80, dt: 0.5, phase: .changed, width: 250, count: count, index: count - 1, create: true)
            XCTAssertEqual(swipe.feed(dx: 0, dt: 0.01, phase: .ended, width: 250, count: count, index: count - 1, create: true).commit, 1)
        }
    }
}
