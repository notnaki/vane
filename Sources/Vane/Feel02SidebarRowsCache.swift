import Foundation

/// A mounted section's topology survives selection, hover and page-metadata updates.
/// Values here describe membership only; row surfaces still observe their live Tabs.
/// Keep the existing accessibility/filtering rules on cache misses, including corrupt
/// overlapping shapes and stashed folders, rather than duplicating the lock logic.
@MainActor final class Feel02SidebarRowsCache {
    final class Snapshot {
        let rows: [SidebarRows.Row]
        let todayCount: Int
        /// Small outlines retain their unlocked, collapsed children so scrolling and
        /// disclosure reuse native controls. Large outlines keep viewport-only mounting.
        let retainedRows: [SidebarRows.Row]?
        /// Captured from the complete outline, before collapse or authentication filtering.
        let eagerlyMountsVisibleRows: Bool

        init(rows: [SidebarRows.Row], todayCount: Int, retainedRows: [SidebarRows.Row]?,
             eagerlyMountsVisibleRows: Bool = false) {
            self.rows = rows
            self.todayCount = todayCount
            self.retainedRows = retainedRows
            self.eagerlyMountsVisibleRows = eagerlyMountsVisibleRows
        }
    }

    private struct Key: Equatable {
        let owner: ObjectIdentifier
        let tabs: [ObjectIdentifier]
        let kinds: [TabKind]
        let panes: [[UUID]]
        let shape: Pins
        let pins: Pins
        let today: Pins
        let stashedShapes: [UUID: [Pins]]
        let unlocked: Set<UUID>
    }

    private var key: Key?
    private var snapshot: Snapshot?

    /// Bounded workaround for nested lazy-stack focus/layout fanout. Count every
    /// tab and folder, including protected/collapsed children and profile favourites.
    /// Larger outlines retain the existing lazy path; this does not solve arbitrary scale.
    nonisolated static func usesBoundedEagerRows(tabCount: Int, folderCount: Int) -> Bool {
        let structuralCount = tabCount + folderCount
        return structuralCount > 40 && structuralCount <= 128
    }

    static func retainsRows(in store: TabStore) -> Bool {
        let folders = store.pins.entries.filter { $0.folder != nil }.count
            + store.todayShape.entries.filter { $0.folder != nil }.count
        return store.tabs.count + folders <= 40
    }

    func resolve(in store: TabStore, shape: Pins) -> Snapshot {
        let unlocked = store.unlockedFolders
        let next = Key(owner: ObjectIdentifier(store), tabs: store.tabs.map(ObjectIdentifier.init),
            kinds: store.tabs.map(\.kind), panes: store.splits.map(\.tabs), shape: shape,
            pins: store.pins, today: store.todayShape,
            stashedShapes: store.stashes.mapValues { [$0.pins, $0.todayShape] }, unlocked: unlocked)
        if key == next, let snapshot { return snapshot }
        let accessible = store.accessibleTabs
        let rows = SidebarRows(tabs: accessible, splits: store.splits,
            shape: shape, unlocked: unlocked).rows
        var retainedRows: [SidebarRows.Row]?
        if Self.retainsRows(in: store), shape.entries.count <= 40 {
            var expanded = shape
            for index in expanded.entries.indices {
                if var folder = expanded.entries[index].folder {
                    folder.collapsed = false
                    expanded.entries[index].row = .folder(folder)
                }
            }
            let originals = Dictionary(shape.entries.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            // Expanding changes disclosure only. Authentication and split-lead filtering
            // still run before constructing retained surfaces, including nested locks.
            retainedRows = SidebarRows(tabs: accessible, splits: store.splits,
                shape: expanded, unlocked: unlocked).rows.map { row in
                    SidebarRows.Row(visible: Pins.Visible(entry: originals[row.id] ?? row.visible.entry,
                        depth: row.visible.depth), tab: row.tab)
                }
        }
        let folders = store.pins.entries.filter { $0.folder != nil }.count
            + store.todayShape.entries.filter { $0.folder != nil }.count
        let result = Snapshot(rows: rows, todayCount: accessible.filter { $0.kind == .today }.count,
            retainedRows: retainedRows,
            eagerlyMountsVisibleRows: Self.usesBoundedEagerRows(tabCount: store.tabs.count, folderCount: folders))
        key = next
        snapshot = result
        return result
    }
}
