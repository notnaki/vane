import XCTest
@testable import vane

final class SpaceStripLayoutTests: XCTestCase {
    func testThreeSpacesUseArcSpacingAndSizes() {
        let layout = SpaceStripLayout(count: 3, availableWidth: 154)
        XCTAssertEqual(layout.itemWidth, 34)
        XCTAssertEqual(layout.dotSize, 8)
        XCTAssertEqual(layout.iconSize, 12)
        XCTAssertFalse(layout.scrolls)
    }

    func testFiveButtonTargetsFitBetweenFooterControls() {
        let layout = SpaceStripLayout(count: 5, availableWidth: 132)
        XCTAssertTrue(layout.showsButtonBackground)
        XCTAssertFalse(layout.scrolls)
        XCTAssertLessThanOrEqual(layout.itemWidth * 5, 132)
        XCTAssertGreaterThanOrEqual(layout.itemWidth, 24)
    }

    func testSixThroughTenShrinkWithoutScrolling() {
        let six = SpaceStripLayout(count: 6, availableWidth: 132)
        let ten = SpaceStripLayout(count: 10, availableWidth: 132)
        XCTAssertFalse(six.showsButtonBackground)
        XCTAssertFalse(ten.showsButtonBackground)
        XCTAssertFalse(six.scrolls)
        XCTAssertFalse(ten.scrolls)
        XCTAssertGreaterThan(six.dotSize, ten.dotSize)
        XCTAssertLessThanOrEqual(ten.itemWidth * 10, 132)
    }

    func testEleventhSpaceScrollsWithoutShrinkingFurther() {
        let ten = SpaceStripLayout(count: 10, availableWidth: 132)
        let eleven = SpaceStripLayout(count: 11, availableWidth: 132)
        XCTAssertTrue(eleven.scrolls)
        XCTAssertEqual(eleven.dotSize, ten.dotSize)
        XCTAssertEqual(eleven.itemWidth, ten.itemWidth)
        XCTAssertGreaterThan(eleven.itemWidth * 11, 132)
    }

    func testNarrowSidebarAllowsOverflowRatherThanOverlappingIcons() {
        let layout = SpaceStripLayout(count: 10, availableWidth: 68)
        XCTAssertTrue(layout.scrolls)
        XCTAssertGreaterThanOrEqual(layout.itemWidth, layout.iconSize + 2)
    }

    func testEmptyStripHasFiniteDimensions() {
        let layout = SpaceStripLayout(count: 0, availableWidth: 0)
        XCTAssertTrue(layout.itemWidth.isFinite)
        XCTAssertFalse(layout.scrolls)
    }
}
