import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Opt-in diagnostics, deliberately without wall-clock assertions in routine CI.
@MainActor final class SidebarPresentationPerformanceTests: XCTestCase {
    func testPopulatedSidebarPresentation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        print("SIDEBAR_PERF policy reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) batterySaver=\(BatterySaver.shared.isActive)")
        // Discard framework/singleton warmup before comparing small and large Spaces.
        let interactiveCount = ProcessInfo.processInfo.environment["VANE_SIDEBAR_INTERACTIVE"].flatMap(Int.init)
        if interactiveCount == nil {
            try XCTSkipUnless(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !BatterySaver.shared.isActive,
                              "Collect reduced-motion policies separately from the full-motion baseline")
        }
        for count in interactiveCount.map({ [2, $0] }) ?? [2, 20, 300] {
            let profile = ProfileManager.shared.create(name: "Sidebar performance fixture").id
            print("SIDEBAR_FIXTURE_STORE \(ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: Store.overrideDirectory)!)")
            let space = Space(name: "Presentation fixture", profileID: profile)
            let neighbour = Space(name: "Neighbour fixture", profileID: profile)
            XCTAssertTrue(ProfileManager.shared.saveSpaces([space, neighbour], for: profile))
            let store = TabStore(profileID: profile, space: space, session: [])
            // Isolate rendering from asynchronous shared-state/persistence work.
            store.sharingReady = false
            store.palette = nil
            Tab.discardPreparedFirstPage(for: profile)
            let tabs = (0..<count).map { index in
                let tab = Tab(profileID: profile)
                tab.kind = index < max(2, count / 3) ? .pinned : .today
                if index < 2 {
                    // Selection measures row presentation with an inert recovery page.
                    tab.park(url: URL(string: "about:blank#selection-\(index)")!,
                             Parked(title: "Fixture \(index)", needsRecovery: true))
                } else {
                    // No host means favicon lookup cannot start a network request.
                    tab.park(url: URL(string: "about:blank#fixture-\(index)")!, Parked(title: "Fixture \(index)"))
                }
                return tab
            }
            store.tabs = tabs
            store.syncShapes()
            let expectedToday = tabs.filter { $0.kind == .today }.count
            XCTAssertEqual(store.tabs.count, count)
            XCTAssertEqual(store.todayShape.entries.count, expectedToday)
            let bounds = NSRect(x: 0, y: 0, width: 900, height: 700)
            let window = VaneWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            // Occluded SwiftUI windows can defer work. Keep both timing versions
            // visible while other desktop apps are used; interactive checks stay normal.
            if interactiveCount == nil { window.level = .floating }
            window.title = "Sidebar performance fixture \(count)"
            store.window = window
            let mountStart = ProcessInfo.processInfo.systemUptime
            let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
                .environmentObject(ProfileManager.shared).frame(width: 900, height: 700))
            host.frame = bounds
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            print("SIDEBAR_PERF count=\(count) operation=mount ms=\((ProcessInfo.processInfo.systemUptime - mountStart) * 1000)")
            defer {
                store.spaceGesture.monitor.remove()
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
                _ = ProfileManager.shared.delete(profile)
            }
            if count == interactiveCount {
                let incoming = tabs.enumerated().map { index, original in
                    let tab = Tab(profileID: profile)
                    tab.kind = original.kind
                    tab.park(url: URL(string: "about:blank#incoming-\(index)")!,
                             Parked(title: "Incoming \(index)", needsRecovery: true))
                    return tab
                }
                store.stashes[neighbour.id] = Stash(tabs: incoming,
                    pins: Pins(entries: incoming.filter { $0.kind == .pinned }.map {
                        .init(row: .tab($0.id.uuidString))
                    }), todayShape: Pins(entries: incoming.filter { $0.kind == .today }.map {
                        .init(row: .tab($0.id.uuidString))
                    }), splits: [], current: incoming[0].id,
                    fingerprint: store.fingerprint(of: neighbour.id))
                try await Task.sleep(for: .seconds(1))
                print("SIDEBAR_INTERACTIVE_READY count=\(count) window=\(window.windowNumber)")
                try await Task.sleep(for: .seconds(240))
                continue
            }
            if ProcessInfo.processInfo.environment["VANE_SIDEBAR_PREFLIGHT"] == "1" {
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(store.tabs.count, count)
                XCTAssertEqual(store.todayShape.entries.count, expectedToday)
                XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
                XCTAssertTrue(window.occlusionState.contains(.visible), "Preflight requires a visible native window")
                if count == 300 && ProcessInfo.processInfo.environment["VANE_SIDEBAR_REALIZATION_CHECK"] == "1" {
                    func mountedRows(in view: NSView) -> Int {
                        let row = (view as? TabTooltipAnchorView)?.title.hasPrefix("Fixture ") == true ? 1 : 0
                        return row + view.subviews.reduce(0) { $0 + mountedRows(in: $1) }
                    }
                    let mounted = mountedRows(in: host)
                    print("SIDEBAR_REALIZED_ROWS count=\(count) mounted=\(mounted)")
                    XCTAssertTrue(mounted > 0, "The diagnostic must find real native tab anchors")
                }
                print("SIDEBAR_PREFLIGHT count=\(count) rows=\(store.pins.entries.count + store.todayShape.entries.count)")
                continue
            }
            if count == 2 { continue }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(window.occlusionState.contains(.visible), "Measurements require a visible native window")
            let heartbeat = SidebarRunLoopProbe()
            defer { heartbeat.stop() }

            func measure(_ name: String, repeats: Int = 5, settlePreparation: Bool = false,
                         prepare: () -> Void = {},
                         _ action: () -> Void) async throws {
                var times: [Double] = []
                var gaps: [Double] = []
                try await Task.sleep(for: .milliseconds(400))
                for _ in 0..<repeats {
                    prepare()
                    if settlePreparation { try await Task.sleep(for: .milliseconds(400)) }
                    XCTAssertTrue(window.occlusionState.contains(.visible), "Discard measurements from an occluded window")
                    heartbeat.reset()
                    let start = ProcessInfo.processInfo.systemUptime
                    action()
                    times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    try await Task.sleep(for: .milliseconds(400))
                    gaps.append(heartbeat.observedGap * 1000)
                }
                times.sort()
                gaps.sort()
                print("SIDEBAR_PERF count=\(count) live=\(store.tabs.count) today=\(store.todayShape.entries.count) operation=\(name) median_ms=\(times[times.count / 2]) max_ms=\(times.last!) median_gap_ms=\(gaps[gaps.count / 2]) max_gap_ms=\(gaps.last!)")
            }
            try await measure("accessibleTabs") { XCTAssertEqual(store.accessibleTabs.count, count) }
            try await measure("rows") {
                let pinned = SidebarRows(tabs: store.accessibleTabs, splits: store.splits, shape: store.pins).rows
                let today = SidebarRows(tabs: store.accessibleTabs, splits: store.splits, shape: store.todayShape).rows
                XCTAssertEqual(pinned.count + today.count, count)
            }
            try await measure("selection-recovery-layout") {
                store.current = store.current == tabs[0].id ? tabs[1].id : tabs[0].id
                host.layoutSubtreeIfNeeded()
            }
            store.current = nil
            let originalToday = store.todayShape
            var appended: vane.Tab?
            func restoreRows() {
                store.tabs = tabs
                store.todayShape = originalToday
                host.layoutSubtreeIfNeeded()
                appended?.tearDown()
                appended = nil
            }
            try await measure("append-ui-layout", settlePreparation: true, prepare: restoreRows) {
                let tab = Tab(profileID: profile)
                appended = tab
                Motion.list {
                    store.tabs.append(tab)
                    store.todayShape.entries.append(.init(row: .tab(tab.id.uuidString)))
                }
                host.layoutSubtreeIfNeeded()
            }
            restoreRows()
            try await measure("remove-ui-layout", settlePreparation: true, prepare: restoreRows) {
                let tab = store.tabs.last!
                Motion.list {
                    store.tabs.removeLast()
                    store.todayShape.entries.removeAll { $0.tab == tab.id.uuidString }
                }
                host.layoutSubtreeIfNeeded()
            }
            restoreRows()
            XCTAssertEqual(store.tabs.count, count)
            XCTAssertEqual(store.todayShape.entries.count, expectedToday)
            try await measure("reorder-layout") {
                guard store.todayShape.entries.count > 1 else { XCTFail("Fixture lost Today rows"); return }
                Motion.list {
                    store.todayShape.entries.swapAt(0, 1)
                    store.applyOrder(.today)
                }
                host.layoutSubtreeIfNeeded()
            }
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            let scroll = try XCTUnwrap(scrollView(in: host))
            var offset = CGFloat(0)
            try await measure("scroll-layout", repeats: 10) {
                offset += 15
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
            }
            // Match the existing preview regression fixture's opaque-state size per tab.
            // Preview labels must not repeatedly pay to decode unrelated page state.
            let parked = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
                tab.currentURL.map { ($0.absoluteString, Parked(title: tab.title,
                    state: Data(repeating: 42, count: 16_384))) }
            })
            XCTAssertTrue(Suspension.SpaceState.save(parked, space: neighbour.id,
                profileID: profile, in: Store.directory))
            let snapshot = SpacePreviewList(space: neighbour, liveTabs: store.tabs,
                state: Stash(tabs: store.tabs, pins: store.pins, todayShape: store.todayShape,
                             splits: [], current: store.current, fingerprint: ""), renderStore: store)
            try await measure("preview-capture") {
                let preview = SpacePreviewList(space: neighbour, liveTabs: store.tabs,
                    state: Stash(tabs: store.tabs, pins: store.pins, todayShape: store.todayShape,
                                 splits: [], current: store.current, fingerprint: ""), renderStore: store)
                XCTAssertEqual(preview.rows.pinned.count + preview.rows.today.count, count)
            }
            var diskNeighbour = neighbour
            diskNeighbour.tabURLs = tabs.filter { $0.kind == .today }.compactMap(\.currentURL)
            diskNeighbour.pinnedTabURLs = tabs.filter { $0.kind == .pinned }.compactMap(\.pinnedURL)
            try await measure("disk-preview-capture") {
                let preview = SpacePreviewList(space: diskNeighbour, liveTabs: nil)
                XCTAssertEqual(preview.rows.pinned.count + preview.rows.today.count, count)
            }
            try await measure("cached-preview-body", repeats: 10) { _ = snapshot.body }
            store.spaceGesture.neighbour = neighbour
            store.spaceGesture.previewDirection = 1
            store.spaceGesture.previews[neighbour.id] = snapshot
            try await measure("preview-mount-layout", repeats: 3, settlePreparation: true, prepare: {
                store.spaceGesture.swiping = false
                host.layoutSubtreeIfNeeded()
            }) {
                store.spaceGesture.swiping = true
                host.layoutSubtreeIfNeeded()
            }
            var drag = CGFloat(0)
            try await measure("swipe-frame-layout", repeats: 10) {
                drag -= 10
                store.spaceGesture.drag = drag
                host.layoutSubtreeIfNeeded()
            }
            store.spaceGesture.drag = 0
            store.spaceGesture.swiping = false
            store.spaceGesture.previews.removeAll()
            try await measure("sidebar-reveal-layout", settlePreparation: true, prepare: {
                store.sidebarShown = false
                host.layoutSubtreeIfNeeded()
            }) {
                store.sidebarShown = true
                host.layoutSubtreeIfNeeded()
            }
            // A populated live stash exercises the supported Space commit without page loading.
            let incoming = tabs.enumerated().map { index, original in
                let tab = Tab(profileID: profile)
                tab.kind = original.kind
                tab.park(url: URL(string: "about:blank#incoming-\(index)")!,
                         Parked(title: "Incoming \(index)", needsRecovery: true))
                return tab
            }
            let incomingPins = Pins(entries: incoming.filter { $0.kind == .pinned }.map {
                .init(row: .tab($0.id.uuidString))
            })
            let incomingToday = Pins(entries: incoming.filter { $0.kind == .today }.map {
                .init(row: .tab($0.id.uuidString))
            })
            store.current = tabs[0].id
            store.stashes[neighbour.id] = Stash(tabs: incoming, pins: incomingPins,
                todayShape: incomingToday, splits: [], current: incoming[0].id,
                fingerprint: store.fingerprint(of: neighbour.id))
            try await measure("cached-space-switch-recovery-layout") {
                let target = store.currentSpaceID == space.id ? neighbour : space
                store.switchTo(space: target)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(store.currentSpaceID, target.id)
                XCTAssertEqual(store.tabs.count, count)
                XCTAssertEqual(store.todayShape.entries.count, expectedToday)
            }
            XCTAssertEqual(store.tabs.count, count)
            XCTAssertEqual(store.todayShape.entries.count, expectedToday)
            XCTAssertTrue(store.everyTab.allSatisfy { $0.existingWeb == nil })
        }
    }
}

/// A diagnostic heartbeat includes deferred graph work and animation frames.
@MainActor private final class SidebarRunLoopProbe {
    private var timer: Timer?
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maxGap: Double = 0
    var observedGap: Double { max(maxGap, ProcessInfo.processInfo.systemUptime - last) }

    init() {
        timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func reset() { last = ProcessInfo.processInfo.systemUptime; maxGap = 0 }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maxGap = max(maxGap, now - last)
        last = now
    }
}
