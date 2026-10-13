import Foundation

/// One small cache per aggregate archive (regular and private never share one).
/// Filtering/grouping runs on this actor, outside SwiftUI and the input actor.
actor Feel05ArchiveSearch {
    typealias Groups = [(title: String, items: [ArchiveLibrary.Entry])]
    private struct Key: Hashable {
        let revision: Int
        let query: String
        let littleOnly: Bool
        let day: Date
        let calendar: Calendar
    }
    private var cache: [Key: Groups] = [:]
    private var order: [Key] = []
    private var generation: Int?
    private var retainedRows = 0

    func groups(_ entries: [ArchiveLibrary.Entry], revision: Int, query: String,
                littleOnly: Bool, now: Date = .now, calendar: Calendar = .current) -> Groups {
        guard !Task.isCancelled else { return [] }
        if generation != revision {
            cache.removeAll(); order.removeAll(); retainedRows = 0
            generation = revision
        }
        let key = Key(revision: revision, query: query, littleOnly: littleOnly,
                      day: calendar.startOfDay(for: now), calendar: calendar)
        if let hit = cache[key] { return hit }
        var found: [ArchiveLibrary.Entry] = []
        for row in entries {
            guard !Task.isCancelled else { return [] }
            if (!littleOnly || row.entry.isLittleArc)
                && Library.matches([row.entry.title, row.entry.url, row.profile.name], query) {
                found.append(row)
            }
        }
        let groups = Library.grouped(found, by: { $0.entry.at }, now: now, calendar: calendar)
        guard !Task.isCancelled else { return [] }
        // Bound both query count and row references across large multi-profile libraries.
        if found.count <= 12_000 {
            while !order.isEmpty && (order.count >= 3 || retainedRows + found.count > 12_000) {
                let oldest = order.removeFirst()
                retainedRows -= cache.removeValue(forKey: oldest)?.reduce(0) { $0 + $1.items.count } ?? 0
            }
            cache[key] = groups; order.append(key); retainedRows += found.count
        }
        return groups
    }
}
