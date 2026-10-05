import AppKit
import XCTest
@testable import vane

@MainActor final class SharedPresentationTests: XCTestCase {
    private class Window: NSWindow {
        var key = false
        var minimized = false
        override var isKeyWindow: Bool { key }
        override var isMiniaturized: Bool { minimized }
    }

    func testVisibleKeyWindowWinsThenVisibleOwnerThenHiddenOwner() {
        withStores { first, second, a, b in
            let tab = Tab(profileID: first.profileID), other = Tab(profileID: first.profileID)
            first.tabs = [tab, other]; second.tabs = [tab, other]
            first.current = tab.id; second.current = tab.id
            tab.presentationOwner = first.windowID
            b.key = true
            SharedTabs.refreshPresentation()
            XCTAssertEqual(tab.presentationOwner, second.windowID)
            let generation = tab.presentationGeneration
            b.key = false
            SharedTabs.refreshPresentation()
            XCTAssertEqual(tab.presentationOwner, second.windowID)
            XCTAssertEqual(tab.presentationGeneration, generation + 1)

            b.minimized = true
            SharedTabs.refreshPresentation()
            XCTAssertEqual(tab.presentationOwner, first.windowID)
            a.minimized = true
            SharedTabs.refreshPresentation()
            XCTAssertEqual(tab.presentationOwner, first.windowID)
            XCTAssertNil(other.existingWeb, "Refreshing ownership must leave background pages parked")
        }
    }

    func testStashDuplicatesDoNotCountAsMultipleWindowsAndIdentityIsPreserved() {
        withStores { first, second, _, _ in
            let tab = Tab(profileID: first.profileID)
            let duplicate = Tab(id: tab.id, profileID: first.profileID)
            first.tabs = [tab]; second.tabs = [duplicate]
            first.stashes[UUID()] = Stash(tabs: [tab], pins: Pins(), todayShape: Pins(),
                                         splits: [], current: nil, fingerprint: "")
            tab.presentationOwner = first.windowID
            tab.windowSnapshot = NSImage(size: NSSize(width: 1, height: 1))
            let generation = duplicate.presentationGeneration
            SharedTabs.refreshPresentation()
            XCTAssertNil(tab.windowSnapshot)
            XCTAssertEqual(tab.presentationOwner, first.windowID)
            XCTAssertEqual(duplicate.presentationGeneration, generation)

            let beforeRelease = tab.presentationGeneration
            SharedTabs.release([tab], excluding: first)
            XCTAssertEqual(tab.presentationGeneration, beforeRelease + 1,
                           "A different object with the same ID must not retain the page")
        }
    }

    func testPageRetainedOnlyInAnotherWindowsStashIsNotReleased() {
        withStores { first, second, _, _ in
            let tab = Tab(profileID: first.profileID)
            first.tabs = [tab]
            second.stashes[UUID()] = Stash(tabs: [tab], pins: Pins(), todayShape: Pins(),
                                          splits: [], current: nil, fingerprint: "")
            let generation = tab.presentationGeneration
            SharedTabs.release([tab], excluding: first)
            XCTAssertEqual(tab.presentationGeneration, generation)
            SharedTabs.refreshPresentation()
            XCTAssertEqual(tab.presentationOwner, first.windowID)
        }
    }

    private func withStores(_ body: (TabStore, TabStore, Window, Window) -> Void) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let first = TabStore(profileID: profile, session: [])
        let second = TabStore(profileID: profile, session: [])
        first.sharingReady = false; second.sharingReady = false
        let a = Window(), b = Window()
        first.window = a; second.window = b
        defer {
            let tabs = first.everyTab + second.everyTab
            first.window = nil; second.window = nil
            TabStore.all.removeAll { $0 === first || $0 === second }
            SharedTabs.release(tabs)
            Store.forget(profile)
        }
        body(first, second, a, b)
    }
}
