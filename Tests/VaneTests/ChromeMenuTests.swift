import XCTest
@testable import vane

final class ChromeMenuTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 264, height: 165)

    func testMenuStaysInsideTheWindowWhenTheSidebarIsNarrowerThanTheMenu() {
        let window = CGRect(x: 200, y: 180, width: 800, height: 600)
        let anchor = CGRect(x: 390, y: 200, width: 28, height: 28)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: window,
                                           screen: screen, above: true)
        XCTAssertTrue(window.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.minX, window.minX + 8)
    }

    func testTallAndWideMenuShrinksToTheWindowAndItsVisibleScreenIntersection() {
        let window = CGRect(x: -100, y: 50, width: 320, height: 300)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: 170, y: 70, width: 28, height: 28),
            size: CGSize(width: 264, height: 2400), window: window, screen: screen, above: true)
        XCTAssertTrue(window.contains(frame))
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.width, 204)
        XCTAssertEqual(frame.height, 284)
    }

    func testHeaderPickerStaysInsideAWindowOnASecondaryScreen() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let window = CGRect(x: -1250, y: 200, width: 800, height: 600)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: -1220, y: 750, width: 180, height: 28),
            size: size, window: window, screen: screen, above: false)
        XCTAssertTrue(window.insetBy(dx: 8, dy: 8).contains(frame))
    }

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
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: true)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.minX, 8, "A narrow sidebar must not put the menu off screen")
    }

    func testHeaderMenuFlipsWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 500, y: 60, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: false)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.maxX, anchor.maxX)
    }

    func testLargeSpaceListFitsOnASmallScreenWithANegativeOrigin() {
        let screen = CGRect(x: -1024, y: -100, width: 1024, height: 768)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: -10, y: 620, width: 20, height: 20),
            size: CGSize(width: 264, height: 2400), window: screen, screen: screen, above: true)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.height, 752)
    }

    func testMenuFlipsDownAtTheTopScreenEdge() {
        let anchor = CGRect(x: 1400, y: 850, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: true)
        XCTAssertLessThan(frame.maxY, anchor.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8)
    }
}
