import Foundation

/// Pure presentation rules: counts belong to this profile, independent of search.
enum ExtensionManagerModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", enabled = "Enabled", disabled = "Disabled", attention = "Needs Attention"
        var id: String { rawValue }
    }

    struct Item {
        let id: String
        let name: String
        let version: String
        let summary: String
        let enabled: Bool
        let needsAttention: Bool
    }

    static func visible(_ items: [Item], query: String, filter: Filter) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            let matchesFilter = switch filter {
            case .all: true
            case .enabled: item.enabled
            case .disabled: !item.enabled
            case .attention: item.needsAttention
            }
            return matchesFilter && (query.isEmpty || [item.name, item.version, item.summary].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            })
        }
    }

    static func counts(_ items: [Item]) -> [Filter: Int] {
        Dictionary(uniqueKeysWithValues: Filter.allCases.map { ($0, visible(items, query: "", filter: $0).count) })
    }

    static func selection(_ current: String?, in visible: [Item]) -> String? {
        current.flatMap { id in visible.contains { $0.id == id } ? id : nil }
    }
}
