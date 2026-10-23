import XCTest
@testable import vane

final class SearchMatchTests: XCTestCase {
    /// Keep the previous matcher as an oracle: an optimization must preserve scores,
    /// including fuzzy alignment, Unicode boundaries, and normalized URL handling.
    func testScoresMatchOriginalAcrossLiteralFuzzyAndUnicodeInputs() {
        let queries = ["\r", "\n", "\r\n", "", "a", "ab", "abc", "aβ", "cafe", "é", "İ", "Σ", "ﬀ", "e\u{301}", "例", "👩‍💻", "100%", "a_b", "a\\b",
                       "example.com", "www.example.com", "https://", "a" + String(repeating: "b", count: 63),
                       "a" + String(repeating: "b", count: 64)]
        let targets = ["a\r\nb", "\r\n", "\r\nabc", "", "abc", "ABC", "xabc", "a b c", "a---ab---bc", "myabc abc", "Café",
                       "a-β", "İstanbul", "Σίσυφος", "ﬀoo", "Cafe\u{301}", "例のページ", "👩‍💻 notes", "100%", "a_b", "a\\b",
                       "https://www.example.com/", "http://example.com/abc", "example.com",
                       String(repeating: "x", count: 510) + "ab", String(repeating: "x", count: 511) + "ab",
                       "a" + String(repeating: "x", count: 510) + "b",
                       "a" + String(repeating: "x", count: 511) + "b", String(repeating: "a", count: 600)]
        for query in queries {
            let match = SearchMatch(query), original = OriginalSearchMatch(query)
            for target in targets {
                for fuzzy in [false, true] {
                    XCTAssertEqual(match.score(target, fuzzy: fuzzy), original.score(target, fuzzy: fuzzy),
                                   "query=\(query), target=\(target), fuzzy=\(fuzzy)")
                    XCTAssertEqual(match.page(title: target, url: "https://www.example.com/abc", fuzzy: fuzzy),
                                   original.page(title: target, url: "https://www.example.com/abc", fuzzy: fuzzy))
                    XCTAssertEqual(match.page(title: "Reference", url: target, fuzzy: fuzzy),
                                   original.page(title: "Reference", url: target, fuzzy: fuzzy))
                }
            }
        }
    }

    func testNormalizedURLPreservesRepeatedCombiningMarkFolding() {
        // Foundation can remove only one repeated combining mark per fold.
        // URL normalization historically folds once, then scoring folds again.
        XCTAssertEqual(SearchMatch("例").page(title: "Reference", url: "https://www.例\u{301}\u{301}/"),
                       5_000_000)
    }

    func testFuzzyScoresMatchOriginalForAllShortASCIIAlignments() {
        var targets = [""]
        var frontier = [""]
        for _ in 0..<6 {
            frontier = frontier.flatMap { prefix in ["a", "b", "-"].map { prefix + $0 } }
            targets += frontier
        }
        for query in ["a", "ab", "aba", "aab", "bba"] {
            let match = SearchMatch(query), original = OriginalSearchMatch(query)
            for target in targets {
                XCTAssertEqual(match.score(target), original.score(target), "\(query) in \(target)")
            }
        }
    }

    func testArchiveMatchingPerformance() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_SEARCH_PERFORMANCE"] == "1",
                          "Opt-in paired release matcher measurements")
        #if DEBUG
        try XCTSkipIf(true, "Use a release build")
        #endif
        let titles = (0..<2000).map { "Synthetic archive entry \($0)" }
        let urls = (0..<2000).map { "https://fixture.invalid/\($0)" }
        for query in ["s", "sy", "syn", "synthetic", "ae", "snt", "entry"] {
            let original = OriginalSearchMatch(query), match = SearchMatch(query)
            func time(_ score: (String, String) -> Int?) -> (Double, Int) {
                let start = ProcessInfo.processInfo.systemUptime
                var checksum = 0
                for _ in 0..<20 {
                    for i in titles.indices { checksum += score(titles[i], urls[i]) ?? 0 }
                }
                return ((ProcessInfo.processInfo.systemUptime - start) * 1000 / 20, checksum)
            }
            let before = time { original.page(title: $0, url: $1) }
            let after = time { match.page(title: $0, url: $1) }
            XCTAssertEqual(before.1, after.1)
            print("SEARCH_PERF \(query): before=\(before.0)ms after=\(after.0)ms per 2000 rows")
        }
    }

}

// Frozen from b34b875, before the optimization. Deliberately independent of production helpers.
private struct OriginalSearchMatch: Sendable {
    let query: String
    private let characters: [Character]

    init(_ query: String) {
        self.query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        characters = Array(self.query)
    }

    static func fold(_ value: String) -> String {
        // Most stored addresses and titles are ASCII. Avoid Foundation's Unicode
        // folding allocation on this hot path over large histories.
        if value.utf8.allSatisfy({ $0 < 128 }) { return value.lowercased() }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    func score(_ target: String, fuzzy: Bool = true) -> Int? {
        guard !query.isEmpty else { return 0 }
        let target = Self.fold(target)
        let length = min(target.count, 999)
        if target == query { return 5_000_000 }
        if target.hasPrefix(query) { return 4_000_000 - length }
        if let first = target.range(of: query) {
            // Choose the best literal occurrence, not just the first one. A later
            // word start in "mydocs — docs" is stronger than the earlier mid-word hit.
            var occurrence: Range<String.Index>? = first
            while let range = occurrence {
                if range.lowerBound == target.startIndex {
                    return 3_000_000 - length
                }
                let before = target[target.index(before: range.lowerBound)]
                if !before.isLetter && !before.isNumber { return 3_000_000 - length }
                let next = target.index(after: range.lowerBound)
                occurrence = target.range(of: query, range: next..<target.endIndex)
            }
            return 2_000_000 - length
        }
        // Bound fuzzy work on pathological input; literal matching above is unlimited.
        guard fuzzy, characters.count <= 64 else { return nil }
        let t = Array(target.prefix(512))
        var next = 0
        for c in t where next < characters.count {
            if c == characters[next] { next += 1 }
        }
        guard next == characters.count else { return nil }
        // Best subsequence alignment, O(query × target) time and O(target) memory.
        // A later contiguous run must beat a greedy walk through earlier distractions.
        let missing = Int.min / 2
        var previous = [Int](repeating: missing, count: t.count)
        for (qi, c) in characters.enumerated() {
            var current = [Int](repeating: missing, count: t.count)
            var best = missing
            for i in t.indices {
                if i > 0 { best = max(best, previous[i - 1]) }
                guard t[i] == c else { continue }
                let boundary = i == 0 ? 12 : (!t[i - 1].isLetter && !t[i - 1].isNumber ? 6 : 0)
                if qi == 0 {
                    current[i] = 1 + boundary
                } else if best != missing {
                    let contiguous = i > 0 && previous[i - 1] != missing
                        ? previous[i - 1] + 8 : missing
                    current[i] = max(best, contiguous) + 1 + boundary
                }
            }
            previous = current
        }
        return 1_000_000 + min(previous.max() ?? 0, 9_999) * 100 - length
    }

    func page(title: String, url: String, fuzzy: Bool = true) -> Int? {
        let titleScore = score(title, fuzzy: fuzzy)
        var address = Self.fold(url)
        // Omitted scheme/www are address-bar conveniences, not changes to stored URLs.
        if !query.contains("://") {
            for prefix in ["https://", "http://"] where address.hasPrefix(prefix) {
                address.removeFirst(prefix.count)
                break
            }
            if address.hasPrefix("www."), !query.hasPrefix("www.") { address.removeFirst(4) }
        }
        if address.hasSuffix("/") && !query.hasSuffix("/") { address.removeLast() }
        let urlScore = score(address, fuzzy: fuzzy)
        let literalURLScore = address == Self.fold(url) ? nil : score(url, fuzzy: fuzzy)
        return [titleScore, urlScore, literalURLScore].compactMap { $0 }.max()
    }

}
