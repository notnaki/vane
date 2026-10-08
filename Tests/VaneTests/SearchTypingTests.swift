import XCTest
@testable import vane

@MainActor final class SearchTypingTests: XCTestCase {
    private func window(isPrivate: Bool = false) -> TabStore {
        TestEnvironment.prepare()
        // An unregistered profile has no user tabs, preferences, or history to touch.
        let store = TabStore(isPrivate: isPrivate, profileID: UUID(), session: [])
        SearchSuggestions.enabled = false
        addTeardownBlock { @MainActor in
            store.clearSuggestions()
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        return store
    }

    private func waitForResults(_ store: TabStore) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while store.suggestions.isEmpty && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.suggestions.isEmpty, "The latest query must eventually produce results")
    }

    func testFastTypingDoesNotScanHistoryOnTheInputThread() async throws {
        let store = window()
        let visits = (0..<240_000).map {
            (URL(string: "https://common.example/\($0)")!, "Common page \($0)", Date(timeIntervalSince1970: Double($0)))
        }
        store.history.record(visits)
        store.history.record(URL(string: "https://latest.example")!, title: "Latest result")
        let began = Date.now
        for query in ["co", "com", "comm", "latest"] { store.suggest(query) }
        let elapsed = Date.now.timeIntervalSince(began)
        print("Four search keystrokes over 240k visits: \(elapsed * 1000)ms")
        XCTAssertLessThan(elapsed, 0.05, "Typing must schedule history work and return immediately")
        XCTAssertTrue(store.suggestions.isEmpty, "Intermediate keystrokes must not run history scans")
        try await waitForResults(store)
        XCTAssertEqual(store.suggestions.map(\.title), ["Latest result"])

        // Debouncing alone is insufficient: a scan after the pause must also leave
        // the main actor available for the next input event.
        let scan = Task { await store.history.suggestAsync("common") }
        let heartbeat = Date.now
        try await Task.sleep(for: .milliseconds(1))
        let delay = Date.now.timeIntervalSince(heartbeat)
        print("Main-actor heartbeat during history scan: \(delay * 1000)ms")
        XCTAssertLessThan(delay, 0.05, "A running scan must not block the input thread")
        let results = await scan.value
        XCTAssertEqual(results.count, 8)

        let historyScan = Task { await store.history.historyAsync(matching: "common", limit: 20) }
        let historyHeartbeat = Date.now
        try await Task.sleep(for: .milliseconds(1))
        XCTAssertLessThan(Date.now.timeIntervalSince(historyHeartbeat), 0.05,
                          "History window scans must leave the input actor available")
        let historyResults = await historyScan.value
        XCTAssertEqual(historyResults.count, 20)

        // Interrupt an expensive scan; the next request must not queue behind it.
        let cancelled = Task { await store.history.historyAsync(matching: "common") }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let latest = await store.history.historyAsync(matching: "latest")
        XCTAssertEqual(latest.map(\.title), ["Latest result"])
        let discarded = await cancelled.value
        XCTAssertTrue(discarded.isEmpty)

    }

    func testClosingSearchDiscardsPendingResults() async throws {
        let store = window()
        store.history.record(URL(string: "https://common.example")!, title: "Common page")
        store.suggest("common")
        store.clearSuggestions()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testLateSuggestionsKeepTheKeyboardDestinationSelected() {
        XCTAssertEqual(Palette.selectedIndex(previous: 1, selectedID: "tab:weak",
            rowIDs: ["typed", "url:history", "tab:weak"], reset: false), 2)
        XCTAssertEqual(Palette.selectedIndex(previous: 3, selectedID: "cmd:reload",
            rowIDs: ["typed", "cmd:reload"], reset: false), 1)
        XCTAssertEqual(Palette.selectedIndex(previous: 2, selectedID: "url:deleted",
            rowIDs: ["typed", "tab:weak"], reset: false), 1)
        XCTAssertEqual(Palette.selectedIndex(previous: 2, selectedID: "tab:weak",
            rowIDs: ["typed", "url:history", "tab:weak"], reset: true), 0)
    }

    func testNewQueryClearsOldRowsAndSeesHistoryChanges() async throws {
        let store = window()
        let url = URL(string: "https://common.example")!
        store.history.record(url, title: "Common page")
        store.suggest("common")
        try await waitForResults(store)
        XCTAssertEqual(store.suggestions.map(\.title), ["Common page"])
        store.history.forget(url: url.absoluteString)
        store.history.toggleBookmark(URL(string: "https://latest.example")!, title: "Latest bookmark")
        store.suggest("latest")
        XCTAssertTrue(store.suggestions.isEmpty, "Rows from the previous query must disappear immediately")
        try await waitForResults(store)
        XCTAssertEqual(store.suggestions.map(\.title), ["Latest bookmark"])
        XCTAssertTrue(store.suggestions[0].bookmarked)
        store.suggest("common")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(store.suggestions.isEmpty, "The reader must see committed history deletions")
    }

    func testPrivateSearchDoesNotReadSavedHistory() async throws {
        let store = window(isPrivate: true)
        store.history.record(URL(string: "https://common.example")!, title: "Common page")
        store.suggest("common")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    func testSiteSearchOnlySuggestsHistoryFromItsSiteAndCancelsOnExit() async throws {
        let store = window()
        store.history.record(URL(string: "https://www.youtube.com/watch?v=1")!, title: "Cats video")
        store.history.record(URL(string: "https://other.example/cats")!, title: "Cats elsewhere")
        store.suggest("cats", scopedTo: Bangs.lookup("yt"))
        try await waitForResults(store)
        XCTAssertEqual(store.suggestions.map(\.title), ["Cats video"])
        store.suggest("cats", scopedTo: Bangs.lookup("yt"))
        store.suggest("cats")
        try await waitForResults(store)
        XCTAssertEqual(Set(store.suggestions.map(\.title)), ["Cats video", "Cats elsewhere"])
    }

    func testSiteSearchFindsMatchingHistoryBelowTheGlobalLimit() async throws {
        let store = window()
        store.history.record([(URL(string: "https://www.youtube.com/watch?v=1")!, "Cats video",
                               Date(timeIntervalSince1970: 1))])
        for i in 0..<12 {
            store.history.record(URL(string: "https://other.example/cats/\(i)")!, title: "Cats elsewhere")
        }
        store.suggest("cats", scopedTo: Bangs.lookup("yt"))
        try await waitForResults(store)
        XCTAssertEqual(store.suggestions.map(\.title), ["Cats video"])
    }
}
