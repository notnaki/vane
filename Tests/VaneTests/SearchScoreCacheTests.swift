import XCTest
@testable import vane

final class SearchScoreCacheTests: XCTestCase {
    func testRepeatedPagesReusePositiveAndRejectedScores() {
        let cache = SearchScoreCache()
        var work = 0
        for _ in 0..<100 {
            XCTAssertEqual(cache.score(title: "GitHub Project", url: "https://github.com/project") {
                work += 1
                return 1_003_486
            }, 1_003_486)
            XCTAssertEqual(cache.score(title: "Unrelated", url: "https://other.example") {
                work += 1
                return -1
            }, -1)
        }
        XCTAssertEqual(work, 2, "Both matches and rejections should be scored once per exact page")
    }

    func testTitleURLAndExactUnicodeBytesEachDistinguishScores() {
        let cache = SearchScoreCache()
        let pages = [
            ("Caf\u{e9}", "https://example.com/a"),
            ("Cafe\u{301}", "https://example.com/a"),
            ("Caf\u{e9}", "https://example.com/b"),
            ("Changed", "https://example.com/a"),
            ("Title", "https://example.com/\u{e9}"),
            ("Title", "https://example.com/e\u{301}")
        ]
        var work = 0
        for _ in 0..<2 {
            for (index, page) in pages.enumerated() {
                XCTAssertEqual(cache.score(title: page.0, url: page.1) {
                    work += 1
                    return index
                }, index)
            }
        }
        XCTAssertEqual(work, 6, "Swift's canonical String equality must not merge byte-distinct page fields")
    }

    func testEntryLimitStopsRetainingNewPagesWithoutChangingScores() {
        let cache = SearchScoreCache(maxEntries: 2, maxBytes: 1_024)
        var work = [0, 0, 0]
        for _ in 0..<3 {
            for index in 0..<3 {
                XCTAssertEqual(cache.score(title: "Page \(index)", url: "https://example.com/\(index)") {
                    work[index] += 1
                    return index + 10
                }, index + 10)
            }
        }
        XCTAssertEqual(work, [1, 1, 3], "Overflow must compute normally while retained entries still reuse scores")
    }

    func testByteLimitCountsUTF8AndOversizedFieldsDoNotConsumeBudget() {
        let cache = SearchScoreCache(maxEntries: 100, maxBytes: 5)
        var work = [0, 0, 0, 0]
        let titles = [String(repeating: "x", count: 100), "\u{e9}", "ab", "c"]
        for _ in 0..<2 {
            for (index, title) in titles.enumerated() {
                XCTAssertEqual(cache.score(title: title, url: "x") {
                    work[index] += 1
                    return index
                }, index)
            }
        }
        XCTAssertEqual(work, [2, 1, 2, 1], "The 3-byte and 2-byte keys fit; oversized and overflow keys remain uncached")
    }
}
