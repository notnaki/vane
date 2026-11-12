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
        func display() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func presentedX(_ view: NSView) throws -> CGFloat {
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
                    afterSample: (Int) -> Void = { _ in }, action: () -> Void) async throws {
            action()
            var intermediate = false
            for index in 0..<20 {
                try await Task.sleep(for: .milliseconds(16))
                display()
                let x = try presentedX(sidebar)
                let lightX = button.convert(button.bounds, to: host).minX
                if x > -200 && x < -2 {
                    intermediate = true
                    // At least one of the three lights is still on-screen here.
                    if x > -60 {
                        XCTAssertFalse(button.isHidden, "\(label): lights must leave with the panel")
                    }
                    XCTAssertEqual(lightX - x, separation, accuracy: 3,
                        "\(label): lights must share the sidebar's intermediate position")
                }
                afterSample(index)
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
