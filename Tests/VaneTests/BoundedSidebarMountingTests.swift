import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class BoundedSidebarMountingTests: XCTestCase {
    @MainActor private final class Retirement {
        private var action: (@MainActor () -> Void)?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func retire() { let pending = action; action = nil; pending?() }
    }
    private var fixtureRetirements: [Retirement] = []
    private var ownsAppKitLoop = false
    private func registerRetirement(_ action: @escaping @MainActor () -> Void) {
        let retirement = Retirement(action)
        fixtureRetirements.append(retirement)
        addTeardownBlock { @MainActor in retirement.retire() }
    }
    private func withNativeContext(_ operation: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        NativeFixturePolicyDiagnostics.setActivationPolicy(NSApp, .accessory)
        defer { NativeFixturePolicyDiagnostics.setActivationPolicy(NSApp, policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        ownsAppKitLoop = true
        var failure: (any Error)?
        do { try await operation() } catch { failure = error }
        fixtureRetirements.reversed().forEach { $0.retire() }
        fixtureRetirements.removeAll()
        ownsAppKitLoop = false
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Mount fixture AppKit cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

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
                                   readinessSection: "today", transition: .opacity) { row, _, _ in
                    Control(id: row.id, controls: controls).frame(height: Look.rowHeight)
                }
            }
        }
    }

    private struct CapturedOutline: View {
        let store: TabStore
        let snapshot: Feel02SidebarRowsCache.Snapshot
        let controls: Controls
        var body: some View {
            SpaceSectionsLayout(animatesCutoffs: false, retainsRows: snapshot.eagerlyMountsVisibleRows) {
                Text("Space header").frame(height: 30)
            } rows: {
                SidebarSectionRows(store: store, snapshot: snapshot, readinessSection: "today", transition: .opacity) { row, _, _ in
                    Control(id: row.id, controls: controls).frame(height: Look.rowHeight)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Today")
                .accessibilityValue("\(snapshot.todayCount) open")
            }
        }
    }
    @MainActor private final class Publication { var delivered = false }

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
        registerRetirement {
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

    private func mount<V: View>(_ content: V) async throws -> (NSWindow, NSHostingView<ModifiedContent<V, NativeFixtureSnapshotReceipt>>) {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NativeFixturePolicyDiagnostics.setActivationPolicy(NSApp, .accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.modifier(NativeFixtureSnapshotReceipt()))
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        if ownsAppKitLoop { NSApp.activate(ignoringOtherApps: true) }
        else { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
        registerRetirement {
            attachment?.cancel()
            window.orderOut(nil); window.contentView = nil; window.close()
            NativeFixturePolicyDiagnostics.setActivationPolicy(NSApp, policy)
        }
        try await compatibilityWait { NativeFixtureMountAdmission.surfaceReady(host, in: window) }
        if ownsAppKitLoop {
            try await compatibilityWait {
                NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window
                    && NSRunningApplication.current.isFinishedLaunching
            }
        }
        return (window, host)
    }

    private func renderedSnapshotReady(_ store: TabStore, root: NSView, window: NSWindow) -> Bool {
#if DEBUG
        let snapshot = Feel02SidebarRowsCache().resolve(in: store, shape: store.todayShape)
        let expected = NativeFixtureSnapshotMarker.Snapshot(store: ObjectIdentifier(store),
            section: "today", ids: snapshot.rows.map(\.id))
        let markers = descendants(root, NativeFixtureSnapshotMarker.self).filter {
            $0.belongs(to: ObjectIdentifier(store), section: "today")
        }
        // An outgoing duplicate cannot acknowledge a newer section lifetime.
        return markers.count == 1 && markers[0].acknowledges(expected, root: root, window: window)
#else
        return true
#endif
    }

    private func admitOutline(_ store: TabStore, controls: Controls, root: NSView,
                              window: NSWindow) async throws -> NSScrollView {
        var admitted: NSScrollView?
        let extent = CGFloat(store.tabs.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap
        do {
            try await compatibilityWait {
                guard NativeFixtureMountAdmission.surfaceReady(root, in: window),
                      self.renderedSnapshotReady(store, root: root, window: window) else { return false }
                // Read the current snapshot receipt first, then force and check
                // the actual current child layout before the immediate sample.
                root.layoutSubtreeIfNeeded()
                guard let scroll = self.descendants(root, NSScrollView.self).first,
                      NativeFixtureMountAdmission.scrollReady(scroll, root: root, window: window, minimumHeight: extent),
                      NativeFixtureMountAdmission.populated(scroll, by: controls.byID.values.compactMap(\.view),
                        root: root, window: window, spacing: Look.rowGap, nativeControls: true, slotHeight: Look.rowHeight) else { return false }
                admitted = scroll
                return true
            }
        } catch {
            let scroll = descendants(root, NSScrollView.self).first
            print("MOUNT_ADMISSION rejected extent=\(extent) root=\(root.bounds) document=\(String(describing: scroll?.documentView?.bounds)) visible=\(String(describing: scroll?.documentVisibleRect))")
            if let scroll, let document = scroll.documentView {
                for (id, entry) in controls.byID.sorted(by: { $0.key < $1.key }) {
                    guard let view = entry.view, view.visibleRect.intersection(view.bounds).height > 1 else { continue }
                    print("MOUNT_ADMISSION control=\(id) rect=\(view.convert(view.bounds, to: document)) visible=\(view.visibleRect) window=\(view.window === window) hit=\(String(describing: NativeFixtureMountAdmission.hitPoint(view, root: root, window: window, nativeControl: true)))")
                }
            }
            throw error
        }
        return try XCTUnwrap(admitted)
    }

    func testMediumSidebarMountsVisibleControlsAndPreservesNativeOffset() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 100), controls = Controls(), offset = Offset()
        let (window, host) = try await mount(Outline(store: store, controls: controls, offset: offset))
        let scroll = try await admitOutline(store, controls: controls, root: host, window: window)
        print("MOUNT_ADMISSION medium rootWindow=\(host.window === window) contentOwner=\(window.contentView === host) controls=\(controls.byID.values.compactMap(\.view).count) active=\(NSApp.isActive) key=\(window.isKeyWindow) running=\(NSApp.isRunning)")
        XCTAssertEqual(controls.byID.values.compactMap(\.view).count, 100,
                       "A bounded medium outline must mount every structurally visible control")
        let start = scroll.documentVisibleRect.minY
        let point = try XCTUnwrap(NativeFixtureMountAdmission.scrollPoint(scroll, root: host, window: window))
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

    /// Causal experiment: remove offscreen responders without changing the scroll
    /// owner, row controls, hosting root or native Space transition machinery.
    func testBufferedSidebarBoundsControlsWithoutChangingExtentOrRowIdentity() async throws {
        useLegacySidebarMountingPolicy()
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        for count in [100, 1_000] {
            let store = fixture(count: count), controls = Controls(), offset = Offset()
            let (window, host) = try await mount(Outline(store: store, controls: controls, offset: offset))
            let scroll = try await admitOutline(store, controls: controls, root: host, window: window)
            let document = try XCTUnwrap(scroll.documentView)
            let originalHeight = document.frame.height
            let originalFirst = try XCTUnwrap(controls.byID[store.tabs[0].id.uuidString]?.view)
            XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 40,
                              "Only the viewport and its buffer may contribute responder nodes")
            XCTAssertNil(controls.byID[store.tabs[count - 2].id.uuidString]?.view)

            // Small movement must reuse the existing controls, rather than remounting
            // a new range for every pixel of a native gesture.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(controls.byID[store.tabs[0].id.uuidString]?.view === originalFirst)
            XCTAssertEqual(document.frame.height, originalHeight, accuracy: 1)

            // A scrollbar-sized jump must realize the destination, with the same exact
            // row pitch and full content extent as the unwindowed section.
            scroll.contentView.scroll(to: NSPoint(x: 0,
                y: originalHeight - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await compatibilityWait { controls.byID[store.tabs[count - 2].id.uuidString]?.view?.window != nil }
            host.layoutSubtreeIfNeeded()
            let last = try XCTUnwrap(controls.byID[store.tabs[count - 1].id.uuidString]?.view)
            let penultimate = try XCTUnwrap(controls.byID[store.tabs[count - 2].id.uuidString]?.view)
            XCTAssertGreaterThan(last.visibleRect.intersection(last.bounds).height, 1)
            XCTAssertEqual(abs(last.convert(last.bounds, to: document).minY
                               - penultimate.convert(penultimate.bounds, to: document).minY),
                           Look.rowHeight + Look.rowGap, accuracy: 1)
            XCTAssertEqual(document.frame.height, originalHeight, accuracy: 1)
            XCTAssertEqual(offset.value, scroll.contentView.bounds.minY, accuracy: 1)
            XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 40)
        }
    }

    func testBufferedWindowChangesInBatchesRatherThanPerPixel() {
        var window = SidebarRowWindow()
        let pitch = Look.rowHeight + Look.rowGap
        _ = window.update(count: 1_000, visible: CGRect(x: 0, y: 0, width: 250, height: 300), pitch: pitch)
        let first = window.range
        for pixel in 1...80 {
            XCTAssertFalse(window.update(count: 1_000,
                visible: CGRect(x: 0, y: pixel, width: 250, height: 300), pitch: pitch))
            XCTAssertEqual(window.range, first)
        }
        XCTAssertTrue(window.update(count: 1_000,
            visible: CGRect(x: 0, y: 400, width: 250, height: 300), pitch: pitch))
        XCTAssertLessThanOrEqual(window.range.count, 40)
        XCTAssertTrue(window.range.contains(Int(400 / pitch)))
        XCTAssertTrue(window.range.contains(Int(699 / pitch)))
    }

    func testBufferedSidebarKeepsDraggedSourceWithoutMountingInterveningRows() async throws {
        useLegacySidebarMountingPolicy()
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer {
            Dragging.shared.cancel()
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let store = fixture(count: 100), controls = Controls(), offset = Offset()
        let (_, host) = try await mount(Outline(store: store, controls: controls, offset: offset))
        let sourceID = store.tabs[2].id
        try await compatibilityWait { controls.byID[sourceID.uuidString]?.view?.window != nil }
        let original = try XCTUnwrap(controls.byID[sourceID.uuidString]?.view)
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        let extent = document.frame.height
        Dragging.shared.tab = sourceID
        try await Task.sleep(for: .milliseconds(80))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: extent - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait { controls.byID[store.tabs[98].id.uuidString]?.view?.window != nil }
        XCTAssertTrue(original.window === host.window, "An active drag must retain its original source control")
        XCTAssertTrue(controls.byID[sourceID.uuidString]?.view === original)
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).filter { $0.window != nil }.count, 40,
                          "Keeping a distant source must not realize every intervening row")
        XCTAssertEqual(document.frame.height, extent, accuracy: 1)
        Dragging.shared.cancel()
        try await compatibilityWait { original.window == nil }
        XCTAssertNil(store.current)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBufferedSidebarKeepsRequestedNonLeadEditorBeforeFocusArrives() async throws {
        useLegacySidebarMountingPolicy()
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer { if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) } }
        let store = fixture(count: 100), controls = Controls()
        let lead = store.tabs[8].id, pane = store.tabs[9].id
        store.splits = [try XCTUnwrap(Split(tabs: [lead, pane]))]
        // Actual section policy, with native controls that deliberately do not
        // install an editor: pending editing ownership must not depend on focus.
        let (window, host) = try await mount(Outline(store: store, controls: controls, offset: Offset()))
        try await compatibilityWait { controls.byID[lead.uuidString]?.view?.window === window }
        let original = try XCTUnwrap(controls.byID[lead.uuidString]?.view)
        XCTAssertNil(controls.byID[pane.uuidString]?.view)
        window.makeFirstResponder(nil)
        store.renamingTab = pane
        try await Task.sleep(for: .milliseconds(80))
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait { controls.byID[store.tabs[98].id.uuidString]?.view?.window === window }
        XCTAssertEqual(store.renamingTab, pane)
        XCTAssertTrue(original.window === window, "Pending nonlead editing must retain its owning split row before focus arrives")
        XCTAssertTrue(controls.byID[lead.uuidString]?.view === original)
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).filter { $0.window != nil }.count, 40)
        store.renamingTab = nil
        try await compatibilityWait { original.window == nil }
    }

    func testBufferedSidebarKeepsActualRenameEditorAcrossViewportEviction() async throws {
        useLegacySidebarMountingPolicy()
        try await assertBufferedEditorSurvivesEviction(nonLeadPane: false)
    }

    func testBufferedSidebarKeepsNonLeadPaneRenameAcrossViewportEviction() async throws {
        useLegacySidebarMountingPolicy()
        try await assertBufferedEditorSurvivesEviction(nonLeadPane: true)
    }

    private func assertBufferedEditorSurvivesEviction(nonLeadPane: Bool) async throws {
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer { if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) } }
        let store = fixture(count: 100)
        let tab = store.tabs[nonLeadPane ? 9 : 8]
        if nonLeadPane {
            store.splits = [try XCTUnwrap(Split(tabs: [store.tabs[8].id, tab.id])).focusing(tab.id)]
            XCTAssertNotEqual(store.leadPane(store.splits[0]), tab.id)
        }
        let (window, host) = try await mount(SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        store.renamingTab = tab.id
        func field() -> NSTextField? {
            descendants(host, NSTextField.self).first { $0.isEditable && $0.isEnabled }
        }
        try await compatibilityWait { field()?.currentEditor() != nil }
        let input = try XCTUnwrap(field())
        try await compatibilityWait {
            input.stringValue == TidyTitles.title(for: tab) && window.firstResponder === input.currentEditor()
        }
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        let draft = "Buffered draft must remain editable"
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await compatibilityWait { input.stringValue == draft }
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let point = try XCTUnwrap(NativeFixtureMountAdmission.scrollPoint(scroll, root: host, window: window))
        for packet in 0..<80 {
            NSApp.sendEvent(ScrollEvent(window: window, dy: -24,
                phase: packet == 0 ? .began : .changed, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 1300)
        XCTAssertEqual(store.renamingTab, tab.id, "Scrolling must not commit or dismiss the active editor")
        XCTAssertTrue(input.window === window)
        XCTAssertTrue(input.currentEditor() === editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, draft)
        XCTAssertNil(TabActions.rename(tab), "The draft remains uncommitted until the user ends editing")
        window.makeFirstResponder(nil)
        try await compatibilityWait { store.renamingTab == nil }
        XCTAssertEqual(TabActions.rename(tab), draft)
    }

#if DEBUG
    func testShrinkAdmissionWaitsForCurrentRenderedStructureInSameHost() async throws {
        try await withNativeContext { try await exerciseShrinkAdmission() }
    }

    private func exerciseShrinkAdmission() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 129), controls = Controls(), cache = Feel02SidebarRowsCache()
        let oldSnapshot = cache.resolve(in: store, shape: store.todayShape)
        let (window, host) = try await mount(CapturedOutline(store: store, snapshot: oldSnapshot, controls: controls))
        _ = try await admitOutline(store, controls: controls, root: host, window: window)
        try await compatibilityWait { self.renderedSnapshotReady(store, root: host, window: window) }
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 64,
            "Reading the rendered snapshot receipt must not realize the offscreen 129 controls")
        let originalHost = host
        let removed = Array(store.tabs.suffix(2))
        defer { removed.forEach { $0.tearDown() } }
        Motion.instant { store.tabs.removeLast(2); store.syncShapes() }
        XCTAssertEqual(store.tabs.count, 127)
        let snapshot = cache.resolve(in: store, shape: store.todayShape)
        let publication = Publication()
        // Deliberately hold the real rendered snapshot while the same model and
        // native host already exist. This is injected publication lag, not a
        // guessed readiness sleep or a delay of the outcome under test.
        let delivery = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            Motion.instant { host.rootView = CapturedOutline(store: store, snapshot: snapshot, controls: controls).modifier(NativeFixtureSnapshotReceipt()) }
            publication.delivered = true
        }
        defer { delivery.cancel() }
        _ = try await admitOutline(store, controls: controls, root: host, window: window)
        XCTAssertTrue(publication.delivered, "Previous 129 geometry must not acknowledge the 127 snapshot")
        XCTAssertTrue(window.contentView === originalHost)
        XCTAssertEqual(controls.byID.values.compactMap(\.view).count, 127)
        XCTAssertTrue(renderedSnapshotReady(store, root: host, window: window))
    }

#endif

    func testStructuralBoundaryMounts127AndKeeps129Virtualized() async throws {
        useLegacySidebarMountingPolicy()
        for count in [127, 129] {
            let store = fixture(count: count), controls = Controls()
            let (window, host) = try await mount(Outline(store: store, controls: controls, offset: Offset()))
            _ = try await admitOutline(store, controls: controls, root: host, window: window)
            let mounted = controls.byID.values.compactMap(\.view).count
            if count == 127 { XCTAssertEqual(mounted, 127) }
            else { XCTAssertLessThan(mounted, 129, "Larger outlines must retain native virtualization") }
            XCTAssertFalse(descendants(host, NSScrollView.self).isEmpty)
        }
    }

    func testCollapsedAndLockedLargeOutlineKeepsItsLazyFolderIdentity() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 128), controls = Controls(), offset = Offset()
        let auth = FolderAuthentication { _, reply in reply(true); return nil }
        store.folderAuthentication = auth
        let folder = Folder(name: "Protected group", collapsed: true, requiresAuthentication: true)
        store.todayShape = Pins(entries: [.init(row: .folder(folder))]
            + store.tabs.map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        let (_, host) = try await mount(Outline(store: store, controls: controls, offset: offset))
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
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 100), controls = Controls(), offset = Offset()
        let folder = Folder(name: "Medium group")
        store.todayShape = Pins(entries: [.init(row: .folder(folder))]
            + store.tabs.prefix(5).map { .init(row: .tab($0.id.uuidString), parent: folder.id) }
            + store.tabs.dropFirst(5).map { .init(row: .tab($0.id.uuidString)) })
        let (_, host) = try await mount(Outline(store: store, controls: controls, offset: offset))
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
        let (window, host) = try await mount(SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        // Real rename input follows a committed visible row, rather than racing
        // the initial native hosting/focus graph immediately after mount.
        try await compatibilityWait {
            descendants(host, NativeSidebarRowLayoutView.self).contains {
                $0.rowID == tab.id.uuidString && $0.hasCommittedCurrentBounds
            }
        }
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
        let point = try XCTUnwrap(NativeFixtureMountAdmission.scrollPoint(scroll, root: host, window: window))
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
        try await withNativeContext { try await exerciseThresholdRename() }
    }

    private func exerciseThresholdRename() async throws {
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 127)
        let tab = store.tabs[0]
        let originalIDs = store.tabs.map(\.id)
        let (window, host) = try await mount(SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        let originalHost = host
        func field() -> NSTextField? {
            descendants(host, NSTextField.self).first { $0.isEditable && $0.isEnabled }
        }
        func beginDraft(_ draft: String, phase: String) async throws -> NSTextView {
            let continuing = store.renamingTab == tab.id
            let initialTitle = continuing ? try XCTUnwrap(store.tabRenameSession).draft : TidyTitles.title(for: tab)
            var stage = "target-row-readiness"
            do {
                if !continuing {
                    // A representable count can be satisfied during insertion,
                    // before the target row has visible native geometry.
                    try await compatibilityWait {
                        host.layoutSubtreeIfNeeded()
                        return descendants(host, TabTooltipAnchorView.self).contains {
                            $0.title == initialTitle && $0.window === window
                                && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0
                                && $0.visibleRect.intersection($0.bounds).height > Look.rowHeight / 2
                        }
                    }
                    store.renamingTab = tab.id
                    stage = "field-readiness"
                    try await compatibilityWait {
                        guard let input = field(), let session = store.tabRenameSession else { return false }
                        return input.window === window && input.stringValue == initialTitle
                            && session.initialized && !session.done && session.draft == initialTitle
                    }
                    // Draft preservation needs a real native editor, regardless
                    // of which desktop app currently owns foreground activation.
                    // Establish it once when beginning an edit; continuing edits
                    // must retain their responder without any focus repair.
                    XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(field())), phase)
                }
                stage = "field-focus"
                host.layoutSubtreeIfNeeded()
                try await compatibilityWait {
                    guard let session = store.tabRenameSession, session.tabID == tab.id,
                          store.renamingTab == tab.id, session.initialized, !session.done,
                          let input = field(), let editor = input.currentEditor() else { return false }
                    return input.window === window && window.firstResponder === editor
                        && input.stringValue == initialTitle && editor.string == initialTitle
                        && session.draft == initialTitle
                }
            } catch {
                let input = field()
                let editor = input?.currentEditor()
                let anchors = descendants(host, TabTooltipAnchorView.self).filter {
                    $0.title == TidyTitles.title(for: tab)
                }
                let rowState = anchors.map {
                    "window=\($0.window === window), bounds=\($0.bounds), visible=\($0.visibleRect), hidden=\($0.isHiddenOrHasHiddenAncestor)"
                }.joined(separator: "; ")
                let session = store.tabRenameSession
                print("THRESHOLD_RENAME phase=\(phase) stage=\(stage) count=\(store.tabs.count) key=\(window.isKeyWindow) active=\(NSApp.isActive)")
                print("THRESHOLD_RENAME renaming=\(String(describing: store.renamingTab)) field=\(String(describing: input)) fieldWindow=\(input?.window === window) fieldTitle=\(String(describing: input?.stringValue)) editor=\(String(describing: editor)) responder=\(String(describing: window.firstResponder))")
                print("THRESHOLD_RENAME sessionInitialized=\(session?.initialized == true) sessionDone=\(session?.done == true) sessionDraft=\(String(describing: session?.draft)) expectedTitle=\(initialTitle) targetRows=[\(rowState)]")
                throw error
            }
            let input = try XCTUnwrap(field())
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            let session = try XCTUnwrap(store.tabRenameSession)
            editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait {
                input.stringValue == draft && editor.string == draft && session.draft == draft
            }
            XCTAssertTrue(store.tabRenameSession === session)
            XCTAssertFalse(session.done)
            XCTAssertEqual(store.renamingTab, tab.id)
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
            do {
                try await compatibilityWait {
                    guard NativeFixtureMountAdmission.surfaceReady(host, in: window),
                          self.renderedSnapshotReady(store, root: host, window: window) else { return false }
                    host.layoutSubtreeIfNeeded()
                    let titles = Set(store.tabs.map { TidyTitles.title(for: $0) })
                    let anchors = descendants(host, TabTooltipAnchorView.self).filter { titles.contains($0.title) }
                    guard let first = anchors.first(where: { $0.title == TidyTitles.title(for: store.tabs[0]) }),
                          let scroll = first.enclosingScrollView,
                          NativeFixtureMountAdmission.scrollReady(scroll, root: host, window: window,
                            minimumHeight: CGFloat(store.tabs.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap)
                    else { return false }
                    guard let document = scroll.documentView else { return false }
                    let firstRect = first.convert(first.bounds, to: document)
                    let today = NSRect(x: document.bounds.minX, y: firstRect.minY,
                        width: document.bounds.width,
                        height: CGFloat(store.tabs.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap)
                    return NativeFixtureMountAdmission.populated(scroll,
                        by: anchors.filter { $0.enclosingScrollView === scroll }, root: host,
                        window: window, spacing: Look.rowGap, region: today)
                }
            } catch {
                print("THRESHOLD_MOUNT count=\(store.tabs.count) eager=\(eager) root=\(host.bounds) contentOwner=\(window.contentView === host)")
                for anchor in descendants(host, TabTooltipAnchorView.self) {
                    guard anchor.visibleRect.intersection(anchor.bounds).height > 1 else { continue }
                    let scroll = anchor.enclosingScrollView
                    print("THRESHOLD_MOUNT title=\(anchor.title) bounds=\(anchor.bounds) frame=\(anchor.frame) visible=\(anchor.visibleRect) window=\(anchor.window === window) scroll=\(String(describing: scroll.map(ObjectIdentifier.init))) document=\(String(describing: scroll?.documentView?.bounds)) viewport=\(String(describing: scroll?.documentVisibleRect)) nativeHit=\(String(describing: NativeFixtureMountAdmission.hitPoint(anchor, root: host, window: window)))")
                }
                throw error
            }
            // Mount counts are sampled after independent native admission. Waiting
            // for the desired low count would conceal a transient overmount.
            let mounted = descendants(host, Feel02PressAnchorView.self).count
            if eager { XCTAssertGreaterThanOrEqual(mounted, 127) }
            else { XCTAssertGreaterThan(mounted, 0); XCTAssertLessThan(mounted, 64) }
        }
        try await waitForMounting(eager: true)
        let firstDraft = "Threshold 127 draft"
        let firstEditor = try await beginDraft(firstDraft, phase: "127-before-growth")
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
        let secondEditor = try await beginDraft(secondDraft, phase: "129-before-shrink")
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
        useLegacySidebarMountingPolicy()
        let store = fixture(count: 40), controls = Controls()
        store.todayShape.entries.append(.init(row: .tab(UUID().uuidString)))
        let snapshot = Feel02SidebarRowsCache().resolve(in: store, shape: store.todayShape)
        XCTAssertNil(snapshot.retainedRows, "The legacy stale-shape guard must still apply")
        XCTAssertFalse(snapshot.eagerlyMountsVisibleRows)
        let captured = preview(store, space: Space(name: "Small stale shape", profileID: store.profileID))
        XCTAssertFalse(captured.eagerlyMountsVisibleRows)
        let (window, host) = try await mount(Outline(store: store, controls: controls, offset: Offset()))
        _ = try await admitOutline(store, controls: controls, root: host, window: window)
        XCTAssertLessThan(controls.byID.values.compactMap(\.view).count, 40)
    }

    func testNativeOwnershipMembershipSurvivesProtectedCollapseButForgetsDeletion() {
        let store = fixture(count: 100)
        let folder = Folder(name: "Protected", collapsed: true, requiresAuthentication: true)
        store.todayShape = Pins(entries: [.init(row: .folder(folder))]
            + store.tabs.map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        let cache = Feel02SidebarRowsCache()
        let collapsed = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertEqual(collapsed.rows.map(\.id), [folder.id.uuidString])
        XCTAssertEqual(collapsed.structuralRowIDs.count, 101)
        let removed = store.todayShape.entries.removeLast().id
        let updated = cache.resolve(in: store, shape: store.todayShape)
        XCTAssertFalse(updated.structuralRowIDs.contains(removed))
        XCTAssertEqual(updated.structuralRowIDs.count, 100)
        XCTAssertEqual(updated.rows.map(\.id), [folder.id.uuidString],
                       "Structural ownership cannot expose protected descendants")
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
