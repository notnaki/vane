import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Exercises production outline mounting and the actual keyboard/press modifiers.
/// These are native correctness gates, not frame-rate measurements.
@MainActor final class BufferedSidebarInteractionTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var requested: String?
        var focused: String?
        var activated: [String] = []
    }
    private struct Row: View {
        let id: String
        @ObservedObject var state: State
        var body: some View {
            Text(id).frame(maxWidth: .infinity).frame(height: Look.rowHeight)
                .modifier(Feel02PressFeedback())
                .contentShape(.rect)
                .onTapGesture { state.activated.append(id) }
                .vaneKeyboardAction(requestFocus: Binding(
                    get: { state.requested == id },
                    set: { if !$0 && state.requested == id { state.requested = nil } }),
                    focusChanged: { next in
                        if next { state.focused = id }
                        else if state.focused == id { state.focused = nil }
                    }, action: { state.activated.append(id) })
                .tabTooltip(id, enabled: true)
        }
    }
    private struct Outline: View {
        @ObservedObject var store: TabStore
        let state: State
        let buffered: Bool
        var generation = 0
        @State private var cache = Feel02SidebarRowsCache()
        var body: some View {
            VStack(spacing: 0) {
                SpaceSectionsLayout(animatesCutoffs: false) {
                    Text("Header").frame(height: 30)
                } rows: {
                    SidebarSectionRows(store: store, snapshot: cache.resolve(in: store, shape: store.todayShape),
                                       transition: .opacity) { row, _, _ in Row(id: row.id, state: state) }
                }
                Button("New Tab sentinel") { state.activated.append("new-tab") }
            }.id("\(buffered)-\(generation)")
        }
    }
    @MainActor private struct Fixture {
        let store: TabStore
        let state: State
        let window: NSWindow
        let host: NSHostingView<Outline>
        let scroll: NSScrollView
    }
    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, T.self) }
    }
    private func fixture(buffered: Bool = true) async throws -> Fixture {
        useLegacySidebarMountingPolicy()
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, buffered ? "1" : "0", 1)
        addTeardownBlock {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        store.tabs = (0..<100).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#interaction-\(UUID().uuidString)")!,
                     Parked(title: "Interaction \(index)", needsRecovery: true))
            return tab
        }
        store.syncShapes(); store.palette = nil
        let state = State()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 320),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Outline(store: store, state: state, buffered: buffered))
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes(); SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
            NSApp.setActivationPolicy(policy)
        }
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        return Fixture(store: store, state: state, window: window, host: host, scroll: scroll)
    }
    private func key(_ text: String, code: UInt16, shift: Bool = false, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
    }
    private func anchor(_ id: String, in host: NSView) -> TabTooltipAnchorView? {
        descendants(host, TabTooltipAnchorView.self).first { $0.title == id }
    }

    func testFocusRevealPreservesHorizontalAndAncestorScrollOffsets() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let outerDocument = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
        outer.documentView = outerDocument
        window.contentView = outer
        let inner = NSScrollView(frame: NSRect(x: 100, y: 100, width: 260, height: 320))
        outerDocument.addSubview(inner)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 600,
                                         height: 100 * (Look.rowHeight + Look.rowGap)))
        inner.documentView = anchor
        outer.contentView.scroll(to: NSPoint(x: 17, y: 23))
        inner.contentView.scroll(to: NSPoint(x: 11, y: 0))
        let outerBounds = outer.contentView.bounds
        let viewport = SidebarRowsViewport()
        let ids = (0..<100).map(String.init)
        viewport.configure(rows: ids, anchor: anchor)
        viewport.receive(count: 100, visible: inner.contentView.bounds, clip: inner.contentView)
        viewport.setFocus(true, row: ids[99], owner: UUID())
        try await compatibilityWait { inner.contentView.bounds.minY > 3000 }
        XCTAssertEqual(inner.contentView.bounds.minX, 11, accuracy: 0.01)
        XCTAssertEqual(outer.contentView.bounds, outerBounds,
                       "Sidebar focus reveal must not propagate to an ancestor scrolling surface")
    }

    func testFocusedRowRemainsMountedAcrossScrollAndStillReceivesSpace() async throws {
        let f = try await fixture(), id = f.store.tabs[3].id.uuidString
        f.state.requested = id
        try await compatibilityWait { f.state.focused == id }
        let original = try XCTUnwrap(anchor(id, in: f.host))
        let document = try XCTUnwrap(f.scroll.documentView)
        f.scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - f.scroll.contentView.bounds.height))
        f.scroll.reflectScrolledClipView(f.scroll.contentView)
        try await compatibilityWait { self.anchor(f.store.tabs[98].id.uuidString, in: f.host) != nil }
        XCTAssertTrue(original.window === f.window, "Scroll eviction must retain the focused control")
        XCTAssertEqual(f.state.focused, id)
        try key(" ", code: 49, in: f.window)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.state.activated, [id], "Space must activate the original focus, never New Tab or a recycled row")
        XCTAssertLessThan(descendants(f.host, Feel02PressAnchorView.self).count, 40)
    }

    /// Separate initial buffered focus eligibility from replacement of an old
    /// SwiftUI focus tree. Neither control repairs or forces AppKit's key loop.
    func testFreshBufferedNativeFocusAdvancesBetweenAlreadyMountedRows() async throws {
        let f = try await fixture(buffered: true)
        try await admitFirstNativeStep(f, phase: "fresh-buffered")
    }

    func testEagerNativeFocusAdvancesAfterSameHostSubtreeReplacement() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_DIAG_KEYVIEW_REMOUNT"] == "1",
                          "Opt-in characterization of AppKit traversal after eager subtree replacement")
        let f = try await fixture(buffered: false)
        try await admitFirstNativeStep(f, phase: "eager-before-replacement")
        f.window.makeFirstResponder(nil)
        f.state.requested = nil; f.state.focused = nil; f.state.activated.removeAll()
        f.host.rootView = Outline(store: f.store, state: f.state, buffered: false, generation: 1)
        f.host.layoutSubtreeIfNeeded()
        try await admitFirstNativeStep(f, phase: "eager-after-replacement")
    }

    private func admitFirstNativeStep(_ f: Fixture, phase: String) async throws {
        let ids = f.store.tabs.map { $0.id.uuidString }
        try await compatibilityWait { self.anchor(ids[0], in: f.host)?.window === f.window
            && self.anchor(ids[1], in: f.host)?.window === f.window }
        f.state.requested = ids[0]
        try await compatibilityWait { f.state.focused == ids[0] }
        let before = f.state.activated.count
        try key(" ", code: 49, in: f.window)
        try await compatibilityWait { f.state.activated.count > before }
        XCTAssertEqual(Array(f.state.activated.dropFirst(before)), [ids[0]],
                       "\(phase): native activation must admit the current tree before traversal")
        defer {
            let index = f.state.focused.flatMap { ids.firstIndex(of: $0) }
            let responder = f.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            print("KEY_ADMISSION phase=\(phase) focused_index=\(String(describing: index)) responder=\(responder) mounted=\(descendants(f.host, Feel02PressAnchorView.self).count)")
        }
        f.window.selectNextKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[1] }
        f.window.selectPreviousKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[0] }
    }

    func testNativeKeyViewTraversalRevealsLogicalNeighborsAcrossBufferBoundaries() async throws {
        let f = try await fixture(buffered: false)
        func walk(_ f: Fixture, buffered: Bool, scroll: NSScrollView) async throws {
            let ids = f.store.tabs.map { $0.id.uuidString }
            print("KEYWALK phase=\(buffered ? "buffered" : "eager") start")
            defer {
                let index = f.state.focused.flatMap { ids.firstIndex(of: $0) }
                let responder = f.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                print("KEYWALK_END buffered=\(buffered) focused_index=\(String(describing: index)) responder=\(responder) offset=\(scroll.contentView.bounds.minY)")
            }
            f.state.requested = ids[0]
            try await compatibilityWait { f.state.focused == ids[0] }
            for index in 1...40 {
                print("KEYWALK phase=\(buffered ? "buffered" : "eager") forward=\(index)")
                f.window.selectNextKeyView(nil)
                try await compatibilityWait { f.state.focused == ids[index] }
                let mounted = descendants(f.host, Feel02PressAnchorView.self).count
                XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
                if buffered { XCTAssertLessThan(mounted, 40) }
                else { XCTAssertEqual(mounted, 100, "Eager native keyboard admission must use all logical rows") }
            }
            print("KEYWALK phase=\(buffered ? "buffered" : "eager") forward_done offset=\(scroll.contentView.bounds.minY)")
            if buffered {
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500, "Buffered keyboard focus must reveal offscreen rows")
            }
            for index in stride(from: 39, through: 0, by: -1) {
                print("KEYWALK phase=\(buffered ? "buffered" : "eager") reverse=\(index)")
                f.window.selectPreviousKeyView(nil)
                try await compatibilityWait { f.state.focused == ids[index] }
            }
            try key(" ", code: 49, in: f.window)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(f.state.activated, [ids[0]])
        }
        // Use a fresh host for each policy: eager-to-eager subtree replacement
        // independently fails native traversal, so it cannot admit this comparison.
        try await walk(f, buffered: false, scroll: f.scroll)
        f.window.orderOut(nil)
        let buffered = try await fixture(buffered: true)
        try await walk(buffered, buffered: true, scroll: buffered.scroll)
    }

    func testNativeKeyViewRevealsNeighborAfterWheelMovesAwayFromFocus() async throws {
        do {
        let f = try await fixture(buffered: false)
        let ids = f.store.tabs.map { $0.id.uuidString }
        f.state.requested = ids[0]
        try await compatibilityWait { f.state.focused == ids[0] }
        print("KEY_NEIGHBOR eager admission next")
        f.window.selectNextKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[1] }
        print("KEY_NEIGHBOR eager admission previous")
        f.window.selectPreviousKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[0] }
        f.window.orderOut(nil)
        }
        let f = try await fixture(buffered: true)
        let ids = f.store.tabs.map { $0.id.uuidString }
        let scroll = f.scroll
        f.state.requested = ids[0]
        try await compatibilityWait { f.state.focused == ids[0] }
        let document = try XCTUnwrap(scroll.documentView)
        let farOffset = document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: farOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait { self.anchor(ids[98], in: f.host) != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scroll.contentView.bounds.minY, farOffset, accuracy: 1,
                       "Wheel/viewport changes must not pull back to an unchanged old focus")
        XCTAssertEqual(f.state.focused, ids[0])
        print("KEY_NEIGHBOR buffered far-focus next")
        f.window.selectNextKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[1] }
        try await compatibilityWait {
            guard let row = self.anchor(ids[1], in: f.host) else { return false }
            return row.visibleRect.intersection(row.bounds).height > Look.rowHeight / 2
        }
        XCTAssertLessThan(scroll.contentView.bounds.minY, 100)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        print("KEY_NEIGHBOR buffered previous")
        f.window.selectPreviousKeyView(nil)
        try await compatibilityWait { f.state.focused == ids[0] }
        XCTAssertLessThan(descendants(f.host, Feel02PressAnchorView.self).count, 40)
        XCTAssertNil(f.store.current)
        XCTAssertFalse(f.store.spaceSwiping)
    }

    /// Generated NSEvents are not a proven pointer route in every XCTest host.
    /// Opt-in characterization only; this is not part of the validated native gates.
    func testPressedRowScrollCancelsWithoutActivatingReplacementOrNewTab() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_DIAG_BUFFERED_POINTER"] == "1",
                          "Pointer parity remains unverified; run only with native click admission")
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        // Admit exactly this event route against the eager policy first. Only
        // unavailable eager admission may skip; candidate failures must fail.
        let eager = try await fixture(buffered: false)
        let eagerID = eager.store.tabs[3].id.uuidString
        let eagerRow = try XCTUnwrap(anchor(eagerID, in: eager.host))
        let eagerPoint = eagerRow.convert(NSPoint(x: eagerRow.bounds.midX, y: eagerRow.bounds.midY), to: nil)
        try mouse(.leftMouseDown, at: eagerPoint, in: eager.window)
        try mouse(.leftMouseUp, at: eagerPoint, in: eager.window)
        for _ in 0..<50 where eager.state.activated.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !eager.state.activated.isEmpty else {
            throw XCTSkip("Generated native clicks could not activate an eager row; pointer parity is UNVERIFIED")
        }
        XCTAssertEqual(eager.state.activated, [eagerID])
        eager.window.orderOut(nil)

        let f = try await fixture(), id = f.store.tabs[3].id.uuidString
        let original = try XCTUnwrap(anchor(id, in: f.host))
        let point = original.convert(NSPoint(x: original.bounds.midX, y: original.bounds.midY), to: nil)
        try mouse(.leftMouseDown, at: point, in: f.window)
        try mouse(.leftMouseUp, at: point, in: f.window)
        try await compatibilityWait { f.state.activated == [id] }
        f.state.activated.removeAll()
        try mouse(.leftMouseDown, at: point, in: f.window)
        let document = try XCTUnwrap(f.scroll.documentView)
        f.scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - f.scroll.contentView.bounds.height))
        f.scroll.reflectScrolledClipView(f.scroll.contentView)
        try await compatibilityWait { self.anchor(f.store.tabs[98].id.uuidString, in: f.host) != nil }
        XCTAssertGreaterThan(f.scroll.contentView.bounds.minY, 1000)
        // A clicked row may remain mounted as the keyboard focus owner. Verify
        // cancellation across relocation, not an unproven native-view eviction.
        try mouse(.leftMouseUp, at: point, in: f.window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(f.state.activated.isEmpty, "Release after scroll must cancel, not target a replacement control")
        XCTAssertNil(f.store.current)
        XCTAssertFalse(f.store.spaceSwiping)
    }
}
