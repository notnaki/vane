import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpacePreviewPRTests: XCTestCase {
    func testGhostKeepsAuthorAndRenderedAppearanceUntilNextGesture() throws {
        try withFixture { store, live, folder, space, url in
            @MainActor func refresh(author: String) {
                live.receive(.success([GitHub.PR(url: url.absoluteString, title: "Review change",
                    draft: false, repo: "fixture/project", number: 1, author: author)]),
                    for: folder.id, token: "fixture-token")
            }
            refresh(author: "first-author")
            let first = preview(store, live: live, space: space)
            let firstPixels = try pixels(first)
            refresh(author: "second-author")
            XCTAssertEqual(try pixels(first), firstPixels,
                           "A refresh must not change a ghost in the middle of a swipe")
            let second = preview(store, live: live, space: space)
            XCTAssertEqual(first.rows.pinned.compactMap(\.pr).map(\.subtitle), ["first-author"])
            XCTAssertEqual(second.rows.pinned.compactMap(\.pr).map(\.subtitle), ["second-author"])
        }
    }

    func testSavedGhostKeepsPRMetadataOnlyInsideItsOwningLiveFolder() throws {
        try withFixture { store, live, folder, space, url in
            live.receive(.success([GitHub.PR(url: url.absoluteString, title: "Review change",
                draft: true, repo: "fixture/project", number: 1, author: "fixture-author")]),
                for: folder.id, token: "fixture-token")
            let nested = Folder(name: "Nested")
            let ordinary = Folder(name: "Ordinary")
            let key = TabStore.shapeKey(space: space.id, profileID: space.profileID)
            defer { UserDefaults.vane.removeObject(forKey: key) }
            let owned = try XCTUnwrap(store.pins.folder(folder.id))
            let files = URL(string: url.absoluteString + "/files")!
            let shape = Pins(entries: [
                .init(row: .folder(nested)),
                .init(row: .folder(owned), parent: nested.id),
                .init(row: .tab(files.absoluteString), parent: owned.id),
                .init(row: .folder(ordinary)),
                .init(row: .tab(url.absoluteString), parent: ordinary.id)
            ])
            UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
            let savedSpace = Space(id: space.id, name: space.name, profileID: space.profileID,
                                   tabURLs: [url], pinnedTabURLs: [files, url])
            let ghost = SpacePreviewList(space: savedSpace, liveTabs: nil, live: live)
            XCTAssertEqual(ghost.rows.pinned.compactMap(\.pr),
                           [GitHub.Row(author: "fixture-author", state: .draft)])
            XCTAssertTrue(ghost.rows.today.allSatisfy { $0.pr == nil })
        }
    }

    private func preview(_ store: TabStore, live: LiveFolders, space: Space) -> SpacePreviewList {
        let state = Stash(tabs: store.tabs.filter { $0.kind != .favourite }, pins: store.pins,
                          todayShape: store.todayShape, splits: store.splits,
                          current: store.current, fingerprint: "")
        return SpacePreviewList(space: space, liveTabs: state.tabs, state: state, live: live)
    }

    private func pixels(_ preview: SpacePreviewList) throws -> Data {
        let renderer = ImageRenderer(content: preview.frame(width: 250, height: 320))
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func withFixture(_ body: (TabStore, LiveFolders, Folder, Space, URL) throws -> Void) throws {
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
        try body(store, live, folder, space, URL(string: "https://github.com/fixture/project/pull/1")!)
    }
}
