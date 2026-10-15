import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceNativeRenderingTests: XCTestCase {
    private func fixture(floatingWindow: Bool = false, coloured: Bool = false) throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Animated interruption requires motion")
        let profile = ProfileManager.shared.create(name: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].enumerated().map { index, name in
            coloured ? Space(name: name, profileID: profile,
                             colorHex: index == 0 ? "#FF0000" : "#0000FF", appearance: "dark", tint: 1)
                : Space(name: name, profileID: profile)
        }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let frame = NSRect(x: 100, y: 100, width: 300, height: 400)
        let window: NSWindow = floatingWindow
            ? VaneWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = BrowserWindowHost(shown: ShownStore(store))
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (store, spaces, window, monitor)
    }

    private func colourSurface(in view: NSView) -> ThemeWashSurface? {
        if let surface = view as? ThemeWashSurface { return surface }
        return view.subviews.lazy.compactMap { self.colourSurface(in: $0) }.first
    }

    private func firstColour(of surface: ThemeWashSurface, presented: Bool = false) throws -> NSColor {
        let layer = presented ? surface.base.presentation() ?? surface.base : surface.base
        let colours = try XCTUnwrap(layer.colors as? [CGColor])
        return try XCTUnwrap(NSColor(cgColor: XCTUnwrap(colours.first))?.usingColorSpace(.deviceRGB))
    }

    func testZeroOffsetKeepsTheIncomingBackgroundColourPrepared() async throws {
        let (store, spaces, window, _) = try fixture(coloured: true)
        _ = store.beginSpaceSelection(spaces[1])
        store.spaceGesture.nativeDrag = 0
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let surface = try XCTUnwrap(colourSurface(in: XCTUnwrap(window.contentView)))
        let start = try firstColour(of: surface)
        XCTAssertGreaterThan(start.redComponent, 0.9)
        let track = try XCTUnwrap(store.spaceGesture.trackGround)
        track(1)
        let end = try firstColour(of: surface)
        track(0.5)
        let middle = try firstColour(of: surface)
        XCTAssertLessThan(middle.redComponent, start.redComponent - 0.1)
        XCTAssertGreaterThan(middle.redComponent, end.redComponent + 0.1)
        XCTAssertGreaterThan(middle.blueComponent, start.blueComponent + 0.1)
        XCTAssertLessThan(middle.blueComponent, end.blueComponent - 0.1,
                          "A zero-offset click must retain the incoming colour for native tracking")
    }

    func testNativeSpaceClickBlendsBackgroundDuringSidebarTravel() async throws {
        let (store, spaces, window, monitor) = try fixture(coloured: true)
        try await Task.sleep(for: .milliseconds(120))
        let surface = try XCTUnwrap(colourSurface(in: XCTUnwrap(window.contentView)))
        let start = try firstColour(of: surface, presented: true).redComponent
        monitor.select(spaces[1], in: store)
        var samples = [start]
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            samples.append(try firstColour(of: surface, presented: true).redComponent)
        } while store.spaceSwiping && ProcessInfo.processInfo.systemUptime < deadline
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        try await Task.sleep(for: .milliseconds(60))
        let end = try firstColour(of: surface, presented: true).redComponent
        samples.append(end)
        XCTAssertGreaterThan(abs(start - end), 0.5)
        XCTAssertTrue(samples.contains { abs($0 - start) > 0.05 && abs($0 - end) > 0.05 },
                      "The actual BrowserWindowHost must show intermediate background colours")
        let largestStep = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(largestStep, abs(start - end) * 0.6,
                          "The background must blend during native travel instead of cutting at handoff")
    }

    func testFirstNativeDragReusesSurfacesPreparedWhileIdle() async throws {
        let (store, spaces, window, monitor) = try fixture()
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<50 where monitor.preparedSlides[spaces[1].id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id],
                                    "Adjacent surfaces must be laid out before finger movement")
        let originX = prepared.outgoing.frame.minX
        for offset: CGFloat in [-0.25, -0.5, -1, -2, -4] {
            let start = ProcessInfo.processInfo.systemUptime
            monitor.track(offset, width: SidebarWidth.shared.width, in: store)
            print("INITIAL_NATIVE_DRAG offset=\(offset) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
            let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
            XCTAssertTrue(slide === prepared, "The first sample must not construct a new hosting tree")
            XCTAssertEqual(slide.outgoing.frame.minX - originX, offset, accuracy: 0.001)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAdjacentButtonSelectionReusesPreparedPopulatedNativeSurfaceWithoutChangingTiming() async throws {
        let (store, spaces, window, monitor) = try fixture()
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        monitor.select(spaces[1], in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "An adjacent button click must reuse the hosting trees prepared while idle")
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "The active surface must leave the idle cache")
        XCTAssertFalse(prepared.isHidden)
        let animation = try XCTUnwrap(prepared.outgoing.layer?.animation(forKey: "space-position"))
        XCTAssertEqual(animation.duration, Look.spaceSlideDuration)
        let timing = try XCTUnwrap(animation.timingFunction)
        var actual: [Float] = [0, 0], expected: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &actual)
        CAMediaTimingFunction(name: .easeInEaseOut).getControlPoint(at: 1, values: &expected)
        XCTAssertEqual(actual, expected, "Prepared button travel must retain the approved click easing")
        try await Task.sleep(for: .milliseconds(500))
    }

    func testCrossProfileButtonSelectionReusesPreparedNativeSurface() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(250))
        let prepared = try XCTUnwrap(monitor.preparedSlides[target.id])
        monitor.select(target, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "Profile-boundary buttons must reuse the prepared favorites and sections")
        XCTAssertNil(monitor.preparedSlides[target.id])
        try await Task.sleep(for: .milliseconds(500))
    }

    func testButtonSelectionRejectsCaptureFromBeforeANewPreviewSupplier() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(250))
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        monitor.select(target, in: store)
        let active = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(active === stale, "Button claims must validate newly live snapshot suppliers too")
        XCTAssertNil(stale.superview)
        try await Task.sleep(for: .milliseconds(500))
    }

    func testPeekingSidebarPreparesAndReusesItsNativeSurface() async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true)
        // Separate the docked sidebar's disappearance from the floating mount. Instant
        // fixture setup leaves native Space motion enabled, with stable peek geometry.
        Motion.instant { store.sidebarShown = false }
        try await Task.sleep(for: .milliseconds(100))
        Motion.instant { store.sidebarPeeking = true; store.palette = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue((window as? VaneWindow)?.peekingSidebar == true)
        XCTAssertTrue(store.spaceGesture.sectionsView?.window === window,
                      "The floating sidebar must have its actual rendered geometry")
        XCTAssertGreaterThan(store.spaceGesture.sectionsView?.bounds.width ?? 0, 0)
        XCTAssertGreaterThan(store.spaceGesture.sectionsView?.bounds.height ?? 0, 0)
        monitor.install(store)
        monitor.schedulePreparation(in: store)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.preparedSlides[spaces[1].id] == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id],
                                    "A visible floating sidebar must prepare before finger input")
        monitor.track(-0.5, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The first floating-sidebar drag must reuse its laid-out hosting trees")
    }

    func testHiddenSidebarDoesNotPrepareNativeSurfaces() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        store.sidebarPeeking = false
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse((window as? VaneWindow)?.peekingSidebar ?? true)
        // Keep a valid native anchor as an outgoing sidebar could during its removal.
        // The hidden-state guard, rather than missing geometry, must prevent preparation.
        let anchor = NSView(frame: NSRect(x: Look.floatingSidebarGap, y: Look.floatingSidebarGap,
                                         width: SidebarWidth.shared.width, height: 300))
        window.contentView?.addSubview(anchor)
        store.spaceGesture.sectionsView = anchor
        store.spaceGesture.stripView = anchor
        monitor.install(store)
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "No hidden sidebar should allocate prepared native lists")
    }

    func testNativeSurfaceCoversTheLiveSidebarUpdateTurn() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-60, width: SidebarWidth.shared.width, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        var coveredUpdate = false
        slide.start(duration: 0.02) {
            // Match the production completion: selection and gesture reset share a
            // handoff transaction so SpaceSlide cannot begin an independent transition.
            Motion.spaceHandoff {
                store.switchTo(space: spaces[1])
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
            DispatchQueue.main.async {
                coveredUpdate = slide.superview === host
            }
        }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(coveredUpdate, "Keep the destination surface over the old live tree until its update is drawn")
        XCTAssertNil(host.spaceSlide)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
    }

    func testHidingSidebarRetiresCommittedNativeLandingWithoutCoveringThePage() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        monitor.track(-80, width: SidebarWidth.shared.width, in: store)
        let departing = try XCTUnwrap(host.spaceSlide)
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 1)
        try await Task.sleep(for: .milliseconds(30))
        Motion.instant { store.sidebarShown = false; store.sidebarPeeking = false }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(host.spaceSlide, "A closed sidebar must not leave its native lists over the page")
        XCTAssertNil(departing.superview)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id, "Closing the sidebar preserves the committed selection")
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)

        Motion.instant { store.sidebarShown = true }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        monitor.select(spaces[2], in: store)
        let replacement = try XCTUnwrap(host.spaceSlide)
        XCTAssertFalse(replacement === departing)
        departing.finish() // An old compositor callback must not remove the replacement.
        XCTAssertTrue(host.spaceSlide === replacement)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while host.spaceSlide != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertNil(host.spaceSlide)
    }

    func testDisappearingSourceDoesNotUncoverAVisibleArrivingSidebarBeforeAcknowledgement() async throws {
        let (source, spaces, window, _) = try fixture()
        let (profile, target) = adjacentProfile(to: source, after: spaces.last!)
        let arriving = TabStore(profileID: profile, space: target, session: [])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: source.swipePreview(in: spaces.last!), incoming: source.swipePreview(in: target),
            drag: -80, direction: 1, source: source, includesFavorites: true, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel(); arriving.window = nil }
        source.sidebarShown = false
        source.sidebarPeeking = false
        slide.start(duration: 1) {
            source.window = nil
            arriving.window = window
            arriving.sidebarShown = true
            slide.attach(arriving)
        }
        slide.sidebarDidDisappear(source)
        XCTAssertTrue(slide.isDestination(arriving))
        XCTAssertTrue(slide.superview === container,
                      "Completion must recheck the arriving visibility instead of unconditionally retiring")
        slide.sidebarDidUpdate(arriving, renderedSpaceID: target.id, atRest: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(slide.superview, "A visible arrival retires after its real rendered acknowledgement")
    }

    func testSlowNativeSpaceLandingNeverReversesItsPresentation() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        try await Task.sleep(for: .milliseconds(400))
        var samples: [CGFloat] = []
        for index in 1...40 {
            monitor.track(-CGFloat(index) * 3, width: SidebarWidth.shared.width, in: store)
            try await Task.sleep(for: .milliseconds(10))
            samples.append(try XCTUnwrap(host.spaceSlide).offset)
        }
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store)
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(8))
            samples.append(host.spaceSlide?.offset ?? -SidebarWidth.shared.width)
        }
        print("SLOW_SPACE_PRESENTATION: \(samples)")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.5,
                                     "A forward slide must never expose the origin again")
        }
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testIdleSurfacesRefreshWithSidebarContentAndLeaveWithMonitor() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await Task.sleep(for: .milliseconds(250))
        let previous = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        _ = store.newBlankTab(focus: false)
        try await Task.sleep(for: .milliseconds(250))
        let refreshed = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(previous === refreshed, "Changed sidebar content must invalidate the prepared capture")
        XCTAssertNil(previous.superview)
        let remaining = Array(monitor.preparedSlides.values)
        monitor.remove()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        XCTAssertTrue(remaining.allSatisfy { $0.superview == nil })
    }

    private func adjacentProfile(to store: TabStore, after space: Space) -> (UUID, Space) {
        let profile = ProfileManager.shared.create(name: "Prepared destination").id
        let target = Space(name: "Remote", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([target], for: profile))
        store.switchTo(space: space)
        XCTAssertEqual(store.swipeNeighbour(for: -1)?.id, target.id)
        addTeardownBlock { @MainActor in
            for peer in TabStore.all.filter({ $0.profileID == profile }) {
                peer.spaceGesture.monitor.remove()
                let tabs = peer.everyTab
                peer.dropStashes()
                TabStore.all.removeAll { $0 === peer }
                SharedTabs.release(tabs)
            }
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (profile, target)
    }

    func testPreparedDestinationInvalidatesBeforeAnotherProfileMutatesItsTabs() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(250))
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        _ = peer.newBlankTab(focus: false)
        XCTAssertNil(monitor.preparedSlides[target.id],
                     "A peer mutation must invalidate before a same-turn gesture can claim the capture")
        XCTAssertNil(stale.superview)
        try await Task.sleep(for: .milliseconds(250))
        let refreshed = try XCTUnwrap(monitor.preparedSlides[target.id])
        XCTAssertFalse(refreshed === stale)
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === refreshed)
    }

    func testNewPreviewSupplyingStoreCannotReuseAnOlderPreparedDestination() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(250))
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        // No run-loop turn for preparation/registry observation before the gesture.
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(slide === stale, "A newly live preview supplier changes the frozen row structure")
        XCTAssertNil(stale.superview)
    }

    func testSidebarPreparationWaitsUntilLibraryDragIsIdle() async throws {
        let (store, _, _, monitor) = try fixture()
        store.librarySwipeProgress = 0.2
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Background sidebar layout must not interrupt an active Library drag")
        store.librarySwipeProgress = nil
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testFingerTrackingReusesNativeSurfaceThroughCommit() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-30, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertEqual(slide.offset, -30, accuracy: 1)
        var publications = 0
        let observer = store.spaceGesture.objectWillChange.sink { publications += 1 }
        monitor.track(-80, width: 250, in: store)
        XCTAssertEqual(publications, 0, "Finger tracking must not invalidate SwiftUI on each event")
        XCTAssertEqual(store.spaceDrag, -80)
        XCTAssertEqual(store.spaceGesture.footer.drag, -80,
                       "The isolated footer must follow every native finger update")
        withExtendedLifetime(observer) {}
        XCTAssertTrue(host.spaceSlide === slide, "Scroll events must retain the mounted lists")
        XCTAssertEqual(slide.offset, -80, accuracy: 1)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id, "Dragging must not activate the page")
        monitor.land(1, to: spaces[1], width: 250, store: store,
                     duration: 0.4)
        XCTAssertTrue(host.spaceSlide === slide, "Release must animate the surface already under the fingers")
        // A newly ordered window may submit its first compositor frame after start().
        // Observe native completion before measuring the separate live-tree handoff.
        let animationDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (store.spaceSwiping || store.spaceGesture.profileSliding),
              ProcessInfo.processInfo.systemUptime < animationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.spaceSwiping, "The native landing must complete")
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        let handoffDeadline = ProcessInfo.processInfo.systemUptime + 0.18
        while host.spaceSlide != nil, ProcessInfo.processInfo.systemUptime < handoffDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(host.spaceSlide, "After native completion, retire through the live acknowledgement, not the one-second safeguard")
    }

    func testLandingKeepsOneContinuousNativeProgressSource() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-20, width: 250, in: store)
        monitor.track(-80, width: 250, in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        var samples: [CGFloat] = []
        let observation = store.spaceGesture.footer.$drag.sink { value in
            guard let value else { return }
            samples.append(value)
            XCTAssertEqual(value, slide.offset, accuracy: 1,
                           "Each footer publication must come from the same native presentation")
        }
        defer { observation.cancel() }
        monitor.land(1, to: spaces[1], width: 250, store: store, duration: 0.4)
        XCTAssertEqual(store.spaceGesture.footer.drag, -80,
                       "Release must not fall back to the first drag sample")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id,
                       "The page should change under the covering native sidebar, not wait for its endpoint")
        XCTAssertEqual(store.spaceGesture.outgoing?.space.id, spaces[0].id,
                       "Footer and tint must keep their captured origin after page selection")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(samples.count, 2, "Landing must publish intermediate presentation progress")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.5, "A committed footer must never reverse")
        }
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertNil(store.spaceGesture.footer.drag)
    }

    func testNativeCoverWaitsForTheLiveSidebarAcknowledgement() async throws {
        let (store, spaces, window, _) = try fixture()
        // A host that has not rendered its new live sidebar cannot acknowledge handoff.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) { store.switchTo(space: spaces[1]) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(slide.superview === container,
                      "One display tick alone does not prove the destination live sidebar exists")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[0].id, atRest: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "A stale identity must not uncover the old sidebar")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "The hidden tree still offset by the drag is not ready")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(slide.superview, "An acknowledged destination retires without waiting for the safeguard")
    }

    func testRenderedSpaceLandingAcknowledgesItsLiveSidebarPromptly() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-80, width: SidebarWidth.shared.width, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.12)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertNil(host.spaceSlide, "The rendered identity must retire the cover before the one-second safeguard")
    }

    func testSynchronousLiveSidebarAcknowledgementIsNotLostDuringCompletion() async throws {
        let (store, spaces, window, _) = try fixture()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) {
            store.switchTo(space: spaces[1])
            store.spaceDrag = 0
            store.spaceSwiping = false
            store.spaceGesture.profileSliding = false
            // NSHostingView can update synchronously with final state publication,
            // before finish() arms its destination-specific retirement guard.
            slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(slide.superview,
                     "A valid acknowledgement during completion must retire without the safeguard")
    }

    func testCommittedNativeLandingRetainsFingerVelocity() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-20, width: 250, in: store)
        try await Task.sleep(for: .milliseconds(20))
        monitor.track(-60, width: 250, in: store)
        monitor.land(1, to: spaces[1], width: 250, store: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        let timing = try XCTUnwrap(slide.outgoing.layer?.animation(forKey: "space-position")?.timingFunction)
        var control: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &control)
        XCTAssertGreaterThan(control[1], 0, "Release must not stop moving before easing to its endpoint")
        try await Task.sleep(for: .milliseconds(400))
    }

    func testCanceledNativeDragUsesTheReturnSpring() async throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-60, width: 250, in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        var completed = false
        slide.start(duration: 0.16, returning: true) { completed = true }
        XCTAssertNotNil(slide.outgoing.layer?.animation(forKey: "space-position") as? CASpringAnimation,
                        "The visible native surface must spring back, not just its hidden SwiftUI copy")
        XCTAssertFalse(completed)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(completed)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    func testFingerTrackingCanCrossZeroAndReverseToAnotherNeighbour() throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.track(-40, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let first = try XCTUnwrap(host.spaceSlide)
        monitor.track(0, width: 250, in: store)
        XCTAssertTrue(host.spaceSlide === first)
        XCTAssertEqual(first.offset, 0, accuracy: 1)
        monitor.track(40, width: 250, in: store)
        let reversed = try XCTUnwrap(host.spaceSlide)
        XCTAssertFalse(reversed === first)
        XCTAssertTrue(reversed.follows(spaces[0], direction: -1))
        XCTAssertEqual(reversed.offset, 40, accuracy: 1)
        monitor.abort()
    }

    func testAbortedFingerTrackingRemovesNativeSurface() throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-40, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(host.spaceSlide)
        monitor.abort()
        XCTAssertNil(host.spaceSlide)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testProfileClickPreservesSlideAndReduceMotionAcrossHosts() async throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Immediate origin")
        let secondProfile = manager.create(name: "Immediate destination")
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
        let reduced = Motion.spaceReduced
        try await Task.sleep(for: .milliseconds(80))
        source.spaceGesture.monitor.select(second, in: source)
        if !reduced {
            XCTAssertTrue(source.window === window)
            try await Task.sleep(for: .milliseconds(310))
        }
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(destination.profileID, secondProfile.id)
        XCTAssertEqual(destination.currentSpaceID, second.id)
        XCTAssertFalse(source.spaceSwiping)
        XCTAssertNil(window.contentView?.layer?.animation(forKey: "profile-space"), "No full-window fade")
        if reduced {
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                         "Reduce Motion switches the page and sidebar immediately")
        } else {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                         "Retire the overlay once the arriving profile has drawn")
        }
        destination.spaceGesture.monitor.select(first, in: destination)
        if !reduced { try await Task.sleep(for: .milliseconds(310)) }
        XCTAssertTrue(source.window === window, "A cached profile must also switch during its slide")
        XCTAssertEqual(source.currentSpaceID, first.id)
    }

    func testHiddenCrossProfileLandingTracksAndRetiresTheActualArrivingSidebar() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "A committed native profile landing requires motion")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Hidden profile origin")
        let secondProfile = manager.create(name: "Hidden profile destination")
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
        try await Task.sleep(for: .milliseconds(80))
        source.spaceGesture.monitor.select(second, in: source)
        let departing = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        Motion.instant { source.sidebarShown = false; source.sidebarPeeking = false }
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while source.window === window, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id, "Hiding preserves the committed profile selection")
        XCTAssertEqual(arriving.currentSpaceID, second.id)
        XCTAssertTrue(departing.isDestination(arriving),
                      "Completion must attach the actual destination before deciding sidebar retirement")
        XCTAssertFalse(arriving.sidebarShown)
        XCTAssertFalse(arriving.spaceGesture.profileSliding)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertNil(departing.superview)
    }

    func testReturningToSameProfileBeforeLandingCancelsTheNativeOverlay() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Interrupting a native slide requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Interrupted origin")
        let secondProfile = manager.create(name: "Interrupted destination")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let local = manager.createSpace(name: "Local", in: firstProfile.id)
        let remote = manager.createSpace(name: "Remote", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(source.beginSpaceSelection(remote))
        try await Task.sleep(for: .milliseconds(30))
        source.spaceGesture.monitor.land(1, to: remote, width: SidebarWidth.shared.width,
            store: source, animation: .linear(duration: 0.4), duration: 0.4)
        try await Task.sleep(for: .milliseconds(40))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let previousSlide = try XCTUnwrap(host.spaceSlide)
        source.spaceGesture.monitor.select(local, in: source)
        XCTAssertFalse(host.spaceSlide === previousSlide,
                       "The previous native track must not cover the replacement swipe")
        XCTAssertFalse(source.spaceGesture.profileSlidesFavorites,
                       "The replacement same-profile track must leave favourites fixed")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(source.window === window)
        XCTAssertEqual(source.currentSpaceID, local.id, "The superseded profile activation must not fire")
    }
}
