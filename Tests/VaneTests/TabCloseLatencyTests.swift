import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Timing is opt-in; the ordinary native fixture verifies the final presentation.
@MainActor final class TabCloseLatencyTests: XCTestCase {
    private func withWindow(count: Int, body: (TabStore, [vane.Tab], NSWindow, NSView) async throws -> Void) async throws {
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let tabs = (0..<count).map { index -> vane.Tab in
            let tab = vane.Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#sidebar-close-\(index)")!, Parked(title: "Close page \(index)"))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        store.current = nil
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared).modifier(NativeFixtureSnapshotReceipt()))
        defer {
            store.spaceGesture.monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let scope = SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID)
        do {
            try await compatibilityWait {
                if !window.isKeyWindow || !window.occlusionState.contains(.visible) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    window.orderFrontRegardless()
                }
                return NativeFixtureMountAdmission.surfaceReady(host, in: window)
                    && window.isKeyWindow && window.occlusionState.contains(.visible)
                    && SidebarNativeReadinessCoordinator.shared.isReady(scope)
            }
        } catch {
            print("TAB_CLOSE_ADMISSION_TIMEOUT count=\(count) key=\(window.isKeyWindow) visible=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) appActive=\(NSApp.isActive) ready=\(SidebarNativeReadinessCoordinator.shared.isReady(scope)) rootWindow=\(host.window === window) bounds=\(host.bounds)")
            throw error
        }
        try await body(store, tabs, window, host)
    }

    private func withLoop(_ body: () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do { try await body() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error }
            else { XCTFail("Tab-close fixture also failed to stop its AppKit loop: \(error)") }
        }
        if let failure { throw failure }
    }

    private func select(_ tab: vane.Tab, in store: TabStore, window: NSWindow, host: NSView) async throws {
        store.current = tab.id
        try await compatibilityWait {
            if !window.isKeyWindow || !window.occlusionState.contains(.visible) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
            }
            host.layoutSubtreeIfNeeded()
            return window.isKeyWindow && window.occlusionState.contains(.visible)
                && store.current == tab.id && tab.existingWeb?.window === window
                && tab.existingWeb?.url != nil && !tab.loading
        }
    }

    private func waitForOutline(_ ids: [String], section: String = "today", in store: TabStore, host: NSView, window: NSWindow) async throws {
#if DEBUG
        let expected = NativeFixtureSnapshotMarker.Snapshot(store: ObjectIdentifier(store), section: section, ids: ids)
        func committed(_ view: NSView) -> Bool {
            if let marker = view as? NativeFixtureSnapshotMarker,
               marker.acknowledges(expected, root: host, window: window) { return true }
            return view.subviews.contains { committed($0) }
        }
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return committed(host)
        }
#endif
    }

    func testActiveCloseCommitsPrunedOutlineAndNeighbourPage() async throws {
        try await withLoop {
            try await withWindow(count: 10) { store, tabs, window, host in
                let folder = Folder(name: "Last child closes")
                store.todayShape = Pins(entries: [.init(row: .folder(folder)),
                    .init(row: .tab(tabs[1].id.uuidString), parent: folder.id)] + tabs.filter { $0 !== tabs[1] }.map {
                        .init(row: .tab($0.id.uuidString))
                    })
                try await select(tabs[1], in: store, window: window, host: host)
                try await waitForOutline(store.todayShape.entries.map(\.id), in: store, host: host, window: window)
                store.close(tabs[1].id)
                XCTAssertNil(tabs[1].existingWeb)
                XCTAssertEqual(store.current, tabs[2].id)
                XCTAssertNil(store.todayShape.folder(folder.id))
                try await compatibilityWait {
                    host.layoutSubtreeIfNeeded()
                    return tabs[2].existingWeb?.window === window
                }
                try await waitForOutline(tabs.filter { $0 !== tabs[1] }.map { $0.id.uuidString },
                                       in: store, host: host, window: window)
                XCTAssertNil(tabs[1].existingWeb, "Later native layout must not resurrect the retired page")
            }
        }
    }

    func testActivePinnedUnloadKeepsRowWithoutRecreatingPage() async throws {
        try await withLoop {
            try await withWindow(count: 10) { store, tabs, window, host in
                let pin = tabs[1]
                pin.kind = .pinned
                store.normaliseSections()
                store.syncShapes()
                try await select(pin, in: store, window: window, host: host)
                try await waitForOutline([pin.id.uuidString], section: "pinned",
                                         in: store, host: host, window: window)
                store.close(pin.id)
                XCTAssertNil(store.current)
                XCTAssertTrue(store.tabs.contains { $0 === pin })
                XCTAssertTrue(pin.suspended)
                XCTAssertFalse(pin.tornDown)
                XCTAssertNil(pin.existingWeb)
                host.layoutSubtreeIfNeeded()
                try await waitForOutline(store.tabs.filter { $0.kind == .today }.map { $0.id.uuidString },
                                       in: store, host: host, window: window)
                XCTAssertNil(pin.existingWeb, "Native layout must not recreate an unloaded pinned page")
            }
        }
    }

    @MainActor private final class WeakPageHost {
        weak var value: WebHost?
        init(_ value: WebHost?) { self.value = value }
    }

    func testActiveSplitPaneCloseDoesNotRecreateRetiredPage() async throws {
        try await withLoop {
            let saver = BatterySaver.shared
            let oldMode = saver.mode
            defer { saver.setMode(oldMode) }
            for mode in [BatterySaver.Mode.off, .alwaysOn] {
                saver.setMode(mode)
                for paneCount in [2, 3] {
                    try await withWindow(count: 10) { store, tabs, window, host in
                        for index in 2...paneCount { store.addPane(tabs[index].id, beside: tabs[1].id) }
                        let closing = tabs[paneCount]
                        try await select(closing, in: store, window: window, host: host)
                        try await compatibilityWait {
                            host.layoutSubtreeIfNeeded()
                            return tabs[1...paneCount].allSatisfy { tab in
                                guard let page = tab.existingWeb, let owner = page.superview as? WebHost else { return false }
                                return !tab.suspended && !tab.loading && page.window === window
                                    && owner.window === window && owner.web === page
                                    && !page.isHiddenOrHasHiddenAncestor && page.visibleRect.width > 1 && page.visibleRect.height > 1
                            }
                        }
                        let owners = Dictionary(uniqueKeysWithValues: tabs[1..<paneCount].map {
                            ($0.id, WeakPageHost($0.existingWeb?.superview as? WebHost))
                        })
                        let visibleIDs = [tabs[0].id, tabs[1].id] + tabs.dropFirst(paneCount + 1).map(\.id)
                        try await waitForOutline(visibleIDs.map(\.uuidString), in: store, host: host, window: window)
                        print("SPLIT_CLOSE_ADMITTED panes=\(paneCount) batterySaver=\(mode.rawValue) systemReduced=\(Motion.spaceReduced)")
                        store.close(closing.id)
                        XCTAssertFalse(store.tabs.contains { $0 === closing })
                        XCTAssertNil(closing.existingWeb)
                        XCTAssertEqual(store.splits.count, paneCount == 2 ? 0 : 1)
                        XCTAssertTrue(tabs[1..<paneCount].contains { $0.id == store.current })
                        do {
                            try await compatibilityWait {
                                host.layoutSubtreeIfNeeded()
                                guard let active = store.active, let page = active.existingWeb,
                                      let owner = page.superview as? WebHost,
                                      owner.window === window, owner.web === page,
                                      page.window === window, !page.isHiddenOrHasHiddenAncestor else { return false }
                                let previous = owners[active.id]?.value
                                // A collapse hands the page to the card, while a larger
                                // split keeps its surviving pane's actual native owner.
                                return paneCount == 2 ? owner !== previous : owner === previous
                            }
                        } catch {
                            print("SPLIT_CLOSE_TIMEOUT panes=\(paneCount) batterySaver=\(mode.rawValue) current=\(String(describing: store.current)) mounted=\(store.active?.existingWeb?.window === window) parent=\(String(describing: store.active?.existingWeb?.superview))")
                            throw error
                        }
                        try await waitForOutline(visibleIDs.map(\.uuidString), in: store, host: host, window: window)
                        XCTAssertNil(closing.existingWeb, "A departing split pane must not recreate its retired page")
                    }
                }
            }
        }
    }

    func testActiveTabCloseTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        try await withLoop {
            for count in [10, 40, 300] {
                try await withWindow(count: count) { store, tabs, window, host in
                    for index in 1...3 {
                        try await select(tabs[index], in: store, window: window, host: host)
                        let start = ProcessInfo.processInfo.systemUptime
                        store.close(tabs[index].id)
                        let handler = ProcessInfo.processInfo.systemUptime - start
                        host.layoutSubtreeIfNeeded()
                        let layout = ProcessInfo.processInfo.systemUptime - start
                        print("ACTIVE_TAB_CLOSE count=\(count) sample=\(index) handler_ms=\(handler * 1000) layout_ms=\(layout * 1000) visible=\(window.occlusionState.contains(.visible))")
                        XCTAssertNil(tabs[index].existingWeb)
                        XCTAssertEqual(store.current, tabs[index + 1].id)
                        // Deliberate spacing between diagnostic samples, after recording
                        // the first layout cost; not an admission or outcome deadline.
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }
    }
}
