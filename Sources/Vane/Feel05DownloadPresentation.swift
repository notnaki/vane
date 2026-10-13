import Combine
import Foundation

/// Membership and ordering change independently of transfer progress. Keep the former
/// out of repeated view evaluation; individual rows still observe live byte/rate changes.
@MainActor final class Feel05DownloadPresentation: ObservableObject {
    struct Row: Equatable {
        let item: Downloads.Item
        let name: String
        let source: String
        let done: Bool
        let completed: Date?
        let image: Bool
        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.item === rhs.item && lhs.name == rhs.name && lhs.source == rhs.source
                && lhs.done == rhs.done && lhs.completed == rhs.completed && lhs.image == rhs.image
        }
    }
    @Published private(set) var rows: [Row] = []
    private let source: DownloadLibrary
    private var subscription: AnyCancellable?
    private var refreshPending = false
    private static var retained: [(ObjectIdentifier, Feel05DownloadPresentation)] = []

    static func shared(for source: DownloadLibrary) -> Feel05DownloadPresentation {
        let key = ObjectIdentifier(source)
        if let hit = retained.first(where: { $0.0 == key }) { return hit.1 }
        let made = Feel05DownloadPresentation(source)
        retained.append((key, made))
        if retained.count > 2 { retained.removeFirst() }
        return made
    }

    init(_ source: DownloadLibrary) {
        self.source = source
        refresh()
        // Aggregate notifications precede row mutations. Coalesce each main-turn burst
        // (bytes, rate and fraction) before reading structural fields.
        subscription = source.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshPending else { return }
            self.refreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    func refresh() {
        let next = source.items.map { item in
            Row(item: item, name: item.name, source: item.source?.absoluteString ?? "",
                done: item.status == .done, completed: item.completed,
                image: Library.isImage(name: item.name))
        }
        if next != rows { rows = next }
    }

    func groups(query: String, completedOnly: Bool) -> [(title: String, items: [Downloads.Item])] {
        let now = Date()
        return Library.grouped(rows.filter {
            Library.keeps(done: $0.done, completedOnly: completedOnly)
                && Library.matches([$0.name, $0.source], query)
        }, by: { $0.completed ?? now }, now: now).map { ($0.title, $0.items.map(\.item)) }
    }

    func media(query: String) -> [Downloads.Item] {
        let now = Date()
        return rows.filter { $0.done && $0.image && Library.matches([$0.name, $0.source], query) }
            .sorted { ($0.completed ?? now) > ($1.completed ?? now) }.map(\.item)
    }
}
