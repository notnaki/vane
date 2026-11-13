import XCTest
@testable import vane

final class LinkPreviewTypingTests: XCTestCase {
    func testCumulativeTokensKeepTheirVisiblePrefixAndCatchUp() {
        var reveal = LinkPreviewTextReveal()
        reveal.retarget("A small beginning", immediately: false)
        reveal.advance()
        XCTAssertFalse(reveal.visible.isEmpty)
        XCTAssertNotEqual(reveal.visible, reveal.target)
        let prefix = reveal.visible
        reveal.retarget("A small beginning becomes a complete sentence.", immediately: false)
        XCTAssertEqual(reveal.visible, prefix)
        var steps = 0
        while reveal.pending, steps < 200 { reveal.advance(); steps += 1 }
        XCTAssertEqual(reveal.visible, reveal.target)
        XCTAssertLessThan(steps, 100, "Finished streams should catch up promptly")
    }

    func testCorrectionsRetractionsAndReducedMotionReplaceImmediately() {
        var reveal = LinkPreviewTextReveal()
        reveal.retarget("Wrong draft", immediately: false)
        reveal.advance()
        reveal.retarget("Corrected text", immediately: false)
        XCTAssertEqual(reveal.visible, "", "Revised text must not retain an unverified prefix")
        reveal.advance()
        reveal.retarget("", immediately: false)
        XCTAssertEqual(reveal.visible, "", "A withdrawn answer must disappear immediately")
        reveal.retarget("The complete accessible answer", immediately: true)
        XCTAssertEqual(reveal.visible, reveal.target)
        XCTAssertFalse(reveal.pending)
    }

    func testRevealNeverSplitsEmojiOrCombiningCharacters() {
        var reveal = LinkPreviewTextReveal()
        let text = "👨‍👩‍👧‍👦 café 🇹🇷 🧑🏽‍💻"
        reveal.retarget(text, immediately: false)
        while reveal.pending {
            let previous = reveal.visible.count
            reveal.advance()
            XCTAssertEqual(reveal.visible, String(text.prefix(reveal.visible.count)))
            XCTAssertGreaterThan(reveal.visible.count, previous)
        }
        XCTAssertEqual(reveal.visible, text)
    }
}
