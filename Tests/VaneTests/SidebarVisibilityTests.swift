import AppKit
import XCTest
@testable import vane

@MainActor final class SidebarVisibilityTests: XCTestCase {
    func testVisibilityFollowsWindowAcrossNewAndParkedProfiles() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Sidebar first")
        let secondProfile = manager.create(name: "Sidebar second")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let unrelated = Windows.open(profile: secondProfile, space: second, focus: false)
        let window = try XCTUnwrap(source.window)
        let otherWindow = try XCTUnwrap(unrelated.window)
        defer {
            window.close()
            otherWindow.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }

        source.sidebarShown = false
        let destination = try XCTUnwrap(Windows.hop(source, to: second))
        XCTAssertFalse(destination.sidebarShown, "A new profile must keep the window's hidden sidebar")
        XCTAssertTrue(unrelated.sidebarShown, "Another window keeps its own visibility")

        destination.sidebarShown = true
        let returning = try XCTUnwrap(Windows.hop(destination, to: first))
        XCTAssertTrue(returning === source)
        XCTAssertTrue(returning.sidebarShown, "A parked profile must adopt the window's latest visibility")

        returning.sidebarShown = false
        let revisited = try XCTUnwrap(Windows.hop(returning, to: second))
        XCTAssertTrue(revisited === destination)
        XCTAssertFalse(revisited.sidebarShown, "Revisiting a profile must not restore its old shown state")
        XCTAssertTrue(unrelated.sidebarShown)
    }

    func testVisibilitySurvivesSpaceSwitchesWithinOneProfile() {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Sidebar spaces")
        let first = manager.createSpace(name: "First", in: profile.id)
        let second = manager.createSpace(name: "Second", in: profile.id)
        let store = TabStore(profileID: profile.id, space: first, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            _ = manager.delete(profile.id)
        }

        store.sidebarShown = false
        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertFalse(store.sidebarShown)
        store.sidebarShown = true
        store.switchTo(space: first)
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.sidebarShown)
    }
}
