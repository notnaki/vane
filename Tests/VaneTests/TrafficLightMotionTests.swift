import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

/// Catches lights teleporting to the destination or disappearing before the
/// sidebar leaves. Compare the real buttons with the retained native viewport.
@MainActor final class TrafficLightMotionTests: XCTestCase {
    func testLightsTravelWithDockedAndFloatingSidebar() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let saver = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { app.setActivationPolicy(policy); BatterySaver.shared.setMode(saver) }
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseMotion() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseMotion() async throws {
        let store = TabStore(isPrivate: true)
        store.palette = nil
        let window = VaneWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A physical pointer on the edge strip can reopen the panel while the
        // fixture dismisses it. Admit a pointer outside this controlled window.
        let pointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: 1, y: 1))
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        // Match BrowserWindowHost: the native window supplies this root's
        // size, so floating chrome must not also trigger three intrinsic fits.
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        func viewport(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { viewport(in: $0) }.first
        }
        @MainActor func display() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        @MainActor func presentedX(_ view: NSView) throws -> CGFloat {
            let layer = try XCTUnwrap(view.layer?.presentation())
            let root = try XCTUnwrap(host.layer?.presentation())
            return layer.convert(layer.bounds, to: root).minX
        }
        var scroll: NSScrollView?
        try await compatibilityWait {
            display()
            guard NSApp.isRunning, window.isVisible, window.occlusionState.contains(.visible),
                  window.contentView === host, let candidate = viewport(in: host),
                  candidate.window === window,
                  let x = try? presentedX(candidate),
                  abs(x - candidate.convert(candidate.bounds, to: host).minX) < 0.5 else { return false }
            scroll = candidate
            return true
        }
        let sidebar = try XCTUnwrap(scroll)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let dockedX = button.convert(button.bounds, to: host).minX
        let separation = dockedX - (try presentedX(sidebar))

        func sample(_ label: String, expectsIntermediate: Bool = true,
                    afterSample: @escaping @MainActor (Int) -> Void = { _ in },
                    action: @escaping @MainActor () -> Void) async throws {
            // Observe from the owned AppKit loop, beginning with the delivered
            // action. An XCTest executor continuation can resume after the whole
            // transition even while the compositor and AppKit timer are running.
            let observation = TrafficLightObservation(capture: {
                display()
                return .init(x: try presentedX(sidebar),
                    lightX: button.convert(button.bounds, to: host).minX, hidden: button.isHidden)
            }, afterSample: afterSample)
            defer { observation.stop() }
            try await performFixtureApplicationAction(in: window) {
                action()
                observation.start()
            }
            try await compatibilityWait { observation.completed }
            if let error = observation.error { throw error }
            XCTAssertEqual(observation.samples.count, 20)
            var intermediate = false
            for sample in observation.samples {
                let x = sample.x
                if x > -200 && x < -2 {
                    intermediate = true
                    // At least one of the three lights is still on-screen here.
                    if x > -60 {
                        XCTAssertFalse(sample.hidden, "\(label): lights must leave with the panel")
                    }
                    XCTAssertEqual(sample.lightX - x, separation, accuracy: 3,
                        "\(label): lights must share the sidebar's intermediate position")
                }
            }
            XCTAssertEqual(intermediate, expectsIntermediate,
                "\(label): normal motion must travel; reduced motion must settle immediately")
        }
        try await sample("docked close") { store.sidebarShown = false }
        XCTAssertTrue(button.isHidden)
        try await sample("docked open") { store.sidebarShown = true }
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.convert(button.bounds, to: host).minX, dockedX, accuracy: 0.5)
        Motion.instant { store.sidebarShown = false }
        try await compatibilityWait { display(); return button.isHidden }
        try await sample("floating open") { store.sidebarPeeking = true }
        XCTAssertFalse(button.isHidden)
        try await sample("floating close") { store.sidebarPeeking = false }
        XCTAssertTrue(button.isHidden)
        try await sample("floating reversal", afterSample: { index in
            if index == 2 { store.sidebarPeeking = false }
        }) { store.sidebarPeeking = true }
        XCTAssertTrue(button.isHidden)
        Motion.instant { store.sidebarShown = true }
        try await compatibilityWait {
            display()
            return !button.isHidden && abs(button.convert(button.bounds, to: host).minX - dockedX) < 0.5
        }
        BatterySaver.shared.setMode(.alwaysOn)
        try await sample("Battery Saver close", expectsIntermediate: false) { store.sidebarShown = false }
        XCTAssertTrue(button.isHidden)
        try await sample("Battery Saver open", expectsIntermediate: false) { store.sidebarShown = true }
        XCTAssertFalse(button.isHidden)
    }
}

/// Timer and observations share one actor owner, including cancellation. Keeping
/// the timer here avoids transferring Foundation's non-Sendable callback value
/// into the fixture's actor-isolated measurement closure.
@MainActor private final class TrafficLightObservation {
    struct Sample {
        let x: CGFloat
        let lightX: CGFloat
        let hidden: Bool
    }
    private let capture: @MainActor () throws -> Sample
    private let afterSample: @MainActor (Int) -> Void
    private var timer: Timer?
    private(set) var samples: [Sample] = []
    private(set) var error: (any Error)?
    private(set) var completed = false

    init(capture: @escaping @MainActor () throws -> Sample,
         afterSample: @escaping @MainActor (Int) -> Void) {
        self.capture = capture
        self.afterSample = afterSample
    }

    func start() {
        precondition(timer == nil && samples.isEmpty)
        let observer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        }
        observer.fireDate = Date(timeIntervalSinceNow: 0.016)
        timer = observer
        RunLoop.main.add(observer, forMode: .common)
    }

    private func observe() {
        do {
            samples.append(try capture())
            afterSample(samples.count - 1)
        } catch { self.error = error }
        if error != nil || samples.count == 20 {
            stop()
            completed = true
        } else {
            // Preserve the original interval after each sample; delayed callbacks
            // must not produce catch-up samples.
            timer?.fireDate = Date(timeIntervalSinceNow: 0.016)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
