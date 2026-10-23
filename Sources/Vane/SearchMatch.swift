import Foundation

/// Shared relevance tiers. Usage and recency only break ties inside a tier, so an
/// exact page never disappears below a popular page containing the same words.
struct SearchMatch: Sendable {
    static let prefixFloor = 4_000_000 - 999
    static let wordFloor = 3_000_000 - 999
    let query: String
    private let characters: [Character]
    private let asciiQuery: [UInt8]?

    init(_ query: String) {
        self.query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        characters = Array(self.query)
        asciiQuery = self.query.utf8.allSatisfy { $0 < 128 } ? Array(self.query.utf8) : nil
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
        return scoreFolded(Self.fold(target), fuzzy: fuzzy)
    }

    private func scoreFolded(_ target: String, fuzzy: Bool) -> Int? {
        guard !query.isEmpty else { return 0 }
        if let asciiQuery, asciiQuery.count <= 64, target.utf8.count <= 512,
           target.utf8.allSatisfy({ $0 < 128 && $0 != 13 }) {
            return scoreASCII(Array(target.utf8), query: asciiQuery, fuzzy: fuzzy)
        }
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
        return fuzzyScore(Array(target.prefix(512)), query: characters, length: length) {
            $0.isLetter || $0.isNumber
        }
    }

    /// The common case needs byte comparisons, not Unicode collation or Character
    /// allocation. Long fields/queries and CRLF graphemes retain the Unicode path,
    /// bounding the byte substring scan and avoiding a full copy of long fields.
    private func scoreASCII(_ target: [UInt8], query: [UInt8], fuzzy: Bool) -> Int? {
        let length = min(target.count, 999)
        if target == query { return 5_000_000 }
        if target.starts(with: query) { return 4_000_000 - length }
        var literal = false
        if target.count >= query.count {
            for i in 0...(target.count - query.count)
            where target[i] == query[0] && target[i...].starts(with: query) {
                if i == 0 || !Self.asciiWord(target[i - 1]) { return 3_000_000 - length }
                literal = true
            }
        }
        if literal { return 2_000_000 - length }
        guard fuzzy else { return nil }
        return fuzzyScore(Array(target.prefix(512)), query: query, length: length, isWord: Self.asciiWord)
    }

    private static func asciiWord(_ c: UInt8) -> Bool {
        (97...122).contains(c) || (48...57).contains(c)
    }

    private func fuzzyScore<Element: Equatable>(_ t: [Element], query: [Element], length: Int,
                                                isWord: (Element) -> Bool) -> Int? {
        var next = 0
        for c in t where next < query.count {
            if c == query[next] { next += 1 }
        }
        guard next == query.count else { return nil }
        // Cache only matched positions: classifying every preceding Unicode
        // character costs more than a sparse query's original boundary checks.
        var boundaries = [Int](repeating: -1, count: t.count)
        // Best subsequence alignment, O(query × target) time and O(target) memory.
        // A later contiguous run must beat a greedy walk through earlier distractions.
        let missing = Int.min / 2
        var previous = [Int](repeating: missing, count: t.count)
        for (qi, c) in query.enumerated() {
            var current = [Int](repeating: missing, count: t.count)
            var best = missing
            for i in t.indices {
                if i > 0 { best = max(best, previous[i - 1]) }
                guard t[i] == c else { continue }
                if boundaries[i] < 0 {
                    boundaries[i] = i == 0 ? 12 : (isWord(t[i - 1]) ? 0 : 6)
                }
                let boundary = boundaries[i]
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
        // Nothing can outrank an exact title.
        if titleScore == 5_000_000 { return titleScore }
        let foldedURL = Self.fold(url)
        var address = foldedURL
        // Omitted scheme/www are address-bar conveniences, not changes to stored URLs.
        if !query.contains("://") {
            for prefix in ["https://", "http://"] where address.hasPrefix(prefix) {
                address.removeFirst(prefix.count)
                break
            }
            if address.hasPrefix("www."), !query.hasPrefix("www.") { address.removeFirst(4) }
        }
        if address.hasSuffix("/") && !query.hasSuffix("/") { address.removeLast() }
        // Preserve the scoring pass's second Unicode fold: Foundation folding is
        // not idempotent for repeated combining marks. ASCII is already final.
        let normalized = address.utf8.allSatisfy { $0 < 128 } ? address : Self.fold(address)
        let urlScore = scoreFolded(normalized, fuzzy: fuzzy)
        let literalURLScore = address == foldedURL ? nil : scoreFolded(foldedURL, fuzzy: fuzzy)
        return [titleScore, urlScore, literalURLScore].compactMap { $0 }.max()
    }

    /// SQLite's LIKE is an inexpensive candidate pass, not the matcher. Non-ASCII
    /// fields also pass it so case/diacritic folding cannot hide a real match.
    var candidatePattern: String {
        let escaped = characters.map { c -> String in
            let s = String(c)
            return ["%", "_", "\\"].contains(s) ? "\\" + s : s
        }
        return "%" + escaped.joined(separator: "%") + "%"
    }
}
