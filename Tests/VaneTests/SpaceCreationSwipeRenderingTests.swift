import AppKit
import XCTest
@testable import vane

@MainActor final class SpaceCreationSwipeRenderingTests: XCTestCase {
    func testAccidentalPullReturnsAndDeliberatePullShowsAUsableForm() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            try await exerciseCreation()
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Creation fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseCreation() async throws {
        let profile = ProfileManager.shared.create(name: "Creation swipe rendering")
        let space = ProfileManager.shared.createSpace(name: "Last Space", in: profile.id)
        let store = TabStore(profileID: profile.id, space: space, session: [])
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        let monitor = store.spaceGesture.monitor
        defer {
            monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile.id)
            _ = ProfileManager.shared.delete(profile.id)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Admit the exact production sidebar owner and foreground AppKit loop.
        do {
            try await compatibilityWait {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && NSApp.modalWindow == nil && window.attachedSheet == nil
                    && monitor.isInstalled && store.spaceGesture.sectionsView?.window === window
                    && store.strip.last?.id == space.id
            }
        } catch {
            print("CREATION_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) unoccluded=\(window.occlusionState.contains(.visible)) monitor=\(monitor.isInstalled) owner=\(store.spaceGesture.sectionsView?.window === window) last=\(store.strip.last?.id == space.id)")
            throw error
        }
        let before = ProfileManager.shared.spaces(for: profile.id)
        let width = SidebarWidth.shared.width
        func send(_ dx: CGFloat = 0, phase: NSEvent.Phase = .changed, at time: TimeInterval) {
            NSApp.sendEvent(ScrollEvent(window: window, dx: dx, phase: phase, timestamp: time))
        }
        send(phase: .began, at: 1)
        send(-width, at: 1.04)
        send(phase: .ended, at: 1.05)
        XCTAssertFalse(store.creatingSpace, "A quick accidental swipe must not replace the sidebar")
        try await compatibilityWait { !store.spaceSwiping && store.spaceDrag == 0 }
        send(phase: .began, at: 2)
        send(-width * 0.1, at: 2.01)
        send(-width * 0.3, at: 2.11)
        send(-width * 0.3, at: 2.21)
        send(-width * 0.3, at: 2.31)
        XCTAssertFalse(store.creatingSpace, "Even a full deliberate pull waits for release")
        send(phase: .ended, at: 2.32)
        XCTAssertTrue(store.creatingSpace)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        func formField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Space name…" { return field }
            return view.subviews.lazy.compactMap { formField(in: $0) }.first
        }
        try await compatibilityWait { formField(in: host)?.window === window }
        XCTAssertNil(host.spaceSlide, "An outgoing native sidebar must not cover the creation form")
        send(-width, phase: [], at: 2.34) // remaining gesture packets cannot dismiss the form
        XCTAssertTrue(store.creatingSpace)
        store.cancelCreatingSpace()
        try await compatibilityWait {
            formField(in: host) == nil && store.spaceGesture.sectionsView?.window === window
        }
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.currentSpaceID, space.id)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), before)
    }
}
