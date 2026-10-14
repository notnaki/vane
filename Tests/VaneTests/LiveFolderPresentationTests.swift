import XCTest
@testable import vane

final class LiveFolderPresentationTests: XCTestCase {
    private let url = "https://github.com/notnaki/vane/pull/195"

    func testSearchAuthorAppearsWithoutAnOpenBadge() throws {
        let data = Data(#"{"items":[{"html_url":"https://github.com/notnaki/vane/pull/195","title":"Show rounded placeholders","number":195,"draft":false,"user":{"login":"notnaki"}}]}"#.utf8)
        let prs = try XCTUnwrap(GitHub.decode(data))
        let row = try XCTUnwrap(GitHub.presentation(prs, goodbyes: [], previous: [:], details: [:])[url])
        XCTAssertEqual(row.subtitle, "notnaki")
        XCTAssertEqual(row.state, .open)
    }

    func testMergedAndUnmergedClosedPRsAreDistinct() throws {
        let merged = try XCTUnwrap(GitHub.detail(Data(#"{"state":"closed","merged":true,"merged_at":"2026-10-02T08:00:00Z","user":{"login":"notnaki"}}"#.utf8)))
        let closed = try XCTUnwrap(GitHub.detail(Data(#"{"state":"closed","merged":false,"merged_at":null,"user":{"login":"notnaki"}}"#.utf8)))
        XCTAssertEqual(merged.subtitle, "notnaki · Merged")
        XCTAssertEqual(closed.subtitle, "notnaki · Closed")
        XCTAssertEqual(GitHub.detail(Data(#"{"state":"closed","merged_at":"2026-10-02T08:00:00Z"}"#.utf8))?.state, .merged)
        XCTAssertNil(GitHub.detail(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(GitHub.detail(Data(#"{"state":"bogus"}"#.utf8)))
    }

    func testDisappearanceDoesNotProveAMergeAndKeepsAuthor() throws {
        let previous = [url: GitHub.Row(author: "notnaki", state: .open)]
        let unknown = try XCTUnwrap(GitHub.presentation([], goodbyes: [url], previous: previous, details: [:])[url])
        XCTAssertEqual(unknown.subtitle, "notnaki")
        XCTAssertEqual(unknown.state, .unavailable)
        let stillOpen = GitHub.Row(author: "notnaki", state: .open)
        XCTAssertEqual(GitHub.presentation([], goodbyes: [url], previous: previous, details: [url: stillOpen])[url]?.subtitle, "notnaki")
        let merged = GitHub.Row(author: "", state: .merged)
        let confirmed = try XCTUnwrap(GitHub.presentation([], goodbyes: [url], previous: previous, details: [url: merged])[url])
        XCTAssertEqual(confirmed.subtitle, "notnaki · Merged")
        XCTAssertEqual(GitHub.presentation([], goodbyes: [url], previous: [url: confirmed], details: [:])[url], confirmed)
    }

    func testBrowsedPRKeepsMetadataDuringGoodbyeAndReopensCleanly() throws {
        let browsed = url + "/files"
        let rows = GitHub.presentation([], goodbyes: [browsed], previous: [url: .init(author: "notnaki", state: .open)], details: [browsed: .init(author: "notnaki", state: .merged)])
        XCTAssertEqual(rows[browsed]?.subtitle, "notnaki · Merged")
        let reopened = GitHub.PR(url: url, title: "Reopened", draft: true, repo: "notnaki/vane", number: 195, author: "notnaki")
        let fresh = GitHub.presentation([reopened], goodbyes: [], previous: rows, details: [:])
        XCTAssertNil(fresh[browsed])
        XCTAssertEqual(fresh[url]?.state, .draft)
        XCTAssertEqual(fresh[url]?.subtitle, "notnaki")
        XCTAssertTrue(GitHub.presentation([], goodbyes: [], previous: rows, details: [:]).isEmpty)
    }

    func testHeldClosedPRIsRecheckedBecauseItCanReopenAndMerge() {
        let closed = [url: GitHub.Row(author: "notnaki", state: .closed)]
        XCTAssertEqual(GitHub.detailRows(have: [url], found: [], previous: closed), [url])
        let merged = [url: GitHub.Row(author: "notnaki", state: .merged)]
        XCTAssertTrue(GitHub.detailRows(have: [url], found: [], previous: merged).isEmpty)
        XCTAssertTrue(GitHub.detailRows(have: [url + "/files"], found: [url], previous: closed).isEmpty)
    }

    func testDetailRequestsUseOnlyTrustedPRPaths() {
        XCTAssertEqual(GitHub.detailURL(url + "/files")?.absoluteString, "https://api.github.com/repos/notnaki/vane/pulls/195")
        for bad in ["https://evil.test/notnaki/vane/pull/195", "http://github.com/notnaki/vane/pull/195", "https://github.com@evil.test/notnaki/vane/pull/195", "https://user@github.com/notnaki/vane/pull/195", "https://github.com/notnaki/vane/pull/0", "https://github.com/notnaki/vane/issues/195"] {
            XCTAssertNil(GitHub.detailURL(bad), bad)
        }
    }
}


@MainActor final class LiveFolderArrivalTests: XCTestCase {
    func testCollapsedFolderShowsOnlyArrivalsUntilOpened() throws {
        try withFixture { store, live, folder in
            receive([1], live: live, folder: folder)
            store.pins.toggle(folder: folder.id)
            XCTAssertTrue(store.pins.folder(folder.id)!.collapsed)
            receive([2, 1], live: live, folder: folder)
            let arrival = try XCTUnwrap(store.tabs.first { store.rowURL($0.id.uuidString)?.hasSuffix("/2") == true })
            XCTAssertEqual(store.pins.visible.map(\.id), [folder.id.uuidString, arrival.id.uuidString])
            XCTAssertEqual(store.pins.visible.map(\.depth), [0, 1])
            XCTAssertTrue(store.pins.folder(folder.id)!.collapsed)
            receive([3, 2, 1], live: live, folder: folder)
            XCTAssertEqual(store.pins.visible.count, 3, "Unopened arrivals accumulate")
            receive([3, 2, 1], live: live, folder: folder)
            XCTAssertEqual(store.pins.visible.count, 3, "An unchanged refresh preserves previews")
            store.pins.toggle(folder: folder.id)
            XCTAssertEqual(store.pins.visible.count, 4)
            store.pins.toggle(folder: folder.id)
            XCTAssertEqual(store.pins.visible.map(\.id), [folder.id.uuidString])
        }
    }

    func testArrivalSurvivesSaveMappingButNeverLeaksThroughLocksOrAncestors() throws {
        try withFixture { store, live, folder in
            store.pins.toggle(folder: folder.id)
            receive([1], live: live, folder: folder)
            let saved = store.pins.mapped(store.rowURL)
            let restored = try JSONDecoder().decode(Pins.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(restored.visible.map(\.id), [folder.id.uuidString, "https://github.com/fixture/project/pull/1"])
            let adopted = TabStore.adopted(restored, opened: [
                (url: "https://github.com/fixture/project/pull/1", id: "restored-tab")
            ])
            XCTAssertEqual(adopted.children(of: folder.id), ["restored-tab"])
            XCTAssertEqual(adopted.visible.map(\.id), [folder.id.uuidString, "restored-tab"])
            store.pins.edit(folder: folder.id) { $0.requiresAuthentication = true }
            XCTAssertEqual(store.pins.visible.count, 1)
            XCTAssertEqual(store.pins.visible(unlocked: [folder.id]).count, 2)
            store.pins.edit(folder: folder.id) { $0.requiresAuthentication = false }
            var outer = Folder(name: "Outer")
            outer.collapsed = true
            store.pins.entries.insert(.init(row: .folder(outer)), at: 0)
            store.pins.entries[1].parent = outer.id
            XCTAssertEqual(store.pins.visible.map(\.id), [outer.id.uuidString])
        }
    }

    func testRestoringArrivalDoesNotExposeOlderDuplicateURL() throws {
        try withFixture { store, live, folder in
            let url = URL(string: "https://github.com/fixture/project/pull/1")!
            let manual = store.newBlankTab(focus: false, as: .pinned)
            manual.park(url: url, Parked(title: "Manually pinned"))
            store.syncShapes()
            store.pins.move(manual.id.uuidString, into: folder.id)
            store.pins.toggle(folder: folder.id)
            receive([1], live: live, folder: folder)
            let saved = store.pins.mapped(store.rowURL)
            let restored = TabStore.adopted(saved, opened: [
                (url: url.absoluteString, id: "older-manual"),
                (url: url.absoluteString, id: "new-arrival")
            ])
            XCTAssertEqual(restored.children(of: folder.id), ["older-manual", "new-arrival"])
            XCTAssertEqual(restored.visible.map(\.id), [folder.id.uuidString, "new-arrival"])
        }
    }

    private func receive(_ numbers: [Int], live: LiveFolders, folder: Folder) {
        live.receive(.success(numbers.map {
            GitHub.PR(url: "https://github.com/fixture/project/pull/\($0)", title: "PR \($0)",
                      draft: false, repo: "fixture/project", number: $0, author: "fixture")
        }), for: folder.id, token: "fixture-token")
    }

    private func withFixture(_ body: (TabStore, LiveFolders, Folder) throws -> Void) throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let space = Space(name: "Work", profileID: profile)
        let store = TabStore(profileID: profile, space: space, session: [])
        let live = LiveFolders(profileID: profile,
            readCredential: { .found(account: "fixture", password: "fixture-token") })
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            LiveFolders.forget(profile)
            Store.forget(profile)
        }
        let folder = Folder(name: "Pull Requests", live: .github(GitHubQuery()))
        store.pins = Pins(entries: [.init(row: .folder(folder))])
        try body(store, live, folder)
    }
}
