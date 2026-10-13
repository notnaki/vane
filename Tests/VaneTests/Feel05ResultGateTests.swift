import XCTest
@testable import vane

@MainActor final class Feel05ResultGateTests: XCTestCase {
    private struct Request: Equatable {
        var profile = UUID()
        var query = ""
        var scope = "all"
        var revision = 0
    }

    func testRetainedRowsCannotMutateStorageUntilMatchingResultsCommit() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        let url = URL(string: "https://fixture.invalid/retained")!
        XCTAssertEqual(store.addBookmarks([(url, "Retained bookmark")]), 1)
        XCTAssertEqual(store.record([(url, "Retained visit", .now)]), 1)
        let mark = try XCTUnwrap(store.managedBookmarks().first)
        let visit = try XCTUnwrap(store.history().first)
        let presented = Request(profile: profile)
        var gate = Feel05ResultGate<Request>()
        var calls = 0
        func deleteRows(_ request: Request, refreshing: Bool) {
            gate.performIfCurrent(request, refreshing: refreshing) {
                calls += 1
                XCTAssertTrue(store.deleteBookmarks([mark.id]))
                XCTAssertTrue(store.deleteVisit(visit.id))
            }
        }
        // First opening has no committed rows.
        deleteRows(presented, refreshing: false)
        gate.present(presented)
        var changedQuery = presented; changedQuery.query = "new query"
        var changedFolder = presented; changedFolder.scope = "folder"
        var changedPeriod = presented; changedPeriod.scope = "today"
        var changedProfile = presented; changedProfile.profile = UUID()
        var changedRevision = presented; changedRevision.revision += 1
        // Input changes must gate immediately, even before the loading flag changes.
        for request in [changedQuery, changedFolder, changedPeriod, changedProfile, changedRevision] {
            deleteRows(request, refreshing: false)
        }
        deleteRows(presented, refreshing: true)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.managedBookmarks().map(\.id), [mark.id])
        XCTAssertEqual(store.history().map(\.id), [visit.id])
        // Only completion of the matching request restores actions.
        gate.present(changedQuery)
        deleteRows(changedQuery, refreshing: false)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.managedBookmarks().isEmpty)
        XCTAssertTrue(store.history().isEmpty)
    }
    func testRetainedArchiveRowsWaitForCurrentQueryFilterAndRevision() async throws {
        TestEnvironment.prepare()
        let profile = Profile(name: "Archive gate fixture")
        let archive = Archive.shared(for: profile.id)
        defer { archive.clear() }
        let url = URL(string: "https://fixture.invalid/archived")!
        archive.add(url: url, title: "Archived row", littleArc: true)
        let library = ArchiveLibrary(sources: [.init(profile: profile, archive: archive)])
        let oldRequest = Request(profile: profile.id, revision: library.revision)
        var gate = Feel05ResultGate<Request>()
        let results = await library.search.groups(library.entries, revision: library.revision,
                                                 query: "", littleOnly: false)
        let row = try XCTUnwrap(results.flatMap(\.items).first)
        gate.present(oldRequest)
        var query = oldRequest; query.query = "another query"
        var filter = oldRequest; filter.scope = "littleOnly"
        archive.add(url: URL(string: "https://fixture.invalid/new")!, title: "New row")
        var mutation = oldRequest; mutation.revision = library.revision
        for current in [query, filter, mutation] {
            gate.performIfCurrent(current, refreshing: false) { archive.remove(row.entry.id) }
        }
        gate.performIfCurrent(oldRequest, refreshing: true) { archive.remove(row.entry.id) }
        XCTAssertTrue(archive.entries.contains { $0.id == row.entry.id })
        _ = await library.search.groups(library.entries, revision: mutation.revision,
                                        query: "", littleOnly: false)
        gate.present(mutation)
        gate.performIfCurrent(mutation, refreshing: false) { archive.remove(row.entry.id) }
        XCTAssertFalse(archive.entries.contains { $0.id == row.entry.id })
    }

}
