import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class Feel01CorePerformanceTests: XCTestCase {
    private class Feel01Window: NSWindow {
        var key = false
        override var isKeyWindow: Bool { key }
    }

    func testSelectionRefreshIncludesBothSplitsAndHandsOutgoingPanesToTheirVisibleWindow() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let space = Space(name: "Split selection", profileID: profile)
        let first = TabStore(profileID: profile, space: space, session: [])
        let second = TabStore(profileID: profile, space: space, session: [])
        first.sharingReady = false; second.sharingReady = false
        let a = Feel01Window(), b = Feel01Window()
        a.key = true
        first.window = a; second.window = b
        let tabs = (0..<5).map { _ in Tab(profileID: profile) }
        let left = try XCTUnwrap(Split(tabs: [tabs[0].id, tabs[1].id]))
        let right = try XCTUnwrap(Split(tabs: [tabs[2].id, tabs[3].id]))
        first.tabs = tabs; second.tabs = tabs
        first.splits = [left, right]; second.splits = [left, right]
        first.current = tabs[0].id; second.current = tabs[0].id
        SharedTabs.refreshPresentation()
        first.sharingReady = true; second.sharingReady = true
        let generations = tabs.map(\.presentationGeneration)
        defer {
            first.window = nil; second.window = nil
            TabStore.all.removeAll { $0 === first || $0 === second }
            SharedTabs.flush()
            SharedTabs.release(tabs)
            Store.forget(profile)
            ExtensionHost.forget(profile)
        }
        first.current = tabs[2].id
        XCTAssertEqual(tabs[0].presentationOwner, second.windowID)
        XCTAssertEqual(tabs[1].presentationOwner, second.windowID)
        XCTAssertEqual(tabs[2].presentationOwner, first.windowID)
        XCTAssertEqual(tabs[3].presentationOwner, first.windowID)
        for index in 0..<4 { XCTAssertEqual(tabs[index].presentationGeneration, generations[index] + 1) }
        XCTAssertEqual(tabs[4].presentationGeneration, generations[4])
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testSelectionDoesNotRevisitUnchangedBackgroundPresentations() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let space = Space(name: "Selection fixture", profileID: profile)
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        let window = NSWindow()
        store.window = window
        let tabs = (0..<500).map { _ in Tab(profileID: profile) }
        store.tabs = tabs
        store.current = tabs[0].id
        SharedTabs.refreshPresentation()
        store.sharingReady = true
        let generations = tabs.map(\.presentationGeneration)
        var backdropPublications = 0
        let observation = store.$lockedFolderBackdrop.dropFirst().sink { _ in backdropPublications += 1 }
        defer {
            store.window = nil
            TabStore.all.removeAll { $0 === store }
            SharedTabs.flush()
            SharedTabs.release(tabs)
            Store.forget(profile)
            ExtensionHost.forget(profile)
        }
        store.current = tabs[1].id
        let revisited = tabs.indices.dropFirst(2).filter { tabs[$0].presentationGeneration != generations[$0] }.count
        XCTAssertEqual(revisited, 0,
                       "Selecting two rows must not rewire or invalidate every parked background row")
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil }, "Blank background rows must not create pages")
        XCTAssertEqual(tabs[1].presentationOwner, store.windowID)
        XCTAssertEqual(backdropPublications, 0, "An absent lock backdrop must not republish on every selection")
        withExtendedLifetime(observation) {}
        print("FEEL01 selection_rows=500 unrelated_presentations_revisited=\(revisited) blank_webviews=\(tabs.filter { $0.existingWeb != nil }.count) backdrop_publications=\(backdropPublications)")
    }

    func testQueuedSharedUpdateDoesNotRetainClosedStore() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        weak var closed: TabStore?
        autoreleasepool {
            let profile = UUID()
            let store = TabStore(profileID: profile, space: Space(name: "Queue fixture", profileID: profile), session: [])
            closed = store
            SharedTabs.schedule(from: store)
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile)
            ExtensionHost.forget(profile)
        }
        XCTAssertNil(closed, "A pending coalesced update must not own a closed store")
        SharedTabs.flush()
    }

    func testManualFlushDoesNotLoseSubsequentUpdatesBeforeQueuedFlushRuns() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let space = Space(name: "Coalescing fixture", profileID: profile)
        let first = TabStore(profileID: profile, space: space, session: [])
        let second = TabStore(profileID: profile, space: space, session: [])
        defer {
            let tabs = first.everyTab + second.everyTab
            TabStore.all.removeAll { $0 === first || $0 === second }
            SharedTabs.flush()
            SharedTabs.release(tabs)
            Store.forget(profile)
            ExtensionHost.forget(profile)
        }
        let one = first.newBlankTab(focus: false), two = first.newBlankTab(focus: false)
        SharedTabs.flush()
        XCTAssertEqual(second.tabs.map(\.id), [one.id, two.id])
        let three = first.newBlankTab(focus: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while second.tabs.count != 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(second.tabs.map(\.id), [one.id, two.id, three.id])
        XCTAssertFalse(first.sharedUpdateQueued)
        XCTAssertTrue(second.tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testDiscardedDockMenuReleasesItsTargetsWhileRetainedMenuStillWorks() throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        weak var discarded: NSObject?
        autoreleasepool {
            let menu = AppLifecycle.shared.applicationDockMenu(app)
            discarded = menu?.items.first?.target as? NSObject
            XCTAssertNotNil(discarded)
        }
        XCTAssertNil(discarded, "Reopening the Dock menu must not accumulate app-lifetime targets")
        let menu = try XCTUnwrap(AppLifecycle.shared.applicationDockMenu(app))
        let target = try XCTUnwrap(menu.items.first?.target as? NSObject)
        _ = AppLifecycle.shared.applicationDockMenu(app)
        XCTAssertTrue(menu.items.first?.target === target, "A menu owns its targets for its whole lifetime")
    }
}
