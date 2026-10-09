import CoreGraphics
import XCTest
@testable import vane

final class SidebarScrollCutoffTests: XCTestCase {
    private func cutoffs(offset: CGFloat, content: CGFloat = 800, viewport: CGFloat = 300) -> SidebarScrollCutoffs {
        SidebarScrollCutoffs(visibleRect: CGRect(x: 0, y: offset, width: 250, height: viewport),
                             contentHeight: content)
    }

    func testOnlyEdgesWithMoreContentShowLines() {
        XCTAssertFalse(cutoffs(offset: 0).top)
        XCTAssertTrue(cutoffs(offset: 0).bottom)
        XCTAssertTrue(cutoffs(offset: 200).top)
        XCTAssertTrue(cutoffs(offset: 200).bottom)
        XCTAssertTrue(cutoffs(offset: 500).top)
        XCTAssertFalse(cutoffs(offset: 500).bottom)
    }

    func testFittingAndEmptyListsHaveNoLines() {
        for height: CGFloat in [0, 150, 300] {
            XCTAssertEqual(cutoffs(offset: 0, content: height), SidebarScrollCutoffs())
        }
    }

    func testElasticScrollingDoesNotInventContentBeyondTheEnds() {
        XCTAssertFalse(cutoffs(offset: -30).top)
        XCTAssertFalse(cutoffs(offset: 530).bottom)
    }

    func testRemovingRowsOrGrowingViewportClearsBottomLine() {
        XCTAssertTrue(cutoffs(offset: 0).bottom)
        XCTAssertFalse(cutoffs(offset: 0, content: 250).bottom)
        XCTAssertFalse(cutoffs(offset: 0, viewport: 900).bottom)
    }
}
