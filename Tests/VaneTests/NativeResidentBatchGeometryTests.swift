import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Default-policy integration and actual native geometry; these parked public
/// URLs are correctness fixtures and cannot establish frame-rate percentiles.
@MainActor final class NativeResidentBatchGeometryTests: XCTestCase {
    private final class WeakButton {
        weak var value: NSButton?
        init(_ value: NSButton) { self.value = value }
    }
    private final class Controls { var fields: [String: WeakButton] = [:] }
    private struct Control: NSViewRepresentable {
        let id: String
        let controls: Controls
        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(title: id, target: nil, action: nil)
            controls.fields[id] = WeakButton(button)
            return button
        }
        func updateNSView(_ button: NSButton, context: Context) {
            button.isEnabled = context.environment.isEnabled
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
            // UUID titles must truncate inside the proposed sidebar width, as
            // real sidebar labels do, rather than impose a wider intrinsic row.
            CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
                   height: nsView.intrinsicContentSize.height)
        }
    }
    private struct Outline: View {
        @ObservedObject var store: TabStore
        let controls: Controls
        @State private var cache = Feel02SidebarRowsCache()
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    SidebarSectionRows(store: store,
                        snapshot: cache.resolve(in: store, shape: store.todayShape),
                        transition: .opacity) { row, _, _ in
                            Control(id: row.id, controls: controls)
                        }
                }
            }
        }
    }
    private func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, T.self) }
    }
    private func reports(_ view: NSView) -> [any NativeCachedSidebarBatchesReporting] {
        ((view as? any NativeCachedSidebarBatchesReporting).map { [$0] } ?? []) + view.subviews.flatMap(reports)
    }

    func testShippingDefaultsBoundNativeControlsAndCoverHundredAndThousandRowFarJumps() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let flags = ["VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE", "VANE_EXPERIMENT_THREE_RESIDENT_BATCHES"]
        let previous = flags.map { ProcessInfo.processInfo.environment[$0] }
        flags.forEach { unsetenv($0) }
        defer {
            for (flag, value) in zip(flags, previous) {
                if let value { setenv(flag, value, 1) } else { unsetenv(flag) }
            }
            app.setActivationPolicy(policy)
        }
        // Deliberately no environment override or enabled:true owner initializer.
        XCTAssertTrue(NativeCachedSidebarBatchesExperiment.enabled, "Shipping default must select the native path")
        XCTAssertTrue(NativeSidebarResidentWindowExperiment.enabled, "Shipping default must select the resident policy")
        let lease = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            for count in [100, 1_000] { try await checkDefaultGeometry(count: count) }
        } catch { failure = error }
        do { try await lease.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Native application loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkDefaultGeometry(count: Int) async throws {
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let tabs = (0..<count).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "https://www.swift.org/documentation/#resident-\(index)")!,
                     Parked(title: "Resident row \(index)", needsRecovery: true))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        store.palette = nil
        let controls = Controls()
        let host = NSHostingView(rootView: Outline(store: store, controls: controls))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 260, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            store.dropStashes()
            SharedTabs.release(tabs)
            tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { self.reports(host).count == 1 }
        let report = try XCTUnwrap(reports(host).first)
        let owner = try XCTUnwrap(report as? NSView)
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let document = try XCTUnwrap(scroll.documentView)
        let pitch = Look.rowHeight + Look.rowGap
        let extent = CGFloat(count) * pitch - Look.rowGap
        XCTAssertTrue(report.usesThreeBatchBudget)
        XCTAssertEqual(report.requestedMaxGraphBudget, 3)
        XCTAssertFalse(report.stagingEnabled)
        try await compatibilityWait { abs(document.frame.height - extent) < 1 }
        var previousControls: [String: WeakButton] = [:]
        for fraction in [CGFloat(0), 0.5, 1, 0.25, 0] {
            let y = max(0, extent - scroll.contentView.bounds.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await compatibilityWait {
                let attached = controls.fields.values.compactMap(\.value).filter { $0.window === window }
                guard attached.count == report.attachedLogicalRows else { return false }
                let visible = owner.convert(scroll.contentView.bounds, from: scroll.contentView)
                return (0..<count).allSatisfy { index in
                    let frame = CGRect(x: 0, y: CGFloat(index) * pitch,
                                       width: owner.bounds.width, height: Look.rowHeight)
                    return frame.intersection(visible).height <= 0
                        || controls.fields[tabs[index].id.uuidString]?.value?.window === window
                }
            }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(document.frame.height, extent, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
            XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 1)
            XCTAssertLessThanOrEqual(report.residentRowRange.count, 24)
            // End groups keep real key-view entry/exit controls available. They
            // are separate from the 24-row viewport resident range.
            XCTAssertLessThanOrEqual(report.attachedGraphCount, 5)
            XCTAssertLessThanOrEqual(report.attachedLogicalRows, 40)
            XCTAssertFalse(report.visibleCoverageExceedsBudget)
            let mounted = controls.fields.values.compactMap(\.value).filter { $0.window === window }
            XCTAssertEqual(mounted.count, report.attachedLogicalRows)
            let rowAnchors = Dictionary(uniqueKeysWithValues:
                descendants(owner, NativeSidebarRowLayoutView.self)
                    .filter { $0.window === window }.map { ($0.rowID, $0) })
            for index in 0..<count {
                let id = tabs[index].id.uuidString
                guard let field = controls.fields[id]?.value, field.window === window else { continue }
                let anchor = try XCTUnwrap(rowAnchors[id])
                let rowFrame = anchor.convert(anchor.bounds, to: owner)
                XCTAssertEqual(rowFrame.minY, CGFloat(index) * pitch, accuracy: 1)
                XCTAssertEqual(rowFrame.height, Look.rowHeight, accuracy: 1)
                XCTAssertEqual(rowFrame.width, owner.bounds.width, accuracy: 1)
                // SwiftUI centers this intrinsic-height NSButton in the row's
                // fixed frame. Verify its actual center and containment rather
                // than mistaking the button's top for the row's top.
                let frame = field.convert(field.bounds, to: owner)
                let rowTop = CGFloat(index) * pitch
                XCTAssertEqual(frame.midY, rowFrame.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(frame.minY, rowTop - 1)
                XCTAssertLessThanOrEqual(frame.maxY, rowTop + Look.rowHeight + 1)
                if let old = previousControls[id]?.value { XCTAssertTrue(old === field) }
                previousControls[id] = WeakButton(field)
            }
        }
        // Warm every canonical owner, then prove native protection work is
        // bounded by live roots rather than all detached cached controls.
        report.recordsProtectionTreeScans = true
        for first in stride(from: 0, to: count, by: 8) {
            let y = min(max(0, extent - scroll.contentView.bounds.height), CGFloat(first) * pitch)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                let visible = owner.convert(scroll.contentView.bounds, from: scroll.contentView)
                return (0..<count).allSatisfy { index in
                    let frame = CGRect(x: 0, y: CGFloat(index) * pitch,
                        width: owner.bounds.width, height: Look.rowHeight)
                    return !frame.intersects(visible)
                        || controls.fields[tabs[index].id.uuidString]?.value?.window === window
                }
            }
        }
        XCTAssertEqual(report.cachedGraphCount, (count + 7) / 8, "The scan regression needs a fully warmed cache")
        XCTAssertGreaterThan(report.batchCounts.protectionOwnerTreeScans, 0,
                             "Instrumentation must observe real native protection scans")
        XCTAssertEqual(report.batchCounts.detachedProtectionOwnerTreeScans, 0,
                       "Detached cached owner trees must never be recursively inspected during scroll")

        let highlightedIndex = 40, interactionIndex = 48
        // Straddle both owners in the actual viewport, regardless of the
        // direction-sensitive resident guard band used for the preceding jump.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(highlightedIndex + 4) * pitch))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait {
            controls.fields[tabs[highlightedIndex].id.uuidString]?.value?.window === window
                && controls.fields[tabs[interactionIndex].id.uuidString]?.value?.window === window
        }
        let highlighted = try XCTUnwrap(controls.fields[tabs[highlightedIndex].id.uuidString]?.value)
        highlighted.highlight(true)
        defer { highlighted.highlight(false) }
        let interaction = try XCTUnwrap(owner as? any NativeSidebarInteractionRetaining)
        let interactionToken = UUID()
        interaction.setInteraction(true, row: tabs[interactionIndex].id.uuidString, token: interactionToken)
        defer { interaction.setInteraction(false, row: tabs[interactionIndex].id.uuidString, token: interactionToken) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, extent - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait {
            controls.fields[tabs[count - 1].id.uuidString]?.value?.window === window
                && controls.fields[tabs[interactionIndex].id.uuidString]?.value?.window === window
        }
        XCTAssertTrue(highlighted.window === window, "A live native highlight still protects its original owner")
        XCTAssertTrue(highlighted.cell?.isHighlighted == true)
        XCTAssertEqual(report.batchCounts.detachedProtectionOwnerTreeScans, 0)
        report.recordsProtectionTreeScans = false
        XCTAssertEqual(report.batchCounts.rootUpdates, 0,
                       "Scrolling alone must reuse roots rather than resubmit SwiftUI content")
        // Stable owners may interleave after a deliberate transpose. Report the
        // exception truthfully instead of claiming 24 controls / 3 roots, and
        // keep attachment bounded by resident row identities, not total rows.
        highlighted.highlight(false)
        interaction.setInteraction(false, row: tabs[interactionIndex].id.uuidString, token: interactionToken)
        window.makeFirstResponder(nil)
        let transposed = (0..<8).flatMap { offset in Array(stride(from: offset, to: count, by: 8)) }
        store.todayShape = Pins(entries: transposed.map { .init(row: .tab(tabs[$0].id.uuidString)) })
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return report.attachedGraphBudgetExceeded
                && report.residentRowRange.contains(0)
                && transposed.prefix(8).allSatisfy { controls.fields[tabs[$0].id.uuidString]?.value?.window === window }
        }
        XCTAssertEqual(report.nominalAttachedGraphBudget, 5)
        XCTAssertTrue(report.attachedGraphBudgetExceeded)
        XCTAssertLessThanOrEqual(report.attachedGraphCount, report.residentRowRange.count + 2)
        XCTAssertLessThanOrEqual(report.attachedLogicalRows, (report.residentRowRange.count + 2) * 8)
        for index in transposed.prefix(8) {
            let field = try XCTUnwrap(controls.fields[tabs[index].id.uuidString]?.value)
            if let previous = previousControls[tabs[index].id.uuidString]?.value {
                XCTAssertTrue(previous === field, "Reordering preserves the existing native control identity")
            }
        }

    }
}
