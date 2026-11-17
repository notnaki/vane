import AppKit
import SwiftUI
import XCTest
@testable import vane

/// A Library swipe dragged the whole way and released at its endpoint, in the first of
/// two profiles' Spaces: the report was a panel that stayed up over a closed Library,
/// with the next swipe switching Space underneath it.
@MainActor final class LibraryProfileSwipeTests: XCTestCase {
    func testFullyDraggedSwipesLeaveThePanelWhereTheLibraryIs() async throws {
        try await onAppKitLoop { try await self.checkFullyDraggedSwipes() }
    }

    /// A flick too short to switch Space springs back, and its momentum tail arrives
    /// while it does. The tail must not catch the returning slide: no fingers are down
    /// to carry it anywhere, and it stayed where it was caught until the next gesture.
    func testAShortFlicksMomentumLetsTheSpaceSlideReturn() async throws {
        try await onAppKitLoop { try await self.checkShortFlickMomentum() }
    }

    /// ⌥⌘→ and ⌃N out of an open Library into another profile's Space end the visit.
    /// The parked profile kept its Library open and came back with the panel up.
    func testAKeyboardSpaceSwitchEndsTheLibraryVisit() async throws {
        try await onAppKitLoop { try await self.checkKeyboardSwitchEndsTheVisit() }
    }

    /// A second opening swipe while the first is still landing belongs to the Library,
    /// as it does once the Library is open. The sidebar's Space swipe took it instead,
    /// and the Library refuses to open under a Space swipe.
    func testASwipeDuringAnOpeningLandingKeepsTheOpen() async throws {
        try await onAppKitLoop { try await self.checkSwipeDuringOpeningLanding() }
    }

    private func onAppKitLoop(_ check: () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await check() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Library swipe AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkFullyDraggedSwipes() async throws {
        try await withWindow { store, window, spaces in
            try await self.checkFullyDraggedSwipes(store, window, spaces)
        }
    }

    /// The first profile's window on its first Space, with a second profile after it on
    /// the strip. `spaces` runs in strip order; the last one is the second profile's.
    private func withWindow(firstProfileSpaces: Int = 1,
                            _ check: (TabStore, NSWindow, [Space]) async throws -> Void) async throws {
        try XCTSkipIf(Motion.spaceReduced || Motion.reduced, "Requires animated navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Library swipe first"), manager.create(name: "Library swipe second")]
        addTeardownBlock { @MainActor in try await NativeFixtureProfileCleanup.release(Set(profiles.map(\.id))) }
        let spaces = (0..<firstProfileSpaces).map { manager.createSpace(name: "Swipe \($0)", in: profiles[0].id) }
            + [manager.createSpace(name: "Swipe", in: profiles[1].id)]
        let store = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(store.window)
        window.animationBehavior = .none
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            let held = TabStore.all.filter { $0.window === window || $0.parkedIn === window }
            for store in held {
                store.spaceGesture.monitor.interruptLanding()
                store.spaceGesture.monitor.remove()
                store.librarySwipeMonitor.remove()
            }
            (window.contentView as? BrowserWindowHost)?.cancelSpaceSlide()
            window.close()
            window.contentView = nil
            for store in held {
                store.window = nil; store.parkedIn = nil; store.profileVisible = false; store.dropStashes()
            }
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        try XCTSkipUnless(store.strip.first?.id == spaces[0].id, "The fixture's Space must be first on the strip")
        store.newTab(URL(string: "about:blank")!)
        store.palette = nil
        try await compatibilityWait {
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                && window.isVisible && window.occlusionState.contains(.visible)
                && store.window === window && store.profileVisible
                && store.spaceGesture.sectionsView?.window === window
                && store.spaceGesture.monitor.isInstalled
                && store.libraryGesture.paint != nil
                && store.active?.web.window === window && store.active?.web.isLoading == false
        }
        try await check(store, window, spaces)
    }

    /// Bounded: a stranded paint never gets there, and that is the failure.
    private func rests(_ store: TabStore, at progress: CGFloat) async throws -> Bool {
        guard let paint = store.libraryGesture.paint else { return false }
        for _ in 0..<100 {
            if paint.progress == progress, !paint.isPreparing, store.librarySwipeProgress == nil { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Bounded, for an outcome whose absence is the failure.
    private func settles(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func checkShortFlickMomentum() async throws {
        try await withWindow(firstProfileSpaces: 2) { store, window, spaces in
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            for (origin, route) in [(spaces[0], "within one profile"), (spaces[1], "into the next profile")] {
                if store.currentSpaceID != origin.id { store.switchTo(space: origin) }
                try await compatibilityWait {
                    store.currentSpaceID == origin.id && host.spaceSlide == nil && !store.spaceSwiping
                        && store.spaceGesture.sectionsView?.window === window
                }
                // Too short and too slow to switch: the default timestamps give it no speed.
                NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
                NSApp.sendEvent(ScrollEvent(window: window, dx: -20))
                NSApp.sendEvent(ScrollEvent(window: window, dx: -20))
                XCTAssertNotNil(host.spaceSlide, "The next-Space swipe travels natively (\(route))")
                XCTAssertTrue(store.spaceSwiping, route)
                NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
                for index in 0..<6 {
                    NSApp.sendEvent(ScrollEvent(window: window, dx: -8, phase: [],
                                                momentum: index == 0 ? .began : .changed))
                }
                NSApp.sendEvent(ScrollEvent(window: window, phase: [], momentum: .ended))
                let returned = try await settles { host.spaceSlide == nil && !store.spaceSwiping }
                XCTAssertTrue(returned, "The momentum tail stranded the returning slide (\(route)): "
                    + "slide=\(host.spaceSlide != nil) swiping=\(store.spaceSwiping)")
                XCTAssertTrue(store.window === window, route)
                XCTAssertEqual(store.currentSpaceID, origin.id, route)
                // Leave nothing travelling for the next route or the teardown.
                store.spaceGesture.monitor.interruptLanding()
                host.cancelSpaceSlide()
                Motion.instant { store.spaceDrag = 0; store.spaceSwiping = false }
            }
        }
    }

    private func checkKeyboardSwitchEndsTheVisit() async throws {
        try await withWindow { store, window, spaces in
            let strip = store.strip
            let home = try XCTUnwrap(strip.firstIndex { $0.id == spaces[0].id })
            let away = try XCTUnwrap(strip.firstIndex { $0.id == spaces[1].id })
            let switches: [(String, (TabStore, Int) -> Void)] = [
                ("⌥⌘→", { store, index in store.cycleSpace(index - (store.strip.firstIndex { $0.id == store.currentSpaceID } ?? 0)) }),
                ("⌃N", { store, index in store.switchTo(spaceNumber: index + 1) }),
            ]
            for (key, press) in switches {
                Library.open(.archived, in: store)
                let opened = try await rests(store, at: 1)
                XCTAssertTrue(opened, key)

                press(store, away)
                let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window }, key)
                XCTAssertEqual(arriving.currentSpaceID, spaces[1].id, key)
                XCTAssertTrue(store.isParked, key)
                XCTAssertFalse(store.libraryOpen, "\(key) left the Library open in the parked profile")
                XCTAssertFalse(store.librarySwipeMonitor.intendsOpen(in: store), key)
                XCTAssertFalse(arriving.libraryOpen, key)

                try await compatibilityWait { arriving.spaceGesture.sectionsView?.window === window }
                press(arriving, home)
                XCTAssertTrue(store.window === window, key)
                XCTAssertFalse(store.libraryOpen, "\(key) brought the profile back with its Library open")
                let closed = try await rests(store, at: 0)
                XCTAssertTrue(closed, "\(key) brought the panel back at "
                    + "\(String(describing: store.libraryGesture.paint?.progress)) over a closed Library")
                try await compatibilityWait {
                    store.spaceGesture.sectionsView?.window === window && store.libraryGesture.paint != nil
                }
            }
        }
    }

    private func checkSwipeDuringOpeningLanding() async throws {
        try await withWindow { store, window, _ in
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: 100))
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            try XCTSkipUnless(!store.libraryOpen && store.librarySwipeMonitor.intendsOpen(in: store),
                              "The opening must still be landing")

            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: 40))
            NSApp.sendEvent(ScrollEvent(window: window, dx: 40))
            XCTAssertFalse(store.spaceSwiping, "The sidebar's Space swipe took a gesture over a landing Library")
            XCTAssertNil(host.spaceSlide)

            // Fingers still down when the landing arrives.
            let opened = try await settles { store.libraryOpen }
            XCTAssertTrue(opened, "The second swipe dropped the pending open")
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            let rested = try await rests(store, at: 1)
            XCTAssertTrue(rested, "The panel stayed at "
                + "\(String(describing: store.libraryGesture.paint?.progress)) under an open Library")
            XCTAssertFalse(store.spaceSwiping)
            // Leave nothing travelling for the teardown.
            Motion.instant { store.spaceDrag = 0; store.spaceSwiping = false }
        }
    }

    private func checkFullyDraggedSwipes(_ store: TabStore, _ window: NSWindow, _ spaces: [Space]) async throws {
        let paint = try XCTUnwrap(store.libraryGesture.paint)
        func rests(at progress: CGFloat) async throws -> Bool {
            // Bounded: a stranded paint never gets there, and that is the failure.
            for _ in 0..<100 {
                if paint.progress == progress, !paint.isPreparing, store.librarySwipeProgress == nil { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        /// Travel past the far edge, then fingers up as soon as the endpoint has been
        /// asked of the page and before the page has painted it.
        func flick(_ dx: CGFloat) async throws {
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: dx))
            for _ in 0..<200 where !paint.isPreparing { await Task.yield() }
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
        }

        Library.open(.archived, in: store)
        let opened = try await rests(at: 1)
        XCTAssertTrue(opened)
        for round in 0..<3 {
            try await flick(-2000)
            XCTAssertFalse(store.libraryOpen, "A full drag closes at fingers-up (round \(round))")
            let closed = try await rests(at: 0)
            XCTAssertTrue(closed, "The panel stayed at \(paint.progress) over a closed Library (round \(round))")

            try await flick(2000)
            XCTAssertTrue(store.libraryOpen, "A full drag opens at fingers-up (round \(round))")
            let reopened = try await rests(at: 1)
            XCTAssertTrue(reopened, "The panel stayed at \(paint.progress) under an open Library (round \(round))")
        }

        // The report's second half: with the panel stranded, the Library was closed as far
        // as the gestures knew, so the closing swipe switched Space instead.
        try await flick(-2000)
        let closed = try await rests(at: 0)
        XCTAssertTrue(closed, "The panel stayed at \(paint.progress) over a closed Library")
        XCTAssertTrue(store.window === window, "Closing the Library must not also leave its Space")
        XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, spaces[0].id)

        // …and its captured sidebar travelled where the stranded panel had left the live
        // one: a panel's width in, drawn over the Library's own list.
        try await compatibilityWait { store.spaceGesture.sectionsView?.window === window }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApp.sendEvent(ScrollEvent(window: window, dx: -40))
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide,
                                  "The next-Space swipe travels natively")
        XCTAssertLessThan(slide.frame.minX, Look.floatingSidebarGap + 1,
                          "The travelling sidebar must start where the sidebar is, not beside a panel")
        NSApp.sendEvent(ScrollEvent(window: window, phase: .cancelled))
        try await compatibilityWait { (window.contentView as? BrowserWindowHost)?.spaceSlide == nil }
    }
}
