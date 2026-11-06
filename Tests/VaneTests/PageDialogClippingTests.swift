import XCTest
@testable import vane

@MainActor final class PageDialogClippingTests: XCTestCase {
    // CRLF is one Swift Character; each of these separators creates a native text line.
    private let separators = ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"]

    func testClippingBoundsEveryNativeNewlineForm() {
        let expected = String(repeating: "line\n", count: 23) + "line…"
        for separator in separators {
            let message = String(repeating: "line" + separator, count: 1000)
            XCTAssertEqual(PageDialogs.clipped(message), expected, "Separator: \(separator.debugDescription)")
        }
    }

    func testShortMessagesPreserveTheirOriginalNewlines() {
        for separator in separators {
            let message = "First" + separator + "Second"
            XCTAssertEqual(PageDialogs.clipped(message), message, "Separator: \(separator.debugDescription)")
            let atLimit = String(repeating: separator, count: 23)
            XCTAssertEqual(PageDialogs.clipped(atLimit), atLimit)
        }
    }

    func testCharacterLimitStillAppliesWithNativeNewlines() {
        for separator in separators {
            let message = "First" + separator + String(repeating: "x", count: 2000)
            let clipped = PageDialogs.clipped(message)
            XCTAssertEqual(clipped.count, 1025)
            XCTAssertTrue(clipped.hasSuffix("…"))
        }
    }
}
