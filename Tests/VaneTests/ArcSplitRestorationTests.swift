import XCTest
import WebKit
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

    func testImportedCachedTitlesFollowLivePagesWhileActualRenamesStayFixed() async throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Arc titles restore \(UUID())")
        let duplicate = URL(string: "https://arc-split.invalid/mail")!
        let rows: [ArcRow] = [.split(panes: [
            .init(url: duplicate, title: "Inbox (1)"),
            .init(url: duplicate, title: "Inbox (1)", customName: "My Inbox")
        ], vertical: false, weights: [0.4, 0.6], active: 1)]
        let layout = ArcImport.layout(pinned: rows,
            today: [.tab(url: URL(string: "https://arc-split.invalid/today")!, title: "Today (1)")])
        var space = Space(name: "Imported titles", profileID: profile.id,
                          tabURLs: layout.tabs.filter { $0.kind == .today }.map(\.savedURL),
                          pinnedTabURLs: layout.tabs.filter { $0.kind == .pinned }.map(\.savedURL))
        space.layout = layout
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space, parked: ArcImport.parkedTitles(in: layout))
        defer {
            let owned = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        XCTAssertEqual(store.tabs.map(\.title), ["Inbox (1)", "Inbox (1)", "Today (1)"])
        XCTAssertEqual(store.tabs.map(\.workspaceName), ["", "My Inbox", ""])
        XCTAssertEqual(Set(store.tabs.map(\.id)).count, 3)
        XCTAssertEqual(store.splits.first?.activeTab, layout.tabs[1].id)
        XCTAssertEqual(store.splits.first?.weights, [0.4, 0.6])
        for (index, page) in layout.tabs.enumerated() {
            let tab = try XCTUnwrap(store.tabs.first { $0.id == page.id })
            store.current = tab.id
            let loaded = "Loaded page \(index)"
            let updated = "Updated page \(index)"
            tab.web.loadHTMLString("<title>\(loaded)</title><p>Local fixture</p>", baseURL: nil)
            try await compatibilityWait { tab.title == loaded && !tab.web.isLoading }
            XCTAssertEqual(TidyTitles.title(for: tab), index == 1 ? "My Inbox" : loaded)
            _ = try await tab.web.evaluateJavaScript("document.title = '\(updated)'")
            try await compatibilityWait { tab.title == updated }
            XCTAssertEqual(TidyTitles.title(for: tab), index == 1 ? "My Inbox" : updated)
        }
    }

}
