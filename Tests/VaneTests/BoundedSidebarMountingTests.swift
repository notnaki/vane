import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class BoundedSidebarMountingTests: XCTestCase {
    private final class WeakControl {
        weak var view: NSButton?
        init(_ view: NSButton) { self.view = view }
    }
    private final class Controls { var byID: [String: WeakControl] = [:] }
    private final class Offset { var value: CGFloat = -1 }
    private struct Control: NSViewRepresentable {
        let id: String
        let controls: Controls
        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: id, target: nil, action: nil)
            controls.byID[id] = WeakControl(button)
            return button
        }
        func updateNSView(_ view: NSButton, context: Context) { view.isEnabled = context.environment.isEnabled }
    }
    private struct Outline: View {
        @ObservedObject var store: TabStore
        let controls: Controls
        let offset: Offset
        @State private var cache = Feel02SidebarRowsCache()
        var body: some View {
            SpaceSectionsLayout(animatesCutoffs: false,
                retainsRows: Feel02SidebarRowsCache.retainsRows(in: store), reportOffset: { offset.value = $0 }) {
                Text("Space header").frame(height: 30)
            } rows: {
                SidebarSectionRows(store: store, snapshot: cache.resolve(in: store, shape: store.todayShape),
                                   transition: .opacity) { row, _, _ in
                    Control(id: row.id, controls: controls).frame(height: Look.rowHeight)
                }
            }
        }
    }

    private func fixture(count: Int) -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let nonce = UUID().uuidString
        store.tabs = (0..<count).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#bounded-\(nonce)-\(index)")!,
                     Parked(title: "Bounded row \(index)", needsRecovery: true))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        addTeardownBlock { @MainActor in
            store.tabs.forEach { TidyTitles.rename($0, to: nil) }
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return store
    }

    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, T.self) }
    }

    private func mount<V: View>(_ content: V) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.orderOut(nil); window.contentView = nil; window.close()
            NSApp.setActivationPolicy(policy)
        }
        return (window, host)
    }

    func testMediumSidebarMountsVisibleControlsAndPreservesNativeOffset() async throws {
        let store = fixture(count: 100), controls = Controls(), offset = Offset()
        let (window, host) = mount(Outline(store: store, controls: controls, offset: offset))
        try await compatibilityWait { !controls.byID.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controls.byID.values.compactMap(\.view).count, 100,
                       "A bounded medium outline must mount every structurally visible control")
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let start = scroll.documentVisibleRect.minY
        let point = scroll.convert(NSPoint(x: 100, y: 100), to: nil)
        for sample in 0..<8 {
            NSApp.sendEvent(ScrollEvent(window: window, dy: -12,
                phase: sample == 0 ? .began : .changed, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(16))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY - start, 20,
                             "The native input must actually move the mounted viewport")
        XCTAssertEqual(offset.value, scroll.documentVisibleRect.minY, accuracy: 1,
                       "Space preparation must still receive the real native offset")
        let document = try XCTUnwrap(scroll.documentView)
        let first = try XCTUnwrap(controls.byID[store.tabs[0].id.uuidString]?.view)
        let last = try XCTUnwrap(controls.byID[store.tabs[99].id.uuidString]?.view)
        XCTAssertEqual(abs(last.convert(last.bounds, to: document).minY - first.convert(first.bounds, to: document).minY),
                       99 * (Look.rowHeight + Look.rowGap), accuracy: 1)
    }

    func testStructuralBoundaryMounts127AndKeeps129Virtualized() async throws {
        for count in [127, 129] {
            let store = fixture(count: count), controls = Controls()
            let (_, host) = mount(Outline(store: store, controls: controls, offset: Offset()))
            try await compatibilityWait { !controls.byID.isEmpty }
            try await Task.sleep(for: .milliseconds(150))
            let mounted = controls.byID.values.compactMap(\.view).count
            if count == 127 { XCTAssertEqual(mounted, 127) }
            else { XCTAssertLessThan(mounted, 129, "Larger outlines must retain native virtualization") }
            XCTAssertFalse(descendants(host, NSScrollView.self).isEmpty)
        }
    }

    func testCollapsedAndLockedLargeOutlineKeepsItsLazyFolderIdentity() async throws {
        let store = fixture(count: 128), controls = Controls(), offset = Offset()
        let auth = FolderAuthentication { _, reply in reply(true); return nil }
        store.folderAuthentication = auth
        let folder = Folder(name: "Protected group", collapsed: true, requiresAuthentication: true)
        store.todayShape = Pins(entries: [.init(row: .folder(folder))]
            + store.tabs.map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        let (_, host) = mount(Outline(store: store, controls: controls, offset: offset))
        try await compatibilityWait { controls.byID[folder.id.uuidString]?.view != nil }
        let identity = try XCTUnwrap(controls.byID[folder.id.uuidString]?.view)
        XCTAssertNil(controls.byID[store.tabs[0].id.uuidString])
        auth.unlock(folder.id, profile: store.profileID, reason: "Fixture") { _ in }
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = false } }
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { controls.byID[store.tabs[0].id.uuidString]?.view?.window != nil }
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === identity,
                      "Hidden structural children must not change mounting strategy when unlocked")
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 129)
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = true } }
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait {
            guard let child = controls.byID[store.tabs[0].id.uuidString]?.view else { return true }
            return child.window == nil || child.isHiddenOrHasHiddenAncestor
        }
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === identity,
                      "Collapsing a large outline must not cross the eager threshold")
    }

    func testMediumDisclosureRemovesExactChildExtentWithoutChangingSurvivingIDs() async throws {
        let store = fixture(count: 100), controls = Controls(), offset = Offset()
        let folder = Folder(name: "Medium group")
        store.todayShape = Pins(entries: [.init(row: .folder(folder))]
            + store.tabs.prefix(5).map { .init(row: .tab($0.id.uuidString), parent: folder.id) }
            + store.tabs.dropFirst(5).map { .init(row: .tab($0.id.uuidString)) })
        let (_, host) = mount(Outline(store: store, controls: controls, offset: offset))
        try await compatibilityWait { controls.byID.values.compactMap(\.view).count == 101 }
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        let before = document.frame.height
        let folderControl = try XCTUnwrap(controls.byID[folder.id.uuidString]?.view)
        let survivor = try XCTUnwrap(controls.byID[store.tabs[5].id.uuidString]?.view)
        let survivorY = survivor.convert(survivor.bounds, to: document).minY
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = true } }
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait {
            abs(document.frame.height - (before - 5 * (Look.rowHeight + Look.rowGap))) < 1
        }
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === folderControl)
        XCTAssertTrue(controls.byID[store.tabs[5].id.uuidString]?.view === survivor)
        XCTAssertEqual(abs(survivor.convert(survivor.bounds, to: document).minY - survivorY),
                       5 * (Look.rowHeight + Look.rowGap), accuracy: 1)
        Motion.instant { store.todayShape.edit(folder: folder.id) { $0.collapsed = false } }
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { abs(document.frame.height - before) < 1 }
        XCTAssertTrue(controls.byID[folder.id.uuidString]?.view === folderControl)
    }

    func testMediumRealRenameDraftSurvivesNativeScrollAndCommits() async throws {
        let store = fixture(count: 100)
        let tab = store.tabs[0]
        let (window, host) = mount(SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        store.renamingTab = tab.id
        func field() -> NSTextField? { descendants(host, NSTextField.self).first { $0.isEditable && $0.isEnabled } }
        try await compatibilityWait { field()?.currentEditor() != nil }
        let input = try XCTUnwrap(field())
        let expected = TidyTitles.title(for: tab)
        try await compatibilityWait { input.stringValue == expected && window.firstResponder === input.currentEditor() }
        // Match the existing real-editor fixture: native focus arrives before the
        // asynchronous FocusState task has armed draft commit.
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        let draft = "Edited bounded draft"
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, draft)
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let point = scroll.convert(NSPoint(x: 100, y: 100), to: nil)
        func move(_ delta: CGFloat) async throws {
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began, x: point.x, y: point.y))
            for _ in 0..<24 {
                NSApp.sendEvent(ScrollEvent(window: window, dy: delta, x: point.x, y: point.y))
                try await Task.sleep(for: .milliseconds(8))
            }
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await move(-24)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 200, "The actual editor row must leave the viewport")
        try await move(24)
        if store.renamingTab == tab.id {
            let returned = try XCTUnwrap(field())
            XCTAssertEqual(returned.currentEditor()?.string ?? returned.stringValue, draft)
            window.makeFirstResponder(nil)
        }
        try await compatibilityWait { store.renamingTab == nil }
        XCTAssertEqual(TabActions.rename(tab), draft)
        XCTAssertFalse(window.firstResponder === editor)
    }

    func testSameHost127To129To127PreservesActiveRenameDraft() async throws {
        let store = fixture(count: 127)
        let tab = store.tabs[0]
        let originalIDs = store.tabs.map(\.id)
        let (window, host) = mount(SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        let originalHost = window.contentView
        func field() -> NSTextField? {
            descendants(host, NSTextField.self).first { $0.isEditable && $0.isEnabled }
        }
        func beginDraft(_ draft: String) async throws -> NSTextView {
            if store.renamingTab != tab.id { store.renamingTab = tab.id }
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait {
                guard let input = field(), let editor = input.currentEditor() else { return false }
                return window.firstResponder === editor && !input.stringValue.isEmpty
            }
            let input = try XCTUnwrap(field())
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait { input.stringValue == draft && editor.string == draft }
            return editor
        }
        func assertDraftPreserved(_ draft: String, previousEditor: NSTextView) async throws {
            // Container replacement may commit through onDisappear or preserve a
            // live field editor. Wait for either actual documented outcome.
            try await compatibilityWait {
                if store.renamingTab == tab.id {
                    guard let input = field(), let editor = input.currentEditor() else { return false }
                    return window.firstResponder === editor && editor.string == draft && input.stringValue == draft
                }
                return store.renamingTab == nil && TabActions.rename(tab) == draft
                    && window.firstResponder !== previousEditor
            }
            if store.renamingTab == tab.id {
                XCTAssertEqual(field()?.currentEditor()?.string, draft)
            } else {
                XCTAssertEqual(TabActions.rename(tab), draft)
                XCTAssertFalse(window.firstResponder === previousEditor)
            }
            XCTAssertTrue(window.contentView === originalHost, "Both crossings must use the same real sidebar host")
            XCTAssertNil(store.palette, "A mounting transition must not activate New Tab")
            XCTAssertNil(store.current, "Changing the row container must not select or resume a tab")
        }
        func waitForMounting(eager: Bool) async throws {
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait {
                let mounted = descendants(host, Feel02PressAnchorView.self).count
                return eager ? mounted >= 127 : mounted > 0 && mounted < 64
            }
        }

        try await waitForMounting(eager: true)
        let firstDraft = "Threshold 127 draft"
        let firstEditor = try await beginDraft(firstDraft)
        let added = (0..<2).map { index -> vane.Tab in
            let extra = Tab(isPrivate: true, profileID: store.profileID)
            extra.park(url: URL(string: "about:blank#threshold-\(UUID().uuidString)-\(index)")!,
                       Parked(title: "Threshold extra \(index)", needsRecovery: true))
            return extra
        }
        defer { added.forEach { $0.tearDown() } }
        Motion.instant { store.tabs.append(contentsOf: added); store.syncShapes() }
        XCTAssertEqual(store.tabs.count, 129)
        try await waitForMounting(eager: false)
        try await assertDraftPreserved(firstDraft, previousEditor: firstEditor)
        XCTAssertEqual(store.tabs.map(\.id), originalIDs + added.map(\.id))

        // Re-arm a real editor if the first crossing committed. The return leg
        // must also carry an actively typed draft, rather than only a saved name.
        let secondDraft = "Threshold 129 draft"
        let secondEditor = try await beginDraft(secondDraft)
        let addedIDs = Set(added.map(\.id))
        Motion.instant { store.tabs.removeAll { addedIDs.contains($0.id) }; store.syncShapes() }
        XCTAssertEqual(store.tabs.count, 127)
        try await waitForMounting(eager: true)
        try await assertDraftPreserved(secondDraft, previousEditor: secondEditor)
        XCTAssertEqual(store.tabs.map(\.id), originalIDs)
        if store.renamingTab == tab.id { window.makeFirstResponder(nil) }
        try await compatibilityWait { store.renamingTab == nil }
        XCTAssertEqual(TabActions.rename(tab), secondDraft)
        XCTAssertNil(store.palette)
        XCTAssertEqual(store.tabs.count, 127)
    }

    func testNewRenameFinishesPriorDraftBeforeLateDisappearance() throws {
        let store = fixture(count: 2)
        let tab = store.tabs[0]
        store.renamingTab = tab.id
        let first = try XCTUnwrap(store.tabRenameSession)
        first.prepare("Page title", tab: tab)
        first.draft = "First typed draft"
        // A same-ID publication must not erase the in-progress edit.
        store.renamingTab = tab.id
        XCTAssertTrue(store.tabRenameSession === first)
        XCTAssertEqual(first.draft, "First typed draft")

        // Re-arm before the outgoing native field has disappeared.
        store.renamingTab = nil
        store.renamingTab = tab.id
        let second = try XCTUnwrap(store.tabRenameSession)
        XCTAssertFalse(second === first)
        XCTAssertEqual(TabActions.rename(tab), "First typed draft")
        second.prepare("First typed draft", tab: tab)
        second.draft = "Latest typed draft"
        second.commit()
        first.commit() // Simulate the old field's delayed onDisappear.
        XCTAssertEqual(TabActions.rename(tab), "Latest typed draft")
        XCTAssertEqual(store.renamingTab, tab.id, "A session commit cannot clear a newer field")

        // Starting a different tab also commits the old draft before its row leaves.
        store.renamingTab = nil
        store.renamingTab = tab.id
        let third = try XCTUnwrap(store.tabRenameSession)
        third.prepare("Latest typed draft", tab: tab)
        third.draft = "Final edit before changing tabs"
        store.renamingTab = store.tabs[1].id
        XCTAssertEqual(TabActions.rename(tab), "Final edit before changing tabs")
        third.commit()
        XCTAssertEqual(store.renamingTab, store.tabs[1].id)
    }

    private func preview(_ store: TabStore, space: Space) -> SpacePreviewList {
        let regular = store.tabs.filter { $0.kind != .favourite }
        let favorites = store.tabs.filter { $0.kind == .favourite }
        let state = Stash(tabs: regular, pins: store.pins, todayShape: store.todayShape,
                          splits: store.splits, current: nil, fingerprint: "")
        return SpacePreviewList(space: space, liveTabs: regular, state: state,
            favorites: favorites.compactMap(\.pinnedURL), pinnedCollapsed: true,
            renderStore: store, favoriteTabs: favorites, unlocked: store.unlockedFolders)
    }

    func testCapturedPolicyCountsAllFavoritesAndProtectedCollapsedMembership() {
        for total in [127, 129] {
            let store = fixture(count: total - 2)
            store.tabs.prefix(4).forEach { $0.kind = .favourite }
            let pin = Folder(name: "Pinned folder")
            let today = Folder(name: "Hidden descendants", collapsed: true, requiresAuthentication: true)
            store.pins = Pins(entries: [.init(row: .folder(pin))])
            store.todayShape = Pins(entries: [.init(row: .folder(today))]
                + store.tabs.filter { $0.kind == .today }.map { .init(row: .tab($0.id.uuidString), parent: today.id) })
            let snapshot = Feel02SidebarRowsCache().resolve(in: store, shape: store.todayShape)
            let captured = preview(store, space: Space(name: "Captured", profileID: store.profileID))
            XCTAssertEqual(captured.rows.today.count, 1, "The visible row count must hide the structural descendants")
            XCTAssertEqual(snapshot.eagerlyMountsVisibleRows, total == 127)
            XCTAssertEqual(captured.eagerlyMountsVisibleRows, total == 127)
        }
    }

    func testMalformedSmallShapeKeepsLegacyLazyFallback() async throws {
        let store = fixture(count: 40), controls = Controls()
        store.todayShape.entries.append(.init(row: .tab(UUID().uuidString)))
        let snapshot = Feel02SidebarRowsCache().resolve(in: store, shape: store.todayShape)
        XCTAssertNil(snapshot.retainedRows, "The legacy stale-shape guard must still apply")
        XCTAssertFalse(snapshot.eagerlyMountsVisibleRows)
        let captured = preview(store, space: Space(name: "Small stale shape", profileID: store.profileID))
        XCTAssertFalse(captured.eagerlyMountsVisibleRows)
        _ = mount(Outline(store: store, controls: controls, offset: Offset()))
        try await compatibilityWait { !controls.byID.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 40)
    }

    func testColdSavedEmptyTodayFolderMatchesRestored128RowBoundary() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let regular = (0..<124).map { URL(string: "https://bounded.example/page/\($0)")! }
        let favorites = (0..<4).map { URL(string: "https://bounded.example/favorite/\($0)")! }
        let space = Space(name: "Cold boundary", profileID: profile, tabURLs: regular)
        let key = TabStore.shapeKey(.today, space: space.id, profileID: profile)
        defer { UserDefaults.vane.removeObject(forKey: key); Store.forget(profile) }
        let stale = Pins(entries: [.init(row: .folder(Folder(name: "Stale empty")))])
        UserDefaults.vane.set(try JSONEncoder().encode(stale), forKey: key)
        let cold = SpacePreviewList(space: space, liveTabs: nil, favorites: favorites)
        XCTAssertTrue(cold.eagerlyMountsVisibleRows,
                      "Cold Today restoration prunes stale empty folders before counting the 128 rows")
        XCTAssertEqual(cold.rows.today.count, 124)
        let store = fixture(count: 128)
        store.tabs.prefix(4).forEach { $0.kind = .favourite }
        store.syncShapes()
        let live = Feel02SidebarRowsCache().resolve(in: store, shape: store.todayShape)
        XCTAssertTrue(live.eagerlyMountsVisibleRows)
        XCTAssertEqual(cold.eagerlyMountsVisibleRows, live.eagerlyMountsVisibleRows)
    }
}
