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
            try await exerciseCreation(holdingStill: false)
            try await exerciseCreation(holdingStill: true)
            try await exerciseCreation(holdingStill: true, flushDuringPublication: true)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Creation fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testPacedRecordedPullOpensCreationAfterSwipingAcrossThreeProfiles() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseRecordedCrossProfilePull() }
        catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Recorded swipe AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseRecordedCrossProfilePull() async throws {
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = (1...3).map { manager.create(name: "Recorded swipe profile \($0)") }
        let spaces = profiles.map { manager.createSpace(name: "Recorded swipe", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func showing() -> TabStore? { TabStore.all.first { $0.window === window } }
        func admit(_ space: Space) async throws {
            try await compatibilityWait {
                guard let store = showing() else { return false }
                store.palette = nil
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && NSApp.modalWindow == nil && window.attachedSheet == nil
                    && store.currentSpaceID == space.id && !store.spaceSwiping
                    && store.spaceGesture.monitor.isInstalled
                    && store.spaceGesture.sectionsView?.window === window
            }
        }
        try await admit(spaces[0])
        for (index, space) in spaces.dropFirst().enumerated() {
            let time = Double(index + 1)
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began, timestamp: time))
            NSApp.sendEvent(ScrollEvent(window: window, dx: -SidebarWidth.shared.width,
                                       timestamp: time + 0.1))
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, timestamp: time + 0.11))
            try await admit(space)
        }
        let store = try XCTUnwrap(showing())
        XCTAssertEqual(store.strip.last?.id, spaces[2].id)
        for index in 0..<6 {
            let tab = store.newBlankTab(focus: false)
            tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Document \(index)"))
        }
        store.palette = nil
        try await compatibilityWait { !store.spaceGesture.monitor.preparedSlides.isEmpty }
        // Real trackpad packets from the reported failure: drift grows only after axis lock.
        let samples: [(TimeInterval, CGFloat, CGFloat)] = [
            (0.000000000, -1, 0),
            (0.008340625, -5, 0),
            (0.016660042, -7, 0),
            (0.024984834, -8, 0),
            (0.033324125, -9, 1),
            (0.041731167, -9, 1),
            (0.051237542, -21, 2),
            (0.058497167, -22, 2),
            (0.066626792, -25, 2),
            (0.075786250, -22, 2),
            (0.083296000, -33, 2),
            (0.091651834, -30, 3),
            (0.099973417, -30, 3),
            (0.108316334, -30, 3),
            (0.118274167, -23, 2),
            (0.125044959, -39, 4),
            (0.133248292, -13, 1),
            (0.141984584, -19, 2),
            (0.150615292, -38, 5),
            (0.158842584, -20, 4),
            (0.167128084, -21, 4),
            (0.175500625, -20, 5),
            (0.184081375, -19, 6),
            (0.194727125, -5, 2),
            (0.199998417, -31, 9),
            (0.210953500, -19, 6),
            (0.217527709, -16, 6),
            (0.224994042, -13, 5),
            (0.242215625, -23, 8),
            (0.249978959, -12, 5),
            (0.260093375, -11, 4),
            (0.267180084, -9, 4),
            (0.274986084, -6, 3),
            (0.283322042, -9, 4),
            (0.291645875, -4, 3),
            (0.299974000, -6, 3),
            (0.308310459, -6, 3),
            (0.325026917, -6, 3),
            (0.334388959, -4, 2),
            (0.341661042, -2, 1),
            (0.349564334, -4, 2),
            (0.358328250, -6, 3),
            (0.366629250, -4, 2),
            (0.374996917, -5, 3),
        ]
        let replayStart = ProcessInfo.processInfo.systemUptime
        for (index, sample) in samples.enumerated() {
            let remaining = sample.0 - (ProcessInfo.processInfo.systemUptime - replayStart)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            NSApp.sendEvent(ScrollEvent(window: window, dx: sample.1, dy: sample.2,
                                       phase: index == 0 ? .began : .changed,
                                       timestamp: 3 + sample.0))
        }
        XCTAssertEqual(store.spacePull, 2, "The recorded deliberate pull must arm creation")
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, timestamp: 3.375062042))
        let host = try XCTUnwrap(window.contentView)
        try await compatibilityWait { store.creatingSpace && formIsUsable(in: host, window: window) }
        XCTAssertFalse(store.spaceSwiping)
    }

    private func exerciseCreation(holdingStill: Bool, flushDuringPublication: Bool = false) async throws {
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
        if holdingStill {
            send(-width * 0.9, at: 2.11)
        } else {
            send(-width * 0.3, at: 2.11)
            send(-width * 0.3, at: 2.21)
            send(-width * 0.3, at: 2.31)
        }
        XCTAssertFalse(store.creatingSpace, "Even a full deliberate pull waits for release")
        // Other native hosting roots can ask AppKit to lay out while @Published is
        // delivering its new value, before the backing property has been assigned.
        // The live sidebar must still eventually show the completed creation state.
        let layout = store.sidebarObservation.objectWillChange.sink {
            guard flushDuringPublication else { return }
            host.subviews.forEach { $0.layoutSubtreeIfNeeded() }
            window.displayIfNeeded()
        }
        defer { layout.cancel() }
        // Hold still, with no intermediate movement packets, then lift the fingers.
        send(phase: .ended, at: 2.42)
        XCTAssertTrue(store.creatingSpace)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        func formField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Space name…" { return field }
            return view.subviews.lazy.compactMap { formField(in: $0) }.first
        }
        try await compatibilityWait { formField(in: host)?.window === window }
        XCTAssertNil(host.spaceSlide, "An outgoing native sidebar must not cover the creation form")
        send(-width, phase: [], at: 2.44) // remaining gesture packets cannot dismiss the form
        XCTAssertTrue(store.creatingSpace)
        store.cancelCreatingSpace()
        try await compatibilityWait {
            formField(in: host) == nil && store.spaceGesture.sectionsView?.window === window
        }
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.currentSpaceID, space.id)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), before)
    }
    private func formField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Space name…" { return field }
        return view.subviews.lazy.compactMap { self.formField(in: $0) }.first
    }

    private func formIsUsable(in host: NSView, window: NSWindow) -> Bool {
        guard let field = formField(in: host), field.window === window,
              !field.isHiddenOrHasHiddenAncestor, field.bounds.width > 0, field.bounds.height > 0,
              field.visibleRect.intersects(field.bounds),
              host.bounds.intersects(field.convert(field.bounds, to: host)),
              let editor = field.currentEditor(), window.firstResponder === editor else { return false }
        var ancestor: NSView? = field
        while let view = ancestor {
            if view.alphaValue < 0.99 { return false }
            ancestor = view.superview
        }
        return true
    }

}
