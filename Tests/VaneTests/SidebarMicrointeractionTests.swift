import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarMicrointeractionTests: XCTestCase {
    func testPressInkFadesAfterReleaseAndPolicyCancelsTheTail() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Release interpolation requires system motion")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let saver = BatterySaver.shared
        let mode = saver.mode
        defer { saver.setMode(mode); app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            saver.setMode(.off)
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 260, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Sidebar press feedback fixture"
            let host = NSHostingView(rootView: Text("Sidebar row").foregroundStyle(.white)
                .frame(width: 220, height: 36).modifier(Feel02PressFeedback())
                .frame(width: 260, height: 100).background(.black))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            defer { window.contentView = nil; window.close() }
            func anchor(in view: NSView) -> Feel02PressAnchorView? {
                (view as? Feel02PressAnchorView) ?? view.subviews.lazy.compactMap { anchor(in: $0) }.first
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && app.isActive && app.keyWindow === window && window.isKeyWindow
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && app.modalWindow == nil && window.attachedSheet == nil && host.window === window
                    && anchor(in: host)?.bounds.size == CGSize(width: 220, height: 36)
            }
            let target = try XCTUnwrap(anchor(in: host))
            let rect = target.convert(target.bounds, to: nil)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            func send(_ type: NSEvent.EventType) throws {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                XCTAssertTrue(Feel02PressMonitor.shared.handle(event) === event,
                              "Decorative feedback must not consume native input")
            }
            let idle = try pixels(host, name: "row-idle")
            try send(.leftMouseDown)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertGreaterThan(difference(try pixels(host, name: "row-pressed"), idle), 4)
            try send(.leftMouseUp)
            // Sample early without waiting for the desired fade to appear.
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertGreaterThan(difference(try pixels(host, name: "row-release"), idle), 1,
                                 "Press ink should ease away rather than disappear on mouse-up")
            saver.setMode(.alwaysOn)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertLessThanOrEqual(difference(try pixels(host, name: "row-saver"), idle), 2,
                                     "Battery Saver must finish an in-flight release")
            saver.setMode(.off)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertLessThanOrEqual(difference(try pixels(host, name: "row-restored"), idle), 2,
                                     "Restoring motion must not replay a cancelled press")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Sidebar feedback loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func pixels(_ host: NSView, name: String) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_FEEDBACK_CAPTURE_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func difference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs.count == rhs.count else { return 255 }
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}
