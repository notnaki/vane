import XCTest
import SQLite3
@testable import vane

@MainActor final class SuggestionAggregationTests: XCTestCase {
    private func fixture() throws -> (Store, OpaquePointer) {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = Store(path: directory.appendingPathComponent("history.db").path)
        return (store, try StoreSQLiteFixture.writer(store))
    }

    func testTitleUsesBestScoreThenNewestMatchingTimestampThenVisitIdentity() throws {
        let (store, _) = try fixture()
        let page = URL(string: "https://renamed.example")!
        let other = URL(string: "https://other.example")!
        XCTAssertEqual(store.record([
            (page, "Needle", Date(timeIntervalSince1970: 5)),
            (page, "NEEDLE", Date(timeIntervalSince1970: 5)),
            (page, "Needle resources", Date(timeIntervalSince1970: 20)),
            (page, "Unrelated", Date(timeIntervalSince1970: 30)),
            (other, "Needle", Date(timeIntervalSince1970: 21))
        ]), 5)
        XCTAssertEqual(store.suggest("needle").map(\.url), [page.absoluteString, other.absoluteString])
        XCTAssertEqual(store.suggest("needle").map(\.title), ["NEEDLE", "Needle"])
        XCTAssertEqual(store.record([(page, "Needle", Date(timeIntervalSince1970: 6))]), 1)
        XCTAssertEqual(store.suggest("needle", limit: 1).first?.title, "Needle")
        XCTAssertTrue(store.toggleBookmark(page, title: "Unrelated bookmark name"))
        let saved = try XCTUnwrap(store.suggest("needle", limit: 1).first)
        XCTAssertEqual(saved.title, "Needle")
        XCTAssertTrue(saved.bookmarked)
    }

    func testMatchingVisitCountAndRecencyExcludeRejectedTitles() throws {
        let (store, _) = try fixture()
        let older = URL(string: "https://older.example")!
        let newer = URL(string: "https://newer.example")!
        XCTAssertEqual(store.record([
            (older, "Café", Date(timeIntervalSince1970: 1)),
            (older, "Unrelated", Date(timeIntervalSince1970: 99)),
            (older, "Unrelated", Date(timeIntervalSince1970: 100)),
            (newer, "CAFÉ", Date(timeIntervalSince1970: 2))
        ]), 4)
        XCTAssertEqual(store.suggest("cafe").map(\.url), [newer.absoluteString, older.absoluteString])
        XCTAssertEqual(store.suggest("cafe").map(\.title), ["CAFÉ", "Café"])
    }

    func testWinningScoreOutsideRecentTitleProbeStillWins() throws {
        let (store, _) = try fixture()
        let page = URL(string: "https://renamed.example")!
        XCTAssertEqual(store.record((0..<80).map { index in
            (page, index == 0 ? "Needle" : "Needle resources",
             Date(timeIntervalSince1970: Double(index)))
        }), 80)
        XCTAssertEqual(store.record([(URL(string: "https://recent.example")!, "Needle",
                                      Date(timeIntervalSince1970: 100))]), 1)
        let winner = try XCTUnwrap(store.suggest("needle", limit: 1).first)
        XCTAssertEqual(winner.url, page.absoluteString, "Popularity still counts every matching visit")
        XCTAssertEqual(winner.title, "Needle", "The title probe must fall back to the full matching history")
    }

    func testSuggestionRankingAvoidsPerVisitWindowSortWork() throws {
        let (store, db) = try fixture()
        let entries = (0..<40_000).map { index in
            (URL(string: "https://fixture.invalid/\(index % 4000)")!, "Common",
             Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.record(entries), 40_000)
        let steps = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        steps.initialize(to: 0)
        defer { steps.deinitialize(count: 1); steps.deallocate() }
        sqlite3_progress_handler(db, 1000, { context in
            context!.assumingMemoryBound(to: Int.self).pointee += 1000
            return 0
        }, steps)
        defer { withExtendedLifetime(store) { sqlite3_progress_handler(db, 0, nil, nil) } }
        let suggestions = store.suggest("common")
        XCTAssertEqual(suggestions.count, 8)
        XCTAssertEqual(suggestions.first?.url, "https://fixture.invalid/3999")
        XCTAssertEqual(suggestions.last?.url, "https://fixture.invalid/3992")
        XCTAssertTrue(suggestions.allSatisfy { $0.title == "Common" && !$0.bookmarked })
        print("SUGGESTION_VM_STEPS rows=40000 steps=\(steps.pointee)")
        // Count SQLite work, not machine speed. The original three-window ranking
        // performs over five million instructions for these same eight results.
        XCTAssertLessThan(steps.pointee, 3_000_000)
    }

    func testAncientWinningTitleDoesNotRescanRejectedVisits() throws {
        let (store, db) = try fixture()
        let page = URL(string: "https://fixture.invalid/old-title")!
        XCTAssertEqual(store.record((0..<40_000).map { index in
            (page, index == 0 ? "Needle" : "Unrelated", Date(timeIntervalSince1970: Double(index)))
        }), 40_000)
        let steps = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        steps.initialize(to: 0)
        defer { steps.deinitialize(count: 1); steps.deallocate() }
        sqlite3_progress_handler(db, 1000, { context in
            context!.assumingMemoryBound(to: Int.self).pointee += 1000
            return 0
        }, steps)
        defer { withExtendedLifetime(store) { sqlite3_progress_handler(db, 0, nil, nil) } }
        let suggestions = store.suggest("needle")
        XCTAssertEqual(suggestions.map(\.url), [page.absoluteString])
        XCTAssertEqual(suggestions.map(\.title), ["Needle"])
        print("SPARSE_SUGGESTION_VM_STEPS rows=40000 steps=\(steps.pointee)")
        // A full backward title lookup adds another 600k instructions to the
        // original ~520k candidate scan, even though just one visit matches.
        XCTAssertLessThan(steps.pointee, 750_000)
    }
}
