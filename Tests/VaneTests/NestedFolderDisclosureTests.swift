import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

@MainActor final class NestedFolderDisclosureTests: XCTestCase {
    func testInnerFolderReversalKeepsNewTabBelowNativeChildrenWhileAncestorMoves() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkDisclosure() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkDisclosure() async throws {
        let previousMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previousMode) }
        try XCTSkipIf(Motion.spaceReduced, "Normal-motion regression requires Reduce Motion off")
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let folder = Folder(name: "Pull Requests", collapsed: true)
        let inner = Folder(name: "Inner")
        let tabs = (0..<6).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.kind = .pinned
            tab.park(url: URL(string: "about:blank#disclosure-\(index)")!, Parked(title: "Child \(index)"))
            return tab
        }
        store.tabs = tabs
        store.pins = Pins(entries: [.init(row: .folder(folder))]
            + tabs.prefix(2).map { .init(row: .tab($0.id.uuidString), parent: folder.id) }
            + [.init(row: .folder(inner), parent: folder.id)]
            + tabs.dropFirst(2).prefix(2).map { .init(row: .tab($0.id.uuidString), parent: inner.id) }
            + tabs.suffix(2).map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        store.palette = nil
        let host = NSHostingView(rootView: SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        func anchors(_ root: NSView) -> [TabTooltipAnchorView] {
            ((root as? TabTooltipAnchorView).map { [$0] } ?? []) + root.subviews.flatMap(anchors)
        }
        func rowAnchors(_ root: NSView) -> [NativeSidebarRowLayoutView] {
            ((root as? NativeSidebarRowLayoutView).map { [$0] } ?? []) + root.subviews.flatMap(rowAnchors)
        }
        func display() {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        try await compatibilityWait {
            display()
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                && window.occlusionState.contains(.visible)
                && anchors(host).contains { $0.title == "New Tab" && $0.bounds.width > 0 }
                && rowAnchors(host).contains { $0.rowID == folder.id.uuidString
                    && $0.hasCommittedCurrentBounds && $0.committedGeneration == $0.generation }
        }
        let newTab = try XCTUnwrap(anchors(host).first { $0.title == "New Tab" })
        func rect(_ view: NSView) -> CGRect { view.convert(view.bounds, to: host) }
        func presentedRect(_ view: NSView) throws -> CGRect {
            var owner = view
            while owner.layer == nil, let parent = owner.superview { owner = parent }
            let source = try XCTUnwrap(owner.layer?.presentation(), "The visible row must have a presentation owner")
            let target = try XCTUnwrap(host.layer?.presentation(), "The visible sidebar must have a presentation owner")
            return source.convert(view.convert(view.bounds, to: owner), to: target)
        }
        // The outer hosting view is flipped: increasing y goes down the list.
        XCTAssertTrue(host.isFlipped)
        try await compatibilityWait {
            display()
            return host.layer?.presentation() != nil
        }
        XCTAssertEqual(try presentedRect(newTab).minY, rect(newTab).minY, accuracy: 1,
                       "Admit the resting presentation before starting disclosure")
        let start = rect(newTab).minY
        var samples: [(CGFloat, CGFloat)] = []
        var checkedMovingHit = false
        var ancestorAtInnerMutation: CGFloat?
        var movingHits: [(presentedY: CGFloat, nativeY: CGFloat, selected: UUID?, palette: PaletteMode?)] = []
        var hitDiagnostics: [String] = []
        let samplingStarted = ProcessInfo.processInfo.systemUptime
        for frame in 0..<48 {
            if frame == 0 {
                Motion.animate(.linear(duration: 0.8)) { store.pins.toggle(folder: folder.id) }
            } else if [6, 12, 18].contains(frame) {
                if frame == 6 { ancestorAtInnerMutation = try presentedRect(newTab).minY }
                Motion.animate(.linear(duration: 0.8)) { store.pins.toggle(folder: inner.id) }
            }
            try await Task.sleep(for: .milliseconds(8))
            display()
            if let current = anchors(host).first(where: { $0.title == "Child 5" }) {
                samples.append((try presentedRect(current).maxY, try presentedRect(newTab).minY))
                if [9, 21].contains(frame), current.enabled {
                    let presentedY = try presentedRect(current).midY
                    let nativeY = rect(current).midY
                    let point = current.convert(NSPoint(x: current.bounds.midX, y: current.bounds.midY), to: nil)
                    // Capture native clipping owners before dispatch, without a
                    // second hitTest that could mutate the batch hit cache.
                    var owners: [String] = []
                    var owner: NSView? = current
                    while let view = owner {
                        owners.append("\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect) clips=\(view.clipsToBounds)")
                        owner = view.superview
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - samplingStarted
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                    }
                    movingHits.append((presentedY, nativeY, store.current, store.palette))
                    hitDiagnostics.append("frame=\(frame) elapsed=\(elapsed) point=\(point) selected=\(String(describing: store.current)) owners=\(owners)")
                    checkedMovingHit = true
                }
            }
        }
        print("NESTED_FOLDER_DISCLOSURE start=\(start) samples=\(samples)")
        print("NESTED_FOLDER_DISCLOSURE_HITS \(hitDiagnostics)")
        // Capture every scheduled frame and event before reporting failures:
        // XCTest's main-actor symbolication must not delay later reversals.
        for hit in movingHits {
            XCTAssertEqual(hit.presentedY, hit.nativeY, accuracy: 1,
                           "The native hit target must track the presented row during motion")
            XCTAssertEqual(hit.selected, tabs[5].id, "A moving child must receive clicks at its visible position")
            XCTAssertNil(hit.palette, "The child hit must not open New Tab")
        }
        let ancestor = try XCTUnwrap(ancestorAtInnerMutation)
        XCTAssertGreaterThan(ancestor, start + 1, "The outer folder must already be opening when the inner one changes")
        XCTAssertLessThan(ancestor, start + 7 * (Look.rowHeight + Look.rowGap) - 1,
                          "The inner mutation must occur before the ancestor finishes")
        XCTAssertFalse(samples.isEmpty, "Opening children must contribute native samples")
        XCTAssertTrue(checkedMovingHit, "The regression must exercise an opening row's hit target")
        XCTAssertTrue(samples.allSatisfy { $0.0 <= $0.1 + 1 },
                      "New Tab must stay below the closing strip, including intermediate frames: \(samples)")
        Motion.instant { store.pins.edit(folder: folder.id) { $0.collapsed = true } }
        try await compatibilityWait {
            display()
            return !anchors(host).contains { $0.title == "Child 5" }
                && abs(start - rect(newTab).minY) < 1
        }
        XCTAssertEqual(rect(newTab).minY, start, accuracy: 1)
    }
}

@MainActor final class LargeFolderDisclosureTests: XCTestCase {
    func testSharedLargeOpeningAndReversalsClipAtTheAuthoritativeSectionExtent() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkLargeDisclosure() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkLargeDisclosure() async throws {
        let previousMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previousMode) }
        try XCTSkipIf(Motion.spaceReduced, "Normal-motion regression requires Reduce Motion off")
        let controls = LargeDisclosureControls()
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let folder = Folder(name: "Large", collapsed: true)
        let tabs = (0..<300).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.tabs = tabs
        store.pins = Pins(entries: [.init(row: .folder(folder))] + tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        let host = NSHostingView(rootView: LargeDisclosureOutline(store: store, controls: controls))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, T.self) }
        }
        func display() {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        func presentedRect(_ view: NSView) throws -> CGRect {
            var owner = view
            while owner.layer == nil, let parent = owner.superview { owner = parent }
            let source = try XCTUnwrap(owner.layer?.presentation(), "Visible paint must have a presentation owner")
            let target = try XCTUnwrap(host.layer?.presentation(), "The sidebar must have a presentation owner")
            return source.convert(view.convert(view.bounds, to: owner), to: target)
        }
        try await compatibilityWait {
            display()
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                && window.occlusionState.contains(.visible)
                && controls.views["new-tab"]?.value?.layer?.presentation() != nil
                && controls.views[folder.id.uuidString]?.value?.layer?.presentation() != nil
                && descendants(host, NativeSidebarRowLayoutView.self).contains {
                    $0.rowID == folder.id.uuidString && $0.hasCommittedCurrentBounds
                        && $0.committedGeneration == $0.generation
                }
        }
        let newTab = try XCTUnwrap(controls.views["new-tab"]?.value)
        let section = try XCTUnwrap(descendants(host, NativeCachedSidebarBatchesView<LargeDisclosurePaintRow>.self).first)
        let start = try presentedRect(newTab).minY
        XCTAssertFalse(section.clipsToBounds, "Resting sections must retain focus/selection overhang")
        func greenPixels(in region: CGRect) throws -> Int {
            let region = region.intersection(host.bounds)
            guard region.width > 0, region.height > 0 else { return 0 }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: region))
            host.cacheDisplay(in: region, to: bitmap)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.greenComponent > 0.8 && color.redComponent < 0.2 && color.blueComponent < 0.2 { count += 1 }
                }
            }
            return count
        }
        var bottomPaint: [Int] = []
        var gapProbes = 0
        var clipping: [Bool] = []
        var newTabHits: [String?] = []
        var witnessedCappedOverflow = false
        var witnessedVisibleChildPaint = false
        var clickDiagnostics: [String] = []
        let samplingStarted = ProcessInfo.processInfo.systemUptime
        for frame in 0..<48 {
            if [0, 6, 12, 18].contains(frame) {
                // A slow explicit animation exposes the short-extent/large-travel
                // phase; the test still samples48 frames with8ms spacing.
                Motion.animate(.linear(duration: 4)) { store.pins.toggle(folder: folder.id) }
            }
            try await Task.sleep(for: .milliseconds(8))
            display()
            let footer = try presentedRect(newTab)
            let extent = section.convert(section.bounds, to: host)
            clipping.append(section.clipsToBounds)
            if [3, 9, 21].contains(frame) {
                clickDiagnostics.append("frame=\(frame) elapsed=\(ProcessInfo.processInfo.systemUptime - samplingStarted) footer=\(footer) extent=\(extent) host=\(host.bounds) eligible=\(footer.maxY + 28 < host.bounds.maxY)")
            }
            for (id, weak) in controls.views where id != "new-tab" && id != folder.id.uuidString {
                if let child = weak.value, child.window === window {
                    let raw = try presentedRect(child)
                    witnessedCappedOverflow = witnessedCappedOverflow ||
                        (raw.maxY > extent.maxY + 1 && raw.minY < host.bounds.maxY && raw.maxY > 0)
                }
            }
            if footer.maxY + 28 < host.bounds.maxY {
                let belowFooter = try greenPixels(in: CGRect(x: 100, y: footer.maxY + 4, width: 2, height: 24))
                let gapHeight = max(0, footer.minY - extent.maxY - 2)
                let inGap = try greenPixels(in: CGRect(x: 100, y: extent.maxY + 1, width: 2, height: gapHeight))
                if gapHeight > 0 { gapProbes += 1 }
                bottomPaint.append(belowFooter + inGap)
                let insidePaint = try greenPixels(in: CGRect(x: 100, y: extent.minY + Look.rowHeight,
                    width: 2, height: max(0, extent.height - Look.rowHeight)))
                witnessedVisibleChildPaint = witnessedVisibleChildPaint || insidePaint > 0
                if [3, 9, 21].contains(frame) {
                    controls.selected = nil
                    let point = newTab.convert(NSPoint(x: newTab.bounds.midX, y: newTab.bounds.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                    }
                    newTabHits.append(controls.selected)
                }
            }
        }
        // Report only after all scheduled observations and reversals complete.
        print("LARGE_FOLDER_DISCLOSURE_CLICKS \(clickDiagnostics) hits=\(newTabHits)")
        XCTAssertTrue(witnessedCappedOverflow, "The fixture must exercise raw children extending past the short outer extent")
        XCTAssertTrue(witnessedVisibleChildPaint, "The bitmap probe must capture actual visible child paint")
        XCTAssertFalse(bottomPaint.isEmpty)
        XCTAssertGreaterThan(gapProbes, 0, "The fixture must probe the gap above New Tab as well as the area below it")
        XCTAssertTrue(bottomPaint.allSatisfy { $0 == 0 }, "Children must stay inside their section near New Tab: \(bottomPaint)")
        XCTAssertTrue(clipping.allSatisfy { $0 }, "Shared native clipping must cover every active-disclosure sample")
        XCTAssertFalse(newTabHits.isEmpty, "Scheduled footer clicks must be visible: \(clickDiagnostics)")
        for hit in newTabHits { XCTAssertEqual(hit, "new-tab", "Overflowing rows must not take New Tab's native hit") }
        Motion.instant { store.pins.edit(folder: folder.id) { $0.collapsed = true } }
        try await compatibilityWait {
            display()
            return controls.views[tabs[0].id.uuidString]?.value?.window == nil
                && !section.clipsToBounds && abs(newTab.convert(newTab.bounds, to: host).minY - start) < 1
        }
        XCTAssertFalse(section.clipsToBounds, "Settled sections must restore focus/selection overhang")
    }
}

@MainActor private final class LargeDisclosureControls {
    final class WeakMarker {
        weak var value: LargeDisclosureMarker?
        init(_ value: LargeDisclosureMarker) { self.value = value }
    }
    var views: [String: WeakMarker] = [:]
    var selected: String?
}
@MainActor private final class LargeDisclosureMarker: NSView {
    var enabled = true
    var selected: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { if enabled { selected?() } }
}
private struct LargeDisclosurePaintRow: NSViewRepresentable {
    let id: String
    let color: NSColor
    let controls: LargeDisclosureControls
    func makeNSView(context: Context) -> LargeDisclosureMarker {
        let view = LargeDisclosureMarker()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.selected = { controls.selected = id }
        controls.views[id] = .init(view)
        return view
    }
    func updateNSView(_ view: LargeDisclosureMarker, context: Context) { view.enabled = context.environment.isEnabled }
}
private struct LargeDisclosureOutline: View {
    @ObservedObject var store: TabStore
    let controls: LargeDisclosureControls
    var body: some View {
        let rows = SidebarRows(tabs: store.tabs, splits: [], shape: store.pins).rows
        ScrollView {
            VStack(spacing: Look.rowGap) {
                NativeCachedSidebarBatchSectionRows(rows: rows, modelIDs: Set(store.pins.entries.map(\.id)), owner: store) { row, _, _ in
                    LargeDisclosurePaintRow(id: row.id,
                        color: row.visible.entry.folder == nil ? NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) : .gray,
                        controls: controls)
                }
                LargeDisclosurePaintRow(id: "new-tab", color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), controls: controls)
                    .frame(height: Look.rowHeight)
            }.frame(maxWidth: .infinity)
        }.background(Color.black)
    }
}
