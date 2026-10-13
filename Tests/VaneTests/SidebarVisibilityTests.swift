import AppKit
import XCTest
@testable import vane

@MainActor final class SidebarVisibilityTests: XCTestCase {
    func testDockingOrHidingEndsTheFloatingRevealImmediately() {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.active.id
        let store = TabStore(profileID: profile, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
        }
        store.sidebarPeeking = true
        store.sidebarShown = false
        XCTAssertFalse(store.sidebarPeeking)
        store.sidebarPeeking = true
        store.sidebarShown = true
        XCTAssertFalse(store.sidebarPeeking)
    }

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
        source.sidebarPeeking = true
        source.switchTo(space: second)
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window && $0.profileID == secondProfile.id })
        XCTAssertEqual(destination.currentSpaceID, second.id)
        XCTAssertFalse(source.sidebarPeeking, "Leaving a profile must dismiss its cached hover sidebar")
        XCTAssertTrue(destination.sidebarPeeking, "The floating sidebar follows the window into a new profile")
        XCTAssertFalse(destination.sidebarShown, "A new profile must keep the window's hidden sidebar")
        XCTAssertTrue(unrelated.sidebarShown, "Another window keeps its own visibility")

        destination.sidebarPeeking = true
        let returning = try XCTUnwrap(Windows.hop(destination, to: first))
        XCTAssertFalse(destination.sidebarPeeking)
        XCTAssertTrue(returning.sidebarPeeking, "The current floating sidebar follows the window into a cached profile")
        XCTAssertTrue(returning === source)
        XCTAssertFalse(returning.sidebarShown, "A parked profile must adopt the window's latest visibility")

        returning.sidebarShown = false
        returning.sidebarPeeking = false
        let revisited = try XCTUnwrap(Windows.hop(returning, to: second))
        XCTAssertTrue(revisited === destination)
        XCTAssertFalse(revisited.sidebarPeeking, "A closed floating sidebar must stay closed when revisiting a profile")
        XCTAssertFalse(revisited.sidebarShown, "Revisiting a profile must not restore its old shown state")
        XCTAssertTrue(unrelated.sidebarShown)

        revisited.sidebarShown = true
        let docked = try XCTUnwrap(Windows.hop(revisited, to: first))
        XCTAssertTrue(docked.sidebarShown, "Docked visibility also follows the window")
        XCTAssertFalse(docked.sidebarPeeking)
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
        store.sidebarPeeking = true
        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertTrue(store.sidebarPeeking, "Switching Spaces must keep the floating sidebar open")
        XCTAssertFalse(store.sidebarShown)
        store.sidebarShown = true
        store.switchTo(space: first)
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.sidebarShown)
    }
}
