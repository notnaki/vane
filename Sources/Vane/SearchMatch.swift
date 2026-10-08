import Foundation

/// Shared relevance tiers. Usage and recency only break ties inside a tier, so an
/// exact page never disappears below a popular page containing the same words.
struct SearchMatch: Sendable {
    static let prefixFloor = 4_000_000 - 999
    static let wordFloor = 3_000_000 - 999
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
