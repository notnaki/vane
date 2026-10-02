import AppKit
import XCTest
@testable import vane

@MainActor final class SpaceDeletionTests: XCTestCase {
    private func spaces() -> (Space, Space) {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        addTeardownBlock { @MainActor in
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (first, second)
    }

    private func store(in space: Space) -> TabStore {
        let store = TabStore(profileID: space.profileID, space: space, session: [])
        addTeardownBlock { @MainActor in
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(store.profileID)
        }
        return store
    }

    func testDeletionSwitchesEveryOwnerBeforeReturning() {
        let (survivor, deleted) = spaces()
        let first = store(in: deleted), second = store(in: deleted)
        let unaffected = store(in: survivor)
        let (other, _) = spaces()
        let otherProfile = store(in: other)

        XCTAssertTrue(Spaces.delete(deleted.id, in: deleted.profileID))

        XCTAssertEqual(first.currentSpaceID, survivor.id)
        XCTAssertEqual(second.currentSpaceID, survivor.id)
        XCTAssertEqual(unaffected.currentSpaceID, survivor.id)
        XCTAssertEqual(otherProfile.currentSpaceID, other.id)
        XCTAssertFalse(first.stashes.keys.contains(deleted.id))
        XCTAssertFalse(second.stashes.keys.contains(deleted.id))
        XCTAssertEqual(TabStore.lastSpaceID(for: deleted.profileID), survivor.id)
    }

    func testDeletionSwitchesAParkedOwnerWithAnUnsavedThemePreview() {
        let (survivor, deleted) = spaces()
        let owner = store(in: deleted)
        let window = NSWindow()
        owner.parkedIn = window
        owner.previewSpace = deleted

        XCTAssertTrue(Spaces.delete(deleted.id, in: deleted.profileID))

        XCTAssertEqual(owner.currentSpaceID, survivor.id)
        XCTAssertEqual(owner.currentSpace?.id, survivor.id)
        XCTAssertNil(owner.previewSpace)
        XCTAssertTrue(owner.isParked)
    }

    func testDeletingAnInactiveSpaceKeepsTheCurrentSpace() {
        let (active, deleted) = spaces()
        let owner = store(in: active)
        XCTAssertTrue(Spaces.delete(deleted.id, in: deleted.profileID))
        XCTAssertEqual(owner.currentSpaceID, active.id)
    }

    func testDeletingTheLastSpaceLeavesOwnersAndTheProfileEmpty() {
        let (active, other) = spaces()
        XCTAssertTrue(Spaces.delete(other.id, in: active.profileID))
        let owner = store(in: active)
        XCTAssertTrue(Spaces.delete(active.id, in: active.profileID))
        XCTAssertFalse(Spaces.delete(UUID(), in: active.profileID))
        XCTAssertNil(owner.currentSpaceID)
        XCTAssertTrue(ProfileManager.shared.spaces(for: active.profileID).isEmpty)
        XCTAssertNil(Spaces.resolve(nil, for: Profile(id: active.profileID, name: "Empty")))
    }

    func testCreatingTheFirstSpaceKeepsLooseTabsAndTheirFolders() {
        let (active, other) = spaces()
        XCTAssertTrue(Spaces.delete(other.id, in: active.profileID))
        let owner = store(in: active)
        XCTAssertTrue(Spaces.delete(active.id, in: active.profileID))
        let url = URL(string: "https://loose.example/")!
        let tab = owner.newBlankTab(focus: false)
        tab.park(url: url, Parked(title: "Loose"))
        let folder = owner.todayShape.newFolder(named: "Loose folder")!
        owner.todayShape.move(tab.id.uuidString, into: folder.id)
        owner.current = tab.id

        let created = owner.newSpace(named: "First")!

        XCTAssertTrue(owner.tabs.contains { $0 === tab })
        XCTAssertEqual(owner.current, tab.id)
        XCTAssertEqual(owner.todayShape.folder(holding: tab.id.uuidString)?.id, folder.id)
        XCTAssertEqual(ProfileManager.shared.spaces(for: active.profileID).first?.tabURLs, [url])
        XCTAssertEqual(owner.currentSpaceID, created.id)
    }

    func testEnteringASpaceCreatedInSettingsPreservesLooseTabs() {
        let (active, other) = spaces()
        XCTAssertTrue(Spaces.delete(other.id, in: active.profileID))
        let owner = store(in: active)
        XCTAssertTrue(Spaces.delete(active.id, in: active.profileID))
        let loose = owner.newBlankTab(focus: false)
        loose.park(url: URL(string: "https://loose-settings.example/")!, Parked(title: "Loose"))
        owner.current = loose.id
        var created = ProfileManager.shared.createSpace(name: "Settings", in: active.profileID)
        created.tabURLs = [URL(string: "https://existing.example/")!]
        XCTAssertTrue(ProfileManager.shared.updateSpace(created))
        owner.resolveStaleSpace()

        XCTAssertTrue(owner.tabs.contains { $0 === loose })
        XCTAssertEqual(owner.current, loose.id)
        XCTAssertEqual(Set(owner.tabs.compactMap(\.pinnedURL)), Set(created.tabURLs + [loose.currentURL!]))
        XCTAssertEqual(ProfileManager.shared.spaces(for: active.profileID).first?.tabURLs.count, 2)
    }
}
