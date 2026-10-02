import XCTest
@testable import vane

@MainActor final class SearchTypingTests: XCTestCase {
    private static let fixtureDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vane-search-tests-\(UUID())")
        setenv("VANE_DATA_DIR", dir.path, 1)
        return dir
    }()

    private func window(isPrivate: Bool = false) -> TabStore {
        _ = Self.fixtureDirectory
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
    }

    func testClosingSearchDiscardsPendingResults() async throws {
        let store = window()
        store.history.record(URL(string: "https://common.example")!, title: "Common page")
        store.suggest("common")
        store.clearSuggestions()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(store.suggestions.isEmpty)
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
}
