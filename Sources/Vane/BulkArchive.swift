import SwiftUI

extension TabStore {
    /// Complete a bulk Today action on the input turn. Animation must not postpone
    /// model changes or select (and resume) a neighbour that is also being archived.
    @discardableResult func archiveToday(_ ids: [Tab.ID]) -> Int {
        SharedTabs.flush()
        let eligible = Dictionary(accessibleTabs.filter { $0.kind == .today }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var seen = Set<Tab.ID>()
        // Folder archive can temporarily reverse the strip while unpinning its
        // members. Archive and Reopen Closed Tab must retain the caller's order.
        let doomed = ids.compactMap { id -> Tab? in
            guard seen.insert(id).inserted else { return nil }
            return eligible[id]
        }
        return finishArchivingToday(doomed.map { (tab: $0, stashed: nil) })
    }

    /// Capture one sweep's eligibility and Space ownership before removing anything.
    /// A peer's selection must never wake the next page the sweep intends to retire.
    func archiveIdleToday(now: Date, after: TimeInterval) {
        SharedTabs.flush()
        let unlocked = unlockedFolders
        let shapes = [pins, todayShape] + stashes.values.flatMap { [$0.pins, $0.todayShape] }
        var owned = Set<String>(), blocked = Set<String>()
        for shape in shapes {
            let locked = Pins.TraversalIndex(shape.entries).lockedRows(in: shape.entries, unlocked: unlocked)
            // Match lockedFolders(for:): the first owning shape decides protection.
            let rows = Set(shape.entries.map(\.id))
            blocked.formUnion(locked.subtracting(owned))
            owned.formUnion(rows)
        }
        var stashedSpaces: [Tab.ID: UUID] = [:]
        for (space, stash) in stashes {
            for tab in stash.tabs where stashedSpaces[tab.id] == nil { stashedSpaces[tab.id] = space }
        }
        var seen = Set<Tab.ID>()
        let doomed = everyTab.compactMap { tab -> (tab: Tab, stashed: UUID?)? in
            guard seen.insert(tab.id).inserted, !blocked.contains(tab.id.uuidString),
                  Archive.due(kind: tab.kind,
                    idle: Archive.idle(now: now, lastActive: tab.lastActive, lastQuiet: tab.lastQuiet),
                    after: after, active: tab.id == current, loaded: tab.currentURL != nil,
                    playing: tab.inMeetCall || TabAudio.isPlaying(tab)) else { return nil }
            return (tab, stashedSpaces[tab.id])
        }
        _ = finishArchivingToday(doomed)
    }

    private func finishArchivingToday(_ doomed: [(tab: Tab, stashed: UUID?)]) -> Int {
        guard !doomed.isEmpty else { return 0 }
        let removing = Set(doomed.map { $0.tab.id })
        if !isPrivate {
            let entries = doomed.compactMap { item -> Archive.Entry? in
                let tab = item.tab
                guard let url = tab.currentURL, TabAddress.restorable(url) else { return nil }
                let title = TidyTitles.title(for: tab)
                return Archive.Entry(url: url.absoluteString,
                    title: title.isEmpty ? url.absoluteString : title, at: .now,
                    space: item.stashed ?? currentSpaceID, littleArc: isLittle ? true : nil)
            }
            Archive.shared(for: profileID).add(entries)
            // Stashed auto-archives historically leave no Reopen Closed Tab entry.
            for item in doomed where item.stashed == nil { ClosedTabs.push(item.tab) }
        }
        Motion.animate(Look.tabClose) {
            sidebarObservation.withCompletedChanges {
                // Every live window and stash must release its references before
                // retiring the pages. Each window chooses its final selection once.
                SharedTabs.removeToday(removing, from: self)
                removeArchivedTodayTabs(removing)
                var changedStash = false
                for space in Array(stashes.keys) {
                    if stashes[space]?.remove(removing) == true { changedStash = true }
                }
                if changedStash { sidebarPreviewInvalidated.send() }
                for item in doomed {
                    item.tab.tearDown()
                    if item.stashed == nil {
                        MediaState.shared.forget(item.tab.id)
                        LiveFolders.existing(for: profileID)?.forget(authTab: item.tab.id)
                    }
                }
            }
        }
        return doomed.count
    }

    /// Reference removal shared by the initiating window and its peers. Archiving
    /// and page retirement belong only to the initiating window.
    func removeArchivedTodayTabs(_ ids: Set<Tab.ID>) {
        let previous = tabs
        let remaining = previous.filter { !ids.contains($0.id) }
        guard remaining.count != previous.count else { return }
        let selected = current
        var next: Tab.ID?
        var remainingSplits: [Split] = []
        for split in splits {
            let survivors = split.tabs.filter { !ids.contains($0) }
            var reduced: Split? = split
            for id in split.tabs where ids.contains(id) { reduced = reduced?.removing(id) }
            if let reduced { remainingSplits.append(reduced) }
            else if let survivor = survivors.first {
                remaining.first { $0.id == survivor }?.lastActive = .now
            }
            if let selected, split.contains(selected), ids.contains(selected) {
                next = reduced?.activeTab ?? survivors.first
            }
        }
        if let selected, ids.contains(selected), next == nil,
           let index = previous.firstIndex(where: { $0.id == selected }) {
            let neighbour = previous.dropFirst(index + 1).first { !ids.contains($0.id) } ?? remaining.last
            next = neighbour?.kind == .today ? neighbour?.id : nil
        }
        var shape = todayShape
        let rowIDs = Set(ids.map(\.uuidString))
        shape.entries.removeAll { rowIDs.contains($0.id) }
        shape.removeEmptyFolders()
        var keptSelection = selection
        keptSelection.keep(remaining.map(\.id))
        tabs = remaining
        if shape != todayShape { todayShape = shape }
        if remainingSplits != splits { splits = remainingSplits }
        if keptSelection != selection { selection = keptSelection }
        if let renamingTab, ids.contains(renamingTab) { self.renamingTab = nil }
        if let selected, ids.contains(selected) { current = next }
        extensions.sync()
    }
}

extension Stash {
    /// Retire a set together, filtering the strip and shapes once. Stashed selection
    /// remains empty when its page leaves; no background neighbour is resumed.
    @MainActor @discardableResult mutating func remove(_ ids: Set<Tab.ID>) -> Bool {
        let remaining = tabs.filter { !ids.contains($0.id) }
        guard remaining.count != tabs.count else { return false }
        let rows = Set(ids.map(\.uuidString))
        tabs = remaining
        pins.entries.removeAll { rows.contains($0.id) }
        todayShape.entries.removeAll { rows.contains($0.id) }
        todayShape.removeEmptyFolders()
        splits = splits.compactMap { split in
            var reduced: Split? = split
            for id in split.tabs where ids.contains(id) { reduced = reduced?.removing(id) }
            return reduced
        }
        if let current, ids.contains(current) { self.current = nil }
        return true
    }
}
