import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Catches losing the padded hit target or press acknowledgement when the compact
/// style wraps TactileButtonStyle, including policy changes during release.
@MainActor final class CompactControlTests: XCTestCase {
    func testNativePressUsesPaddedTargetAndSettlesWithBatterySaver() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let saver = BatterySaver.shared
        let mode = saver.mode
        defer { saver.setMode(mode); app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            saver.setMode(.off)
            let state = CompactControlState()
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Vane Compact Control Test"
            window.isReleasedWhenClosed = false
            // Keep the real pointer away from this fixture's hover presentation without
            // moving the user's cursor. Native synthetic presses do not move it either.
            let screen = try XCTUnwrap(NSScreen.main).visibleFrame.insetBy(dx: 30, dy: 30)
            let origins = [NSPoint(x: screen.minX, y: screen.minY),
                           NSPoint(x: screen.maxX - window.frame.width, y: screen.minY),
                           NSPoint(x: screen.minX, y: screen.maxY - window.frame.height),
                           NSPoint(x: screen.maxX - window.frame.width, y: screen.maxY - window.frame.height)]
            let origin = try XCTUnwrap(origins.first {
                !NSRect(origin: $0, size: window.frame.size).contains(NSEvent.mouseLocation)
            })
            window.setFrameOrigin(origin)
            let host = NSHostingView(rootView: CompactControlSurface(state: state))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            defer { window.contentView = nil; window.close() }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && app.isActive && app.keyWindow === window
                    && window.isKeyWindow && window.isVisible && window.occlusionState.contains(.visible)
                    && app.modalWindow == nil && window.attachedSheet == nil
                    && host.window === window && state.mounted && host.bounds.size == NSSize(width: 240, height: 100)
                    && state.targetFrame == CGRect(x: 106, y: 36, width: 28, height: 28)
                    && !window.frame.contains(NSEvent.mouseLocation)
            }

            func send(_ type: NSEvent.EventType, x: CGFloat) throws {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            let idle = try capture(host, name: "idle")
            // x=107 is inside the 28pt target (106...134), outside the small plus glyph.
            try send(.leftMouseDown, x: 107)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertGreaterThan(difference(try capture(host, name: "pressed"), idle), 10,
                                 "The padded edge must acknowledge a press before activation")
            XCTAssertEqual(state.actions, 0)
            try send(.leftMouseUp, x: 107)
            XCTAssertEqual(state.actions, 1)
            saver.setMode(.alwaysOn)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertLessThanOrEqual(difference(try capture(host, name: "saver"), idle), 2,
                                     "Battery Saver must settle the release immediately")
            saver.setMode(.off)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertLessThanOrEqual(difference(try capture(host, name: "restored"), idle), 2,
                                     "Restoring motion must not replay a cancelled release")

            state.enabled = false
            try await compatibilityWait { !state.presentedEnabled }
            let disabled = try capture(host, name: "disabled")
            try send(.leftMouseDown, x: 120)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertLessThanOrEqual(difference(try capture(host, name: "disabled-press"), disabled), 2)
            try send(.leftMouseUp, x: 120)
            XCTAssertEqual(state.actions, 1, "Disabled controls must not acknowledge or activate")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Compact control AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func capture(_ host: NSView, name: String) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["VANE_COMPACT_CAPTURE_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return Data(bytes: try XCTUnwrap(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func difference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs.count == rhs.count else { return 255 }
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}

@MainActor private final class CompactControlState: ObservableObject {
    @Published var enabled = true
    var presentedEnabled = true
    var mounted = false
    var targetFrame = CGRect.zero
    var actions = 0
}

private struct CompactControlSurface: View {
    @ObservedObject var state: CompactControlState
    var body: some View {
        Button { state.actions += 1 } label: { Image(systemName: "plus").font(.system(size: 12)) }
            .buttonStyle(CompactControlStyle(size: 28))
            .disabled(!state.enabled)
            .onAppear { state.mounted = true }
            .onChange(of: state.enabled) { _, enabled in state.presentedEnabled = enabled }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("compact-control")) }
                action: { state.targetFrame = $0 }
            .frame(width: 240, height: 100)
            .coordinateSpace(name: "compact-control")
            .foregroundStyle(.black)
            .background(.white)
            .environment(\.colorScheme, .light)
    }
}
