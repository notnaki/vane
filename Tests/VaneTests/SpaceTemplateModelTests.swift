import XCTest
@testable import vane

@MainActor final class SpaceTemplateModelTests: XCTestCase {
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
