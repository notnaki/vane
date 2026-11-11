import XCTest
@testable import vane

@MainActor final class AccessibleTabIndexTests: XCTestCase {
    private func fixture() -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        store.sharingReady = false
        store.folderAuthentication = FolderAuthentication { _, reply in reply(true); return nil }
        addTeardownBlock { @MainActor in
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(store.profileID)
        }
        store.tabs = (0..<3).map { _ in Tab(profileID: store.profileID) }
        return store
    }

    func testWarmLookupReflectsProtectionGrantsRelockingAndParentEdits() {
        let store = fixture()
        var folder = Folder(name: "Private")
        folder.requiresAuthentication = true
        let tabs = store.tabs
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(tabs[0].id.uuidString), parent: folder.id),
            .init(row: .tab(tabs[1].id.uuidString))])
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[1].id, tabs[2].id])
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[1].id, tabs[2].id])
        store.folderAuthentication.unlock(folder.id, profile: store.profileID, reason: "Fixture") { _ in }
        XCTAssertEqual(store.accessibleTabs.map(\.id), tabs.map(\.id))
        store.folderAuthentication.lockAll()
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[1].id, tabs[2].id])
        store.pins.entries[1].parent = nil
        store.pins.entries[2].parent = folder.id
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[0].id, tabs[2].id])
        store.tabs = [tabs[2], tabs[1], tabs[0]]
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[2].id, tabs[0].id])
        let replacement = Tab(id: tabs[0].id, profileID: store.profileID)
        store.tabs = [replacement, tabs[1]]
        XCTAssertTrue(store.accessibleTabs.first === replacement, "Membership must return current live objects")
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testBooleanProtectionKeepsLegacyDuplicateFolderSemantics() {
        let store = fixture()
        let tab = store.tabs[0]
        let first = Folder(name: "First identity")
        var duplicate = first
        duplicate.requiresAuthentication = true
        store.pins = Pins(entries: [.init(row: .folder(first)), .init(row: .folder(duplicate)),
            .init(row: .tab(tab.id.uuidString), parent: first.id)])
        XCTAssertFalse(store.isTabLocked(tab.id), "Ancestor lookup uses the first folder with this identity")
        XCTAssertFalse(store.isFolderLocked(first.id))
        XCTAssertTrue(store.accessibleTabs.contains { $0 === tab })
        let colliding = Tab(id: first.id, profileID: store.profileID)
        store.tabs.append(colliding)
        XCTAssertFalse(store.accessibleTabs.contains { $0 === colliding }, "The bulk filter protects every protected row occurrence")
        XCTAssertFalse(store.isTabLocked(colliding.id), "Boolean ancestor lookup retains its first-folder semantics")
        store.pins.entries[0].row = .folder(duplicate)
        XCTAssertTrue(store.isTabLocked(tab.id))
        XCTAssertTrue(store.isFolderLocked(first.id))
    }

    func testWarmLookupReflectsStashReplacementAndFirstOwningShape() {
        let store = fixture()
        let tab = store.tabs[0]
        var folder = Folder(name: "Stashed protection")
        folder.requiresAuthentication = true
        let protected = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        let space = UUID()
        store.stashes[space] = Stash(tabs: [], pins: protected, todayShape: Pins(), splits: [], current: nil, fingerprint: "fixture")
        XCTAssertFalse(store.accessibleTabs.contains { $0 === tab })
        store.pins = Pins(entries: [.init(row: .tab(tab.id.uuidString))])
        XCTAssertTrue(store.accessibleTabs.contains { $0 === tab }, "The first owning shape controls protection")
        store.pins = Pins()
        XCTAssertFalse(store.accessibleTabs.contains { $0 === tab })
        store.stashes[space]?.pins = Pins()
        XCTAssertTrue(store.accessibleTabs.contains { $0 === tab })
        store.stashes[space]?.todayShape = protected
        XCTAssertFalse(store.accessibleTabs.contains { $0 === tab })
        store.stashes = [:]
        XCTAssertTrue(store.accessibleTabs.contains { $0 === tab })
    }

    func testDuplicateRowsCyclesAndCanonicalIdentityKeepExistingProtection() {
        let store = fixture()
        store.tabs[1] = Tab(id: UUID(uuidString: "ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF")!,
                            profileID: store.profileID)
        let tabs = store.tabs
        let outer = Folder(name: "Outer")
        var inner = Folder(name: "Inner")
        inner.requiresAuthentication = true
        let protected = Pins(entries: [.init(row: .folder(outer), parent: inner.id),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(tabs[0].id.uuidString), parent: outer.id),
            .init(row: .tab(tabs[0].id.uuidString)),
            .init(row: .tab(tabs[1].id.uuidString.lowercased()), parent: inner.id),
            .init(row: .tab(tabs[2].id.uuidString), parent: UUID())])
        store.todayShape = protected
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[1].id, tabs[2].id])
        store.folderAuthentication.unlock(inner.id, profile: UUID(), reason: "Other profile") { _ in }
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tabs[1].id, tabs[2].id])
        store.folderAuthentication.unlock(inner.id, profile: store.profileID, reason: "Fixture") { _ in }
        XCTAssertEqual(store.accessibleTabs.map(\.id), tabs.map(\.id))
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testBooleanFastRejectionMatchesAncestorChecksForMalformedShapes() {
        let store = fixture()
        let ids = (0..<4).map { _ in UUID() }
        var seed: UInt64 = 71
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        for _ in 0..<200 {
            var shape = Pins()
            for _ in 0..<12 {
                let id = ids[next(ids.count)]
                let parent = next(3) == 0 ? nil : ids[next(ids.count)]
                if next(2) == 0 {
                    var folder = Folder(id: id, name: "Duplicate fixture")
                    folder.requiresAuthentication = next(2) == 0
                    shape.entries.append(.init(row: .folder(folder), parent: parent))
                } else {
                    shape.entries.append(.init(row: .tab(id.uuidString), parent: parent))
                }
            }
            store.pins = shape
            for id in ids {
                XCTAssertEqual(store.isTabLocked(id), !store.lockedFolders(for: id.uuidString).isEmpty,
                               "Fast rejection must never bypass an existing authentication boundary")
            }
        }
    }

    func testNonFolderParentCannotBypassLegacyAuthenticationBoundary() {
        let store = fixture()
        let parent = store.tabs[0], child = store.tabs[1]
        var folder = Folder(name: "Protected")
        folder.requiresAuthentication = true
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(parent.id.uuidString), parent: folder.id),
            .init(row: .tab(child.id.uuidString), parent: parent.id)])
        XCTAssertEqual(store.lockedFolders(for: child.id.uuidString).map(\.id), [folder.id])
        XCTAssertTrue(store.isTabLocked(child.id), "A malformed tab parent still carries the legacy authentication boundary")
        XCTAssertTrue(store.isFolderLocked(child.id))
        // The bulk filter historically treats non-folder parents as missing.
        XCTAssertTrue(store.accessibleTabs.contains { $0 === child })
        store.pins.entries.append(.init(row: .folder(Folder(id: parent.id, name: "Shadowed folder"))))
        XCTAssertTrue(store.isTabLocked(child.id), "An earlier tab row still shadows a later folder with the same ID")
    }
}
