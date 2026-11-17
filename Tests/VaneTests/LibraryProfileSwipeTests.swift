import AppKit
import SwiftUI
import XCTest
@testable import vane

/// A Library swipe dragged the whole way and released at its endpoint, in the first of
/// two profiles' Spaces: the report was a panel that stayed up over a closed Library,
/// with the next swipe switching Space underneath it.
@MainActor final class LibraryProfileSwipeTests: XCTestCase {
    func testFullyDraggedSwipesLeaveThePanelWhereTheLibraryIs() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkFullyDraggedSwipes() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Library swipe AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkFullyDraggedSwipes() async throws {
        try XCTSkipIf(Motion.spaceReduced || Motion.reduced, "Requires animated navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Library swipe first"), manager.create(name: "Library swipe second")]
        addTeardownBlock { @MainActor in try await NativeFixtureProfileCleanup.release(Set(profiles.map(\.id))) }
        let spaces = profiles.map { manager.createSpace(name: "Swipe", in: $0.id) }
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
