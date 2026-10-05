import Foundation

/// Resolve a section once per render. Each row keeps its live tab reference so drawing
/// it does not repeat the UUID-string conversion and strip search used to filter it.
/// This is a local snapshot, rebuilt after changes to the strip, folders or splits.
@MainActor struct SidebarRows {
    struct Row: Identifiable {
        let visible: Pins.Visible
        let tab: Tab?
        var id: String { visible.id }
    }

    let rows: [Row]

    init(tabs: [Tab], splits: [Split], shape: Pins) {
        let tabsByID = Dictionary(tabs.map { ($0.id.uuidString, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let strip = tabs.map { ($0.id, $0.kind) }
        var leadsByPane: [UUID: UUID] = [:]
        for split in splits {
            guard let lead = Split.lead(of: split.tabs, strip: strip) else { continue }
            // Match the store's first containing split, even for overlapping restore data.
            for pane in split.tabs where leadsByPane[pane] == nil { leadsByPane[pane] = lead }
        }
        rows = shape.visible.compactMap { visible in
            if visible.entry.folder != nil { return Row(visible: visible, tab: nil) }
            guard let id = visible.entry.tab, let tab = tabsByID[id],
                  leadsByPane[tab.id].map({ $0 == tab.id }) ?? true else { return nil }
            return Row(visible: visible, tab: tab)
        }
    }
}
