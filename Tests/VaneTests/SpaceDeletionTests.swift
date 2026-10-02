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

    func testRefusingTheLastSpaceKeepsTheCurrentSpace() {
        let (active, other) = spaces()
        XCTAssertTrue(Spaces.delete(other.id, in: active.profileID))
        let owner = store(in: active)
        XCTAssertFalse(Spaces.delete(active.id, in: active.profileID))
        XCTAssertFalse(Spaces.delete(UUID(), in: active.profileID))
        XCTAssertEqual(owner.currentSpaceID, active.id)
        XCTAssertEqual(ProfileManager.shared.spaces(for: active.profileID).map(\.id), [active.id])
    }
}
