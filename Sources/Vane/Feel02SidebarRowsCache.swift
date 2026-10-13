import Foundation

/// A mounted section's topology survives selection, hover and page-metadata updates.
/// Values here describe membership only; row surfaces still observe their live Tabs.
/// Keep the existing accessibility/filtering rules on cache misses, including corrupt
/// overlapping shapes and stashed folders, rather than duplicating the lock logic.
@MainActor final class Feel02SidebarRowsCache {
    final class Snapshot {
        let rows: [SidebarRows.Row]
        let todayCount: Int

        init(rows: [SidebarRows.Row], todayCount: Int) {
            self.rows = rows
            self.todayCount = todayCount
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

    func resolve(in store: TabStore, shape: Pins) -> Snapshot {
        let unlocked = store.unlockedFolders
        let next = Key(owner: ObjectIdentifier(store), tabs: store.tabs.map(ObjectIdentifier.init),
            kinds: store.tabs.map(\.kind), panes: store.splits.map(\.tabs), shape: shape,
            pins: store.pins, today: store.todayShape,
            stashedShapes: store.stashes.mapValues { [$0.pins, $0.todayShape] }, unlocked: unlocked)
        if key == next, let snapshot { return snapshot }
        let accessible = store.accessibleTabs
        let result = Snapshot(rows: SidebarRows(tabs: accessible, splits: store.splits,
            shape: shape, unlocked: unlocked).rows,
            todayCount: accessible.filter { $0.kind == .today }.count)
        key = next
        snapshot = result
        return result
    }
}
