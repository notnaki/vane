import XCTest
@testable import vane

final class LibraryScrollbarTests: XCTestCase {
    func testHoverRevealsThenExitShrinksBeforeFading() {
        var state = LibraryScrollbarInteraction()
        XCTAssertFalse(state.visible)
        state.hover(true, at: 0)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.width, 6)
        state.hover(false, at: 1)
        XCTAssertTrue(state.visible, "Leaving must shrink before hiding")
        XCTAssertEqual(state.width, 3)
        state.advance(to: 1.44)
        XCTAssertTrue(state.visible)
        state.advance(to: 1.46)
        XCTAssertFalse(state.visible)
    }

    func testUseStaysLargeUntilIdleThenShrinksAndFadesInOrder() {
        var state = LibraryScrollbarInteraction()
        state.scroll(true, at: 0)
        XCTAssertEqual(state.width, 8)
        state.advance(to: 10)
        XCTAssertTrue(state.visible, "Active scrolling must not time out")
        state.scroll(false, at: 10)
        state.advance(to: 10.64)
        XCTAssertEqual(state.width, 8)
        state.advance(to: 10.66)
        XCTAssertEqual(state.width, 3)
        XCTAssertTrue(state.visible)
        state.advance(to: 11.11)
        XCTAssertFalse(state.visible)
    }

    func testHoverPreventsIdleFadeAndReentryCancelsOldHide() {
        var state = LibraryScrollbarInteraction()
        state.hover(true, at: 0)
        state.pulse(at: 1)
        state.advance(to: 2)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.width, 6)
        XCTAssertNil(state.nextDeadline)
        state.hover(false, at: 3)
        state.hover(true, at: 3.2)
        state.advance(to: 4)
        XCTAssertTrue(state.visible)
        XCTAssertNil(state.nextDeadline)
    }

    func testDraggingOutsideRailRemainsLargeAndVisibleUntilRelease() {
        var state = LibraryScrollbarInteraction()
        state.hover(true, at: 0)
        state.drag(true, at: 1)
        state.hover(false, at: 2)
        state.advance(to: 20)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.width, 8)
        state.drag(false, at: 20)
        state.advance(to: 20.66)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.width, 3)
        state.advance(to: 21.11)
        XCTAssertFalse(state.visible)
    }

    func testRenewedUseCancelsPendingFadeAndExtendsIdleHold() {
        var state = LibraryScrollbarInteraction()
        state.pulse(at: 0)
        state.advance(to: 0.7)
        XCTAssertEqual(state.width, 3)
        state.pulse(at: 0.8)
        state.advance(to: 1.11)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.width, 8)
        state.advance(to: 1.46)
        XCTAssertEqual(state.width, 3)
        state.advance(to: 1.91)
        XCTAssertFalse(state.visible)
    }

    func testScrollEndDoesNotEndAnOngoingThumbDrag() {
        var state = LibraryScrollbarInteraction()
        state.scroll(true, at: 0)
        state.drag(true, at: 1)
        state.scroll(false, at: 2)
        state.advance(to: 10)
        XCTAssertEqual(state.width, 8)
        XCTAssertNil(state.nextDeadline)
    }
    func testThumbGeometryAndDragMappingReachBothEnds() {
        var metrics = LibraryScrollbarMetrics(viewport: 400, content: 2000, offset: 0)
        XCTAssertTrue(metrics.scrolls)
        XCTAssertEqual(metrics.top, 4)
        XCTAssertEqual(metrics.offset(forThumbTop: metrics.top), 0)
        metrics.offset = 1600
        XCTAssertEqual(metrics.top + metrics.thumb, 396, accuracy: 0.001)
        XCTAssertEqual(metrics.offset(forThumbTop: metrics.top), 1600, accuracy: 0.001)
        XCTAssertEqual(metrics.offset(forThumbTop: -100), 0)
        XCTAssertEqual(metrics.offset(forThumbTop: 1000), 1600)
    }

    func testShortListsAndOverscrollHaveSafeThumbGeometry() {
        let short = LibraryScrollbarMetrics(viewport: 400, content: 200, offset: 0)
        XCTAssertFalse(short.scrolls)
        let long = LibraryScrollbarMetrics(viewport: 400, content: 100000, offset: -50)
        XCTAssertEqual(long.thumb, 28)
        XCTAssertEqual(long.top, 4)
        let empty = LibraryScrollbarMetrics()
        XCTAssertFalse(empty.scrolls)
        XCTAssertEqual(empty.thumb, 0)
        XCTAssertEqual(empty.offset(forThumbTop: 10), 0)
    }

    func testSafeAreaVisibleExtentStillMapsTheTrueBottomToOneHundredPercent() {
        let metrics = LibraryScrollbarMetrics(viewport: 450, content: 2640, offset: 2158,
                                               visibleHeight: 482)
        XCTAssertEqual(metrics.fraction, 1)
        XCTAssertEqual(metrics.maximumOffset, 2158)
        XCTAssertEqual(metrics.top + metrics.thumb, 446, accuracy: 0.001)
        XCTAssertEqual(metrics.offset(forThumbTop: metrics.top), 2158, accuracy: 0.001)
    }

}
