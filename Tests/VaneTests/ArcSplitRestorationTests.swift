import XCTest
@testable import vane

@MainActor final class ArcSplitRestorationTests: XCTestCase {
    func testImportedFirstSplitRestoresItsFocusedPaneAndOneSidebarRow() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Arc split restore \(UUID())")
        let rows: [ArcRow] = [.split(panes: [
            .init(url: URL(string: "https://arc-split.invalid/a")!, title: "A"),
            .init(url: URL(string: "https://arc-split.invalid/b")!, title: "B")
        ], vertical: true, weights: [0.3, 0.7], active: 1)]
        let layout = ArcImport.layout(pinned: rows, today: [])
        var space = Space(name: "Imported split", profileID: profile.id,
                          pinnedTabURLs: layout.tabs.map(\.savedURL))
        space.layout = layout
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space)
        defer {
            let owned = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        let focused = layout.tabs[1].id
        XCTAssertEqual(store.current, focused)
        XCTAssertEqual(store.splits.first?.activeTab, focused)
        XCTAssertEqual(store.splits.first?.weights, [0.3, 0.7])
        XCTAssertEqual(store.splits.first?.vertical, true)
        XCTAssertEqual(SidebarRows(tabs: store.accessibleTabs, splits: store.splits, shape: store.pins).rows.count, 1)
    }
}
