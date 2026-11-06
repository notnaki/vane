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
        guard !doomed.isEmpty else { return 0 }
        let removing = Set(doomed.map(\.id))
        if !isPrivate {
            let entries = doomed.compactMap { tab -> Archive.Entry? in
                guard let url = tab.currentURL, TabAddress.restorable(url) else { return nil }
                let title = TidyTitles.title(for: tab)
                return Archive.Entry(url: url.absoluteString,
                    title: title.isEmpty ? url.absoluteString : title, at: .now,
                    space: currentSpaceID, littleArc: isLittle ? true : nil)
            }
            Archive.shared(for: profileID).add(entries)
            for tab in doomed { ClosedTabs.push(tab) }
        }
        Motion.animate(Look.tabClose) {
            sidebarObservation.withCompletedChanges {
                // Every live window and stash must release its references before
                // retiring the pages. Each window chooses its final selection once.
                SharedTabs.removeToday(removing, from: self)
                removeArchivedTodayTabs(removing)
                for tab in doomed {
                    tab.tearDown()
                    LiveFolders.existing(for: profileID)?.forget(authTab: tab.id)
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
