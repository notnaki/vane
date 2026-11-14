import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

/// Real compositor positions are required. Model NSView frames cannot establish
/// animation continuity, and an unavailable presentation baseline is a failure.
@MainActor final class NativeSidebarMotionTests: XCTestCase {
    private enum AdmissionError: Error { case noIntermediatePresentation, presentationTimedOut }
    private enum ProbeMode { case animated, frozen, stationary }
    private struct PresentationProbe {
        let initial: CGFloat
        let samples: [CGFloat]
        let elapsed: [CFTimeInterval]
        var hasInteriorPosition: Bool {
            samples.contains { $0 > initial + 2 && $0 < initial + 78 }
        }
        var observedMotion: Bool {
            guard hasInteriorPosition, let low = samples.min(), let high = samples.max() else { return false }
            return high - low > 2
        }
    }
    private final class WeakField {
        weak var value: NSTextField?
        init(_ value: NSTextField) { self.value = value }
    }
    @MainActor private final class Controls { var fields: [String: WeakField] = [:] }
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
    private func withApplicationLoop(_ body: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        // The body's fixture defers run before the owned AppKit loop closes.
        do { try await body() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error }
            else { XCTFail("Native motion fixture loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
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
    private func admitPresentationSampling(sentinel: NSView, root: NSView, window: NSWindow,
                                          field: NSView, host: NSView, container: NSView,
                                          firstSampleDelay: Duration = .milliseconds(20)) async throws {
        let probe = try await observePresentationSampling(sentinel: sentinel, root: root, window: window,
            field: field, host: host, container: container, firstSampleDelay: firstSampleDelay)
        guard probe.observedMotion else {
            XCTFail("Native presentation sampling must observe real intermediate motion; samples=\(probe.samples) elapsed=\(probe.elapsed) running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow)")
            throw AdmissionError.noIntermediatePresentation
        }
    }
    private func observePresentationSampling(sentinel: NSView, root: NSView, window: NSWindow,
                                            field: NSView, host: NSView, container: NSView,
                                            firstSampleDelay: Duration = .milliseconds(20),
                                            mode: ProbeMode = .animated) async throws -> PresentationProbe {
        XCTAssertTrue(NSApp.isRunning, "Native compositor sampling requires an owned AppKit loop")
        // Share the existing compatibility admission budget with the probe. Eight
        // asynchronous observations alone do not impose a wall-clock deadline.
        let admissionDeadline = ContinuousClock.now + .seconds(10)
        try await compatibilityWait {
            guard ContinuousClock.now < admissionDeadline else { throw AdmissionError.presentationTimedOut }
            if NSApp.isHidden { NSApp.unhide(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            self.display(window)
            guard NSApp.isRunning, NSApp.isActive, !NSApp.isHidden,
                  window.isKeyWindow, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  window.contentView === root, root.window === window,
                  sentinel.window === window, field.window === window, host.window === window,
                  container.window === window, self.owner(of: field, in: container) === host,
                  !field.isHiddenOrHasHiddenAncestor, !host.isHiddenOrHasHiddenAncestor,
                  !field.visibleRect.intersection(field.bounds).isEmpty,
                  host.layer?.presentation() != nil, container.layer?.presentation() != nil,
                  let fieldLayer = field.layer?.presentation(),
                  let sentinelLayer = sentinel.layer?.presentation(),
                  let rootLayer = root.layer?.presentation() else { return false }
            let presented = fieldLayer.convert(fieldLayer.bounds, to: rootLayer)
            let model = field.convert(field.bounds, to: root)
            let marker = sentinelLayer.convert(sentinelLayer.bounds, to: rootLayer)
            // Admit only the resting initial owner, before starting the sentinel
            // or the tested row mutation. No desired motion outcome is awaited.
            return presented.intersection(root.bounds).height > 1
                && abs(presented.minX - model.minX) < 0.5
                && abs(presented.minY - model.minY) < 0.5
                && abs(marker.minX - sentinel.convert(sentinel.bounds, to: root).minX) < 0.5
        }
        guard ContinuousClock.now < admissionDeadline else { throw AdmissionError.presentationTimedOut }
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
        // This independent readiness witness must still be moving when an
        // executor-delayed observation arrives. The tested row action has not
        // begun; its animation duration and samples remain unchanged.
        animation.autoreverses = true
        animation.repeatCount = .infinity
        if mode == .frozen {
            animation.speed = 0
            animation.timeOffset = 0.12
        }
        let began = CACurrentMediaTime()
        if mode != .stationary { layer.add(animation, forKey: "native-motion-admission") }
        defer { layer.removeAnimation(forKey: "native-motion-admission") }
        let addedAt = CACurrentMediaTime() - began
        CATransaction.flush()
        let committedAt = CACurrentMediaTime() - began
        var samples: [CGFloat] = []
        var elapsed: [CFTimeInterval] = []
        var phases: [[CFTimeInterval]] = []
        for index in 0..<8 {
            let requestedAt = CACurrentMediaTime() - began
            try await Task.sleep(for: index == 0 ? firstSampleDelay : .milliseconds(20))
            let resumedAt = CACurrentMediaTime() - began
            guard ContinuousClock.now < admissionDeadline else { throw AdmissionError.presentationTimedOut }
            window.contentView?.layoutSubtreeIfNeeded()
            let laidOutAt = CACurrentMediaTime() - began
            window.displayIfNeeded()
            let displayedAt = CACurrentMediaTime() - began
            CATransaction.flush()
            let flushedAt = CACurrentMediaTime() - began
            samples.append(try presentedRect(sentinel, in: root).minX)
            elapsed.append(CACurrentMediaTime() - began)
            phases.append([requestedAt, resumedAt, laidOutAt, displayedAt, flushedAt])
            guard ContinuousClock.now < admissionDeadline else { throw AdmissionError.presentationTimedOut }
        }
        print("NATIVE_MOTION_ADMISSION case=\(name) added=\(addedAt) committed=\(committedAt) phases=requested,resumed,layout,display,flush values=\(phases) samples=\(samples) elapsed=\(elapsed)")
        return PresentationProbe(initial: initial, samples: samples, elapsed: elapsed)
    }

    /// Moving original40 to16 changes its permanent owner's lower bound from40
    /// to16. Original41 keeps authoritative index41. Animating a compensating
    /// child offset after jumping the native parent makes this stationary row
    /// visibly travel away and return, which must fail this actual-render gate.
    func testStationaryRowDoesNotTravelWhenAnotherMemberMovesBeforeItsOwner() async throws {
        try await withApplicationLoop { try await assertStationaryRowDoesNotTravelWhenAnotherMemberMovesBeforeItsOwner() }
    }

    private func assertStationaryRowDoesNotTravelWhenAnotherMemberMovesBeforeItsOwner() async throws {
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
        @MainActor func configure(_ transaction: Transaction) {
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
        let field = try XCTUnwrap(controls.fields[original[41].id]?.value)
        let originalHost = try XCTUnwrap(self.owner(of: field, in: owner))
        try await admitPresentationSampling(sentinel: sentinel, root: root, window: window,
                                           field: field, host: originalHost, container: owner)
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
        try await withApplicationLoop { try await assertReorderedRowTravelsContinuouslyInsideItsOriginalOwner() }
    }

    private func assertReorderedRowTravelsContinuouslyInsideItsOriginalOwner() async throws {
        TestEnvironment.prepare()
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(oldMode) }
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Normal-motion interpolation is unavailable while system Reduce Motion is enabled")
        XCTAssertFalse(Motion.reduced, "Normal-motion presentation gate requires system Reduce Motion off")
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        try await fixture.admit(row: 40)
        let movingID = fixture.rows[40].id
        let field = try XCTUnwrap(fixture.controls.fields[movingID]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window,
                                           field: field, host: originalOwner, container: fixture.owner)
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
        try await withApplicationLoop {
            try await assertImmediateReorder(disablesAnimations: true, batterySaver: false)
        }
    }

    func testBatterySaverMovesReorderedNativeRowImmediately() async throws {
        TestEnvironment.prepare()
        try await withApplicationLoop {
            try await assertImmediateReorder(disablesAnimations: false, batterySaver: true)
        }
    }

    /// Admission must establish current sampling capability even when the first
    /// observation is delivered after a complete 240 ms readiness pulse.
    func testPresentationAdmissionSurvivesDelayedFirstObservation() async throws {
        try await withApplicationLoop {
            try await assertImmediateReorder(disablesAnimations: true, batterySaver: false,
                                             firstAdmissionSampleDelay: .milliseconds(750))
        }
    }

    func testPresentationAdmissionRejectsFrozenInterior() async throws {
        try await withApplicationLoop {
            let probe = try await observeControl(mode: .frozen)
            XCTAssertTrue(probe.hasInteriorPosition, "Control must expose a real interior presentation position")
            XCTAssertFalse(probe.observedMotion, "A frozen interior position is not evidence of compositor motion")
        }
    }

    func testPresentationAdmissionRejectsNonmovingProbe() async throws {
        try await withApplicationLoop {
            let probe = try await observeControl(mode: .stationary)
            XCTAssertFalse(probe.hasInteriorPosition)
            XCTAssertFalse(probe.observedMotion, "A nonmoving presentation must never admit an animation test")
        }
    }

    private func observeControl(mode: ProbeMode) async throws -> PresentationProbe {
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        try await fixture.admit(row: 40)
        let field = try XCTUnwrap(fixture.controls.fields[fixture.rows[40].id]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        return try await observePresentationSampling(sentinel: fixture.sentinel, root: fixture.root,
            window: fixture.window, field: field, host: originalOwner, container: fixture.owner, mode: mode)
    }

    private func assertImmediateReorder(disablesAnimations: Bool, batterySaver: Bool,
                                        firstAdmissionSampleDelay: Duration = .milliseconds(20)) async throws {
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(batterySaver ? .alwaysOn : .off)
        defer { BatterySaver.shared.setMode(oldMode) }
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        fixture.configure(Fixture.instant)
        try await fixture.admit(row: 40)
        let movingID = fixture.rows[40].id
        let field = try XCTUnwrap(fixture.controls.fields[movingID]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window,
                                           field: field, host: originalOwner, container: fixture.owner,
                                           firstSampleDelay: firstAdmissionSampleDelay)
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
        try await withApplicationLoop { try await assertClipScrollingDoesNotReplayThePreviousStructuralAnimation() }
    }

    private func assertClipScrollingDoesNotReplayThePreviousStructuralAnimation() async throws {
        TestEnvironment.prepare()
        let oldMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(oldMode) }
        let fixture = Fixture(rows: rows(100))
        defer { fixture.close() }
        try await fixture.admit(row: 41)
        let field = try XCTUnwrap(fixture.controls.fields[fixture.rows[41].id]?.value)
        let originalOwner = try XCTUnwrap(owner(of: field, in: fixture.owner))
        try await admitPresentationSampling(sentinel: fixture.sentinel, root: fixture.root, window: fixture.window,
                                           field: field, host: originalOwner, container: fixture.owner)
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
