import XCTest
@testable import vane

final class SidebarResizeTests: XCTestCase {
    func testDragCatchesDefaultWidthFromEitherDirection() {
        for approach: [CGFloat] in [[210, 223, 230, 239, 241], [250, 233, 226, 217, 215]] {
            var detent = SidebarResizeDetent()
            let widths = approach.map { detent.width(for: $0) }
            XCTAssertEqual(widths, [approach[0], 228, 228, 228, approach[4]])
        }
    }

    func testDetentReleasesAndCanBeEnteredAgainWithoutPointerDrift() {
        var detent = SidebarResizeDetent()
        XCTAssertEqual(detent.width(for: 225), 228)
        XCTAssertEqual(detent.width(for: 241), 241)
        XCTAssertEqual(detent.width(for: 300), 300)
        XCTAssertEqual(detent.width(for: 232), 228)
        XCTAssertEqual(detent.width(for: 214), 214)
    }

    func testNewDragDoesNotInheritPreviousCatch() {
        var previous = SidebarResizeDetent()
        XCTAssertEqual(previous.width(for: 228), 228)
        var next = SidebarResizeDetent()
        XCTAssertEqual(next.width(for: 238), 238)
    }

    func testDragStillClampsAndPreservesRawCollapseDecision() {
        var detent = SidebarResizeDetent()
        XCTAssertEqual(detent.width(for: 80), 164)
        XCTAssertTrue(SidebarWidth.shouldCollapse(80))
        XCTAssertEqual(detent.width(for: 600), 500)
        XCTAssertEqual(detent.width(for: .nan), 228)
    }
}
