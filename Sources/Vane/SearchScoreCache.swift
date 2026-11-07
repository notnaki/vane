/// Query-owned memoization of page scores. Visit rows still flow through SQLite's
/// ranking and popularity aggregates independently; only matching work is reused.
final class SearchScoreCache {
    private struct Key: Hashable {
        let title: String
        let url: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title.utf8.elementsEqual(rhs.title.utf8)
                && lhs.url.utf8.elementsEqual(rhs.url.utf8)
        }

        func hash(into hasher: inout Hasher) {
            Self.hashBytes(title, into: &hasher)
            Self.hashBytes(url, into: &hasher)
        }

        private static func hashBytes(_ value: String, into hasher: inout Hasher) {
            // String equality/hashing uses canonical Unicode equivalence. Matchers
            // must receive each distinct stored spelling, including combining marks.
            hasher.combine(value.utf8.count)
            if let _ = value.utf8.withContiguousStorageIfAvailable({ bytes in
                hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
            }) { return }
            Array(value.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private var retainedBytes = 0
    private var scores: [Key: Int] = [:]

    init(maxEntries: Int = 4_096, maxBytes: Int = 1_048_576) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    func score(title: String, url: String, compute: () -> Int) -> Int {
        let titleBytes = title.utf8.count
        let urlBytes = url.utf8.count
        guard maxEntries > 0, titleBytes <= maxBytes, urlBytes <= maxBytes - titleBytes else {
            return compute()
        }
        let key = Key(title: title, url: url)
        if let score = scores[key] { return score }
        let score = compute()
        let bytes = titleBytes + urlBytes
        // Oversized fields and overflow entries still get their normal score. The
        // count cap bounds dictionary overhead; the byte cap bounds retained fields.
        if scores.count < maxEntries, bytes <= maxBytes - retainedBytes {
            scores[key] = score
            retainedBytes += bytes
        }
        return score
    }
}
