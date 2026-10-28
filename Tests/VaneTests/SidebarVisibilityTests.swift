import AppKit
import XCTest
import SwiftUI
import QuartzCore
@testable import vane

@MainActor final class SidebarVisibilityTests: XCTestCase {
    private func sidebarViewport(in view: NSView) -> NSScrollView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.sidebarViewport(in: $0) }.first
    }

    private func origins(of viewport: NSScrollView, in host: NSView) -> (presented: CGPoint, model: CGPoint)? {
        guard let layer = viewport.layer, let presentation = layer.presentation(),
              let root = host.layer, let presentedRoot = root.presentation() else { return nil }
        return (presentation.convert(.zero, to: presentedRoot), layer.convert(.zero, to: root))
    }

    private func admitRestingViewport(in host: NSView) async throws -> NSScrollView {
        var admitted: NSScrollView?
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            CATransaction.flush()
            guard let viewport = self.sidebarViewport(in: host),
                  let points = self.origins(of: viewport, in: host),
                  abs(points.presented.x - points.model.x) < 0.5,
                  abs(points.presented.y - points.model.y) < 0.5 else { return false }
            admitted = viewport
            return true
        }
        return try XCTUnwrap(admitted)
    }

    func testPresentationSamplingExcludesParkedProfileTrees() {
        let root = NSView()
        let parked = NSView()
        let hiddenViewport = NSScrollView()
        let arriving = NSScrollView()
        parked.addSubview(hiddenViewport)
        root.addSubview(parked)
        root.addSubview(arriving)
        parked.isHidden = true
        XCTAssertTrue(sidebarViewport(in: root) === arriving,
                      "A retained parked profile must not supply the arriving profile's geometry")
        arriving.isHidden = true
        XCTAssertNil(sidebarViewport(in: root), "An entirely hidden tree has no visible sidebar")
    }

    func testFloatingRevealRetainsTheLaidOutSidebar() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.palette = nil
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = VaneWindow(contentRect: bounds, styleMask: .borderless,
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        host.frame = bounds
        window.contentView = host
        defer {
            store.spaceGesture.monitor.remove()
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
        host.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(viewport(in: host))
        for _ in 0..<2 {
            store.sidebarShown = false
            store.sidebarPeeking = false
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(viewport(in: host) === original,
                          "Hiding must retain the laid-out rows so edge reveal does not rebuild mid-animation")
            store.sidebarPeeking = true
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(viewport(in: host) === original,
                          "Repeated edge reveals must reuse the sidebar viewport")
        }
    }

    func testDockingOrHidingEndsTheFloatingRevealImmediately() {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.active.id
        let store = TabStore(profileID: profile, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
        }
        store.sidebarPeeking = true
        store.sidebarShown = false
        XCTAssertFalse(store.sidebarPeeking)
        store.sidebarPeeking = true
        store.sidebarShown = true
        XCTAssertFalse(store.sidebarPeeking)
    }

    func testHidingSidebarDisablesItsFocusedRenameField() async throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let previous = manager.active
        let profile = manager.create(name: "Hidden sidebar input")
        let space = manager.createSpace(name: "Rename fixture", in: profile.id)
        let store = Windows.open(profile: profile, space: space, focus: false)
        let window = try XCTUnwrap(store.window)
        defer {
            window.close()
            _ = manager.delete(profile.id)
            manager.active = previous
        }
        store.palette = nil
        store.renamingSpace = space.id
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func renameField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == "Rename fixture", field.isEditable {
                return field
            }
            return view.subviews.lazy.compactMap { renameField(in: $0) }.first
        }
        let field = try XCTUnwrap(renameField(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        Motion.instant { store.sidebarShown = false }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(field.window == nil || !field.isEnabled,
                      "Hidden inline editors must not accept keyboard input")
        XCTAssertFalse(window.firstResponder === editor,
                       "Hiding the sidebar must release its field editor")
    }

    func testVisibilityFollowsWindowAcrossNewAndParkedProfiles() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Sidebar first")
        let secondProfile = manager.create(name: "Sidebar second")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let unrelated = Windows.open(profile: secondProfile, space: second, focus: false)
        let window = try XCTUnwrap(source.window)
        let otherWindow = try XCTUnwrap(unrelated.window)
        defer {
            window.close()
            otherWindow.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }

        source.sidebarShown = false
        source.sidebarPeeking = true
        source.switchTo(space: second)
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window && $0.profileID == secondProfile.id })
        XCTAssertEqual(destination.currentSpaceID, second.id)
        XCTAssertFalse(source.sidebarPeeking, "Leaving a profile must dismiss its cached hover sidebar")
        XCTAssertTrue(destination.sidebarPeeking, "The floating sidebar follows the window into a new profile")
        XCTAssertFalse(destination.sidebarShown, "A new profile must keep the window's hidden sidebar")
        XCTAssertTrue(unrelated.sidebarShown, "Another window keeps its own visibility")

        destination.sidebarPeeking = true
        let returning = try XCTUnwrap(Windows.hop(destination, to: first))
        XCTAssertFalse(destination.sidebarPeeking)
        XCTAssertTrue(returning.sidebarPeeking, "The current floating sidebar follows the window into a cached profile")
        XCTAssertTrue(returning === source)
        XCTAssertFalse(returning.sidebarShown, "A parked profile must adopt the window's latest visibility")

        returning.sidebarShown = false
        returning.sidebarPeeking = false
        let revisited = try XCTUnwrap(Windows.hop(returning, to: second))
        XCTAssertTrue(revisited === destination)
        XCTAssertFalse(revisited.sidebarPeeking, "A closed floating sidebar must stay closed when revisiting a profile")
        XCTAssertFalse(revisited.sidebarShown, "Revisiting a profile must not restore its old shown state")
        XCTAssertTrue(unrelated.sidebarShown)

        revisited.sidebarShown = true
        let docked = try XCTUnwrap(Windows.hop(revisited, to: first))
        XCTAssertTrue(docked.sidebarShown, "Docked visibility also follows the window")
        XCTAssertFalse(docked.sidebarPeeking)
    }

    func testSlidingRowsReachTheWindowEdge() throws {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://edge.invalid")!, Parked(title: "Window edge row"))
        store.current = tab.id
        store.palette = nil
        func edgePixels() throws -> [CGFloat] {
            let bounds = NSRect(x: 0, y: 0, width: 900, height: 700)
            let window = NSWindow(contentRect: bounds, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
                .environmentObject(ProfileManager.shared)
                .environment(\.colorScheme, .dark)
                .transaction { $0.disablesAnimations = true })
            host.frame = bounds
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / bounds.height
            return try (120..<500).flatMap { y in
                try (0..<4).map { x in
                    let color = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scaleX),
                        y: Int(CGFloat(y) * scaleY))?.usingColorSpace(.deviceRGB))
                    return color.redComponent
                }
            }
        }
        let resting = try edgePixels()
        store.spaceDrag = -24
        let sliding = try edgePixels()
        let changed = zip(resting, sliding).filter { abs($0 - $1) > 0.03 }.count
        XCTAssertGreaterThan(changed, 20, "Sliding rows must remain visible up to the window edge")
    }

    func testReturningToCachedProfileDoesNotReplaySidebarDocking() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exerciseCachedProfileDocking() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Sidebar presentation loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseCachedProfileDocking() async throws {
        let manager = ProfileManager.shared
        let previous = manager.active
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        let firstProfile = manager.create(name: "Dock source")
        let secondProfile = manager.create(name: "Dock target")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        try await LibraryFocusFixture.admitForeground(window)
        let host = try XCTUnwrap(window.contentView)
        _ = try await admitRestingViewport(in: host)
        source.sidebarShown = false
        source.sidebarPeeking = true
        let target = try XCTUnwrap(Windows.hop(source, to: second))
        let targetViewport = try await admitRestingViewport(in: host)
        let returning = try XCTUnwrap(Windows.hop(target, to: first))
        let sourceViewport = try await admitRestingViewport(in: host)
        let floatingOrigin = try XCTUnwrap(origins(of: sourceViewport, in: host)).presented
        returning.sidebarShown = true
        // Observe the source's docking update before the profile switch. SwiftUI
        // can drive this through layout, without a separate CALayer animation.
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            guard let points = self.origins(of: sourceViewport, in: host) else { return false }
            return abs(points.presented.x - floatingOrigin.x) > 0.5 ||
                abs(points.presented.y - floatingOrigin.y) > 0.5
        }
        _ = try XCTUnwrap(Windows.hop(returning, to: second))
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(sidebarViewport(in: host))
        XCTAssertTrue(viewport === targetViewport, "Sample the cached arriving profile, not its parked source")
        XCTAssertFalse(viewport.isHiddenOrHasHiddenAncestor,
                       "Presentation samples must belong to the visible arriving profile")
        func presentedOrigin() throws -> CGPoint {
            let layer = try XCTUnwrap(viewport.layer?.presentation())
            return layer.convert(.zero, to: host.layer?.presentation())
        }
        let early = try presentedOrigin()
        try await Task.sleep(for: .milliseconds(350))
        let settled = try presentedOrigin()
        XCTAssertEqual(early.x, settled.x, accuracy: 0.5,
                       "The arriving profile must already use docked geometry")
        XCTAssertEqual(early.y, settled.y, accuracy: 0.5,
                       "An old floating inset must not animate after switching profiles")
    }

    func testVisibilitySurvivesSpaceSwitchesWithinOneProfile() {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Sidebar spaces")
        let first = manager.createSpace(name: "First", in: profile.id)
        let second = manager.createSpace(name: "Second", in: profile.id)
        let store = TabStore(profileID: profile.id, space: first, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            _ = manager.delete(profile.id)
        }

        store.sidebarShown = false
        store.sidebarPeeking = true
        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertTrue(store.sidebarPeeking, "Switching Spaces must keep the floating sidebar open")
        XCTAssertFalse(store.sidebarShown)
        store.sidebarShown = true
        store.switchTo(space: first)
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.sidebarShown)
    }
}
