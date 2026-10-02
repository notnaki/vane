import XCTest
@testable import vane

final class ChromeMenuTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 264, height: 165)

    func testFastTypingFindsTheWholePrefixInsteadOfTheLastLetter() {
        var search = ChromeMenuTypeahead()
        let titles = ["Work", "Web", "Entertainment"]
        let first = search.match("w", at: 1, titles: titles, current: nil)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(search.match("e", at: 1.1, titles: titles, current: first), 1)
    }

    func testRepeatedLettersCycleAndAPauseStartsANewPrefix() {
        var search = ChromeMenuTypeahead()
        let titles = ["Work", "Web", "Entertainment"]
        XCTAssertEqual(search.match("w", at: 1, titles: titles, current: nil), 0)
        XCTAssertEqual(search.match("W", at: 1.1, titles: titles, current: 0), 1)
        XCTAssertEqual(search.match("e", at: 2.5, titles: titles, current: 1), 2)
    }

    func testTypeaheadDistinguishesCreationActionsWithTheSameFirstWord() {
        var search = ChromeMenuTypeahead()
        let titles = ["New Space", "New Folder", "New Tab"]
        var selection: Int?
        for (index, char) in "new f".enumerated() {
            selection = search.match(String(char), at: Double(index) / 10, titles: titles, current: selection)
        }
        XCTAssertEqual(selection, 1)
    }

    func testFooterMenuOpensAboveTheTrigger() {
        let anchor = CGRect(x: 190, y: 30, width: 28, height: 28)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, screen: screen, above: true)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.minX, 8, "A narrow sidebar must not put the menu off screen")
    }

    func testHeaderMenuFlipsWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 500, y: 60, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, screen: screen, above: false)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.maxX, anchor.maxX)
    }

    func testLargeSpaceListFitsOnASmallScreenWithANegativeOrigin() {
        let screen = CGRect(x: -1024, y: -100, width: 1024, height: 768)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: -10, y: 620, width: 20, height: 20),
            size: CGSize(width: 264, height: 2400), screen: screen, above: true)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.height, 752)
    }

    func testMenuFlipsDownAtTheTopScreenEdge() {
        let anchor = CGRect(x: 1400, y: 850, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, screen: screen, above: true)
        XCTAssertLessThan(frame.maxY, anchor.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8)
    }
}
