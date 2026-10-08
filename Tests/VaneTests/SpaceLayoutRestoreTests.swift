import XCTest
@testable import vane

@MainActor final class SpaceLayoutRestoreTests: XCTestCase {
    private func store() -> TabStore {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Templates test \(UUID())")
        let space = Space(name: "Source", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space, session: [])
        addTeardownBlock { @MainActor in
            let owned = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        return store
    }

    private func coldCopy(in store: TabStore, locked: Bool = false) throws -> Space {
        let ids = (0..<3).map { _ in UUID() }
        let urls = ["https://example.test/same", "https://example.test/same", "https://example.test/free"].map { URL(string: $0)! }
        var folder = Folder(name: "Saved folder"); folder.requiresAuthentication = locked ? true : nil
        let layout = SpaceLayout(tabs: ids.indices.map { .init(id: ids[$0], url: urls[$0], kind: .today,
                                                              title: "Page", customName: ["Alpha", "Beta", "Free"][$0]) },
            pins: Pins(), today: Pins(entries: [.init(row: .folder(folder))] + ids.map { .init(row: .tab($0.uuidString), parent: folder.id) }),
            splits: [.init(urls: Array(urls.prefix(2)).map(\.absoluteString), vertical: true, active: 1,
                           ids: Array(ids.prefix(2)).map(\.uuidString), weights: [0.25, 0.75])], selected: ids[1])
        let library = WorkspaceTemplates(manager: .shared)
        let saved = try library.save(name: "Saved", space: try XCTUnwrap(store.currentSpace), layout: layout,
                                     unlocked: locked ? [folder.id] : [])
        return try library.create(saved.id, profile: store.profileID, name: "Cold copy",
                                  unlocked: Set(saved.layout.protectedFolders.map(\.id)))
    }

    func testMovingTabsIntoAndOutOfColdTemplateSpaceKeepsDetailedLayout() throws {
        let source = store(), copy = try coldCopy(in: source)
        let incoming = source.newBlankTab(focus: false)
        incoming.park(url: URL(string: "https://example.test/incoming")!, Parked(title: "Incoming"))
        Spaces.move(incoming.id, to: copy.id, as: .today, from: source)
        var saved = try XCTUnwrap(source.spaces.first { $0.id == copy.id })
        XCTAssertTrue(try XCTUnwrap(saved.layout).matches(saved))
        XCTAssertEqual(saved.layout?.tabs.prefix(3).map(\.customName), ["Alpha", "Beta", "Free"])
        XCTAssertEqual(saved.layout?.splits, copy.layout?.splits)
        let destination = ProfileManager.shared.createSpace(name: "Destination", in: source.profileID)
        Library.move(URL(string: "https://example.test/free")!, from: copy.id, to: destination.id,
                          pinned: false, profile: source.profileID)
        saved = try XCTUnwrap(source.spaces.first { $0.id == copy.id })
        XCTAssertTrue(try XCTUnwrap(saved.layout).matches(saved))
        XCTAssertEqual(saved.layout?.tabs.compactMap(\.customName), ["Alpha", "Beta"])
        source.switchTo(space: saved)
        XCTAssertEqual(source.splits.first?.weights, [0.25, 0.75])
        XCTAssertEqual(source.todayShape.entries.compactMap { $0.folder?.name }, ["Saved folder"])
    }

    func testOrganizerOfColdTemplateSpaceKeepsNamesSplitsFoldersAndUndo() throws {
        let source = store(), copy = try coldCopy(in: source)
        let model = TabOrganization(store: source)
        let rows = model.rows.filter { $0.spaceID == copy.id }
        XCTAssertEqual(rows.map(\.title), ["Alpha", "Beta", "Free"])
        XCTAssertEqual(rows.map(\.canChange), [false, false, true])
        model.selection = [try XCTUnwrap(rows.last).id]
        XCTAssertTrue(model.archiveSelected())
        let after = try XCTUnwrap(source.spaces.first { $0.id == copy.id })
        XCTAssertTrue(try XCTUnwrap(after.layout).matches(after))
        XCTAssertEqual(after.layout?.tabs.map(\.customName), ["Alpha", "Beta"])
        XCTAssertEqual(after.layout?.splits, copy.layout?.splits)
        XCTAssertTrue(model.undo())
        let restored = try XCTUnwrap(source.spaces.first { $0.id == copy.id })
        XCTAssertEqual(restored.layout?.tabs, copy.layout?.tabs)
        XCTAssertEqual(restored.layout?.today, copy.layout?.today)
        XCTAssertEqual(restored.layout?.splits, copy.layout?.splits)
    }

    func testColdTemplateLockedShapeIsAvailableToExistingLibraryReaders() throws {
        let source = store(), copy = try coldCopy(in: source, locked: true)
        let page = try XCTUnwrap(copy.layout?.tabs.last)
        let shape = try XCTUnwrap(TabStore.savedShape(.today, space: copy.id, profileID: source.profileID))
        XCTAssertFalse(shape.lockedFolders(for: page.savedURL.absoluteString, unlocked: []).isEmpty)
        XCTAssertFalse(TabOrganization(store: source).rows.contains { $0.spaceID == copy.id })
    }

    func testPublicDuplicateCannotMoveLockedCopyThroughURLAddressedLibrary() throws {
        let source = store()
        var copy = try coldCopy(in: source, locked: true)
        var layout = try XCTUnwrap(copy.layout)
        let first = layout.today.entries.remove(at: 1)
        layout.today.entries.insert(.init(row: first.row), at: 0)
        copy.layout = layout
        XCTAssertTrue(ProfileManager.shared.updateSpace(copy))
        let duplicate = layout.tabs[0].savedURL
        let shape = try XCTUnwrap(TabStore.savedShape(.today, space: copy.id, profileID: source.profileID))
        XCTAssertFalse(shape.lockedFolders(for: duplicate.absoluteString, unlocked: []).isEmpty)
        let target = ProfileManager.shared.createSpace(name: "Target", in: source.profileID)
        Library.move(duplicate, from: copy.id, to: target.id, pinned: false, profile: source.profileID)
        XCTAssertEqual(source.spaces.first { $0.id == copy.id }?.layout, layout)
        XCTAssertEqual(source.spaces.first { $0.id == target.id }?.tabURLs, [])
        XCTAssertEqual(TabOrganization(store: source).rows.filter { $0.spaceID == copy.id }.map(\.title), ["Alpha"])
    }

    func testRecreatedSpaceLoadsDuplicatePagesWithIndependentNamesAndNoPageState() throws {
        let source = store()
        let tabs = (0..<2).map { _ in source.newBlankTab(focus: false) }
        for tab in tabs { tab.park(url: URL(string: "https://example.test/same")!, Parked(title: "Raw")) }
        tabs[0].workspaceName = "One"; tabs[1].workspaceName = "Two"
        let folder = Folder(name: "Writing")
        source.todayShape = Pins(entries: [.init(row: .folder(folder))] + tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        source.splits = [try XCTUnwrap(Split(tabs: tabs.map(\.id), vertical: true)).resized(divider: 0, from: [0.5, 0.5], by: -0.2)]
        let snapshot = try source.workspaceLayout().forTemplate(unlocked: [])
        let library = WorkspaceTemplates(manager: .shared)
        let saved = try library.save(name: "Writing", space: try XCTUnwrap(source.currentSpace), layout: snapshot, unlocked: [])
        let created = try library.create(saved.id, profile: source.profileID, name: "Copy", unlocked: [])
        let target = TabStore(profileID: source.profileID, space: created)
        defer {
            let owned = target.everyTab; target.dropStashes()
            TabStore.all.removeAll { $0 === target }; SharedTabs.release(owned)
        }
        XCTAssertEqual(target.tabs.map { TidyTitles.title(for: $0) }, ["One", "Two"])
        XCTAssertEqual(target.tabs.count, 2)
        XCTAssertEqual(target.todayShape.entries.compactMap { $0.folder?.name }, ["Writing"])
        XCTAssertEqual(target.splits.first?.vertical, true)
        XCTAssertEqual(target.splits.first?.weights, [0.3, 0.7])
        XCTAssertNil(target.tabs[1].existingWeb, "Only the selected page should load")
        XCTAssertFalse(target.tabs[0].canGoBack, "A copy has no inherited navigation history")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("interactionState"))
        TidyTitles.rename(target.tabs[0], to: "Edited")
        XCTAssertEqual(TidyTitles.title(for: tabs[0]), "One")
        XCTAssertTrue(target.saveCurrentSpace())
        let persisted = try XCTUnwrap(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == created.id }?.layout)
        XCTAssertEqual(persisted.tabs.first?.customName, "Edited")
    }

    func testSessionAndColdSpaceSwitchKeepRowNamesNestedFoldersAndDividerWeights() throws {
        let source = store()
        let pages = (0..<2).map { _ in source.newBlankTab(focus: false) }
        for page in pages { page.park(url: URL(string: "https://example.test/repeated")!, Parked(title: "Page")) }
        pages[0].workspaceName = "Alpha"; pages[1].workspaceName = "Beta"
        let folder = Folder(name: "Nested")
        source.todayShape = Pins(entries: [.init(row: .folder(folder))] + pages.map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        source.splits = [try XCTUnwrap(Split(tabs: pages.map(\.id))).withWeights([0.25, 0.75])]
        let library = WorkspaceTemplates(manager: .shared)
        let template = try library.save(name: "Session", space: try XCTUnwrap(source.currentSpace), layout: source.workspaceLayout(), unlocked: [])
        let copy = try library.create(template.id, profile: source.profileID, name: "Copy", unlocked: [])
        let target = TabStore(profileID: source.profileID, space: copy)
        defer { let owned = target.everyTab; target.dropStashes(); TabStore.all.removeAll { $0 === target }; SharedTabs.release(owned) }
        let other = ProfileManager.shared.createSpace(name: "Other", in: source.profileID)
        target.switchTo(space: other)
        target.drop(stash: copy.id)
        target.switchTo(space: copy)
        XCTAssertEqual(target.tabs.map { TidyTitles.title(for: $0) }, ["Alpha", "Beta"])
        XCTAssertEqual(target.splits.first?.weights, [0.25, 0.75])
        XCTAssertEqual(target.todayShape.entries.compactMap { $0.folder?.name }, ["Nested"])
        XCTAssertTrue(Session.save())
        let bytes = try Data(contentsOf: ProfileManager.sessionURL(for: source.profileID, in: Store.directory))
        let index = try XCTUnwrap(Session.decodeSpaces(bytes).firstIndex { $0 == copy.id })
        let entries = Session.decode(bytes)[index]
        XCTAssertEqual(entries.map(\.customName), ["Alpha", "Beta"])
        let saved = try XCTUnwrap(ProfileManager.shared.spaces(for: source.profileID).first { $0.id == copy.id })
        let old = target.tabs
        TabStore.all.removeAll { $0 === target }; SharedTabs.release(old)
        let restored = TabStore(profileID: source.profileID, space: saved, session: entries)
        defer { let owned = restored.tabs; TabStore.all.removeAll { $0 === restored }; SharedTabs.release(owned) }
        restored.applySplits(Session.decodeSplits(bytes)[index])
        XCTAssertEqual(restored.tabs.map { TidyTitles.title(for: $0) }, ["Alpha", "Beta"])
        XCTAssertEqual(restored.todayShape.entries.compactMap { $0.folder?.name }, ["Nested"])
        XCTAssertEqual(restored.splits.first?.weights, [0.25, 0.75])
    }

    func testLockedTemplateCreationRetainsProtectionWithFreshFolderIdentity() throws {
        let source = store()
        let tab = source.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/protected")!, Parked(title: "Protected"))
        var folder = Folder(name: "Private"); folder.requiresAuthentication = true
        source.todayShape = Pins(entries: [.init(row: .folder(folder)), .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        let library = WorkspaceTemplates(manager: .shared)
        XCTAssertThrowsError(try library.save(name: "Locked", space: try XCTUnwrap(source.currentSpace), layout: source.workspaceLayout(), unlocked: []))
        let saved = try library.save(name: "Locked", space: try XCTUnwrap(source.currentSpace), layout: source.workspaceLayout(), unlocked: [folder.id])
        XCTAssertThrowsError(try library.create(saved.id, profile: source.profileID, name: "Copy", unlocked: []))
        let created = try library.create(saved.id, profile: source.profileID, name: "Copy", unlocked: [folder.id])
        let target = TabStore(profileID: source.profileID, space: created)
        defer { let owned = target.tabs; TabStore.all.removeAll { $0 === target }; SharedTabs.release(owned) }
        XCTAssertNotEqual(target.todayShape.entries.first?.folder?.id, folder.id)
        XCTAssertTrue(target.isTabLocked(try XCTUnwrap(target.tabs.first?.id)))
        XCTAssertNil(target.tabs.first?.existingWeb)
    }
}
