import AppKit
import XCTest
@testable import vane

@MainActor final class LittleArcSpaceMenuTests: XCTestCase {
    private func fixture() -> (TabStore, [Space]) {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let source = manager.create(name: "Little Vane source")
        let other = manager.create(name: "Little Vane destination")
        let spaces = [Space(name: "Menu source", profileID: source.id),
                      Space(name: "Menu sibling", profileID: source.id),
                      Space(name: "Menu destination", profileID: other.id)]
        XCTAssertTrue(manager.saveSpaces(Array(spaces.prefix(2)), for: source.id))
        XCTAssertTrue(manager.saveSpaces([spaces[2]], for: other.id))
        let store = TabStore(profileID: source.id, isLittle: true, session: [])
        addTeardownBlock { @MainActor in
            let owned = TabStore.all.filter { [source.id, other.id].contains($0.profileID) }
            for one in owned {
                one.window?.close()
                one.window = nil
                one.dropStashes()
                let tabs = one.tabs
                TabStore.all.removeAll { $0 === one }
                SharedTabs.release(tabs)
            }
            for profile in [source, other] {
                Store.forget(profile.id)
                _ = manager.delete(profile.id)
            }
        }
        return (store, spaces)
    }

    private func browser(in space: Space) -> (TabStore, NSWindow) {
        let store = TabStore(profileID: space.profileID, space: space, session: [])
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        store.window = window
        return (store, window)
    }

    func testMenuListsEveryProfilesSpacesAndTicksOnlyTheDefaultDestination() {
        let (store, spaces) = fixture()
        UserDefaults.vane.set(spaces[1].id.uuidString, forKey: TabStore.lastSpaceKey(store.profileID))

        let rows = LittleArc.spaceMenu(store).items.filter { $0.title.hasPrefix("Menu ") }

        XCTAssertEqual(rows.map(\.title), ["Menu source", "Menu sibling", "Menu destination"])
        XCTAssertEqual(rows.filter { $0.state == .on }.map(\.title), ["Menu sibling"])
    }

    func testChoosingAnotherProfilesSpaceOpensThePageInItsExistingWindow() throws {
        let (store, spaces) = fixture()
        let (source, sourceWindow) = browser(in: spaces[0])
        let (destination, destinationWindow) = browser(in: spaces[2])
        let url = URL(string: "about:blank")!
        let page = store.newBlankTab()
        page.park(url: url, Parked(title: "Floating page"))
        store.current = page.id
        let menu = LittleArc.spaceMenu(store)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Menu destination" })

        withExtendedLifetime((sourceWindow, destinationWindow)) {
            menu.performActionForItem(at: index)
            XCTAssertEqual(destination.active?.currentURL, url)
            XCTAssertEqual(destination.currentSpaceID, spaces[2].id)
            XCTAssertEqual(destination.active?.profileID, spaces[2].profileID)
            XCTAssertTrue(source.tabs.isEmpty, "The page must not be added to the source profile")
            XCTAssertEqual(source.currentSpaceID, spaces[0].id)
        }
    }

    func testChoosingAnotherProfilesSpaceCreatesAWindowInThatProfile() throws {
        let (store, spaces) = fixture()
        let url = URL(string: "about:blank")!
        let page = store.newBlankTab()
        page.park(url: url, Parked(title: "Floating page"))
        store.current = page.id
        let menu = LittleArc.spaceMenu(store)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Menu destination" })

        menu.performActionForItem(at: index)

        let destination = try XCTUnwrap(Windows.current(in: spaces[2].profileID))
        XCTAssertEqual(destination.currentSpaceID, spaces[2].id)
        XCTAssertEqual(destination.active?.currentURL, url)
        XCTAssertEqual(destination.active?.profileID, spaces[2].profileID)
        XCTAssertEqual(destination.tabs.count, 1, "Creating the window must not duplicate the page")
    }

    func testDeletedDestinationDoesNotSendThePageToAnotherSpace() throws {
        let (store, spaces) = fixture()
        let (source, sourceWindow) = browser(in: spaces[0])
        let page = store.newBlankTab()
        page.park(url: URL(string: "about:blank")!, Parked(title: "Keep this page"))
        store.current = page.id
        let menu = LittleArc.spaceMenu(store)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Menu destination" })
        XCTAssertTrue(ProfileManager.shared.saveSpaces([], for: spaces[2].profileID))

        withExtendedLifetime(sourceWindow) {
            menu.performActionForItem(at: index)
            XCTAssertTrue(source.tabs.isEmpty)
            XCTAssertNil(Windows.current(in: spaces[2].profileID))
            XCTAssertTrue(store.active === page)
        }
    }
}
