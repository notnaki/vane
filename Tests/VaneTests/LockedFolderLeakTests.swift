import AppKit
import XCTest
@testable import vane

@MainActor final class LockedFolderLeakTests: XCTestCase {
    private func store() -> TabStore {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), space = Space(name: "Leak fixture", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.folderAuthentication = FolderAuthentication { _, reply in reply(true); return nil }
        let settings = ["appleAI", "tidyTitles"].map { ($0, UserDefaults.vane.object(forKey: $0)) }
        UserDefaults.vane.set(false, forKey: "appleAI")
        TidyTitles.enabled = true
        addTeardownBlock { @MainActor in
            let tabs = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            TidyTitles.forget(profile)
            TabStore.forgetShape(space: space.id, profileID: profile)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
            settings.forEach { UserDefaults.vane.set($0.1, forKey: $0.0) }
        }
        return store
    }

    private func tab(in store: TabStore, path: String, kind: TabKind = .pinned) -> vane.Tab {
        let tab = store.newBlankTab(focus: false, as: kind)
        tab.park(url: URL(string: "https://example.test/\(path)")!, Parked(title: "Project Notes - Example"))
        return tab
    }

    func testTitleRefreshSkipsProtectedDescendantAfterAncestorMove() async {
        let store = store()
        let secret = tab(in: store, path: "secret", kind: .today)
        let outer = Folder(name: "Public ancestor")
        let inner = Folder(name: "Secret child", requiresAuthentication: true)
        store.todayShape = Pins(entries: [.init(row: .folder(outer)),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(secret.id.uuidString), parent: inner.id)])
        XCTAssertTrue(store.move(folder: outer.id, from: \.todayShape, to: \.pins,
            at: .init(parent: nil, index: 0), saying: false))
        XCTAssertEqual(secret.kind, .pinned)
        XCTAssertTrue(store.isTabLocked(secret.id))
        var sent = false
        let task = TidyTitles.refresh(secret) { _, _ in sent = true; return "Notes" }
        await task?.value
        XCTAssertFalse(sent)
        XCTAssertNil(UserDefaults.vane.dictionary(forKey:
            ProfileManager.defaultsKey("tidyTitleCacheV2", store.profileID))?[secret.currentURL!.absoluteString])
    }

    func testTitleRefreshRechecksProtectionBeforeQueuedGeneration() async throws {
        let store = store(), folder = Folder(name: "Later locked")
        let page = tab(in: store, path: "queued")
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(page.id.uuidString), parent: folder.id)])
        var sent = false
        let task = try XCTUnwrap(TidyTitles.refresh(page) { _, _ in sent = true; return "Notes" })
        // No actor suspension between scheduling and protection changing.
        store.pins.edit(folder: folder.id) { $0.requiresAuthentication = true }
        await task.value
        XCTAssertFalse(sent)
    }

    func testTitleRefreshAllowsPublicGenerationButDiscardsRelockedAnswer() async throws {
        let store = store(), folder = Folder(name: "Relocked", requiresAuthentication: true)
        let page = tab(in: store, path: "relocked")
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(page.id.uuidString), parent: folder.id)])
        store.folderAuthentication.unlock(folder.id, profile: store.profileID, reason: "Fixture") { _ in }
        var sent = false
        let task = try XCTUnwrap(TidyTitles.refresh(page) { _, _ in
            sent = true
            store.folderAuthentication.lock(folder.id, profile: store.profileID)
            return "Notes"
        })
        await task.value
        XCTAssertTrue(sent)
        XCTAssertNil(UserDefaults.vane.dictionary(forKey:
            ProfileManager.defaultsKey("tidyTitleCacheV2", store.profileID))?[page.currentURL!.absoluteString])
        store.pins.edit(folder: folder.id) { $0.requiresAuthentication = nil }
        let publicTask = try XCTUnwrap(TidyTitles.refresh(page) { _, _ in "Notes" })
        await publicTask.value
        XCTAssertEqual(TidyTitles.title(for: page), "Notes")
    }

    func testOpenTabPublicationExcludesProtectedIdentityButKeepsPublicDuplicate() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-leaks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "vane-leaks-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.dropScratchSuite(suite); try? FileManager.default.removeItem(at: root) }
        let manager = ProfileManager(directory: root, sandboxed: true)
        let profile = manager.active.id, secret = UUID(), publicID = UUID()
        let url = URL(string: "https://duplicate.example.test/")!
        let folder = Folder(name: "Protected", requiresAuthentication: true)
        var space = manager.createSpace(name: "Fixture", in: profile)
        space.tabURLs = [url, url]
        space.layout = SpaceLayout(tabs: [secret, publicID].map {
            .init(id: $0, url: url, kind: .today, title: $0 == secret ? "Secret title" : "Public title")
        }, pins: Pins(), today: Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(secret.uuidString), parent: folder.id), .init(row: .tab(publicID.uuidString))]),
            splits: [], selected: nil)
        XCTAssertTrue(manager.updateSpace(space))
        let rows = [Session.Entry(id: secret.uuidString, url: url.absoluteString, title: "Secret title", kind: .today),
                    Session.Entry(id: publicID.uuidString, url: url.absoluteString, title: "Public title", kind: .today)]
        let bytes = try XCTUnwrap(Session.encode([rows], spaces: [space.id.uuidString]))
        let file = ProfileManager.sessionURL(for: profile, in: root)
        try bytes.write(to: file)
        let adapter = ICloudLibraryAdapter(directory: root, defaults: defaults, deviceID: "fixture", profiles: manager)
        let items = try await adapter.capture([.openTabs])
        XCTAssertEqual(try items.map { try $0.decode(ICloudRemoteTab.self).title }, ["Public title"])
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Filtering must preserve the local restore session")

        // Legacy sessions can lack identities/Space associations; legacy outlines use URLs.
        space.layout = nil
        XCTAssertTrue(manager.updateSpace(space))
        defaults.set(try JSONEncoder().encode(Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(url.absoluteString), parent: folder.id)])),
            forKey: TabStore.shapeKey(.today, space: space.id, profileID: profile))
        let legacyRow = Session.Entry(url: url.absoluteString, title: "Legacy secret")
        try XCTUnwrap(Session.encode([[legacyRow], [legacyRow]], spaces: ["", UUID().uuidString]))
            .write(to: file)
        let legacy = try await adapter.capture([.openTabs])
        XCTAssertTrue(legacy.isEmpty)
    }

    func testSaveSheetFiltersTabsNestedFoldersAndSplitsAgainstCurrentProtection() throws {
        let store = store(), page = tab(in: store, path: "preview", kind: .today)
        let outer = Folder(name: "Later locked"), inner = Folder(name: "Private nested name")
        store.todayShape = Pins(entries: [.init(row: .folder(outer)),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(page.id.uuidString), parent: inner.id)])
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: store.profileID, sourceID: store.currentSpaceID, saving: true))
        let captured = try XCTUnwrap(model.preview)
        let preview = WorkspaceContentsPreview(layout: captured, unlocked: [], canPreview: model.canPreview)
        XCTAssertTrue(preview.accessible(page.id.uuidString))
        store.todayShape.edit(folder: outer.id) { $0.requiresAuthentication = true }
        XCTAssertEqual(model.draft, captured, "Save confirmation still compares against the reviewed snapshot")
        XCTAssertFalse(preview.accessible(page.id.uuidString), "Split labels use the same access gate")
        XCTAssertFalse(model.canPreview(inner.id.uuidString))
        XCTAssertTrue(model.canPreview(outer.id.uuidString), "The protected folder's own label can remain")
        model.cancel()
        XCTAssertFalse(preview.accessible(page.id.uuidString))
    }
}
