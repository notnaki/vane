import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

/// Real compositor positions are required. Model NSView frames cannot establish
/// animation continuity, and an unavailable presentation baseline is a failure.
@MainActor final class NativeSidebarMotionTests: XCTestCase {
    private enum AdmissionError: Error { case noIntermediatePresentation }
    private final class WeakField {
        weak var value: NSTextField?
        init(_ value: NSTextField) { self.value = value }
    }
    private final class Controls { var fields: [String: WeakField] = [:] }
    private struct NativeRow: NSViewRepresentable {
        let id: String
        let index: Int
        let total: Int
        let controls: Controls
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.wantsLayer = true
            controls.fields[id] = WeakField(field)
            return field
        }
        func updateNSView(_ field: NSTextField, context: Context) {
            field.stringValue = "\(index)/\(total)"
        }
    }
    private func rows(_ count: Int) -> [SidebarRows.Row] {
        (0..<count).map { index in
            SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Motion \(index)"))), depth: 0), tab: nil)
        }
    }
    private func owner(of field: NSView, in container: NSView) -> NSView? {
        var current: NSView? = field
        while let candidate = current, candidate.superview !== container { current = candidate.superview }
        return current
    }
    private func presentedRect(_ view: NSView, in container: NSView) throws -> CGRect {
        let source = try XCTUnwrap(view.layer?.presentation(), "Native source presentation layer was not admitted")
        let target = try XCTUnwrap(container.layer?.presentation(), "Native ancestor presentation layer was not admitted")
        // Both ends belong to the committed presentation tree. CALayer performs
        // the complete ancestor conversion, including native hosting/clip layers.
        return source.convert(source.bounds, to: target)
    }
    private func display(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }
    private func admitPresentationSampling(sentinel: NSView, root: NSView, window: NSWindow) async throws {
        display(window)
        try await Task.sleep(for: .milliseconds(80))
        let initial = try presentedRect(sentinel, in: root).minX
        let layer = try XCTUnwrap(sentinel.layer)
        let start = layer.position
        let end = CGPoint(x: start.x + 80, y: start.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = end
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: start)
        animation.toValue = NSValue(point: end)
        animation.duration = 0.24
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "native-motion-admission")
        CATransaction.flush()
        var samples: [CGFloat] = []
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(20))
            display(window)
            samples.append(try presentedRect(sentinel, in: root).minX)
        }
        layer.removeAnimation(forKey: "native-motion-admission")
        guard samples.contains(where: { $0 > initial + 2 && $0 < initial + 78 }) else {
            XCTFail("Native presentation sampling must observe real intermediate motion; samples=\(samples)")
            throw AdmissionError.noIntermediatePresentation
        }
    }

    /// Moving original40 to16 changes its permanent owner's lower bound from40
    /// to16. Original41 keeps authoritative index41. Animating a compensating
    /// child offset after jumping the native parent makes this stationary row
    /// visibly travel away and return, which must fail this actual-render gate.
    func testStationaryRowDoesNotTravelWhenAnotherMemberMovesBeforeItsOwner() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        var rows = rows(100)
        let original = rows
        let controls = Controls()
        let pitch = Look.rowHeight + Look.rowGap
        let owner = NativeCachedSidebarBatchesView<NativeRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 4095))
        owner.wantsLayer = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 320))
        root.wantsLayer = true
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = owner
        root.addSubview(scroll)
        let sentinel = NSView(frame: NSRect(x: 5, y: 5, width: 3, height: 3))
        sentinel.wantsLayer = true
        sentinel.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(sentinel)
        let window = NSWindow(contentRect: root.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            sentinel.layer?.removeAllAnimations()
            owner.detach()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        var initialTransaction = Transaction()
        initialTransaction.disablesAnimations = true
        func configure(_ transaction: Transaction) {
            owner.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: EnvironmentValues(), transaction: transaction) { row, index, total in
                NativeRow(id: row.id, index: index, total: total, controls: controls)
            }
            owner.reconcile(visible: owner.convert(scroll.contentView.bounds, from: scroll.contentView))
            display(window)
        }
        configure(initialTransaction)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 36 * pitch))
        scroll.reflectScrolledClipView(scroll.contentView)
        owner.reconcile(visible: owner.convert(scroll.contentView.bounds, from: scroll.contentView))
        display(window)
        try await compatibilityWait { controls.fields[original[41].id]?.value?.window === window }
        try await admitPresentationSampling(sentinel: sentinel, root: root, window: window)
        let field = try XCTUnwrap(controls.fields[original[41].id]?.value)
        let originalHost = try XCTUnwrap(self.owner(of: field, in: owner))
        let initialRect = try presentedRect(field, in: root)
        XCTAssertGreaterThan(initialRect.intersection(root.bounds).height, 1, "Stationary native row must start in the actual viewport")
        let moving = rows.remove(at: 40)
        rows.insert(moving, at: 16)
        configure(Transaction(animation: .linear(duration: 0.4)))
        var samples: [CGFloat] = []
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            display(window)
            samples.append(try presentedRect(field, in: root).minY)
        }
        XCTAssertTrue(controls.fields[original[41].id]?.value === field, "A structural animation must keep the actual native control")
        XCTAssertTrue(self.owner(of: field, in: owner) === originalHost, "A structural animation must keep the original hosting graph")
        XCTAssertEqual(field.stringValue, "41/100", "Authoritative content updates while motion runs")
        XCTAssertLessThanOrEqual(samples.map { abs($0 - initialRect.minY) }.max() ?? .infinity, 1.5,
                                 "Stationary original41 visibly travelled after owner lower40→16; initial=\(initialRect.minY) samples=\(samples)")
    }

    /// A fix which simply disables structural animation would keep stationary
    /// rows still but would make a reordered row teleport. Sample the actual
    /// moving native control, through all of its presentation ancestors.
    func testReorderedRowTravelsContinuouslyInsideItsOriginalOwner() async throws {
        TestEnvironment.prepare()
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(oldMode) }
        XCTAssertFalse(Motion.reduced, "Normal-motion presentation gate requires system Reduce Motion off")
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        try await fixture.admit(row: 40)
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window)
        let movingID = fixture.rows[40].id
        let field = try XCTUnwrap(fixture.controls.fields[movingID]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        let start = try presentedRect(field, in: fixture.root).minY
        let target = start + fixture.documentDisplacement(from: 40, to: 16)
        let moved = fixture.rows.remove(at: 40)
        fixture.rows.insert(moved, at: 16)
        fixture.configure(Transaction(animation: .linear(duration: 0.4)))
        let lower = min(start, target)
        let upper = max(start, target)
        var samples: [CGFloat] = []
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(20))
            display(fixture.window)
            samples.append(try presentedRect(field, in: fixture.root).minY)
        }
        XCTAssertTrue(fixture.controls.fields[movingID]?.value === field)
        XCTAssertTrue(owner(of: field, in: fixture.owner) === originalOwner)
        XCTAssertTrue(samples.contains { $0 > lower + 2 && $0 < upper - 2 },
                      "Reordered row must have actual intermediate positions, not teleport; start=\(start) target=\(target) samples=\(samples)")
        XCTAssertEqual(try XCTUnwrap(samples.last), target, accuracy: 1.5)
        XCTAssertTrue(samples.allSatisfy { $0 >= lower - 1.5 && $0 <= upper + 1.5 },
                      "Linear structural motion must not overshoot due to a native-parent coordinate change: \(samples)")
        XCTAssertEqual(field.stringValue, "16/100")
    }

    /// The SDK exposes system Reduce Motion as read-only. Exercise the actual
    /// placement policy without modifying global OS preferences or inventing a
    /// test-only environment override at the hosting boundary.
    func testReduceMotionPolicySuppressesAnInheritedPlacementAnimation() {
        TestEnvironment.prepare()
        let transaction = Transaction(animation: .linear(duration: 0.4))
        XCTAssertNotNil(NativeSidebarPlacementMotion.animation(transaction: transaction,
            reduceMotion: false, reducedByPolicy: false))
        XCTAssertNil(NativeSidebarPlacementMotion.animation(transaction: transaction,
            reduceMotion: true, reducedByPolicy: false),
            "System Reduce Motion must override even an explicit structural animation")
    }

    /// A disabled inherited transaction must also cross the NSHostingView
    /// boundary. Sample its real native control instead of the policy value.
    func testDisabledTransactionMovesReorderedNativeRowImmediately() async throws {
        TestEnvironment.prepare()
        try await assertImmediateReorder(disablesAnimations: true, batterySaver: false)
    }

    func testBatterySaverMovesReorderedNativeRowImmediately() async throws {
        TestEnvironment.prepare()
        try await assertImmediateReorder(disablesAnimations: false, batterySaver: true)
    }

    private func assertImmediateReorder(disablesAnimations: Bool, batterySaver: Bool) async throws {
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(batterySaver ? .alwaysOn : .off)
        defer { BatterySaver.shared.setMode(oldMode) }
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        fixture.configure(Fixture.instant)
        try await fixture.admit(row: 40)
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window)
        let movingID = fixture.rows[40].id
        let field = try XCTUnwrap(fixture.controls.fields[movingID]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        let start = try presentedRect(field, in: fixture.root).minY
        let target = start + fixture.documentDisplacement(from: 40, to: 16)
        let moved = fixture.rows.remove(at: 40)
        fixture.rows.insert(moved, at: 16)
        var transaction = Transaction(animation: .linear(duration: 0.4))
        transaction.disablesAnimations = disablesAnimations
        fixture.configure(transaction)
        for delay in [20, 80, 160] {
            try await Task.sleep(for: .milliseconds(delay))
            display(fixture.window)
            XCTAssertEqual(try presentedRect(field, in: fixture.root).minY, target, accuracy: 1.5,
                           "Reduced-motion structural placement must be immediate, including under an inherited animation")
        }
        XCTAssertTrue(fixture.controls.fields[movingID]?.value === field)
        XCTAssertTrue(owner(of: field, in: fixture.owner) === originalOwner)
        XCTAssertEqual(field.stringValue, "16/100")
    }

    /// Cached roots can retain a prior structural transaction. A later clip
    /// scroll must move its already-mounted controls by the clip delta at once;
    /// it must not replay that old structural motion on the native document.
    func testClipScrollingDoesNotReplayThePreviousStructuralAnimation() async throws {
        TestEnvironment.prepare()
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(oldMode) }
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        try await fixture.admit(row: 41)
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window)
        let field = try XCTUnwrap(fixture.controls.fields[fixture.rows[41].id]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        fixture.configure(Transaction(animation: .linear(duration: 1)))
        let start = try presentedRect(field, in: fixture.root).minY
        let documentOrigin = fixture.owner.convert(NSPoint.zero, to: fixture.root).y
        let before = fixture.owner.batchCounts
        let origin = fixture.scroll.contentView.bounds.origin
        fixture.scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 12))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        fixture.owner.reconcile(visible: fixture.owner.convert(fixture.scroll.contentView.bounds, from: fixture.scroll.contentView))
        display(fixture.window)
        let target = start + fixture.owner.convert(NSPoint.zero, to: fixture.root).y - documentOrigin
        XCTAssertEqual(abs(target - start), 12, accuracy: 0.01)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            display(fixture.window)
            XCTAssertEqual(try presentedRect(field, in: fixture.root).minY, target, accuracy: 1.5,
                           "Clip scrolling must immediately expose the new viewport without tweening or replaying the structural transaction")
        }
        XCTAssertTrue(owner(of: field, in: fixture.owner) === originalOwner)
        XCTAssertEqual(fixture.owner.batchCounts.rootUpdates, before.rootUpdates,
                       "A small clip change must not submit another SwiftUI root")
        XCTAssertEqual(fixture.owner.batchCounts.coldGraphCreates, before.coldGraphCreates)
    }

    @MainActor private final class Fixture {
        var rows: [SidebarRows.Row]
        var environment = EnvironmentValues()
        let controls = Controls()
        let pitch = Look.rowHeight + Look.rowGap
        let owner: NativeCachedSidebarBatchesView<NativeRow>
        let root: NSView
        let scroll: NSScrollView
        let sentinel: NSView
        let window: NSWindow
        static var instant: Transaction {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            return transaction
        }
        init(rows: [SidebarRows.Row]) {
            _ = NSApplication.shared
            self.rows = rows
            let rowPitch = Look.rowHeight + Look.rowGap
            owner = NativeCachedSidebarBatchesView(frame: NSRect(x: 0, y: 0, width: 250,
                height: CGFloat(rows.count) * rowPitch - Look.rowGap))
            owner.wantsLayer = true
            root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 320))
            root.wantsLayer = true
            scroll = NSScrollView(frame: root.bounds)
            scroll.documentView = owner
            root.addSubview(scroll)
            sentinel = NSView(frame: NSRect(x: 5, y: 5, width: 3, height: 3))
            sentinel.wantsLayer = true
            sentinel.layer?.backgroundColor = NSColor.systemRed.cgColor
            root.addSubview(sentinel)
            window = NSWindow(contentRect: root.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            configure(Self.instant)
        }
        func configure(_ transaction: Transaction) {
            owner.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment, transaction: transaction) { [controls] row, index, total in
                NativeRow(id: row.id, index: index, total: total, controls: controls)
            }
            owner.reconcile(visible: owner.convert(scroll.contentView.bounds, from: scroll.contentView))
            display()
        }
        /// Expected travel comes from the hand-checked40→16 move and AppKit's
        /// coordinate conversion, never from the hosted control's model frame.
        func documentDisplacement(from oldIndex: Int, to newIndex: Int) -> CGFloat {
            owner.convert(NSPoint(x: 0, y: CGFloat(newIndex) * pitch), to: root).y
                - owner.convert(NSPoint(x: 0, y: CGFloat(oldIndex) * pitch), to: root).y
        }
        func display() {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func admit(row index: Int) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 36 * pitch))
            scroll.reflectScrolledClipView(scroll.contentView)
            owner.reconcile(visible: owner.convert(scroll.contentView.bounds, from: scroll.contentView))
            display()
            try await compatibilityWait { self.controls.fields[self.rows[index].id]?.value?.window === self.window }
        }
        func close() {
            sentinel.layer?.removeAllAnimations()
            owner.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
}
