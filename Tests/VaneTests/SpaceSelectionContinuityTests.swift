import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSelectionContinuityTests: XCTestCase {
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

    func testSwipeKeepsTheVisibleSidebarSlidingWhenContentActivates() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.spaceSwiping = true
        store.spaceDrag = -70
        try await Task.sleep(for: .milliseconds(60))
        let moving = try XCTUnwrap(store.spaceGesture.outgoingView,
                                  "The moving sidebar must be mounted before committing the page")
        func x() throws -> CGFloat {
            let surface = (window.contentView as? BrowserWindowHost)?.spaceSlide?.outgoing ?? moving
            return try XCTUnwrap(surface.layer?.presentation()).convert(.zero,
                to: window.contentView?.layer?.presentation()).x
        }
        let before = try x()
        monitor.land(1, to: spaces[1], width: 250, store: store,
                     animation: .linear(duration: 0.4), activationDelay: 0.1)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id, "Keep the page before the quarter point")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id, "Switch at the quarter point, while the sidebar is moving")
        let during = try x()
        XCTAssertLessThan(during, before - 10, "The sidebar must keep sliding after content activates")
        XCTAssertGreaterThan(during, before - 170, "Content activation must not snap it to the endpoint")
        XCTAssertEqual(try XCTUnwrap(moving.layer?.presentation()).opacity, 1,
                       "The swipe must stay opaque")
        try await Task.sleep(for: .milliseconds(400))
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

    func testClickActivatesContentAtTheQuarterPoint() async throws {
        let (store, spaces, _, monitor) = try fixture()
        let outgoing = store.newBlankTab(focus: true)
        store.switchTo(space: spaces[1])
        let incoming = store.newBlankTab(focus: true)
        store.switchTo(space: spaces[0])
        XCTAssertEqual(store.current, outgoing.id)
        try await Task.sleep(for: .milliseconds(60))
        monitor.select(spaces[1], in: store)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertEqual(store.current, incoming.id, "The page must change on selection, before animation completion")
        XCTAssertTrue(store.spaceSwiping, "The sidebar still has its travel to finish")
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
                     activationDelay: 0.1)
        XCTAssertTrue(host.spaceSlide === slide, "Release must animate the surface already under the fingers")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertNil(host.spaceSlide)
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

    func testSidebarContinuesMovingAfterFocusedPageHandoff() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let outgoing = store.newBlankTab(focus: true)
        store.switchTo(space: spaces[1])
        let incoming = store.newBlankTab(focus: true)
        store.switchTo(space: spaces[0])
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(outgoing.web))
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        try await Task.sleep(for: .milliseconds(60))
        let moving = try XCTUnwrap(store.spaceGesture.outgoingView)
        func x() throws -> CGFloat {
            let surface = (window.contentView as? BrowserWindowHost)?.spaceSlide?.outgoing ?? moving
            return try XCTUnwrap(surface.layer?.presentation()).convert(.zero,
                to: window.contentView?.layer?.presentation()).x
        }
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store,
                     animation: .easeIn(duration: 0.4), activationDelay: 0.1)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.current, incoming.id)
        let first = try x()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(try x(), first - 5,
                          "Page activation must not freeze the still-travelling sidebar")
        try await Task.sleep(for: .milliseconds(250))
    }

    func testCommittedSwipeActivatesContentAtTheQuarterPoint() async throws {
        let (store, spaces, _, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        let incoming = store.newBlankTab(focus: true)
        store.switchTo(space: spaces[0])
        store.spaceSwiping = true
        store.spaceDrag = -80

        monitor.land(1, to: spaces[1], width: 250, store: store,
                     animation: .linear(duration: 0.4), activationDelay: 0.1)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertEqual(store.current, incoming.id)
        XCTAssertTrue(store.spaceSwiping)
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
            try await Task.sleep(for: .milliseconds(110))
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
            XCTAssertNotNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                            "The same sidebar track must survive the page host switch")
            try await Task.sleep(for: .milliseconds(200))
        }
        destination.spaceGesture.monitor.select(first, in: destination)
        if !reduced { try await Task.sleep(for: .milliseconds(110)) }
        XCTAssertTrue(source.window === window, "A cached profile must also switch during its slide")
        XCTAssertEqual(source.currentSpaceID, first.id)
    }

    func testReturningToSameProfileBeforeQuarterCancelsTheNativeOverlay() async throws {
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
            store: source, animation: .linear(duration: 0.4), activationDelay: 0.1)
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

    func testClosingWindowBeforeQuarterCancelsTheDelayedSelection() async throws {
        let (store, spaces, _, monitor) = try fixture()
        store.spaceSwiping = true
        store.spaceDrag = -70
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width,
                     store: store, animation: .linear(duration: 0.2), activationDelay: 0.05)
        store.window = nil
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id,
                       "Closing the window must not activate or resume the destination later")
        XCTAssertFalse(store.spaceSwiping)
    }

    func testLatestClickReplacesAMountingSelection() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        monitor.select(spaces[2], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id, "The latest click must win")
        XCTAssertFalse(store.spaceSwiping)
    }

    func testClickingOriginReversesAnInFlightLanding() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(store.spaceSwiping)
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id, "A superseded completion cannot switch away")
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testLatestClickReplacesAnInFlightLanding() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(110))
        let beforeRetarget = store.currentSpaceID
        monitor.select(spaces[2], in: store)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, beforeRetarget,
                       "Retargeting keeps the old page until the new quarter-point activation")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBatterySaverKeepsTheLatestSelectionAnimated() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        BatterySaver.shared.setMode(.alwaysOn)
        monitor.select(spaces[2], in: store)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertTrue(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testBatterySaverKeepsTheVisibleLandingAnimatedWithoutMoreInput() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(100))
        BatterySaver.shared.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertTrue(store.spaceSwiping)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testPolicyChangePreservesNewerNavigation() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        store.switchTo(space: spaces[2])
        BatterySaver.shared.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testReduceMotionFinishesAnOwnedSelectionImmediately() throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        monitor.finishForReducedMotion()
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testBatterySaverKeepsTheReturnToOriginMounted() async throws {
        TestEnvironment.prepare()
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        defer { BatterySaver.shared.setMode(previous) }
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        monitor.select(spaces[0], in: store)
        XCTAssertTrue(store.spaceSwiping, "The returning preview must remain mounted")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testClickAfterNewerNavigationOwnsItsCompletion() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(60))
        store.switchTo(space: spaces[2])
        monitor.select(spaces[3], in: store)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.currentSpaceID, spaces[3].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testRepeatedOriginClickKeepsTheReturnMounted() async throws {
        let (store, spaces, _, monitor) = try fixture()
        monitor.select(spaces[1], in: store)
        try await Task.sleep(for: .milliseconds(100))
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(20))
        monitor.select(spaces[0], in: store)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.spaceSwiping, "A repeated origin click must preserve the moving return")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
    }

}
