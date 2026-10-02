import XCTest
@testable import vane

final class LiveFolderMenuTests: XCTestCase {
    private let url = "https://github.com/notnaki/vane/pull/195"

    func testOwnedPRUsesCanonicalLinkAndNumberBeforeMetadataArrives() throws {
        let folder = Folder(name: "Live", live: .github(GitHubQuery()), owned: [url])
        let pr = try XCTUnwrap(GitHub.menuPR(row: url + "/files?diff=split#review", in: folder))
        XCTAssertEqual(pr.url.absoluteString, url)
        XCTAssertEqual(pr.number, 195)
    }

    func testManualRowsAndStoppedFoldersKeepNormalTabMenus() {
        let live = Folder(name: "Live", live: .github(GitHubQuery()), owned: [url])
        XCTAssertNil(GitHub.menuPR(row: "https://github.com/notnaki/vane/pull/196", in: live))
        XCTAssertNil(GitHub.menuPR(row: url, in: Folder(name: "Ordinary", owned: [url])))
        XCTAssertNil(GitHub.menuPR(row: url, in: Folder(name: "Unrefreshed", live: .github(GitHubQuery()))))
        let bad = "https://evil.test/notnaki/vane/pull/195"
        XCTAssertNil(GitHub.menuPR(row: bad, in: Folder(name: "Bad", live: .github(GitHubQuery()), owned: [bad])))
    }
}

@MainActor final class LiveFolderArchiveTests: XCTestCase {
    func testManualDuplicateOfOwnedPRKeepsOrdinaryMenuAndCannotDismissGeneratedRow() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        let url = URL(string: "https://github.com/notnaki/vane/pull/195")!
        let generated = store.newBlankTab(focus: false, as: .pinned)
        let manual = store.newBlankTab(focus: false, as: .pinned)
        generated.park(url: url, Parked(title: "Generated"))
        manual.park(url: url, Parked(title: "Manual"))
        let folder = Folder(name: "Live", live: .github(GitHubQuery()), owned: [url.absoluteString])
        store.pins = Pins(entries: [
            .init(row: .folder(folder), parent: nil),
            .init(row: .tab(generated.id.uuidString), parent: folder.id),
            .init(row: .tab(manual.id.uuidString), parent: folder.id)
        ])
        XCTAssertNotNil(store.livePullRequest(generated.id))
        XCTAssertNil(store.livePullRequest(manual.id))
        store.archivePullRequest(manual.id)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertTrue(store.pins.folder(folder.id)?.dismissed?.isEmpty ?? true)
        XCTAssertTrue(Archive.shared(for: store.profileID).entries.isEmpty)
    }

    func testArchiveRemovesParkedPRAndPersistsDismissalAndCanonicalArchive() throws {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        let url = URL(string: "https://github.com/notnaki/vane/pull/195")!
        let tab = store.newBlankTab(focus: false, as: .pinned)
        tab.park(url: url, Parked(title: "Review this"))
        let folder = Folder(name: "Live", live: .github(GitHubQuery()), owned: [url.absoluteString])
        store.pins = Pins(entries: [
            .init(row: .folder(folder), parent: nil),
            .init(row: .tab(tab.id.uuidString), parent: folder.id)
        ])
        XCTAssertNotNil(store.livePullRequest(tab.id))
        store.archivePullRequest(tab.id)
        XCTAssertFalse(store.tabs.contains { $0.id == tab.id })
        XCTAssertTrue(store.pins.children(of: folder.id).isEmpty)
        XCTAssertEqual(store.pins.folder(folder.id)?.dismissed, [url.absoluteString])
        let entry = try XCTUnwrap(Archive.shared(for: store.profileID).entries.first)
        XCTAssertEqual(entry.url, url.absoluteString)
        XCTAssertEqual(entry.title, "Review this")
        XCTAssertEqual(GitHub.dismissed(previous: store.pins.folder(folder.id)?.dismissed ?? [],
            owned: [url.absoluteString], have: [], want: [url.absoluteString]), [url.absoluteString])
        store.archivePullRequest(tab.id)
        XCTAssertEqual(Archive.shared(for: store.profileID).entries.count, 1)
    }
}
