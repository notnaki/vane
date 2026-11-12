import Foundation

/// One window's current protection topology. Shapes are copy-on-write values, so
/// unchanged outlines compare without rebuilding ancestry or allocating row IDs.
/// Grants are part of the key: relocking must take effect on the very next read.
@MainActor final class FolderAccessIndex {
    struct Snapshot {
        let blockedIDs: Set<UUID>
        let canRejectUnblockedRows: Bool
    }

    private struct Key: Equatable {
        let shapes: [Pins]
        let unlocked: Set<UUID>
    }

    private var key: Key?
    private var snapshot = Snapshot(blockedIDs: [], canRejectUnblockedRows: true)

    func resolve(in shapes: [Pins], unlocked: Set<UUID>) -> Snapshot {
        let next = Key(shapes: shapes, unlocked: unlocked)
        if key == next { return snapshot }

        var owned = Set<String>(), blockedRows = Set<String>()
        var canReject = true
        // No ancestry work is needed when every folder is ordinary or unlocked.
        if shapes.contains(where: { shape in
            shape.entries.contains { entry in
                entry.folder.map { $0.requiresAuthentication == true && !unlocked.contains($0.id) } == true
            }
        }) {
            for shape in shapes {
                let firstRows = Dictionary(shape.entries.map { ($0.id, $0.folder != nil) },
                                           uniquingKeysWith: { first, _ in first })
                // Legacy ancestor lookup follows any first matching row, even a tab.
                // The bulk traversal deliberately follows folders only. Such malformed
                // parents must retain the full legacy Boolean authentication check.
                if shape.entries.contains(where: { entry in
                    entry.parent.map { firstRows[$0.uuidString] == false } == true
                }) { canReject = false }
                let locked = Pins.TraversalIndex(shape.entries).lockedRows(in: shape.entries, unlocked: unlocked)
                // Match lockedFolders(for:): the first owning shape wins, including
                // an unprotected row shadowing a protected copy in a stashed Space.
                blockedRows.formUnion(locked.subtracting(owned))
                owned.formUnion(shape.entries.map(\.id))
            }
        }
        let blocked = Set(blockedRows.compactMap { row -> UUID? in
            guard let id = UUID(uuidString: row), id.uuidString == row else { return nil }
            return id
        })
        snapshot = Snapshot(blockedIDs: blocked, canRejectUnblockedRows: canReject)
        key = next
        return snapshot
    }
}
