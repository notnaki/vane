import XCTest
import SQLite3
@testable import vane

@MainActor final class DuplicateSearchScoringTests: XCTestCase {
    private func fixture() throws -> (Store, OpaquePointer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = Store(path: directory.appendingPathComponent("history.db").path)
        return (store, try StoreSQLiteFixture.writer(store))
    }

    func testDuplicateScoresKeepPerVisitPopularityAndBestHistoricalTitle() throws {
        let (store, _) = try fixture()
        let popular = URL(string: "https://popular.example")!
        let recent = URL(string: "https://recent.example")!
        let renamed = URL(string: "https://renamed.example")!
        XCTAssertEqual(store.record([
            (popular, "Needle", Date(timeIntervalSince1970: 1)),
            (popular, "Needle", Date(timeIntervalSince1970: 2)),
            (popular, "Needle", Date(timeIntervalSince1970: 3)),
            (recent, "Needle", Date(timeIntervalSince1970: 10)),
            (recent, "Needle", Date(timeIntervalSince1970: 11)),
            (renamed, "Needle", Date(timeIntervalSince1970: 4)),
            (renamed, "Unrelated", Date(timeIntervalSince1970: 20))
        ]), 7)
        XCTAssertEqual(store.suggest("needle").map(\.url),
                       [popular.absoluteString, recent.absoluteString, renamed.absoluteString])
        XCTAssertEqual(store.suggest("needle").map(\.title), ["Needle", "Needle", "Needle"])
        XCTAssertEqual(store.history(matching: "needle").map { $0.at.timeIntervalSince1970 }, [11, 10, 4, 3, 2, 1])
    }

    func testQueryCacheDoesNotLeakAcrossQueriesEngineScopesOrCommittedChanges() throws {
        let (store, db) = try fixture()
        let youtube = URL(string: "https://www.youtube.com/watch?v=1")!
        let other = URL(string: "https://other.example")!
        XCTAssertEqual(store.record([(youtube, "Café GitHub Project", Date(timeIntervalSince1970: 1)),
                                     (youtube, "Café GitHub Project", Date(timeIntervalSince1970: 2)),
                                     (other, "Café GitHub Project", Date(timeIntervalSince1970: 3))]), 3)
        XCTAssertEqual(LocalSuggestionReader.read(db, query: "cafe", limit: 8, scopedTo: Bangs.lookup("yt")).map(\.url),
                       [youtube.absoluteString])
        XCTAssertEqual(LocalSuggestionReader.read(db, query: "ghp", limit: 8).map(\.url),
                       [youtube.absoluteString, other.absoluteString], "Fuzzy matching still includes duplicate pages")
        XCTAssertTrue(LocalSuggestionReader.read(db, query: "missing", limit: 8).isEmpty)
        XCTAssertTrue(store.retitle(other, title: "Missing"))
        XCTAssertEqual(LocalSuggestionReader.read(db, query: "missing", limit: 8).map(\.url), [other.absoluteString])
        XCTAssertEqual(store.history(matching: "cafe").count, 2, "The other page's committed retitle must be visible")
    }
}
