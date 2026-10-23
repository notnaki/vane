import XCTest
@testable import vane

@MainActor final class FolderDisclosureTests: XCTestCase {
    func testDisclosurePersistsWithoutPublishingAnUnchangedSpace() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Folder disclosure").id
        let space = Space(name: "Documents", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        defer {
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
            _ = manager.delete(profile)
        }
        let folder = Folder(name: "Work", collapsed: true)
        store.pins = Pins(entries: [.init(row: .folder(folder))])
        store.savePins()
        let revision = manager.spacesRevision
        let saved = try XCTUnwrap(manager.spaces(for: profile).first)

        store.toggleFolder(folder.id)

        XCTAssertEqual(manager.spacesRevision, revision,
                       "Disclosure must not invalidate every Space observer when only its folder shape changed")
        XCTAssertEqual(manager.spaces(for: profile).first, saved)
        XCTAssertEqual(TabStore.savedShape(space: space.id, profileID: profile)?.folder(folder.id)?.collapsed, false)
        store.toggleFolder(folder.id)
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertEqual(TabStore.savedShape(space: space.id, profileID: profile)?.folder(folder.id)?.collapsed, true)
    }

    func testLayoutDisclosureAndChangedPinnedURLsStillReachDisk() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Layout disclosure").id
        var space = Space(name: "Documents", profileID: profile)
        XCTAssertTrue(manager.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        defer {
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
            _ = manager.delete(profile)
        }
        let tab = Tab(profileID: profile)
        tab.kind = .pinned
        let url = URL(string: "https://example.com/document")!
        tab.park(url: url, Parked(title: "Document"))
        store.tabs = [tab]
        let folder = Folder(name: "Work", collapsed: true)
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        store.savePins()
        XCTAssertEqual(manager.spaces(for: profile).first?.pinnedTabURLs, [url])
        space = try XCTUnwrap(manager.spaces(for: profile).first)
        space.layout = store.workspaceLayout()
        XCTAssertTrue(manager.updateSpace(space))

        store.toggleFolder(folder.id)
        XCTAssertEqual(manager.spaces(for: profile).first?.layout?.pins.folder(folder.id)?.collapsed, false)
        XCTAssertEqual(TabStore.savedShape(space: space.id, profileID: profile)?.folder(folder.id)?.collapsed, false)
        store.toggleFolder(folder.id)
        XCTAssertEqual(manager.spaces(for: profile).first?.layout?.pins.folder(folder.id)?.collapsed, true)
        XCTAssertEqual(manager.spaces(for: profile).first?.pinnedTabURLs, [url])
    }
}
