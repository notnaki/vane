import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

/// Selecting a tab is the most frequent publication a window makes. It has to reach what
/// draws the selection — the page, the pill, the rows — and nothing else.
@MainActor final class TabSwitchPublicationTests: XCTestCase {
    private func reports(_ view: NSView) -> [any NativeCachedSidebarBatchesReporting] {
        ((view as? any NativeCachedSidebarBatchesReporting).map { [$0] } ?? []) + view.subviews.flatMap(reports)
    }

    private func rootUpdates(_ view: NSView) -> Int {
        reports(view).reduce(0) { $0 + $1.batchCounts.rootUpdates }
    }

    func testSelectionReachesTheStoreAndTheRowsButNotTheChrome() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let tabs = (0..<2).map { index -> vane.Tab in
            let tab = vane.Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#switch-\(index)")!, Parked(title: "Switch \(index)"))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        store.palette = nil
        defer {
            store.dropStashes()
            tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        var window = 0, chrome = 0, rows = 0
        let observations = [
            store.objectWillChange.sink { window += 1 },
            store.chromeObservation.objectWillChange.sink { chrome += 1 },
            store.sidebarObservation.objectWillChange.sink { rows += 1 },
        ]
        defer { observations.forEach { $0.cancel() } }

        store.current = tabs[0].id
        store.selection.clear()
        store.current = tabs[1].id
        XCTAssertEqual(window, 3, "Every existing observer of the window still hears a selection")
        XCTAssertEqual(rows, 3, "Rows draw the selection")
        XCTAssertEqual(chrome, 0, "Chrome that draws no tab must sit out a tab switch")

        store.findOpen.toggle()
        XCTAssertEqual(chrome, 1, "Everything else the window publishes still reaches its chrome")
        store.sidebarShown.toggle()
        XCTAssertGreaterThan(chrome, 1)
        // A selection's own consequences are ordinary publications.
        store.splits = [Split(tabs: tabs.map(\.id))].compactMap { $0?.focusing(tabs[1].id) }
        let before = chrome
        store.current = tabs[0].id
        XCTAssertEqual(store.splits.first?.activeTab, tabs[0].id)
        XCTAssertGreaterThan(chrome, before, "The pane focus a selection moves is not a selection")
    }

    func testSelectingATabLeavesNativeRowOwnersAloneUntilTheirContentChanges() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do { try await checkOwners() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error }
            else { XCTFail("Tab-switch fixture also failed to stop its AppKit loop: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkOwners() async throws {
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let tabs = (0..<6).map { index -> vane.Tab in
            let tab = vane.Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#switch-\(index)")!, Parked(title: "Switch \(index)"))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        // From one tab to another, which is what a switch is: the first page a window
        // shows replaces its empty card, and that is not the case being pinned here.
        store.current = tabs[5].id
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        var added: vane.Tab?
        defer {
            store.spaceGesture.monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            (tabs + [added].compactMap { $0 }).forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let scope = SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID)
        try await compatibilityWait {
            reassertForeground(window)
            host.layoutSubtreeIfNeeded()
            return NativeFixtureMountAdmission.surfaceReady(host, in: window)
                && SidebarNativeReadinessCoordinator.shared.isReady(scope)
                && self.reports(host).contains { $0.attachedLogicalRows == tabs.count }
        }
        // Let the mount's own deferred updates finish before counting. The first switch
        // after a mount still hands the owners their environment once.
        store.current = tabs[4].id
        host.layoutSubtreeIfNeeded()
        var settled = rootUpdates(host)
        try await compatibilityWait {
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            defer { settled = self.rootUpdates(host) }
            return self.rootUpdates(host) == settled
        }

        for tab in [tabs[0], tabs[3], tabs[1]] {
            store.selection.clear()
            store.current = tab.id
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(rootUpdates(host), settled,
                       "A tab switch changes no row's place or content; its rows redraw themselves")

        // The same owners still take a real change to what they hold.
        let tab = vane.Tab(isPrivate: true, profileID: store.profileID)
        tab.park(url: URL(string: "about:blank#switch-added")!, Parked(title: "Switch added"))
        added = tab
        store.tabs.append(tab)
        store.syncShapes()
        host.layoutSubtreeIfNeeded()
        let grown = rootUpdates(host)
        XCTAssertGreaterThan(grown, settled, "A new row must reach its native owner")

        // And an environment change that arrives with no structural change at all: the
        // command bar disables the sidebar, which every row reads. Once the new row has
        // settled, that crosses the native boundary without rebuilding a row.
        settled = rootUpdates(host)
        try await compatibilityWait {
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            defer { settled = self.rootUpdates(host) }
            return self.rootUpdates(host) == settled
        }
        let adoptions = { self.reports(host).reduce(0) { $0 + $1.batchCounts.environmentAdoptions } }
        let adopted = adoptions()
        store.palette = .tabs
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(adoptions(), adopted,
                             "The inherited environment must still cross the native boundary")
        XCTAssertEqual(rootUpdates(host), settled,
                       "Disabling the sidebar changes no row's place or content")
    }
}
