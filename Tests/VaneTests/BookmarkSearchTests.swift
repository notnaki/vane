import XCTest
@testable import vane

@MainActor final class BookmarkSearchTests: XCTestCase {
    func testBackgroundReadPreservesSearchFoldersOrderingAndLiveEdits() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        let folder = try XCTUnwrap(store.createBookmarkFolder(named: "Folder"))
        XCTAssertEqual(store.addBookmarks([
            (URL(string: "https://fixture.invalid/a")!, "A 100% guide"),
            (URL(string: "https://fixture.invalid/b")!, "B under_score"),
            (URL(string: "https://fixture.invalid/c")!, "C café")]), 3)
        let mark = try XCTUnwrap(store.managedBookmarks().first)
        XCTAssertTrue(store.moveBookmarks([mark.id], to: folder.id))
        for query in ["", "guide", "%", "_", "CAFÉ", "no match"] {
            for folderID in [nil, folder.id] {
                let results = await store.managedBookmarksAsync(matching: query, folderID: folderID)
                XCTAssertEqual(results, store.managedBookmarks(matching: query, folderID: folderID))
            }
            let unfiled = await store.managedBookmarksAsync(matching: query, unfiledOnly: true, limit: 1)
            XCTAssertEqual(unfiled, store.managedBookmarks(matching: query, unfiledOnly: true, limit: 1))
        }
        let percent = await store.managedBookmarksAsync(matching: "%")
        XCTAssertEqual(percent.map(\.title), ["A 100% guide"])
        let underscore = await store.managedBookmarksAsync(matching: "_")
        XCTAssertEqual(underscore.map(\.title), ["B under_score"])
        let filed = await store.managedBookmarksAsync(folderID: folder.id)
        XCTAssertEqual(filed.map(\.id), [mark.id])
        let all = await store.managedBookmarksAsync()
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.0.at >= $0.1.at })
        let unlimited = await store.managedBookmarksAsync(limit: -1)
        XCTAssertEqual(unlimited, all, "Preserve SQLite's negative-limit behavior")
        let zero = await store.managedBookmarksAsync(limit: 0)
        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(store.deleteBookmarks([mark.id]))
        let edited = await store.managedBookmarksAsync()
        XCTAssertFalse(edited.contains { $0.id == mark.id })
        XCTAssertEqual(edited, store.managedBookmarks())
    }

    func testCancelledRequestsReturnNoRowsAndLatestRequestStillWorks() async {
        TestEnvironment.prepare()
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        XCTAssertEqual(store.addBookmarks((0..<3000).map {
            (URL(string: "https://fixture.invalid/\($0)")!, "Common bookmark \($0)")
        }), 3000)
        let cancelled = Task { await store.managedBookmarksAsync(matching: "common") }
        cancelled.cancel()
        let discarded = await cancelled.value
        XCTAssertTrue(discarded.isEmpty)
        let latest = await store.managedBookmarksAsync(matching: "bookmark 2999")
        XCTAssertEqual(latest.map(\.title), ["Common bookmark 2999"])
    }

    func testBackgroundBookmarksRemainProfileIsolated() async {
        TestEnvironment.prepare()
        let first = UUID(), second = UUID()
        defer { Store.forget(first); Store.forget(second) }
        Store.store(for: first).addBookmarks([(URL(string: "https://first.invalid")!, "First")])
        Store.store(for: second).addBookmarks([(URL(string: "https://second.invalid")!, "Second")])
        let results = await Store.store(for: first).managedBookmarksAsync()
        XCTAssertEqual(results.map(\.title), ["First"])
        let privateResults = await Store.store(for: Profile.incognito.id).managedBookmarksAsync()
        XCTAssertFalse(privateResults.contains { ["https://first.invalid", "https://second.invalid"].contains($0.url) })
    }

    func testPrivateSessionBookmarksRemainAvailableWithoutReadingSavedProfiles() async {
        let store = Store(path: ":memory:")
        let folder = store.createBookmarkFolder(named: "Private")!
        XCTAssertEqual(store.addBookmarks([(URL(string: "https://private.invalid")!, "Private bookmark")],
                                           to: folder.id), 1)
        let results = await store.managedBookmarksAsync(matching: "private", folderID: folder.id)
        XCTAssertEqual(results.map(\.title), ["Private bookmark"])
        let cancelled = Task { await store.managedBookmarksAsync() }
        cancelled.cancel()
        let discarded = await cancelled.value
        XCTAssertTrue(discarded.isEmpty)
    }
}
