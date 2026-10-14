import XCTest
@testable import vane

@MainActor final class SpaceTemplateModelTests: XCTestCase {
    func testUsingTemplateFromNewSpaceReplacesDraftAndRestoresItsTabs() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Creation template")
        let original = Space(name: "Keep", profileID: profile.id)
        let draft = Space(name: "Draft name", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([original, draft], for: profile.id))
        let store = TabStore(profileID: profile.id, space: draft, session: [])
        defer {
            let owned = store.tabs; TabStore.all.removeAll { $0 === store }; SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        let library = WorkspaceTemplates(manager: .shared)
        let page = SpaceLayout.Page(id: UUID(), url: URL(string: "https://example.com/work")!,
                                    kind: .today, title: "Work")
        let layout = SpaceLayout(tabs: [page], pins: Pins(),
                                 today: Pins(entries: [.init(row: .tab(page.id.uuidString))]),
                                 splits: [], selected: page.id, omitted: 0)
        _ = try library.save(name: "Work", space: original, layout: layout, unlocked: [])
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: profile.id, sourceID: draft.id, saving: false,
                           replacingEmptySpace: draft.id), library: library)
        var created: Space?
        model.create(name: "Draft name") { created = $0; store.switchTo(space: $0) }
        let result = try XCTUnwrap(created, model.message)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id).map(\.name), ["Keep", "Draft name"])
        XCTAssertFalse(store.spaces.contains { $0.id == draft.id })
        XCTAssertEqual(store.currentSpaceID, result.id)
        XCTAssertEqual(store.tabs.filter { $0.kind != .favourite }.map(\.currentURL), [page.url])
    }

    func testTemplateReplacementRefusesANewBlankTabWithoutDiscardingIt() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Changed creation")
        let draft = Space(name: "Draft", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([draft], for: profile.id))
        let store = TabStore(profileID: profile.id, space: draft, session: [])
        defer {
            let owned = store.tabs; TabStore.all.removeAll { $0 === store }; SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        let library = WorkspaceTemplates(manager: .shared)
        _ = try library.save(name: "Empty", space: draft,
            layout: SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil, omitted: 0), unlocked: [])
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: profile.id, sourceID: draft.id, saving: false,
                           replacingEmptySpace: draft.id), library: library)
        let tab = store.newBlankTab(focus: false)
        var created = false
        model.create(name: "Work") { _ in created = true }
        XCTAssertFalse(created)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertTrue(store.tabs.contains { $0.id == tab.id })
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id).map(\.id), [draft.id])
    }

    func testCancelledAuthenticationCannotSaveAndSuccessfulRetryCapturesProtectedContents() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Auth template")
        let space = Space(name: "Locked source", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space, session: [])
        defer {
            let owned = store.tabs; TabStore.all.removeAll { $0 === store }; SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/secret")!, Parked(title: "Secret"))
        var folder = Folder(name: "Protected"); folder.requiresAuthentication = true
        store.todayShape = Pins(entries: [.init(row: .folder(folder)), .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        var reply: FolderAuthentication.Reply?
        let auth = FolderAuthentication(authenticate: { _, done in reply = done; return nil })
        auth.systemAuthenticator = { _, done in reply = done; return nil }
        let library = WorkspaceTemplates(manager: .shared)
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: profile.id, sourceID: space.id, saving: true), library: library, authentication: auth)
        model.save(name: "Saved")
        XCTAssertTrue(model.busy)
        XCTAssertTrue(try library.load(profile: profile.id).isEmpty)
        reply?(false)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertTrue(try library.load(profile: profile.id).isEmpty)
        model.save(name: "Saved")
        reply?(true)
        XCTAssertEqual(try library.load(profile: profile.id).first?.layout.tabs.first?.title, "Secret")
    }

    func testDismissalDuringAuthenticationAndSourceChangesDoNotCommit() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Pending template")
        let space = Space(name: "Source", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space, session: [])
        defer { let owned = store.tabs; TabStore.all.removeAll { $0 === store }; SharedTabs.release(owned); _ = ProfileManager.shared.delete(profile.id) }
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/before")!, Parked(title: "Before"))
        var folder = Folder(name: "Protected"); folder.requiresAuthentication = true
        store.todayShape = Pins(entries: [.init(row: .folder(folder)), .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        var reply: FolderAuthentication.Reply?
        let auth = FolderAuthentication(authenticate: { _, done in reply = done; return nil })
        auth.systemAuthenticator = { _, done in reply = done; return nil }
        let library = WorkspaceTemplates(manager: .shared)
        let model = WorkspaceTemplateModel(store: store, request: .init(profileID: profile.id, sourceID: space.id, saving: true), library: library, authentication: auth)
        model.save(name: "Stale")
        tab.park(url: URL(string: "https://example.test/after")!, Parked(title: "After"))
        reply?(true)
        XCTAssertTrue(try library.load(profile: profile.id).isEmpty)
        XCTAssertFalse(model.message.isEmpty)
        auth.lockAll(); model.refreshSource(); model.save(name: "Dismissed"); model.cancel()
        reply?(true)
        XCTAssertTrue(try library.load(profile: profile.id).isEmpty)
    }
}
