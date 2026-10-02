import Combine
import Foundation

/// Real store notifications matter here: correct final IDs alone would miss a reorder
/// that redraws the entire sidebar once for every tab in the section.
@MainActor enum TabOrderingChecks {
    static func check() -> [(String, Bool)] {
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<12).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let original = store.tabs.map(\.id)
        var updates = 0
        let subscription = store.$tabs.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }

        store.applyOrder(.today)
        var out = [("an unchanged section publishes no tab-list updates", updates == 0)]
        print("  ordering baseline: unchanged section published \(updates) updates")
        updates = 0
        store.todayShape.move(original[11].uuidString, next: original[0].uuidString, after: false)
        store.applyOrder(.today)
        out += [
            ("a section reorder publishes the completed tab list once", updates == 1),
            ("the tab list follows the visible shape order",
             store.tabs.map(\.id) == [original[11]] + original.dropLast()),
        ]
        print("  ordering baseline: reordered section published \(updates) updates")
        updates = 0
        store.drop(original[11], onto: original[10], after: true)
        out += [
            ("a drop publishes at most two complete tab lists", updates <= 2),
            ("a drop preserves every tab and its requested order", store.tabs.map(\.id) == original),
        ]
        print("  ordering baseline: drop published \(updates) updates")
        return out
    }
}
