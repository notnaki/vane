import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class RetainedRowVirtualizationTests: XCTestCase {
    private final class WeakControl {
        weak var view: NSButton?
        init(_ view: NSButton) { self.view = view }
    }
    private final class Controls {
        var byID: [String: WeakControl] = [:]
    }
    private struct Control: NSViewRepresentable {
        let id: String
        let controls: Controls
        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: id, target: nil, action: nil)
            controls.byID[id] = WeakControl(button)
            return button
        }
        func updateNSView(_ button: NSButton, context: Context) {
            button.isEnabled = context.environment.isEnabled
        }
    }
    private struct Outline: View {
        @ObservedObject var store: TabStore
        let controls: Controls
        @State private var cache = Feel02SidebarRowsCache()
        var body: some View {
            ScrollView {
                // Keep the production small-outline outer eager stack unchanged.
                VStack(spacing: 0) {
                    SidebarSectionRows(store: store, snapshot: cache.resolve(in: store, shape: store.todayShape),
                                       transition: .opacity) { row, _, _ in
                        Control(id: row.id, controls: controls)
                    }
                }
            }
        }
    }

    private func fixture(count: Int) -> TabStore {
        TestEnvironment.prepare()
        let previous = RetainedRowVirtualizationExperiment.enabled
        RetainedRowVirtualizationExperiment.enabled = true
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        let fixtureID = UUID().uuidString
        store.tabs = (0..<count).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#retention-\(fixtureID)-\(index)")!, Parked(title: "Row \(index)"))
            return tab
        }
        store.syncShapes()
        addTeardownBlock { @MainActor in
            RetainedRowVirtualizationExperiment.enabled = previous
            store.tabs.forEach { TidyTitles.rename($0, to: nil) }
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return store
    }

    private func mount(_ store: TabStore, controls: Controls, height: CGFloat = 180) -> NSHostingView<Outline> {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Outline(store: store, controls: controls))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        return host
    }

    func testVisibleFolderKeepsIdentityAndCollapsedChildrenCannotReceiveInput() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 3), controls = Controls()
        let folder = Folder(name: "Folder")
        let child = store.tabs[0].id.uuidString
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(child), parent: folder.id),
            .init(row: .tab(store.tabs[1].id.uuidString))])
        let host = mount(store, controls: controls)
        try await compatibilityWait { controls.byID[child]?.view != nil }
        let folderControl = try XCTUnwrap(controls.byID[folder.id.uuidString]?.view)
        let childControl = try XCTUnwrap(controls.byID[child]?.view)
        Motion.spaceHandoff { store.todayShape.edit(folder: folder.id) { $0.collapsed = true } }
        try await compatibilityWait {
            childControl.window == nil || childControl.isHiddenOrHasHiddenAncestor || !childControl.isEnabled
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === folderControl)
        if childControl.window != nil {
            XCTAssertTrue(childControl.isHiddenOrHasHiddenAncestor || !childControl.isEnabled)
            XCTAssertLessThanOrEqual(childControl.visibleRect.intersection(childControl.bounds).height, 0.5)
            let formerCenter = childControl.convert(NSPoint(x: childControl.bounds.midX,
                                                           y: childControl.bounds.midY), to: host)
            XCTAssertFalse(host.hitTest(formerCenter) === childControl,
                           "A cached collapsed control must not receive pointer input")
        }
        Motion.spaceHandoff { store.todayShape.edit(folder: folder.id) { $0.collapsed = false } }
        try await compatibilityWait {
            guard let reopened = controls.byID[child]?.view else { return false }
            return reopened.isEnabled && reopened.window != nil && !reopened.isHiddenOrHasHiddenAncestor
                && reopened.visibleRect.intersection(reopened.bounds).height > 1
        }
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === folderControl)
        let reopened = try XCTUnwrap(controls.byID[child]?.view)
        XCTAssertTrue(reopened.isEnabled)
        XCTAssertNotNil(reopened.window)
        XCTAssertGreaterThan(reopened.visibleRect.intersection(reopened.bounds).height, 1,
                             "A reopened child must be a visible, usable control; it may be remounted")
    }

    func testRetainedTopologyStillExcludesLockedChildren() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 3), controls = Controls()
        var folder = Folder(name: "Locked", collapsed: true)
        folder.requiresAuthentication = true
        let child = store.tabs[0].id.uuidString
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(child), parent: folder.id)])
        let host = mount(store, controls: controls)
        try await compatibilityWait { controls.byID[folder.id.uuidString]?.view != nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(controls.byID[child], "Protected rows must never be constructed as retained children")
    }

    func testSmallOutlineDoesNotMountEveryOffscreenNativeControl() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 28), controls = Controls()
        let host = mount(store, controls: controls, height: 120)
        try await compatibilityWait { !controls.byID.isEmpty }
        host.layoutSubtreeIfNeeded()
        let mounted = controls.byID.values.compactMap(\.view)
        XCTAssertFalse(mounted.isEmpty)
        XCTAssertLessThan(mounted.count, 28,
                          "The inner retained stack must actually virtualize with the outer stack still eager")
    }

    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, T.self) }
    }

    private func mountRealSidebar(_ store: TabStore, height: CGFloat = 240) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarSpaceSections()
            .environmentObject(store).environmentObject(ProfileManager.shared))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        return (window, host)
    }

    private func move(_ scroll: NSScrollView, to offset: CGFloat, in host: NSView) async throws {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
    }

    /// A clip-view jump bypasses ScrollPosition's native user-scroll ownership and
    /// can move the section origin on the next realization. Exercise the actual
    /// scroll path when checking exact document geometry across disclosure.
    private func scrollNatively(_ scroll: NSScrollView, to offset: CGFloat, in host: NSView) async throws {
        let window = try XCTUnwrap(host.window)
        let point = scroll.convert(NSPoint(x: 100, y: 80), to: nil)
        NSApp.sendEvent(RetainedGeometryScrollEvent(window: window, phase: .began, point: point))
        for _ in 0..<160 {
            let delta = offset - scroll.contentView.bounds.minY
            if abs(delta) < 0.5 { break }
            NSApp.sendEvent(RetainedGeometryScrollEvent(window: window,
                dy: -max(-24, min(24, delta)), point: point))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApp.sendEvent(RetainedGeometryScrollEvent(window: window, phase: .ended, point: point))
        try await Task.sleep(for: .milliseconds(180))
    }

    private func exerciseRealEditor(folder: Bool, collapse: Bool) async throws {
        let store = fixture(count: 28)
        let parent = Folder(name: "Parent")
        let childFolder = Folder(name: "Editable folder")
        let tab = store.tabs[0]
        store.todayShape = Pins(entries: [.init(row: .folder(parent)),
            .init(row: .folder(childFolder), parent: parent.id),
            .init(row: .tab(tab.id.uuidString), parent: parent.id)]
            + store.tabs.dropFirst().map { .init(row: .tab($0.id.uuidString)) })
        let (window, host) = mountRealSidebar(store)
        try await Task.sleep(for: .milliseconds(120))
        if folder { store.renamingFolder = childFolder.id }
        else { store.renamingTab = tab.id }
        func editorField() -> NSTextField? {
            descendants(host, NSTextField.self).first { $0.isEditable && $0.isEnabled }
        }
        try await compatibilityWait { editorField() != nil }
        let field = try XCTUnwrap(editorField())
        let initialTitle = folder ? childFolder.name : TidyTitles.title(for: tab)
        try await compatibilityWait {
            guard let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor && field.stringValue == initialTitle
        }
        // Native autofocus can be ready before FolderNameField's asynchronous
        // FocusState change has armed its draft commit. Let that propagation finish
        // before synthesizing typing, as it does between real user interactions.
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let draft = folder ? "Edited folder draft" : "Edited tab draft"
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, draft)
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let bottom = max(0, try XCTUnwrap(scroll.documentView).frame.height - scroll.contentView.bounds.height)
        try await move(scroll, to: bottom, in: host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 200, "The edited row must actually leave the viewport")
        if collapse {
            Motion.instant { store.todayShape.edit(folder: parent.id) { $0.collapsed = true } }
            // Semantic disappearance can precede AppKit's field-editor teardown.
            // Wait for both acknowledgements before reopening the parent.
            try await compatibilityWait {
                (folder ? store.renamingFolder == nil : store.renamingTab == nil)
                    && window.firstResponder !== editor
            }
            XCTAssertFalse(window.firstResponder === editor,
                           "Collapsing an offscreen editor must release its field editor")
            Motion.instant { store.todayShape.edit(folder: parent.id) { $0.collapsed = false } }
        }
        try await move(scroll, to: 0, in: host)
        let stillEditing = folder ? store.renamingFolder == childFolder.id : store.renamingTab == tab.id
        if stillEditing {
            // SwiftUI may keep a focused row alive beyond the viewport. In that case
            // its draft must survive; if it evicts the row, onDisappear must commit it.
            let returned = try XCTUnwrap(editorField())
            XCTAssertEqual(returned.currentEditor()?.string ?? returned.stringValue, draft)
            window.makeFirstResponder(nil)
        }
        try await compatibilityWait { folder ? store.renamingFolder == nil : store.renamingTab == nil }
        if folder {
            XCTAssertEqual(store.todayShape.entries.first { $0.folder?.id == childFolder.id }?.folder?.name, draft)
        } else {
            XCTAssertEqual(TabActions.rename(tab), draft)
        }
        XCTAssertFalse(window.firstResponder === editor)
    }

    func testRealTabRenameDraftSurvivesViewportExitAndReturn() async throws {
        try await exerciseRealEditor(folder: false, collapse: false)
    }

    func testRealFolderRenameDraftSurvivesViewportExitAndReturn() async throws {
        try await exerciseRealEditor(folder: true, collapse: false)
    }

    func testCollapsingOffscreenEditedDescendantsCommitsDraftAndClearsFocus() async throws {
        try await exerciseRealEditor(folder: false, collapse: true)
        try await exerciseRealEditor(folder: true, collapse: true)
    }

    func testOffscreenCollapsedFolderHasNoPhantomHeightAndEndRemainsReachable() async throws {
        let store = fixture(count: 28)
        let folder = Folder(name: "Offscreen group", collapsed: true)
        store.todayShape = Pins(entries: store.tabs.prefix(18).map { .init(row: .tab($0.id.uuidString)) }
            + [.init(row: .folder(folder))]
            + store.tabs[18..<25].map { .init(row: .tab($0.id.uuidString), parent: folder.id) }
            + store.tabs.suffix(3).map { .init(row: .tab($0.id.uuidString)) })
        let (_, host) = mountRealSidebar(store)
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        // Lazy row realization can finish after the initial window layout. Establish
        // the reference from the actual top viewport, not a fixed sleep's timing.
        try await scrollNatively(scroll, to: 0, in: host)
        try await compatibilityWait {
            descendants(host, TabTooltipAnchorView.self).contains { $0.title == "Row 0" }
        }
        let first = try XCTUnwrap(descendants(host, TabTooltipAnchorView.self).first { $0.title == "Row 0" })
        let firstY = first.convert(first.bounds, to: document).minY
        func assertVisibleRowPositions() {
            var checked = 0
            let collapsed = store.todayShape.entries.first { $0.folder?.id == folder.id }?.folder?.collapsed == true
            for anchor in descendants(host, TabTooltipAnchorView.self) where anchor.enabled {
                guard anchor.title.hasPrefix("Row "), let index = Int(anchor.title.dropFirst(4)),
                      anchor.visibleRect.intersection(anchor.bounds).height > 1 else { continue }
                checked += 1
                let slot = index < 18 ? index : index + 1 - (collapsed ? 7 : 0)
                XCTAssertEqual(anchor.convert(anchor.bounds, to: document).minY,
                               firstY + CGFloat(slot) * (Look.rowHeight + Look.rowGap), accuracy: 1,
                               "Realized row \(index) must keep its exact slot, not a lazy estimated position")
            }
            XCTAssertGreaterThan(checked, 0, "The sampled viewport must contain real rows; position checks cannot pass vacuously")
        }
        func reachEnd() async throws -> CGFloat {
            for _ in 0..<3 {
                try await scrollNatively(scroll, to: max(0, document.frame.height - scroll.contentView.bounds.height), in: host)
            }
            let last = try XCTUnwrap(descendants(host, TabTooltipAnchorView.self).first { $0.title == "Row 27" })
            XCTAssertGreaterThan(last.visibleRect.intersection(last.bounds).height, 1,
                                 "The final real row must remain reachable at the document end")
            assertVisibleRowPositions()
            return document.frame.height
        }
        let closedHeight = try await reachEnd()
        try await scrollNatively(scroll, to: closedHeight / 2, in: host)
        assertVisibleRowPositions()
        try await scrollNatively(scroll, to: 0, in: host)
        assertVisibleRowPositions()
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = false } }
        let openHeight = try await reachEnd()
        try await scrollNatively(scroll, to: openHeight / 2, in: host)
        assertVisibleRowPositions()
        XCTAssertEqual(openHeight - closedHeight, 7 * (Look.rowHeight + Look.rowGap), accuracy: 1,
                       "Opening an offscreen group must add precisely its seven slots")
        try await scrollNatively(scroll, to: 0, in: host)
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = true } }
        let closedAgain = try await reachEnd()
        XCTAssertEqual(closedAgain, closedHeight, accuracy: 1,
                       "Closing an offscreen group must not preserve lazy estimated-height gaps")
    }


    func testSmallRetainedSidebarAndPreparedSwipeShareNonzeroViewport() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Native preview parity requires animation")
        let previous = RetainedRowVirtualizationExperiment.enabled
        RetainedRowVirtualizationExperiment.enabled = true
        let profile = ProfileManager.shared.create(name: "Retained preview parity").id
        let spaces = ["Origin", "Destination"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        store.sharingReady = false
        store.tabs = (0..<28).map { index in
            let tab = Tab(profileID: profile)
            tab.park(url: URL(string: "about:blank#preview-\(index)")!, Parked(title: "Preview \(index)"))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        defer {
            monitor.remove()
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            RetainedRowVirtualizationExperiment.enabled = previous
        }
        try await compatibilityWait { monitor.preparedSlides[spaces[1].id] != nil }
        let live = try XCTUnwrap(descendants(host, NSScrollView.self).first {
            let frame = $0.convert($0.bounds, to: host)
            return !$0.isHiddenOrHasHiddenAncestor && frame.minX >= 0
                && frame.maxX < SidebarWidth.shared.width + 20 && frame.height > 100
                && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 180
        })
        try await move(live, to: 180, in: host)
        XCTAssertEqual(live.documentVisibleRect.minY, 180, accuracy: 1)
        try await compatibilityWait { abs(store.spaceGesture.sidebarOffset - 180) < 1 }
        try await compatibilityWait {
            guard let candidate = monitor.preparedSlides[spaces[1].id],
                  candidate.updatePreparedScrollOffset(store.spaceGesture.sidebarOffset),
                  candidate.preparedPopulationReady,
                  let outgoing = descendants(candidate.outgoing, NSScrollView.self).first else { return false }
            return abs(outgoing.documentVisibleRect.minY - 180) < 1
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue(host.spaceSlide === prepared)
        let outgoing = try XCTUnwrap(descendants(prepared.outgoing, NSScrollView.self).first)
        XCTAssertEqual(outgoing.documentVisibleRect.minY, live.documentVisibleRect.minY, accuracy: 1)
        XCTAssertEqual(outgoing.contentView.bounds.height, live.contentView.bounds.height, accuracy: 1,
                       "The preview must preserve the real viewport at first native travel")
        XCTAssertEqual(outgoing.contentView.bounds.width, live.contentView.bounds.width, accuracy: 1)
    }

}

private final class RetainedGeometryScrollEvent: NSEvent, @unchecked Sendable {
    private let owner: NSWindow
    private let ownerNumber: Int
    private let eventPhase: NSEvent.Phase
    private let dy: CGFloat
    private let point: NSPoint

    @MainActor init(window: NSWindow, dy: CGFloat = 0,
                    phase: NSEvent.Phase = .changed, point: NSPoint) {
        owner = window
        ownerNumber = window.windowNumber
        self.dy = dy
        eventPhase = phase
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { owner }
    override var windowNumber: Int { ownerNumber }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
