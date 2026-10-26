import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel02SidebarTests: XCTestCase {
    private func fixture(count: Int = 8) -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        store.tabs = (0..<count).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#Feel02-\(index)")!,
                     Parked(title: "Fixture \(index)", needsRecovery: true))
            return tab
        }
        store.syncShapes()
        addTeardownBlock { @MainActor in
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return store
    }

    func testSelectionAndMetadataKeepTopologySnapshotAndLiveTab() throws {
        let store = fixture(), cache = Feel02SidebarRowsCache()
        let first = cache.resolve(in: store, shape: store.todayShape)
        store.current = store.tabs[3].id
        store.tabs[0].title = "Updated immediately"
        let next = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertTrue(first === next)
        XCTAssertTrue(next.rows[0].tab === store.tabs[0])
        XCTAssertEqual(next.rows[0].tab?.title, "Updated immediately")
    }

    func testFolderCollapseReversalAndLockGrantInvalidateSnapshot() throws {
        let store = fixture(), cache = Feel02SidebarRowsCache()
        var folder = Folder(name: "Private")
        folder.requiresAuthentication = true
        folder.collapsed = false
        let tab = store.tabs[0]
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        let locked = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertEqual(locked.rows.map(\.id), [folder.id.uuidString])
        let auth = FolderAuthentication { _, reply in reply(true); return nil }
        store.folderAuthentication = auth
        auth.unlock(folder.id, profile: store.profileID, reason: "Test") { _ in }
        let open = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertFalse(locked === open)
        XCTAssertEqual(open.rows.map(\.id), [folder.id.uuidString, tab.id.uuidString])
        store.todayShape.edit(folder: folder.id) { $0.collapsed = true }
        XCTAssertEqual(cache.resolve(in: store, shape: store.todayShape).rows.count, 1)
        store.todayShape.edit(folder: folder.id) { $0.collapsed = false }
        XCTAssertEqual(cache.resolve(in: store, shape: store.todayShape).rows.count, 2)
        auth.lock(folder.id, profile: store.profileID)
        XCTAssertEqual(cache.resolve(in: store, shape: store.todayShape).rows.count, 1)
    }

    func testReorderKindsSplitsAndReplacementKeepExistingRowSemantics() {
        let store = fixture(), cache = Feel02SidebarRowsCache()
        let tabs = store.tabs
        store.splits = [Split(tabs: [tabs[0].id, tabs[1].id])!]
        func assertParity() {
            let actual = cache.resolve(in: store, shape: store.todayShape).rows
            let expected = SidebarRows(tabs: store.accessibleTabs, splits: store.splits,
                                      shape: store.todayShape, unlocked: store.unlockedFolders).rows
            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
            XCTAssertEqual(actual.map(\.visible.depth), expected.map(\.visible.depth))
            XCTAssertTrue(zip(actual, expected).allSatisfy { $0.tab === $1.tab })
        }
        assertParity()
        store.tabs.swapAt(0, 1)
        assertParity()
        store.tabs[0].kind = .favourite
        assertParity()
        store.splits = []
        assertParity()
        let old = cache.resolve(in: store, shape: store.todayShape)
        let replacement = Tab(id: tabs[0].id, profileID: store.profileID)
        store.tabs[1] = replacement
        let next = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertFalse(old === next)
        assertParity()
    }

    func testPopulatedSelectionKeepsSnapshotWithoutCreatingWebViews() {
        let store = fixture(count: 300), cache = Feel02SidebarRowsCache()
        let initial = cache.resolve(in: store, shape: store.todayShape)
        for index in [0, 299, 1, 298, 2, 297, 0] {
            store.current = store.tabs[index].id
            store.tabs[index].title = "Selected \(index)"
            XCTAssertTrue(cache.resolve(in: store, shape: store.todayShape) === initial)
        }
        XCTAssertEqual(initial.rows.count, 300)
        XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testStashedLockChangesCannotReuseAccessibleRows() {
        let store = fixture(), cache = Feel02SidebarRowsCache()
        let tab = store.tabs[0]
        // Corrupt/restored duplicate membership follows the existing accessibleTabs
        // rule: if no live shape owns an ID, a stashed protected shape can hide it.
        let standalone = Pins(entries: [.init(row: .tab(tab.id.uuidString))])
        store.todayShape = Pins()
        let open = cache.resolve(in: store, shape: standalone)
        XCTAssertEqual(open.rows.count, 1)
        var folder = Folder(name: "Protected")
        folder.requiresAuthentication = true
        let stashID = UUID()
        store.stashes[stashID] = Stash(tabs: [], pins: Pins(entries: [
            .init(row: .folder(folder)), .init(row: .tab(tab.id.uuidString), parent: folder.id)
        ]), todayShape: Pins(), splits: [], current: nil, fingerprint: "")
        let closed = cache.resolve(in: store, shape: standalone)
        XCTAssertFalse(open === closed)
        XCTAssertTrue(closed.rows.isEmpty)
        store.stashes.removeValue(forKey: stashID)
        XCTAssertEqual(cache.resolve(in: store, shape: standalone).rows.count, 1)
    }

    func testRetainedOutlineKeepsNestedDisclosureAndExcludesLockedContent() throws {
        let store = fixture(), cache = Feel02SidebarRowsCache()
        var outer = Folder(name: "Outer", collapsed: true)
        let inner = Folder(name: "Inner", collapsed: true)
        var locked = Folder(name: "Locked", collapsed: true)
        locked.requiresAuthentication = true
        let tabs = store.tabs
        store.todayShape = Pins(entries: [
            .init(row: .folder(outer)),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(tabs[0].id.uuidString), parent: inner.id),
            .init(row: .folder(locked), parent: outer.id),
            .init(row: .tab(tabs[1].id.uuidString), parent: locked.id),
            .init(row: .tab(tabs[2].id.uuidString))
        ])
        let closed = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertEqual(closed.rows.map(\.id), [outer.id.uuidString, tabs[2].id.uuidString])
        let retained = try XCTUnwrap(closed.retainedRows)
        XCTAssertEqual(retained.map(\.id), [outer.id.uuidString, inner.id.uuidString,
            tabs[0].id.uuidString, locked.id.uuidString, tabs[2].id.uuidString])
        XCTAssertEqual(retained.map(\.visible.depth), [0, 1, 2, 1, 0])
        XCTAssertTrue(retained[1].visible.entry.folder?.collapsed == true)
        outer.collapsed = false
        store.todayShape.edit(folder: outer.id) { $0 = outer }
        XCTAssertEqual(cache.resolve(in: store, shape: store.todayShape).rows.map(\.id),
            [outer.id.uuidString, inner.id.uuidString, locked.id.uuidString, tabs[2].id.uuidString])
    }

    func testLargeCollapsedOutlineDoesNotRetainOffscreenControls() {
        let store = fixture(count: 300), cache = Feel02SidebarRowsCache()
        let folder = Folder(name: "Large", collapsed: true)
        store.todayShape = Pins(entries: [.init(row: .folder(folder))] + store.tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        let snapshot = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertEqual(snapshot.rows.map(\.id), [folder.id.uuidString])
        XCTAssertNil(snapshot.retainedRows)
    }

    func testLiveResizePublishesOnlyChangedClampedWidth() {
        let sidebar = SidebarWidth()
        sidebar.width = SidebarWidth.maximum
        var values: [CGFloat] = []
        let observation = sidebar.$width.dropFirst().sink { values.append($0) }
        sidebar.setLiveWidth(900)
        sidebar.setLiveWidth(800)
        XCTAssertTrue(values.isEmpty, "Clamped pointer movement must not dirty the whole window")
        sidebar.setLiveWidth(320)
        sidebar.setLiveWidth(320)
        XCTAssertEqual(values, [320])
        withExtendedLifetime(observation) {}
    }
}

@MainActor final class Feel02PressTests: XCTestCase {
    func testNativeHoverExitPreservesPressUntilMouseUp() async throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(anchor)
        let monitor = Feel02PressMonitor()
        var pressed = false, hovered = false
        anchor.changed = { pressed = $0 }
        anchor.hoverChanged = { hovered = $0 }
        monitor.register(anchor)
        defer { monitor.remove(anchor); window.close() }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        _ = monitor.handle(try event(.mouseMoved))
        XCTAssertTrue(hovered)
        _ = monitor.handle(try event(.leftMouseDown))
        XCTAssertTrue(pressed)
        anchor.updateTrackingAreas()
        let area = try XCTUnwrap(anchor.trackingAreas.first { $0.owner === anchor })
        XCTAssertFalse(window.isKeyWindow, "The fixture exercises admitted hover in a non-key window")
        XCTAssertTrue(area.options.contains(.activeAlways),
                      "Exit observation must remain active in non-key windows that admit pointer motion")
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited,
            location: NSPoint(x: -20, y: -20), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exitOwner = try XCTUnwrap(area.owner as? NSResponder)
        exitOwner.mouseExited(with: exit)
        try await compatibilityWait { !hovered }
        XCTAssertTrue(pressed, "Hover exit must leave mouse-up and drag ownership unchanged")
        _ = monitor.handle(try event(.leftMouseUp))
        XCTAssertFalse(pressed)
        anchor.hoverChanged = nil
        XCTAssertTrue(anchor.trackingAreas.isEmpty, "Press-only controls do not need hover tracking")
    }

    func testDisclosureOrDisableCancelsAnOutstandingPress() throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.frame)
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(anchor)
        let monitor = Feel02PressMonitor()
        var pressed = false
        anchor.changed = { pressed = $0 }
        monitor.register(anchor)
        defer { monitor.remove(anchor); window.close() }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        _ = monitor.handle(down)
        XCTAssertTrue(pressed)
        anchor.enabled = false
        XCTAssertFalse(pressed, "A folded row must not keep a held decoration")
        anchor.enabled = true
        _ = monitor.handle(down)
        XCTAssertTrue(pressed)
        anchor.setFrameOrigin(NSPoint(x: 0, y: 70))
        XCTAssertFalse(pressed, "Moving rows underneath the pointer must cancel the old press")
    }

    func testPassivePressReturnsEventsAndCancelsOnDragReleaseAndDetach() throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = Feel02PressAnchorView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let monitor = Feel02PressMonitor()
        var pressed = false
        anchor.changed = { pressed = $0 }
        monitor.register(anchor)
        defer { monitor.remove(anchor); window.close() }
        func event(_ type: NSEvent.EventType, x: CGFloat = 10) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 10),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown)
        XCTAssertTrue(down.window === window, "Synthetic input must belong to the registered fixture window")
        XCTAssertTrue(monitor.handle(down) === down, "Feedback must never consume activation")
        XCTAssertTrue(pressed, "Feedback starts before a click action")
        _ = monitor.handle(try event(.leftMouseDragged, x: 40))
        XCTAssertFalse(pressed, "A native drag must not leave a stuck press")
        _ = monitor.handle(down)
        _ = monitor.handle(try event(.leftMouseUp))
        XCTAssertFalse(pressed)
        _ = monitor.handle(down)
        monitor.remove(anchor)
        XCTAssertFalse(pressed)
    }

    func testSpacePreviewRowsNeverRegisterInteractivePressTargets() async throws {
        TestEnvironment.prepare()
        let space = Space(name: "Inert preview", profileID: ProfileManager.shared.active.id,
                          tabURLs: [URL(string: "about:blank#preview")!])
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        let host = NSHostingView(rootView: preview.frame(width: 228, height: 400))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 228, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func targets(in view: NSView) -> [Feel02PressAnchorView] {
            (view as? Feel02PressAnchorView).map { [$0] } ?? view.subviews.flatMap { targets(in: $0) }
        }
        let anchors = targets(in: host)
        XCTAssertTrue(anchors.isEmpty,
                      "Inert Space previews must not allocate native press targets or register them with the monitor")
    }

    func testDisabledHiddenAndOtherWindowAnchorsDoNotPress() throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = Feel02PressAnchorView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView = anchor
        window.orderFront(nil)
        let monitor = Feel02PressMonitor()
        var pressed = false
        anchor.changed = { pressed = $0 }
        monitor.register(anchor)
        defer { monitor.remove(anchor); window.close() }
        func down(windowNumber: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let ownedDown = try down(windowNumber: window.windowNumber)
        XCTAssertTrue(ownedDown.window === window, "The disabled/hidden checks require an associated event")
        anchor.enabled = false
        _ = monitor.handle(ownedDown)
        XCTAssertFalse(pressed)
        anchor.enabled = true
        anchor.isHidden = true
        _ = monitor.handle(ownedDown)
        XCTAssertFalse(pressed)
        anchor.isHidden = false
        _ = monitor.handle(try down(windowNumber: 0))
        XCTAssertFalse(pressed)
    }
}

@MainActor final class Feel02NativeRowTests: XCTestCase {
    func testPointerClicksAndTrailingButtonKeepTheirExistingActivation() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var selected = 0, closed = 0
        let row = SidebarRow(selected: false, action: { selected += 1 }) {
            Image(systemName: "globe")
        } label: {
            Text("Pointer fixture")
        } trailing: {
            Button { closed += 1 } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                .buttonStyle(.plain)
        }
        let host = Feel02FirstMouseHostingView(rootView: row.frame(width: 300, height: 44))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 44),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func send(_ type: NSEvent.EventType, x: CGFloat) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: x, y: 22), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
        try send(.leftMouseDown, x: 60)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, 0, "Pointer feedback must not invoke the row early")
        try send(.leftMouseUp, x: 60)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, 1, "Adding feedback must not consume or postpone a normal click")
        try send(.leftMouseDown, x: 276)
        try await Task.sleep(for: .milliseconds(50))
        try send(.leftMouseUp, x: 276)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(closed, 1, "A child control retains its own activation")
        XCTAssertEqual(selected, 1, "Closing must not also select the row")
    }
}

@MainActor final class Feel02MotionIdentityTests: XCTestCase {
    func testBatterySaverChangesDuringFolderReversalsKeepInlineFocusAndRowAnchor() async throws {
        TestEnvironment.prepare()
        let policy = Feel02PolicyFixture()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let host = NSHostingView(rootView: Feel02PolicyRow(fixture: policy))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 44),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let field = try XCTUnwrap(find(NSTextField.self, in: host))
        let anchor = try XCTUnwrap(find(Feel02PressAnchorView.self, in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let focused = try XCTUnwrap(window.firstResponder)
        for saving in [true, false, true] {
            Motion.animate(Look.quick) { policy.collapsed.toggle() }
            BatterySaver.shared.setMode(saving ? .alwaysOn : .off)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            XCTAssertTrue(find(Feel02PressAnchorView.self, in: host) === anchor,
                          "Policy changes may replace decoration, never the row target")
            XCTAssertTrue(window.firstResponder === focused, "An inline editor must retain keyboard focus")
            XCTAssertEqual(field.stringValue, "Editable fixture")
        }
    }
}

@MainActor private final class Feel02PolicyFixture: ObservableObject {
    @Published var collapsed = true
    @Published var title = "Editable fixture"
}

private struct Feel02PolicyRow: View {
    @ObservedObject var fixture: Feel02PolicyFixture
    var body: some View {
        var folder = Folder(name: "Fixture")
        folder.collapsed = fixture.collapsed
        return SidebarRow(selected: false, action: {}) {
            FolderDisclosure(folder: folder, locked: false)
        } label: {
            TextField("Fixture", text: $fixture.title)
        } trailing: { EmptyView() }
        .frame(width: 300, height: 44)
        .vaneMotionPolicy()
    }
}

private final class Feel02FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
