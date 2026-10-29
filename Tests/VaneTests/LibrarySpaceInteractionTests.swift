import AppKit
import XCTest
@testable import vane

@MainActor final class LibrarySpaceInteractionTests: XCTestCase {
    private func fixture() -> (TabStore, Space, Space) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Library interactions \(UUID())")
        let first = manager.createSpace(name: "First", in: profile.id)
        let second = manager.createSpace(name: "Second", in: profile.id)
        let store = TabStore(profileID: profile.id, space: first, session: [])
        store.palette = nil
        addTeardownBlock { @MainActor in
            store.libraryOpen = false
            let tabs = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            _ = manager.delete(profile.id)
        }
        return (store, first, second)
    }

    func testGoToSpaceClosesLibraryAndShowsDestination() {
        let (store, _, second) = fixture()
        store.libraryOpen = true
        XCTAssertTrue(Library.show(second, from: store) === store)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertFalse(store.libraryOpen, "The destination must be visible after Go to Space")
    }

    func testGoToCurrentSpaceAlsoClosesLibrary() {
        let (store, first, _) = fixture()
        store.libraryOpen = true
        XCTAssertTrue(Library.show(first, from: store) === store)
        XCTAssertFalse(store.libraryOpen)
    }

    func testDeletedDestinationKeepsLibraryOpen() {
        let (store, first, second) = fixture()
        XCTAssertTrue(ProfileManager.shared.deleteSpace(second.id, in: second.profileID))
        store.libraryOpen = true
        XCTAssertNil(Library.show(second, from: store))
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(store.currentSpaceID, first.id)
    }
    func testCardDropReordersWithinProfileAndPersists() throws {
        let (store, first, second) = fixture()
        let data = SpaceCardDragging.start(first)
        XCTAssertTrue(SpaceCardDragging.accept(data, onto: second, in: store))
        XCTAssertEqual(ProfileManager.shared.spaces(for: first.profileID).map(\.id), [second.id, first.id])
        XCTAssertFalse(SpaceCardDragging.accept(data, onto: second, in: store), "A consumed drag cannot replay")
    }

    func testStaleForeignAndCrossProfileCardDropsDoNotChangeOrder() throws {
        let (store, first, second) = fixture()
        let stale = SpaceCardDragging.start(first)
        let current = SpaceCardDragging.start(second)
        XCTAssertFalse(SpaceCardDragging.accept(stale, onto: second, in: store))
        XCTAssertFalse(SpaceCardDragging.accept(Data("foreign text".utf8), onto: first, in: store))
        XCTAssertEqual(ProfileManager.shared.spaces(for: first.profileID).map(\.id), [first.id, second.id])
        let other = ProfileManager.shared.create(name: "Foreign drag")
        defer { _ = ProfileManager.shared.delete(other.id) }
        let foreign = ProfileManager.shared.createSpace(name: "Foreign", in: other.id)
        XCTAssertFalse(SpaceCardDragging.accept(current, onto: foreign, in: store))
        let deleted = SpaceCardDragging.start(second)
        XCTAssertTrue(ProfileManager.shared.deleteSpace(second.id, in: second.profileID))
        XCTAssertFalse(SpaceCardDragging.accept(deleted, onto: first, in: store))
        XCTAssertEqual(ProfileManager.shared.spaces(for: first.profileID).map(\.id), [first.id])
    }

    func testProfileHopClosesSourceAndReusedDestinationLibraries() async throws {
        let (_, first, _) = fixture()
        let manager = ProfileManager.shared, original = manager.active
        let other = manager.create(name: "Library hop")
        let foreign = manager.createSpace(name: "Foreign", in: other.id)
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy); manager.active = original; _ = manager.delete(other.id) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        let source = Windows.open(space: first, focus: false, session: [])
        let window = try XCTUnwrap(source.window)
        do {
            source.palette = nil
            try await LibraryFocusFixture.admitForeground(window)
            source.libraryOpen = true
            let target = try XCTUnwrap(Library.show(foreign, from: source))
            XCTAssertEqual(target.profileID, other.id)
            XCTAssertFalse(source.libraryOpen)
            XCTAssertFalse(target.libraryOpen)
            // Returning reuses a parked profile whose Library may have been left open.
            source.libraryOpen = true
            target.libraryOpen = true
            XCTAssertTrue(Library.show(first, from: target) === source)
            XCTAssertFalse(source.libraryOpen)
            XCTAssertFalse(target.libraryOpen)
        } catch { failure = error }
        window.orderOut(nil); window.close()
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") } }
        if let failure { throw failure }
    }

}
