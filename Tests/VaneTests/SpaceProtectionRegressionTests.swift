import XCTest
@testable import vane

@MainActor final class SpaceProtectionRegressionTests: XCTestCase {
    private func spaces() -> (Space, Space) {
        TestEnvironment.prepare()
        let profile = UUID()
        let source = Space(name: "Source", profileID: profile)
        let target = Space(name: "Target", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([source, target], for: profile))
        addTeardownBlock { @MainActor in
            TabStore.forgetShape(space: source.id, profileID: profile)
            TabStore.forgetShape(space: target.id, profileID: profile)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (source, target)
    }

    private func save(_ shape: Pins, kind: TabKind, space: Space) throws {
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey:
            TabStore.shapeKey(kind, space: space.id, profileID: space.profileID))
    }

    func testSynchronousSpaceDeletionCannotArchiveLockedColdContents() throws {
        var (source, _) = spaces()
        let url = URL(string: "https://secret.example.test/")!
        source.tabURLs = [url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        try save(Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(url.absoluteString), parent: folder.id)]), kind: .today, space: source)
        let archive = Archive.shared(for: source.profileID)
        let before = archive.entries
        XCTAssertFalse(Spaces.delete(source.id, in: source.profileID))
        XCTAssertTrue(ProfileManager.shared.spaces(for: source.profileID).contains { $0.id == source.id })
        XCTAssertEqual(archive.entries, before)
    }

    func testOfflineMovePreservesLockedDuplicateInOtherSection() async throws {
        var (source, target) = spaces()
        let url = URL(string: "https://duplicate.example.test/")!
        source.tabURLs = [url]; source.pinnedTabURLs = [url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        try save(Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(url.absoluteString), parent: folder.id)]), kind: .pinned, space: source)
        await Library.moveAsync(url, from: source.id, to: target.id, pinned: false, profile: source.profileID)
        let saved = try XCTUnwrap(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == source.id })
        XCTAssertEqual(saved.tabURLs, [])
        XCTAssertEqual(saved.pinnedTabURLs, [url])
        XCTAssertNotNil(TabStore.savedShape(.pinned, space: source.id, profileID: source.profileID)?.folder(folder.id))
    }

    func testMixedProtectedSplitDoesNotSuppressPublicPreviewRows() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let tabs = (0..<3).map { _ in Tab(profileID: profile) }
        defer { tabs.forEach { $0.tearDown() }; Store.forget(profile) }
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        let shape = Pins(entries: [.init(row: .tab(tabs[0].id.uuidString)),
            .init(row: .tab(tabs[1].id.uuidString)), .init(row: .folder(folder)),
            .init(row: .tab(tabs[2].id.uuidString), parent: folder.id)])
        let state = Stash(tabs: tabs, pins: Pins(), todayShape: shape,
            splits: [try XCTUnwrap(Split(tabs: tabs.map(\.id)))], current: tabs[0].id, fingerprint: "")
        let preview = SpacePreviewList(space: Space(name: "Preview", profileID: profile), liveTabs: tabs, state: state)
        XCTAssertEqual(preview.rows.today.count, 3, "Two public rows and the locked folder; no protected pane strip")
    }
    func testAsyncDeletionAuthenticatesEveryColdFolderAndCancellationKeepsArchiveUnchanged() async throws {
        var (source, _) = spaces()
        let url = URL(string: "https://secret.example.test/cancel")!
        source.tabURLs = [url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let outer = Folder(name: "Outer", requiresAuthentication: true)
        let inner = Folder(name: "Empty inner", requiresAuthentication: true)
        try save(Pins(entries: [.init(row: .folder(outer)),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(url.absoluteString), parent: inner.id)]), kind: .today, space: source)
        var requests = 0
        let authentication = FolderAuthentication { _, reply in
            requests += 1; reply(requests == 1); return nil
        }
        let before = Archive.shared(for: source.profileID).entries
        let deleted = await Spaces.deleteAsync(source.id, in: source.profileID, authentication: authentication)
        XCTAssertFalse(deleted)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(Archive.shared(for: source.profileID).entries, before)
        XCTAssertTrue(ProfileManager.shared.spaces(for: source.profileID).contains { $0.id == source.id })
    }

    func testAsyncDeletionRechecksNewProtectionAfterAuthentication() async throws {
        let (source, _) = spaces()
        let first = Folder(name: "First", requiresAuthentication: true)
        let added = Folder(name: "Added during authentication", requiresAuthentication: true)
        try save(Pins(entries: [.init(row: .folder(first))]), kind: .pinned, space: source)
        let changed = Pins(entries: [.init(row: .folder(first)), .init(row: .folder(added))])
        let authentication = FolderAuthentication { _, reply in
            try! self.save(changed, kind: .pinned, space: source)
            reply(true); return nil
        }
        let deleted = await Spaces.deleteAsync(source.id, in: source.profileID, authentication: authentication)
        XCTAssertFalse(deleted)
        XCTAssertTrue(ProfileManager.shared.spaces(for: source.profileID).contains { $0.id == source.id })
    }

    func testAsyncDeletionWithAllGrantsArchivesAndDeletes() async throws {
        var (source, _) = spaces()
        let url = URL(string: "https://secret.example.test/granted")!
        source.tabURLs = [url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        try save(Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(url.absoluteString), parent: folder.id)]), kind: .today, space: source)
        var requests = 0
        let authentication = FolderAuthentication { _, reply in requests += 1; reply(true); return nil }
        let deleted = await Spaces.deleteAsync(source.id, in: source.profileID, authentication: authentication)
        XCTAssertTrue(deleted)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(ProfileManager.shared.spaces(for: source.profileID).contains { $0.id == source.id })
        XCTAssertTrue(Archive.shared(for: source.profileID).entries.contains { $0.url == url.absoluteString })
    }

    func testLibraryTitleAndLiveMoveUseExactAccessibleOccurrence() async throws {
        let (source, target) = spaces()
        let store = TabStore(profileID: source.profileID, space: source, session: [])
        defer {
            let tabs = store.everyTab; store.dropStashes()
            TabStore.all.removeAll { $0 === store }; SharedTabs.release(tabs)
        }
        let url = URL(string: "https://duplicate.example.test/live")!
        let secret = store.newBlankTab(focus: false, as: .pinned)
        secret.park(url: url, Parked(title: "Secret title"))
        let publicTab = store.newBlankTab(focus: false)
        publicTab.park(url: url, Parked(title: "Public title"))
        let other = store.newBlankTab(focus: false)
        other.park(url: url, Parked(title: "Other public title"))
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(secret.id.uuidString), parent: folder.id)])
        XCTAssertEqual(Library.cardTitle(url, kind: .today, occurrence: .live(other.id), in: store), "Other public title")
        XCTAssertEqual(Library.cardTitle(url, kind: .today, occurrence: .live(secret.id), in: store), Library.label(for: url))
        await Library.moveAsync(url, from: source.id, to: target.id, pinned: false, profile: source.profileID,
                                occurrence: .live(other.id))
        XCTAssertTrue(store.tabs.contains { $0 === secret })
        XCTAssertTrue(store.tabs.contains { $0 === publicTab })
        XCTAssertFalse(store.tabs.contains { $0 === other })
    }

    func testColdLayoutMoveRemovesOnlySelectedSameSectionOccurrence() async throws {
        var (source, target) = spaces()
        let url = URL(string: "https://duplicate.example.test/layout")!
        let secret = UUID(), selected = UUID(), survivor = UUID()
        let folder = Folder(name: "Secret", requiresAuthentication: true)
        source.tabURLs = [url, url, url]
        source.layout = SpaceLayout(tabs: [secret, selected, survivor].map {
            .init(id: $0, url: url, kind: .today, title: $0.uuidString)
        }, pins: Pins(), today: Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(secret.uuidString), parent: folder.id),
            .init(row: .tab(selected.uuidString)), .init(row: .tab(survivor.uuidString))]),
            splits: [], selected: survivor)
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let shape = TabStore.savedShape(.today, space: source.id, profileID: source.profileID)
        let rows = Library.cardRows(space: source, kind: .today, shape: shape).filter { $0.url != nil }
        XCTAssertEqual(rows.map(\.sourceIndex), [1, 2])
        await Library.moveAsync(url, from: source.id, to: target.id, pinned: false, profile: source.profileID,
            occurrence: .saved(space: source, index: 1, shape: shape))
        let saved = try XCTUnwrap(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == source.id })
        XCTAssertEqual(saved.tabURLs, [url, url])
        XCTAssertEqual(saved.layout?.tabs.map(\.id), [secret, survivor])
        XCTAssertEqual(saved.layout?.today.folder(holding: secret.uuidString)?.id, folder.id)
    }

    func testStaleLegacyOccurrenceCannotSelectReplacement() async throws {
        var (source, target) = spaces()
        let url = URL(string: "https://duplicate.example.test/stale")!
        source.tabURLs = [url, url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        let captured = source
        source.tabURLs = [url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(source))
        await Library.moveAsync(url, from: source.id, to: target.id, pinned: false, profile: source.profileID,
            occurrence: .saved(space: captured, index: 1, shape: nil))
        XCTAssertEqual(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == source.id }?.tabURLs, [url])
        XCTAssertEqual(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == target.id }?.tabURLs, [])
    }

}
