import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

@MainActor final class LibraryPageMountReceiptTests: XCTestCase {
    @MainActor private final class Fixture {
        let store: TabStore
        let window: VaneWindow
        let root: NSView
        let marker = LibraryPaintView()
        let paint = LibraryNavigationPaint(progress: 0)
        let tab: vane.Tab
        let host: WebHost
        let source: LibraryPageMountReceiptSource

        init() throws {
            store = TabStore(isPrivate: true, session: [])
            tab = store.newBlankTab(loading: URL(string: "about:blank"))
            store.palette = nil
            store.libraryOpen = false
            store.sidebarShown = true
            window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            root.wantsLayer = true
            host = WebHost(tab.web)
            host.frame = NSRect(x: 228, y: 11, width: 661, height: 578)
            root.addSubview(host)
            root.addSubview(marker)
            store.window = window
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            store.librarySwipeMonitor.install(store)
            store.libraryGesture.paint = paint
            marker.paint = paint
            host.libraryNavigationPaintOwner = paint.owner
            source = try XCTUnwrap(paint.pageMountReceiptSource(store: store,
                gesture: store.libraryGesture, monitor: store.librarySwipeMonitor))
            request(0)
        }

        func request(_ value: CGFloat) {
            paint.request(value, sampledAt: nil, marker: marker, leading: { 228 + 164 * $0 })
        }

        func ready() async throws {
            try await ResizeNativeWindowAdmission.wait(window, web: tab.web, layout: true)
            try await compatibilityWait { !tab.web.isLoading && !self.paint.isPreparing }
        }

        func close() {
            paint.cancel()
            store.librarySwipeMonitor.remove()
            store.spaceGesture.monitor.remove()
            store.libraryGesture.paint = nil
            host.removePage()
            window.orderOut(nil); window.contentView = nil; store.window = nil; window.close()
            store.dropStashes()
            SharedTabs.release(store.tabs, excluding: store)
            TabStore.all.removeAll { $0 === store }
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let previousBatteryMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previousBatteryMode) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let fixture = try Fixture()
            defer { fixture.close() }
            try await fixture.ready()
            try await body(fixture)
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Receipt cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    func testCurrentClosedOwnerCanCaptureAfterColdMarkerReadiness() async throws {
        try await withFixture { f in
            let receipt = try XCTUnwrap(f.source.capture(), "Actual closed idle owners must become eligible")
            XCTAssertEqual(receipt.owner, f.paint.owner)
            XCTAssertTrue(receipt.isCurrentAndIdle())
            XCTAssertNil(f.paint.pageMountReceiptSource(store: nil,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor))
            XCTAssertNil(EnvironmentValues().libraryPageMountReceiptSource)
        }
    }

    func testHeldZeroIsNotIdleAndCannotReviveTheOldReceipt() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            f.store.libraryGesture.progress = 0
            XCTAssertNil(f.source.capture(), "A held endpoint is active even with all paint floats zero")
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            f.store.libraryGesture.progress = nil
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true, "A held-zero cycle cannot resurrect a previous receipt")
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testSynchronousRequestRoundTripInvalidatesBeforeAnyDrain() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            f.request(0.5); f.request(0)
            XCTAssertNil(f.source.capture(), "Queued publication is not idle")
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            try await compatibilityWait { !f.paint.isPreparing }
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true, "Returning to zero before drain never revives the old epoch")
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testIdenticalAtRestBridgeReevaluationDoesNotInvalidateItsEpoch() async throws {
        try await withFixture { f in
            let old = try XCTUnwrap(f.source.capture())
            let same = f.paint.pageMountReceiptSource(store: f.store,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor)
            XCTAssertTrue(same === f.source)
            f.request(0)
            XCTAssertNil(f.source.capture(), "The existing queued update still has to drain")
            try await compatibilityWait { !f.paint.isPreparing }
            XCTAssertTrue(old.isCurrentAndIdle(), "An identical update cannot create a metadata invalidation loop")
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testExplicitCommandInvalidatesWithoutAPendingDestination() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            f.store.librarySwipeMonitor.cancelPendingActivation(toward: false)
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            XCTAssertNotNil(f.source.capture(), "A completed no-op command may yield a new resting receipt")
        }
    }

    func testNativeMarkerDetachAndSameWindowReattachCannotReviveReceipt() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            f.marker.removeFromSuperview()
            XCTAssertNil(f.source.capture())
            f.root.addSubview(f.marker)
            f.request(0)
            try await compatibilityWait { !f.paint.isPreparing }
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testPaintReplacementAndCancellationInvalidateOldReceipt() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            let replacement = LibraryNavigationPaint(progress: 0)
            f.store.libraryGesture.paint = replacement
            f.marker.paint = replacement
            XCTAssertNil(f.source.capture())
            f.store.libraryGesture.paint = f.paint
            f.marker.paint = f.paint
            f.request(0)
            try await compatibilityWait { !f.paint.isPreparing }
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            let current = f.source.capture(); XCTAssertNotNil(current)
            f.paint.cancel()
            XCTAssertFalse(current?.isCurrentAndIdle() ?? true)
        }
    }

    func testPendingArrivalAndCancelledCallbackCannotAdmitIdle() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            var completions = 0
            f.paint.afterPresentation(of: 0, when: { false }) { completions += 1 }
            XCTAssertNil(f.source.capture())
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            await Task.yield()
            XCTAssertNil(f.source.capture(), "The current arrival/frame wait is not resting")
            f.paint.cancel()
            try await compatibilityWait { !f.paint.isPreparing }
            XCTAssertEqual(completions, 0)
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testNativeBufferOwnerRejectsEvenAtZeroPaintProgress() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            var callbacks: [@MainActor @Sendable () -> Void] = []
            let native = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
                presenter: { _, callback in callbacks.append(callback) }, deadline: { _, _ in }, apply: { _, _ in }))
            defer { native.cancel() }
            native.start()
            XCTAssertNil(f.source.capture())
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            native.cancel()
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testCurrentClosedFinishedMineStillConsumesMomentum() async throws {
        try await withFixture { f in
            f.store.libraryOpen = true
            let monitor = f.store.librarySwipeMonitor
            XCTAssertNotNil(monitor.handle(ReceiptScrollEvent(window: f.window, phase: .began), in: f.store))
            XCTAssertNil(monitor.handle(ReceiptScrollEvent(window: f.window, dx: -150), in: f.store))
            XCTAssertNil(f.source.capture())
            XCTAssertNil(monitor.handle(ReceiptScrollEvent(window: f.window, phase: .ended), in: f.store))
            XCTAssertFalse(f.store.libraryOpen)
            XCTAssertNil(f.store.libraryGesture.progress)
            XCTAssertNotNil(f.source.capture(), "Finished mine is a momentum verdict, not live navigation")
            XCTAssertNil(monitor.handle(ReceiptScrollEvent(window: f.window, phase: [], momentum: .changed), in: f.store))
            XCTAssertNotNil(f.source.capture(), "Checking eligibility must not reset event ownership")
        }
    }

    func testPendingLandingRejectsEvenIfTheModelPresentationWasCleared() async throws {
        try await withFixture { f in
            let beforeGesture = try XCTUnwrap(f.source.capture())
            let panel = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            panel.wantsLayer = true
            f.root.addSubview(panel)
            let monitor = f.store.librarySwipeMonitor
            monitor.presentationView = panel
            f.store.libraryOpen = true
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, phase: .began), in: f.store)
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, dx: -150), in: f.store)
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, phase: .ended), in: f.store)
            if self.verifyImmediateLandingWhenReduced(f, beforeGesture: beforeGesture) { return }
            XCTAssertNotNil(monitor.pageMountPendingSettlement, "The actual gesture must issue a landing tail")
            // Current logical endpoints alone cannot retire an issued landing.
            f.store.libraryOpen = false
            f.store.libraryGesture.progress = nil
            XCTAssertNil(f.source.capture(), "Pending destination/settlement must still reject idle")
            f.store.libraryGesture.progress = 0
            monitor.cancelPendingActivation(toward: true)
            f.store.libraryGesture.progress = nil
            XCTAssertNil(f.source.capture(), "A superseding command's current tail is still owned")
        }
    }

    func testProviderAndReceiptDoNotRetainTheActualPaintOwner() async throws {
        try await withFixture { f in
            var replacement: LibraryNavigationPaint? = LibraryNavigationPaint(progress: 0)
            weak var weakPaint = replacement
            f.store.libraryGesture.paint = replacement
            f.marker.paint = replacement
            let source = try XCTUnwrap(replacement?.pageMountReceiptSource(store: f.store,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor))
            replacement?.request(0, sampledAt: nil, marker: f.marker, leading: { _ in 228 })
            try await compatibilityWait { replacement?.isPreparing == false }
            let receipt = source.capture(); XCTAssertNotNil(receipt)
            replacement = nil
            XCTAssertNil(weakPaint)
            XCTAssertNil(source.capture())
            XCTAssertFalse(receipt?.isCurrentAndIdle() ?? true)
        }
    }

    func testStaleSettlementMetadataCannotClearTheNewerActualLanding() async throws {
        try await withFixture { f in
            let beforeGesture = try XCTUnwrap(f.source.capture())
            let panel = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            panel.wantsLayer = true
            f.root.addSubview(panel)
            let monitor = f.store.librarySwipeMonitor
            monitor.presentationView = panel
            f.store.libraryOpen = true
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, phase: .began), in: f.store)
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, dx: -150), in: f.store)
            _ = monitor.handle(ReceiptScrollEvent(window: f.window, phase: .ended), in: f.store)
            if self.verifyImmediateLandingWhenReduced(f, beforeGesture: beforeGesture) { return }
            let old = try XCTUnwrap(monitor.pageMountPendingSettlement)
            monitor.cancelPendingActivation(toward: true)
            let newer = try XCTUnwrap(monitor.pageMountPendingSettlement)
            XCTAssertNotEqual(old, newer)
            let epoch = monitor.pageMountEpoch
            let progress = f.store.libraryGesture.progress
            monitor.pageMountSettlementCompleted(old)
            XCTAssertEqual(monitor.pageMountPendingSettlement, newer)
            XCTAssertEqual(monitor.pageMountEpoch, epoch)
            XCTAssertEqual(f.store.libraryGesture.progress, progress, "Metadata cannot run a production completion")
            f.store.libraryOpen = false
            f.store.libraryGesture.progress = nil
            XCTAssertNil(f.source.capture(), "The newer actual tail still owns cleanup")
        }
    }

    /// Reduced motion completes synchronously, so there is no animated tail to
    /// supersede. Hosted normal-motion preflights still exercise every original
    /// pending-tail assertion above; neither policy is skipped or overridden.
    private func verifyImmediateLandingWhenReduced(_ f: Fixture,
                                                   beforeGesture: LibraryPageMountReceipt) -> Bool {
        let reduced = Motion.reduced
        print("RECEIPT_LANDING_POLICY reduced=\(reduced) path=\(reduced ? "immediate" : "animated")")
        guard reduced else { return false }
        XCTAssertFalse(f.store.libraryOpen)
        XCTAssertNil(f.store.libraryGesture.progress)
        XCTAssertNil(f.store.librarySwipeMonitor.pageMountPendingSettlement)
        XCTAssertFalse(beforeGesture.isCurrentAndIdle(), "Immediate settlement also retires the pre-gesture receipt")
        let settled = f.source.capture()
        XCTAssertNotNil(settled, "A completed reduced-motion landing must admit a fresh receipt")
        f.store.librarySwipeMonitor.cancelPendingActivation(toward: true)
        XCTAssertFalse(settled?.isCurrentAndIdle() ?? true, "A command invalidates even without a pending tail")
        XCTAssertNil(f.store.librarySwipeMonitor.pageMountPendingSettlement)
        XCTAssertNotNil(f.source.capture())
        return true
    }

    func testBindingReplacementCannotResurrectAnOldReceipt() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            let other = TabStore(isPrivate: true, session: [])
            defer {
                other.librarySwipeMonitor.remove(); other.spaceGesture.monitor.remove()
                other.dropStashes(); TabStore.all.removeAll { $0 === other }
            }
            let rebound = f.paint.pageMountReceiptSource(store: other,
                gesture: other.libraryGesture, monitor: other.librarySwipeMonitor)
            XCTAssertTrue(rebound === f.source)
            XCTAssertNil(rebound?.capture())
            _ = f.paint.pageMountReceiptSource(store: f.store,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor)
            XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testCheckedEpochExhaustionNeverWraps() {
        var epoch = LibraryPageMountEpoch(value: .max - 1)
        epoch.invalidate()
        XCTAssertEqual(epoch.value, .max)
        XCTAssertFalse(epoch.exhausted)
        epoch.invalidate()
        XCTAssertEqual(epoch.value, .max)
        XCTAssertTrue(epoch.exhausted)
        epoch.invalidate()
        XCTAssertEqual(epoch.value, .max)
        XCTAssertTrue(epoch.exhausted)
    }

    func testExhaustedActualPaintOwnerStaysFailClosedAfterIdleRebinding() async throws {
        try await withFixture { f in
            let exhausted = LibraryNavigationPaint(progress: 0, mountEpoch: .init(value: .max))
            f.store.libraryGesture.paint = exhausted
            f.marker.paint = exhausted
            let source = try XCTUnwrap(exhausted.pageMountReceiptSource(store: f.store,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor))
            exhausted.request(0, sampledAt: nil, marker: f.marker, leading: { _ in 228 })
            try await compatibilityWait { !exhausted.isPreparing }
            XCTAssertTrue(exhausted.pageMountEpoch.exhausted)
            XCTAssertNil(source.capture())
            exhausted.cancel()
            _ = exhausted.pageMountReceiptSource(store: f.store,
                gesture: f.store.libraryGesture, monitor: f.store.librarySwipeMonitor)
            exhausted.request(0, sampledAt: nil, marker: f.marker, leading: { _ in 228 })
            try await compatibilityWait { !exhausted.isPreparing }
            XCTAssertEqual(exhausted.pageMountEpoch.value, .max)
            XCTAssertTrue(exhausted.pageMountEpoch.exhausted)
            XCTAssertNil(source.capture())
        }
    }

    func testSynchronousVisibilityRestorationNeverRevivesOldReceipt() async throws {
        try await withFixture { f in
            let old = try XCTUnwrap(f.source.capture())
            f.store.profileVisible = false
            f.store.profileVisible = true
            // No yield, predicate read, monitor event or SwiftUI update between
            // the lifecycle edges: invalidation belongs to the actual owner.
            XCTAssertFalse(old.isCurrentAndIdle())
            XCTAssertNotNil(f.source.capture(), "A fresh resting receipt may admit after restoration")
        }
    }

    func testSynchronousParkingRestorationNeverRevivesOldReceipt() async throws {
        try await withFixture { f in
            let old = try XCTUnwrap(f.source.capture())
            f.store.parkedIn = f.window
            f.store.parkedIn = nil
            XCTAssertFalse(old.isCurrentAndIdle())
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testSynchronousWindowRestorationNeverRevivesOldReceipt() async throws {
        try await withFixture { f in
            let old = try XCTUnwrap(f.source.capture())
            f.store.window = nil
            f.store.window = f.window
            XCTAssertFalse(old.isCurrentAndIdle())
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testIdenticalOwnerLifecycleAssignmentsPreserveRestingReceipt() async throws {
        try await withFixture { f in
            let old = try XCTUnwrap(f.source.capture())
            f.store.profileVisible = true
            f.store.parkedIn = nil
            f.store.window = f.window
            XCTAssertTrue(old.isCurrentAndIdle(), "Identical owner values must not create an epoch loop")
            XCTAssertNotNil(f.source.capture())
        }
    }

    func testHiddenParkedOrUnknownOwnerCannotCapture() async throws {
        try await withFixture { f in
            let old = f.source.capture(); XCTAssertNotNil(old)
            f.store.profileVisible = false
            XCTAssertNil(f.source.capture()); XCTAssertFalse(old?.isCurrentAndIdle() ?? true)
            f.store.profileVisible = true
            f.store.parkedIn = f.window
            XCTAssertNil(f.source.capture())
            f.store.parkedIn = nil
            f.store.window = nil
            XCTAssertNil(f.source.capture())
            f.store.window = f.window
            f.window.orderOut(nil)
            XCTAssertNil(f.source.capture())
        }
    }
}

private final class ReceiptScrollEvent: NSEvent, @unchecked Sendable {
    private let target: NSWindow
    private let targetNumber: Int
    private let dx: CGFloat
    private let scrollPhase: NSEvent.Phase
    private let momentum: NSEvent.Phase
    @MainActor init(window: NSWindow, dx: CGFloat = 0, phase: NSEvent.Phase = .changed,
                    momentum: NSEvent.Phase = []) {
        target = window; targetNumber = window.windowNumber
        self.dx = dx; scrollPhase = phase; self.momentum = momentum
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { NSPoint(x: 100, y: 300) }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { 0 }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
}
