import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceNativeRenderingTests: XCTestCase {
    private func fixture() throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Animated interruption requires motion")
        let profile = ProfileManager.shared.create(name: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
