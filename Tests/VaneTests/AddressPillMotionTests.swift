import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class AddressPillFixture: ObservableObject {
    @Published var tab: vane.Tab?
    init(tab: vane.Tab?) { self.tab = tab }
}

private struct AddressPillFixtureView: View {
    @ObservedObject var state: AddressPillFixture
    let store: TabStore
    var body: some View {
        AddressPill(tab: state.tab)
            .environmentObject(store)
            .frame(width: 300)
            .padding(20)
            .background(.black)
            .environment(\.colorScheme, .dark)
    }
}

@MainActor final class AddressPillMotionTests: XCTestCase {
    private var captureIndex = 0

    private func capture(_ bitmap: NSBitmapImageRep) throws {
        guard let directory = ProcessInfo.processInfo.environment["VANE_PILL_CAPTURE_DIR"] else { return }
        let name = "\(self.name)-\(captureIndex).png".replacingOccurrences(of: "/", with: "_")
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        captureIndex += 1
    }
    private func withPill(mode: BatterySaver.Mode = .alwaysOn,
        _ body: @MainActor (AddressPillFixture, TabStore, NSWindow, NSView) async throws -> Void
    ) async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let previousWidth = SidebarWidth.shared.width
            SidebarWidth.shared.width = 340
            let saver = BatterySaver.shared
            let previousMode = saver.mode
            saver.setMode(mode)
            let store = TabStore(isPrivate: true)
            // This fixture mounts only the pill, not the empty-store command bar.
            // Keep its model consistent with that presentation; a real palette
            // remains a refusal gate in the production keyboard endpoint.
            store.palette = nil
            let tab = Tab(isPrivate: true)
            tab.address = "github.com"
            let state = AddressPillFixture(tab: tab)
            let host = NSHostingView(rootView: AddressPillFixtureView(state: state, store: store))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 76),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                saver.setMode(previousMode)
                SidebarWidth.shared.width = previousWidth
            }
            // Hover reveals the same glyphs as focus. Keep the owned window clear
            // of the physical pointer so the keyboard assertions cannot pass on hover.
            let screen = try XCTUnwrap(NSScreen.main)
            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let size = window.frame.size
            let origins = [NSPoint(x: visible.minX, y: visible.minY),
                           NSPoint(x: visible.maxX - size.width, y: visible.minY),
                           NSPoint(x: visible.minX, y: visible.maxY - size.height),
                           NSPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)]
            let origin = try XCTUnwrap(origins.first {
                !NSRect(origin: $0, size: size).insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
            })
            window.setFrameOrigin(origin)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            store.window = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                    && NSApp.keyWindow === window && window.isVisible
                    && window.occlusionState.contains(.visible) && host.window === window
                    && host.bounds.width == 340 && NSApp.modalWindow == nil
                    && window.attachedSheet == nil && !window.frame.contains(NSEvent.mouseLocation)
            }
            // Move focus away from the pill before establishing its resting render.
            window.makeFirstResponder(nil)
            try await body(state, store, window, host)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Address pill loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func labelPixels(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rect = NSRect(x: 32, y: 26, width: 200, height: 24)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        try capture(bitmap)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func difference(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return 255 }
        return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    private func actionPixels(_ host: NSView) throws -> Int {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try capture(bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var bright = 0
        // Only the two trailing glyphs, excluding the pill's focus outline and host.
        for y in Int(27 * scale)..<Int(49 * scale) {
            for x in Int(244 * scale)..<Int(303 * scale) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.45 { bright += 1 }
            }
        }
        return bright
    }

    /// A hosting root can mount before its store receives the window. Readiness
    /// admits the real native view, never the requested focus or its outcome.
    private func withPillAwaitingWindowOwnership(
        _ body: @MainActor (TabStore, NSWindow, NSView, MountedAddressButton) async throws -> Void
    ) async throws {
        try await withPill { state, store, window, _ in
            window.contentView = nil
            store.window = nil
            store.chromeFocusRequested = true
            let host = NSHostingView(rootView: AddressPillFixtureView(state: state, store: store))
            window.contentView = host
            @MainActor func endpoint(in view: NSView) -> MountedAddressButton? {
                if let button = view as? MountedAddressButton { return button }
                return view.subviews.lazy.compactMap { endpoint(in: $0) }.first
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                guard let button = endpoint(in: host) else { return false }
                return NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window
                    && host.window === window && button.window === window
                    && button.bounds.width > 0 && button.bounds.height > 0
                    && !host.needsDisplay && host.layer?.presentation() != nil
            }
            let button = try XCTUnwrap(endpoint(in: host))
            XCTAssertTrue(store.chromeFocusRequested,
                          "Mounting before window ownership must not discard the pending request")
            XCTAssertFalse(window.firstResponder === button,
                           "An unowned endpoint must not acquire the keyboard")
            try await body(store, window, host, button)
        }
    }

    func testFocusRequestSurvivesMountBeforeStoreWindowOwnership() async throws {
        try await withPillAwaitingWindowOwnership { store, window, _, button in
            store.window = window
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(window.firstResponder === button,
                          "Window installation must deliver the retained request to the exact mounted control")
            XCTAssertFalse(store.chromeFocusRequested)
        }
    }

    func testPendingMountRequestCannotTakeFocusFromAnInterveningField() async throws {
        try await withPillAwaitingWindowOwnership { store, window, host, _ in
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
            host.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let holder = try XCTUnwrap(window.firstResponder)
            store.window = window
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(window.firstResponder === holder,
                          "A retained request belongs to its original responder, not later input")
            XCTAssertFalse(store.chromeFocusRequested, "Superseded requests must retire")
        }
    }

    func testPageActionsAreHiddenAtRestAndRevealForKeyboardFocus() async throws {
        try await withPill { _, store, _, host in
            XCTAssertLessThan(try self.actionPixels(host), 5,
                              "The reference pill keeps page-action glyphs hidden at rest")
            store.chromeFocusRequested = true
            try await compatibilityWait { !store.chromeFocusRequested && ((try? self.actionPixels(host)) ?? 0) > 20 }
            XCTAssertGreaterThan(try self.actionPixels(host), 20,
                                 "Keyboard focus must reveal actions without pointer hover")
        }
    }

    func testEmptyTabRoundTripKeepsThePillsKeyboardFocus() async throws {
        try await withPill { state, store, window, host in
            let tab = try XCTUnwrap(state.tab)
            store.chromeFocusRequested = true
            try await compatibilityWait { !store.chromeFocusRequested && ((try? self.actionPixels(host)) ?? 0) > 20 }
            state.tab = nil
            try await compatibilityWait { (try? self.actionPixels(host)) ?? 100 < 5 }
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(key)
            XCTAssertEqual(store.palette, .newTab,
                           "Return must still activate the same pill after its page becomes empty")
            store.palette = nil
            state.tab = tab
            try await compatibilityWait { !store.chromeFocusRequested && ((try? self.actionPixels(host)) ?? 0) > 20 }
            XCTAssertGreaterThan(try self.actionPixels(host), 20,
                                 "Switching through the search prompt must retain the focused pill")
        }
    }

    func testPromptCrossfadesThroughIntermediateFramesAndRapidReversalSettles() async throws {
        try await withPill(mode: .off) { state, _, _, host in
            try XCTSkipIf(Motion.spaceReduced, "Reference motion requires system animation")
            let tab = try XCTUnwrap(state.tab)
            let page = try self.labelPixels(host)
            state.tab = nil
            var frames: [Data] = []
            // Sample immediately after the mutation; never await the prompt's final state.
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(20))
                frames.append(try self.labelPixels(host))
            }
            try await Task.sleep(for: .milliseconds(200))
            let prompt = try self.labelPixels(host)
            XCTAssertGreaterThan(self.difference(page, prompt), 20)
            XCTAssertTrue(frames.contains {
                self.difference($0, page) > 10 && self.difference($0, prompt) > 10
            }, "The host/search replacement must render intermediate frames rather than jump")
            state.tab = tab
            try await Task.sleep(for: .milliseconds(35))
            state.tab = nil
            try await Task.sleep(for: .milliseconds(35))
            state.tab = tab
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertLessThanOrEqual(self.difference(try self.labelPixels(host), page), 2,
                                     "Rapid reversal must settle on the latest host with no ghost prompt")
        }
    }

    func testLiveAddressUpdatesAndBatterySaverSettlesImmediately() async throws {
        try await withPill { state, _, _, host in
            let tab = try XCTUnwrap(state.tab)
            let page = try self.labelPixels(host)
            // This changes the observed Tab without replacing the selected tab object.
            tab.address = ""
            try await compatibilityWait {
                self.difference(try self.labelPixels(host), page) > 20
            }
            let prompt = try self.labelPixels(host)
            BatterySaver.shared.setMode(.off)
            tab.address = "github.com"
            // A different rendered label admits the full-motion owner before mutation.
            try await compatibilityWait { self.difference(try self.labelPixels(host), page) <= 2 }
            tab.address = ""
            try await Task.sleep(for: .milliseconds(40))
            BatterySaver.shared.setMode(.alwaysOn)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertLessThanOrEqual(self.difference(try self.labelPixels(host), prompt), 2,
                                     "A live motion-policy change must settle the prompt immediately")
            BatterySaver.shared.setMode(.off)
            try await Task.sleep(for: .milliseconds(220))
            XCTAssertLessThanOrEqual(self.difference(try self.labelPixels(host), prompt), 2,
                                     "Restoring animation must not replay a cancelled transition")
        }
    }

}
