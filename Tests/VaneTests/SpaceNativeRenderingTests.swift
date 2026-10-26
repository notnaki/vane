import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceNativeRenderingTests: XCTestCase {
    private func fixture(floatingWindow: Bool = false, coloured: Bool = false, defaultColours: Bool = false, activateWindow: Bool = true) throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        addTeardownBlock { @MainActor in NSApp.setActivationPolicy(activationPolicy) }
        try XCTSkipIf(Motion.spaceReduced, "Animated interruption requires motion")
        let profile = ProfileManager.shared.create(name: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].enumerated().map { index, name in
            coloured ? Space(name: name, profileID: profile,
                             colorHex: index == 0 ? "#FF0000" : "#0000FF", appearance: "dark", tint: 1)
                : Space(name: name, profileID: profile, colorHex: defaultColours ? ["#6E7DD2", "#678575", "#B08068", "#6E7DD2"][index] : nil)
        }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        // Empty windows initially offer search. These fixtures exercise the sidebar;
        // search-specific tests opt back into its presentation explicitly.
        store.palette = nil
        let frame = NSRect(x: 100, y: 100, width: 300, height: 400)
        let window: NSWindow = floatingWindow
            ? VaneWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = BrowserWindowHost(shown: ShownStore(store))
        window.contentView?.layoutSubtreeIfNeeded()
        // Presentation-layer frame assertions require a visible active test window.
        // A user's running Vane copy can otherwise keep this fixture occluded.
        if activateWindow {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
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
        let selectionStart = ContinuousClock.now
        monitor.select(spaces[1], in: store)
        let selectionTime = selectionStart.duration(to: .now)
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
        print("NATIVE_CLICK_TINT select=\(selectionTime) reds=\(samples)")
        XCTAssertLessThan(largestStep, abs(start - end) * 0.6,
                          "The background must blend during native travel instead of cutting at handoff")
    }

    func testProfileClickDoesNotRestoreItsDepartureColour() async throws {
        try await checkProfileColourReturn(swipe: false)
    }

    func testProfileSwipeDoesNotRestoreItsDepartureColour() async throws {
        try await checkProfileColourReturn(swipe: true)
    }

    private func checkProfileColourReturn(swipe: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let blackProfile = manager.create(name: "Black profile")
        let blueProfile = manager.create(name: "Blue profile")
        var black = manager.createSpace(name: "Black", in: blackProfile.id)
        black.colorHex = "#000000"; black.tint = 1; black.appearance = "dark"
        manager.updateSpace(black)
        var blue = manager.createSpace(name: "Blue", in: blueProfile.id)
        blue.colorHex = "#0000FF"; blue.tint = 1; blue.appearance = "dark"
        manager.updateSpace(blue)
        let source = Windows.open(profile: blackProfile, space: black, focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            _ = manager.delete(blackProfile.id)
            _ = manager.delete(blueProfile.id)
            manager.active = previous
        }
        try await Task.sleep(for: .milliseconds(150))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let blackSurface = try XCTUnwrap(colourSurface(in: host))
        XCTAssertEqual(try firstColour(of: blackSurface).blueComponent, 0, accuracy: 0.001)
        source.spaceGesture.monitor.select(blue, in: source)
        try await Task.sleep(for: .milliseconds(500))
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(destination.profileID, blueProfile.id)
        XCTAssertTrue(blackSurface.window === window && blackSurface.isHiddenOrHasHiddenAncestor,
                      "Parked profiles keep their backing frames mounted outside input and accessibility")
        XCTAssertEqual(try firstColour(of: blackSurface).blueComponent, 0, accuracy: 0.001,
                       "A cached profile must retain its own black wash, ready for the return handoff")
        if swipe {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
            for _ in 0..<10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: 12))
                try await Task.sleep(for: .milliseconds(8))
            }
            NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        } else {
            destination.spaceGesture.monitor.select(black, in: destination)
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(source.window === window)
        XCTAssertTrue(blackSurface.window === window)
        XCTAssertEqual(try firstColour(of: blackSurface, presented: true).blueComponent, 0, accuracy: 0.001)
    }

    func testRealShortSwipeRestoresLiveSidebarAfterCancellation() async throws {
        let (store, spaces, window, _) = try fixture()
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/source")!, Parked(title: "Visible source row"))
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        func capture() throws -> NSBitmapImageRep {
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        let baseline = try capture()
        let originalAnchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        let region = originalAnchor.convert(originalAnchor.bounds, to: host)
        func edges(_ image: NSBitmapImageRep) -> Double {
            let scale = Double(image.pixelsWide) / host.bounds.width
            let x0 = max(0, Int(region.minX * scale)), x1 = min(image.pixelsWide - 2, Int(region.maxX * scale))
            let y0 = max(0, Int(region.minY * scale)), y1 = min(image.pixelsHigh - 2, Int(region.maxY * scale))
            var total: Double = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    if let a = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       let b = image.colorAt(x: x + 1, y: y)?.usingColorSpace(.deviceRGB) {
                        total += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    }
                }
            }
            return total
        }
        let beforeEdges = edges(baseline)
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -8))
        XCTAssertNotNil(host.spaceSlide, "The real monitor must mount its native finger track")
        var queuedRepeat = false
        let observer = store.spaceGesture.$profileSliding.sink { hidden in
            guard !hidden, !queuedRepeat, host.spaceSlide != nil else { return }
            queuedRepeat = true
            DispatchQueue.main.async {
                // The acknowledged cover can already be retired. A new zero-travel
                // gesture at this boundary must still release its swiping ownership.
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12, phase: .began))
                NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
            }
        }
        defer { observer.cancel() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(queuedRepeat)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.spaceGesture.drag, 0)
        XCTAssertNil(store.spaceGesture.nativeDrag)
        XCTAssertNil(host.spaceSlide)
        let anchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        XCTAssertTrue(anchor.window === window)
        XCTAssertFalse(anchor.isHiddenOrHasHiddenAncestor)
        let afterEdges = edges(try capture())
        XCTAssertGreaterThan(beforeEdges, 1, "The pre-gesture fixture must render sidebar content")
        XCTAssertGreaterThan(afterEdges, beforeEdges * 0.7,
                             "Canceled swipe must restore visible text and rows instead of a blank sidebar")
    }

    func testRealSwipePresentedColourFollowsNativeLandingPosition() async throws {
        let (store, spaces, window, _) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        let start = try firstColour(of: surface, presented: true)
        let sampler = SwipeColourSampler(host: host, surface: surface)
        sampler.start(on: try XCTUnwrap(window.screen))
        defer { sampler.stop() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        for _ in 0..<10 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        // Page activation measured a 147ms main-turn stall in the original regression.
        // Commit first, then model a bounded synchronous restore while CA keeps rendering.
        DispatchQueue.main.async {
            CATransaction.flush()
            Thread.sleep(forTimeInterval: 0.08)
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        let end = try firstColour(of: surface, presented: true)
        let vector = [end.redComponent-start.redComponent, end.greenComponent-start.greenComponent, end.blueComponent-start.blueComponent]
        let length = vector.reduce(0) { $0 + $1*$1 }
        XCTAssertGreaterThan(length, 0.001)
        var worst: Double = 0
        for sample in sampler.samples {
            let delta = [sample.colour.redComponent-start.redComponent, sample.colour.greenComponent-start.greenComponent, sample.colour.blueComponent-start.blueComponent]
            let fraction = zip(vector, delta).reduce(0) { $0 + $1.0*$1.1 } / length
            let expected = min(1, abs(sample.offset / SidebarWidth.shared.width))
            worst = max(worst, abs(fraction-expected))
        }
        XCTAssertGreaterThan(sampler.samples.count, 5)
        XCTAssertLessThan(worst, 0.16, "Presented colour must follow the compositor's sidebar position through release")
    }

    func testNativeWashUsesLandingCurveAndReleasesOwnershipForReducedMotion() async throws {
        let (store, spaces, window, monitor) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        monitor.track(-40, width: SidebarWidth.shared.width, in: store)
        try await Task.sleep(for: .milliseconds(20))
        monitor.track(-60, width: SidebarWidth.shared.width, in: store)
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store)
        let position = try XCTUnwrap(host.spaceSlide?.outgoing.layer?.animation(forKey: "space-position") as? CABasicAnimation)
        let colour = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertEqual(position.duration, colour.duration)
        for index in 1...2 {
            var a: [Float] = [0, 0], b: [Float] = [0, 0]
            position.timingFunction?.getControlPoint(at: index, values: &a)
            colour.timingFunction?.getControlPoint(at: index, values: &b)
            XCTAssertEqual(a, b)
        }
        XCTAssertTrue(surface.nativeAnimating)
        monitor.finishForReducedMotion()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
    }

    func testNativeWashCancellationCopiesSpringAndCanRestoreOriginImmediately() throws {
        let surface = ThemeWashSurface()
        let from = ThemeWash(colors: [ThemeColor(hex: "#6E7DD2")!], strength: 1, opacity: 1, grain: 0)
        let to = ThemeWash(colors: [ThemeColor(hex: "#678575")!], strength: 1, opacity: 1, grain: 0)
        let animation = CASpringAnimation(keyPath: "position")
        animation.mass = 1
        animation.stiffness = 1542
        animation.damping = 70
        animation.initialVelocity = 2
        animation.duration = animation.settlingDuration
        let token = surface.animateNative(from: from, to: to, animation: animation)
        let colour = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CASpringAnimation)
        XCTAssertEqual(colour.mass, animation.mass)
        XCTAssertEqual(colour.stiffness, animation.stiffness)
        XCTAssertEqual(colour.damping, animation.damping)
        XCTAssertEqual(colour.initialVelocity, animation.initialVelocity)
        surface.finishNative(token: token, wash: from)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(try firstColour(of: surface).redComponent,
                       try XCTUnwrap(from.colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent, accuracy: 0.001)
    }

    func testOldNativeWashCompletionCannotCancelReplacementAnimation() throws {
        let surface = ThemeWashSurface()
        let from = ThemeWash(colors: [ThemeColor(hex: "#6E7DD2")!], strength: 1, opacity: 1, grain: 0)
        let to = ThemeWash(colors: [ThemeColor(hex: "#678575")!], strength: 1, opacity: 1, grain: 0)
        let animation = CABasicAnimation(keyPath: "position")
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let old = surface.animateNative(from: from, to: to, animation: animation)
        let replacement = surface.animateNative(from: to, to: from, animation: animation)
        surface.finishNative(token: old, wash: to)
        XCTAssertTrue(surface.nativeAnimating)
        XCTAssertNotNil(surface.base.animation(forKey: "colors"))
        surface.finishNative(token: replacement, wash: from)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        let colour = try firstColour(of: surface)
        XCTAssertEqual(colour.redComponent, try XCTUnwrap(from.colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent, accuracy: 0.001)
    }

    func testRetargetedLandingPreservesPresentedWashForReversalAndNewDestination() async throws {
        for targetIndex in [0, 2] {
            let (store, spaces, window, monitor) = try fixture(defaultColours: true)
            store.palette = nil
            try await Task.sleep(for: .milliseconds(250))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let surface = try XCTUnwrap(colourSurface(in: host))
            // Give a loaded CI runner a deterministic mid-flight interruption point;
            // the replacement still uses the production click/return timing.
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.8)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while (store.currentSpaceID != spaces[1].id || abs(host.spaceSlide?.offset ?? 0) / SidebarWidth.shared.width < 0.35),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[1].id)
            let previous = try XCTUnwrap(host.spaceSlide)
            XCTAssertTrue(previous.isActive)
            let before = try firstColour(of: surface, presented: true)
            monitor.select(spaces[targetIndex], in: store)
            if targetIndex == 0 {
                XCTAssertTrue(host.spaceSlide === previous, "A reversal must keep the native surface under the fingers")
                XCTAssertTrue(previous.outgoing.layer?.animation(forKey: "space-position") is CASpringAnimation)
            }
            let animation = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CABasicAnimation)
            let values = try XCTUnwrap(animation.fromValue as? [CGColor])
            let from = try XCTUnwrap(NSColor(cgColor: XCTUnwrap(values.first))?.usingColorSpace(.deviceRGB))
            if targetIndex == 0 {
                let delta = abs(from.redComponent-before.redComponent)
                    + abs(from.greenComponent-before.greenComponent) + abs(from.blueComponent-before.blueComponent)
                XCTAssertLessThan(delta, 0.02, "A reversal must begin at the actual presented wash")
            } else {
                XCTAssertTrue(host.spaceSlide === previous, "A new destination waits for the exposed leg")
            }
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertTrue(try XCTUnwrap(host.spaceSlide).isActive, "The superseded animation must not finish its replacement")
            if let slide = host.spaceSlide,
               let position = slide.outgoing.layer?.animation(forKey: "space-position") as? CABasicAnimation,
               let start = (position.fromValue as? NSValue)?.pointValue.x,
               let end = (position.toValue as? NSValue)?.pointValue.x,
               let x = slide.outgoing.layer?.presentation()?.position.x, end != start {
                let fraction = max(0, min(1, (x-start)/(end-start)))
                let colors = try XCTUnwrap(animation.toValue as? [CGColor])
                let to = try XCTUnwrap(NSColor(cgColor: XCTUnwrap(colors.first))?.usingColorSpace(.deviceRGB))
                let actual = try firstColour(of: surface, presented: true)
                let expected = [from.redComponent+(to.redComponent-from.redComponent)*fraction,
                                from.greenComponent+(to.greenComponent-from.greenComponent)*fraction,
                                from.blueComponent+(to.blueComponent-from.blueComponent)*fraction]
                let renderedError = abs(actual.redComponent-expected[0])+abs(actual.greenComponent-expected[1])+abs(actual.blueComponent-expected[2])
                XCTAssertLessThan(renderedError, 0.02, "Retargeted presented colour must remain on the native sidebar's actual curve")
            }
            let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
            while (store.currentSpaceID != spaces[targetIndex].id || store.spaceSwiping || host.spaceSlide != nil),
                  ProcessInfo.processInfo.systemUptime < finalDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[targetIndex].id)
            XCTAssertFalse(surface.nativeAnimating)
        }
    }

    func testQueuedDestinationDoesNotReplaceAlreadyVisibleIncomingRows() async throws {
        let (store, spaces, window, monitor) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.8)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while abs(host.spaceSlide?.offset ?? 0) / SidebarWidth.shared.width < 0.35,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try XCTUnwrap(host.spaceSlide)
        let incoming = try XCTUnwrap(original.subviews.last)
        func pixels(_ view: NSView) throws -> Data {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return try XCTUnwrap(image.tiffRepresentation)
        }
        let before = try pixels(incoming)
        monitor.select(spaces[2], in: store)
        XCTAssertTrue(host.spaceSlide === original, "Already visible B rows must remain on their native surface")
        let after = try XCTUnwrap(host.spaceSlide?.subviews.last)
        XCTAssertTrue(after === incoming)
        XCTAssertEqual(try pixels(after), before, "Requesting C must not swap the exposed B pixels")
        let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (store.currentSpaceID != spaces[2].id || store.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < finalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertNil(host.spaceSlide)
    }

    func testQueuedDestinationHonorsLatestClickAndClearsForVisibleOrOriginClicks() async throws {
        for requestedIndex in [3, 1, 0] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let original = try XCTUnwrap(host.spaceSlide)
            monitor.select(spaces[2], in: store)
            monitor.select(spaces[requestedIndex], in: store)
            XCTAssertTrue(host.spaceSlide === original)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while (store.currentSpaceID != spaces[requestedIndex].id || store.spaceSwiping || host.spaceSlide != nil),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[requestedIndex].id)
            XCTAssertNil(host.spaceSlide)
        }
    }

    func testQueuedDestinationKeepsVisibleIncomingDuringNativeReturnSpring() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.palette = nil
        try await Task.sleep(for: .milliseconds(150))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
        monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.8)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while (store.currentSpaceID != spaces[1].id || abs(host.spaceSlide?.offset ?? 0) / SidebarWidth.shared.width < 0.35),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try XCTUnwrap(host.spaceSlide)
        monitor.select(spaces[0], in: store)
        monitor.select(spaces[2], in: store)
        XCTAssertTrue(host.spaceSlide === original)
        XCTAssertTrue(original.outgoing.layer?.animation(forKey: "space-position") is CASpringAnimation)
        let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (store.currentSpaceID != spaces[2].id || store.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < finalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertNil(host.spaceSlide)
    }

    func testQueuedDestinationResolvesReducedMotionAndDoesNotSurviveAbortOrHide() async throws {
        for action in ["reduce", "abort", "hide"] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            monitor.select(spaces[2], in: store)
            switch action {
            case "reduce": monitor.finishForReducedMotion()
            case "abort": monitor.abort()
            default:
                store.sidebarShown = false
                host.spaceSlide?.sidebarDidDisappear(store)
            }
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(store.currentSpaceID, spaces[action == "reduce" ? 2 : 1].id, action)
            XCTAssertFalse(store.spaceSwiping, action)
            XCTAssertNil(host.spaceSlide, action)
        }
    }

    func testQueuedDestinationRevalidatesDeletionAndExternalSelection() async throws {
        for action in ["delete", "external"] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: SidebarWidth.shared.width, store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            monitor.select(spaces[2], in: store)
            if action == "delete" {
                XCTAssertTrue(ProfileManager.shared.deleteSpace(spaces[2].id, in: store.profileID))
            } else {
                Motion.spaceHandoff { store.switchTo(space: spaces[3]) }
            }
            try await Task.sleep(for: .milliseconds(1000))
            XCTAssertEqual(store.currentSpaceID, spaces[action == "delete" ? 1 : 3].id)
            XCTAssertFalse(store.spaceSwiping)
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        }
    }

    func testFirstProfileVisitChangesPageAtStartOfNativeLanding() async throws {
        try await checkEarlyProfilePageSelection(cached: false)
    }

    func testReverseSwipeTakesOverThePresentedLandingWithoutFinishingIt() async throws {
        for direction in [1, -1] {
            let (store, spaces, window, monitor) = try fixture()
            let origin = spaces[direction > 0 ? 0 : 1]
            let target = spaces[direction > 0 ? 1 : 0]
            store.switchTo(space: origin)
            try await checkReverseLanding(store: store, origin: origin, target: target,
                                          window: window, monitor: monitor, direction: direction)
        }
    }

    func testReverseProfileSwipeTakesOverTheSamePresentedNativeRows() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Catch origin"), manager.create(name: "Catch arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Catch", in: $0.id) }
        let store = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(store.window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        try await checkReverseLanding(store: store, origin: spaces[0], target: spaces[1],
                                      window: window, monitor: store.spaceGesture.monitor, direction: 1)
    }

    private func checkReverseLanding(store: TabStore, origin: Space, target: Space,
                                     window: NSWindow, monitor: SwipeMonitor, direction: Int) async throws {
        store.palette = nil
        let width = SidebarWidth.shared.width
        let sign = CGFloat(direction)
        try await Task.sleep(for: .milliseconds(150))
        monitor.track(-sign * 60, width: width, in: store)
        monitor.land(direction, to: target, width: width, store: store, duration: 0.8)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        // Admit a real middle frame with room to move in either direction. Fixed sleeps
        // can sample the insertion frame or an endpoint on a loaded desktop.
        try await compatibilityWait {
            slide.isActive && abs(slide.offset) > width * 0.45 && abs(slide.offset) < width * 0.8
        }
        XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, target.id)
        let originalRows = slide.outgoing
        let presentedX = try XCTUnwrap(originalRows.layer?.presentation()).frame.minX

        NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApp.sendEvent(ScrollEvent(window: window, dx: sign * 12))
        XCTAssertTrue(host.spaceSlide === slide, "Reversing must retain both captured native surfaces")
        XCTAssertTrue(slide.isActive, "The next swipe must own the still-unfinished transition")
        XCTAssertNil(originalRows.layer?.animation(forKey: "space-position"))
        XCTAssertEqual(originalRows.frame.minX, presentedX + sign * 12, accuracy: 5,
                       "Take over at the visible position, without snapping to the old endpoint")
        let held = originalRows.frame.minX
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "The previous animation completion must not retire the new gesture")
        XCTAssertEqual(originalRows.frame.minX, held, accuracy: 1)
        NSApp.sendEvent(ScrollEvent(window: window, dx: sign * 40))
        XCTAssertEqual(originalRows.frame.minX, held + sign * 40, accuracy: 1)
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(400))
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(showing.currentSpaceID, origin.id)
        XCTAssertFalse(showing.spaceSwiping)
        XCTAssertNil(host.spaceSlide)
    }

    func testRapidBackToBackSwipesDoNotWaitForThePreviousLanding() async throws {
        for direction: CGFloat in [-1, 1] {
            let (store, spaces, window, _) = try fixture()
            store.switchTo(space: direction < 0 ? spaces[0] : spaces[3])
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            for _ in 0..<2 {
                NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
                NSApp.sendEvent(ScrollEvent(window: window, dx: direction * 100))
                NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
                try await Task.sleep(for: .milliseconds(40))
            }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(store.currentSpaceID, spaces[direction < 0 ? 2 : 1].id,
                           "Two distinct quick gestures must each change Space, in either direction")
        }
    }

    func testCachedProfileColourStaysContinuousAcrossRepeatedSwipes() async throws {
        for mixedThemes in [false, true] {
            try await checkRepeatedProfileSwipes(mixedThemes: mixedThemes)
        }
    }

    func testCachedArrivingWashIsPrimedBeforeItsNextSwiftUIUpdate() async throws {
        let (source, spaces, window, _) = try fixture(coloured: true)
        let container = try XCTUnwrap(window.contentView)
        let arriving = TabStore(profileID: source.profileID, space: spaces[1], session: [])
        let target = ThemeWash.space(spaces[1], fallback: source.profile,
                                     profiles: ProfileManager.shared.profiles, systemDark: true)
        // A parked host last rendered its settled destination, so its installed
        // callback still captures two identical blue endpoints when attach runs.
        let cached = NSHostingView(rootView: NativeThemeWash(wash: target, reduced: false,
            gesture: arriving.spaceGesture, origin: target, destination: target,
            fallback: source.profile, profiles: ProfileManager.shared.profiles, systemDark: true))
        cached.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        container.addSubview(cached)
        defer {
            cached.removeFromSuperview()
            arriving.window = nil
            TabStore.all.removeAll { $0 === arriving }
        }
        cached.layoutSubtreeIfNeeded()
        try await compatibilityWait { arriving.spaceGesture.trackGround != nil }
        let surface = try XCTUnwrap(colourSurface(in: cached))
        let origin = ThemeWash.space(spaces[0], fallback: source.profile,
            profiles: ProfileManager.shared.profiles, systemDark: true)
        // Interpolate in the wash's color space before converting for the native
        // layer read; device-RGB conversion is not itself a linear interpolation.
        func expectedRed(at fraction: Double) throws -> CGFloat {
            try XCTUnwrap(origin.mixed(towards: target, fraction: fraction)
                .colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent
        }
        cached.isHidden = true
        let slide = ProfileSpaceSlide(frame: cached.frame,
            outgoing: source.swipePreview(in: spaces[0]), incoming: source.swipePreview(in: spaces[1]),
            drag: -70, direction: 1, source: source, includesFavorites: true, travelWidth: 228)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.prepare()
        slide.start(duration: 1) {}
        slide.attach(arriving)
        XCTAssertEqual(try XCTUnwrap(arriving.spaceGesture.nativeDrag), -70, accuracy: 0.001,
                       "SwiftUI must receive the same published progress as the primed native wash")
        // No await/layout occurs between attachment and this read. The pixels must
        // be ready before the cached host is exposed, even before CA presents the
        // new position animation (whose model position already holds its endpoint).
        XCTAssertEqual(try firstColour(of: surface).redComponent,
                       try expectedRed(at: 70.0 / 228.0), accuracy: 0.001,
                       "A cached host must not expose its settled target color before tracking catches up")
        arriving.spaceGesture.trackGround?(0.5)
        XCTAssertEqual(try firstColour(of: surface).redComponent, try expectedRed(at: 0.5), accuracy: 0.001,
                       "The installed callback must resolve the new gesture endpoints before SwiftUI renders again")
    }

    private func checkRepeatedProfileSwipes(mixedThemes: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Repeated red"), manager.create(name: "Repeated blue")]
        let spaces = profiles.enumerated().map { index, profile in
            Space(name: "Repeated \(index)", profileID: profile.id,
                  colorHex: mixedThemes ? (index == 0 ? "#000000" : "#26456B") : (index == 0 ? "#FF0000" : "#0000FF"),
                  appearance: mixedThemes ? nil : "dark", tint: mixedThemes ? (index == 0 ? 0.8953 : 0.6246) : 1)
        }
        for (profile, space) in zip(profiles, spaces) {
            XCTAssertTrue(manager.saveSpaces([space], for: profile.id))
        }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        window.orderFrontRegardless()
        defer {
            window.close()
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        for (index, space) in spaces.enumerated() {
            let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
            showing.switchTo(space: space)
            let owner = try XCTUnwrap(TabStore.all.first { $0.window === window })
            for row in 0..<20 {
                let tab = owner.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank#\(row)")!, Parked(title: "Profile \(index) document \(row)"))
            }
            owner.palette = nil
        }
        TabStore.all.first { $0.window === window }?.switchTo(space: spaces[0])
        try await Task.sleep(for: .milliseconds(150))
        // Alternate twelve times with both saturated themes and mixed default themes.
        for leg in 0..<12 {
            let index = (leg + 1) % 2
            let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
            let direction = index == 1 ? 1 : -1
            let monitor = showing.spaceGesture.monitor
            let sampler = ProfileWashSampler(host: host)
            sampler.start(on: try XCTUnwrap(window.screen))
            defer { sampler.stop() }
            // A new display link and a freshly restored hosting tree may not have
            // presented yet. Establish actual source-color samples before asking
            // this sampler to verify the subsequent transition's continuity.
            try await compatibilityWait { sampler.reds.count >= 3 }
            sampler.beginTransitionSampling()
            XCTAssertNotNil(showing.beginSpaceSelection(spaces[index]))
            monitor.track(-CGFloat(direction) * 70, width: SidebarWidth.shared.width, in: showing)
            monitor.land(direction, to: spaces[index], width: SidebarWidth.shared.width,
                         store: showing, duration: 0.3)
            // Hosting/layout can defer CA's first commit beyond the nominal
            // duration. Sample the entire handoff, including its actual endpoint,
            // rather than stopping at an assumed 450 ms wall-clock deadline.
            let retirementDeadline = ContinuousClock.now + .seconds(2)
            while host.spaceSlide != nil, ContinuousClock.now < retirementDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            sampler.stop()
            XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, spaces[index].id)
            XCTAssertGreaterThan(sampler.reds.count, 3)
            XCTAssertEqual(sampler.unadmittedTransitionCallbacks, 0,
                           "Every transition callback must identify exactly one presented wash; missing samples cannot pass continuity")
            let reversals = zip(sampler.reds, sampler.reds.dropFirst()).map { previous, next in
                (direction == 1) != mixedThemes ? next - previous : previous - next
            }
            print("PROFILE_WASH_SAMPLE mixed=\(mixedThemes) leg=\(leg) direction=\(direction) frames=\(sampler.reds.count) max_reverse=\(reversals.max() ?? 0) max_gap_ms=\(sampler.maxGap * 1000) first_callback_ms=\((sampler.firstCallbackLatency ?? 0) * 1000)")
            if (reversals.max() ?? 0) >= 0.08 || sampler.unadmittedTransitionCallbacks > 0 {
                sampler.dumpDiagnostics(label: "mixed=\(mixedThemes) leg=\(leg) direction=\(direction)")
            }
            XCTAssertLessThan(reversals.max() ?? 0, 0.08,
                              "The displayed background must not flash back toward its source after profile activation")
            XCTAssertNil(host.spaceSlide)
            XCTAssertEqual(showing.spaceDrag, 0, "Parked profile progress must be released at every landing")
        }
    }

    func testCachedProfileChangesPageAtStartOfNativeLanding() async throws {
        try await checkEarlyProfilePageSelection(cached: true)
    }

    func testCachedProfileReturnInstallsInputBeforeTheNextRender() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Input origin"), manager.create(name: "Input arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Input", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        source.palette = nil
        try await compatibilityWait { source.spaceGesture.monitor.isInstalled }
        let arriving = try XCTUnwrap(Windows.hop(source, to: spaces[1]))
        try await compatibilityWait {
            !source.spaceGesture.monitor.isInstalled && arriving.spaceGesture.monitor.isInstalled
        }
        XCTAssertTrue(Windows.hop(arriving, to: spaces[0]) === source)
        XCTAssertTrue(source.spaceGesture.monitor.isInstalled,
                      "Cached profiles must accept the next gesture before SwiftUI renders their visibility change")
    }

    func testRapidProfileBoundarySwipesCanImmediatelyReverse() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [manager.create(name: "Rapid origin"), manager.create(name: "Rapid arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Rapid", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        source.palette = nil
        try await Task.sleep(for: .milliseconds(150))
        for leg in 0..<8 {
            let direction: CGFloat = leg.isMultiple(of: 2) ? -1 : 1
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: direction * 100))
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            try await Task.sleep(for: .milliseconds(40))
            let showing = TabStore.all.first { $0.window === window }
            print("RAPID_PROFILE leg=\(leg) actual=\(showing?.profileID == profiles[0].id ? 0 : 1) installed=\(showing?.spaceGesture.monitor.isInstalled == true) swiping=\(showing?.spaceSwiping == true) anchor=\(showing?.spaceGesture.stripView?.window === window)")
            XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID,
                           spaces[leg.isMultiple(of: 2) ? 1 : 0].id,
                           "Every fast boundary crossing and reversal must be accepted")
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(source.window === window)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    private func checkEarlyProfilePageSelection(cached: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Native landing requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Early page origin")
        let secondProfile = manager.create(name: "Early page arrival")
        var first = manager.createSpace(name: "A", in: firstProfile.id)
        first.colorHex = "#FF0000"; first.tint = 1; first.appearance = "dark"
        XCTAssertTrue(manager.updateSpace(first))
        var second = manager.createSpace(name: "B", in: secondProfile.id)
        second.colorHex = "#0000FF"; second.tint = 1; second.appearance = "dark"
        second.tabURLs = [URL(string: "about:blank")!]
        XCTAssertTrue(manager.updateSpace(second))
        let other = manager.createSpace(name: "Other parked Space", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.orderFrontRegardless()
        defer {
            window.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        if cached {
            source.switchTo(space: second)
            let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
            try await Task.sleep(for: .milliseconds(100))
            arriving.switchTo(space: other)
            arriving.switchTo(space: first)
        }
        source.newTab(URL(string: "about:blank")!)
        source.palette = nil
        try await Task.sleep(for: .milliseconds(150))
        let sourcePage = try XCTUnwrap(source.active?.web)
        var observedCachedSelection = false
        let selection = TabStore.all.first { $0.parkedIn === window && $0.profileID == secondProfile.id }?
            .$currentSpaceID.sink { id in
                guard id == second.id else { return }
                observedCachedSelection = true
                XCTAssertTrue(sourcePage.window === window && !sourcePage.isHiddenOrHasHiddenAncestor,
                              "Select the requested cached Space before uncovering its profile host")
            }
        defer { selection?.cancel() }
        let monitor = source.spaceGesture.monitor
        XCTAssertNotNil(source.beginSpaceSelection(second))
        monitor.track(-60, width: SidebarWidth.shared.width, in: source)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertTrue(source.window === window, "Finger tracking must keep the outgoing page")
        monitor.land(1, to: second, width: SidebarWidth.shared.width, store: source, duration: 0.8)
        try await Task.sleep(for: .milliseconds(100))
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id,
                       "Profile activation must not wait for the sidebar animation to finish")
        XCTAssertEqual(arriving.currentSpaceID, second.id)
        if cached { XCTAssertTrue(observedCachedSelection) }
        XCTAssertTrue(arriving.active?.web.window === window,
                      "The destination web content must be mounted during landing")
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "The original captured sidebar must continue travelling over the new profile")
        XCTAssertTrue(arriving.spaceGesture.profileSliding,
                      "Live incoming rows must stay hidden underneath the moving sidebar")
        XCTAssertFalse(source.profileVisible)
        XCTAssertTrue(arriving.profileVisible)
        XCTAssertTrue(source.spaceGesture.monitor.preparedSlides.isEmpty,
                      "Parked roots must release their gesture preparation and observers")
        source.liveFolderSheet = true
        source.externalApp = ExternalApps.Prompt(url: URL(string: "example-app://background")!,
            scope: nil, tabID: source.active!.id, documentID: UUID(), scheme: "example-app", app: nil, name: nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(window.attachedSheet,
                     "A late result from a parked root must not present over the arriving profile")
        source.liveFolderSheet = false
        source.externalApp = nil
        let arrivingMonitor = arriving.spaceGesture.monitor
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, phase: .began, x: 900), arriving))
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, dy: 20, x: 900), arriving))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "Scrolling over the page must not cut the sidebar landing short")
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, phase: .began), arriving))
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, dy: 20), arriving))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "Vertical sidebar scrolling must not cut the landing short")
        XCTAssertEqual(arriving.spaceGesture.outgoing?.space.id, first.id,
                       "The arriving footer must keep the gesture's original Space")
        XCTAssertNotNil(arriving.spaceGesture.footer.drag)
        var footerFrames = 0
        let observation = arriving.spaceGesture.footer.$drag.dropFirst().sink { drag in
            guard let drag else { return }
            footerFrames += 1
            XCTAssertEqual(drag, slide.offset, accuracy: 2,
                           "Each arriving footer frame must follow the same native presentation")
        }
        defer { observation.cancel() }
        let surface = try XCTUnwrap(colourSurface(in: host))
        let colour = try firstColour(of: surface, presented: true)
        XCTAssertGreaterThan(colour.redComponent, 0.1,
                             "The background must continue blending after the early profile handoff")
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertGreaterThan(footerFrames, 2)
        XCTAssertNil(host.spaceSlide)
        XCTAssertFalse(arriving.spaceGesture.profileSliding)
        XCTAssertFalse(source.spaceSwiping)
        XCTAssertFalse(source.spaceGesture.profileSliding)
        XCTAssertEqual(source.spaceDrag, 0, "A parked source must not retain stale native travel")
    }

    func testQueuedDestinationStartsFromActualArrivingProfileStore() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Native queue requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = manager.create(name: "Queued origin")
        let secondProfile = manager.create(name: "Queued arrival")
        let first = manager.createSpace(name: "A", in: firstProfile.id)
        let second = manager.createSpace(name: "B", in: secondProfile.id)
        let third = manager.createSpace(name: "C", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        defer {
            window.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(source.beginSpaceSelection(second))
        source.spaceGesture.monitor.land(1, to: second, width: SidebarWidth.shared.width, store: source, duration: 0.5)
        try await Task.sleep(for: .milliseconds(60))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let original = try XCTUnwrap(host.spaceSlide)
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        showing.spaceGesture.monitor.select(third, in: showing)
        XCTAssertTrue(host.spaceSlide === original)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while (TabStore.all.first { $0.window === window }?.currentSpaceID != third.id || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id)
        XCTAssertEqual(arriving.currentSpaceID, third.id)
        XCTAssertFalse(arriving.spaceSwiping)
        XCTAssertNil(source.window)
        XCTAssertNil(host.spaceSlide)
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

    func testPreparedSurfaceStaysAttachedToCompositorAtFirstDrag() async throws {
        try await assertPreparedCompositorHandoff(selecting: false)
    }

    func testPreparedSurfaceStaysAttachedToCompositorAtButtonSelection() async throws {
        try await assertPreparedCompositorHandoff(selecting: true)
    }

    private func assertPreparedCompositorHandoff(selecting: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true)
        window.setContentSize(NSSize(width: 1280, height: 840))
        window.contentView?.wantsLayer = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id]?.layer?.superlayer !== host.layer,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let layer = try XCTUnwrap(prepared.layer)
        XCTAssertTrue(layer.superlayer === host.layer, "Idle preparation must already reach the compositor")
        XCTAssertTrue(prepared.isHidden, "Idle surfaces must not paint over the live sidebar")
        if selecting { monitor.select(spaces[1], in: store) }
        else { monitor.track(-10, width: SidebarWidth.shared.width, in: store) }
        XCTAssertTrue(host.spaceSlide === prepared)
        XCTAssertTrue(store.spaceGesture.profileSliding)
        XCTAssertFalse(prepared.isHidden)
        XCTAssertFalse(layer.isHidden)
        XCTAssertTrue(layer.superlayer === host.layer,
                      "Hiding live sections must not detach their replacement until a later AppKit turn")
        XCTAssertTrue(host.layer?.sublayers?.last === layer,
                      "The already attached replacement must paint above the live hosting tree")
    }

    func testFreshSurfaceReachesCompositorBeforeCoveringLiveSidebar() async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true)
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        host.wantsLayer = true
        try await Task.sleep(for: .milliseconds(250))
        monitor.remove()
        monitor.install(store)
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        let start = ProcessInfo.processInfo.systemUptime
        monitor.track(-10, width: SidebarWidth.shared.width, in: store)
        print("COLD_NATIVE_COMPOSITOR_CLAIM seconds=\(ProcessInfo.processInfo.systemUptime - start)")
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertTrue(store.spaceGesture.profileSliding)
        XCTAssertTrue(slide.layer?.superlayer === host.layer,
                      "A cold claim must attach its surface before covering live content too")
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
        try await waitForPreparation(monitor, target: target.id)
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
        try await waitForPreparation(monitor, target: target.id)
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
            coveredUpdate = slide.superview === host
        }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(coveredUpdate, "Keep the native rows through publication until the live update acknowledges them")
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

    func testAnotherWindowLosingFocusDoesNotCancelThisWindowsSpaceGesture() throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-40, width: SidebarWidth.shared.width, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        let unrelated = NSWindow(contentRect: .zero, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelated)
        XCTAssertTrue(store.spaceSwiping, "Focus notifications belong to their own browser window")
        XCTAssertTrue(host.spaceSlide === slide)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(store.spaceSwiping, "This window losing focus must still cancel an uncommitted drag")
        XCTAssertNil(host.spaceSlide)
    }

    func testDisappearingSourceDoesNotUncoverAVisibleArrivingSidebarBeforeAcknowledgement() async throws {
        let (source, spaces, window, _) = try fixture()
        let (profile, target) = adjacentProfile(to: source, after: spaces.last!)
        let arriving = TabStore(profileID: profile, space: target, session: [])
        let population = try EmptyNativeSidebarPopulationFixture(store: arriving, spaceID: target.id)
        defer { population.close() }
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
        population.complete()
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
        try await waitForPreparation(monitor, target: spaces[1].id)
        let refreshed = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(previous === refreshed, "Changed sidebar content must invalidate the prepared capture")
        XCTAssertNil(previous.superview)
        let remaining = Array(monitor.preparedSlides.values)
        monitor.remove()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        XCTAssertTrue(remaining.allSatisfy { $0.superview == nil })
    }

    func testUnchangedAnchorUpdatesKeepPreparedSidebars() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        for _ in 0..<5 { monitor.schedulePreparation(in: store) }
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Repeated layout acknowledgements must not rebuild identical hidden trees")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        window.setContentSize(NSSize(width: 340, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === prepared,
                       "Changed viewport geometry still needs a fresh capture")
    }

    func testUnchangedSpaceSavesAndAbsentWarningsKeepPreparedCaptureClaimable() async throws {
        let (store, spaces, window, monitor) = try fixture(activateWindow: false)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let manager = ProfileManager.shared
        let committed = manager.spaces(for: store.profileID)
        XCTAssertTrue(committed.contains { $0.id == store.currentSpaceID })
        XCTAssertFalse(manager.saveFailures.contains { $0.id == .spaces(store.profileID) })
        let revision = manager.spacesRevision
        // Model the same durable metadata save made by periodic session capture.
        // Keep a delayed preparation queued, as ordinary scrolling does.
        monitor.postponePreparation(in: store, by: 0.35, preservingSurfaces: true)
        for _ in 0..<3 {
            XCTAssertTrue(manager.saveSpaces(committed, for: store.profileID))
            manager.dismissSaveFailure(.spaces(store.profileID))
        }
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Unchanged saves and absent warning dismissal must not revoke a ready native capture")
        // This is a negative lifetime assertion through the existing quiet deadline,
        // not a readiness sleep: a capture was positively admitted above.
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Idle scheduling after an unchanged save must retain the same laid-out trees")
        XCTAssertTrue(prepared.superview === window.contentView)
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The first directional claim must consume the same warm capture")
        XCTAssertNil(monitor.preparedSlides[spaces[1].id])
        monitor.abort()
    }

    func testActualMetadataContentAndFolderProtectionStillRevokePreparedCaptures() async throws {
        let (store, spaces, window, monitor) = try fixture(activateWindow: false)
        store.sharingReady = false
        store.folderAuthentication = FolderAuthentication()
        let child = store.newBlankTab(focus: false)
        let folder = Folder(name: "Protected fixture folder")
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(child.id.uuidString), parent: folder.id)])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let original = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let manager = ProfileManager.shared
        var renamed = try XCTUnwrap(manager.spaces(for: store.profileID).first { $0.id == spaces[1].id })
        renamed.name += " renamed"
        XCTAssertTrue(manager.updateSpace(renamed))
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Real adjacent metadata changes must revoke on the sending turn")
        XCTAssertNil(original.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterMetadata = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterMetadata === original)

        _ = store.newBlankTab(focus: false)
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Real sidebar content changes must still revoke synchronously")
        XCTAssertNil(afterMetadata.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterContent = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterContent === afterMetadata)

        store.lockFolder(folder.id)
        XCTAssertTrue(store.isFolderLocked(folder.id))
        XCTAssertTrue(store.todayShape.folder(folder.id)?.requiresAuthentication == true)
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Actual folder protection must revoke before any following claim")
        XCTAssertNil(afterContent.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterProtection = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterProtection === afterContent)
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === afterProtection,
                      "Fresh protected content must remain ready for Space navigation")
        monitor.abort()
    }

    func testCancelledSwipeRepreparesBothNeighbours() async throws {
        try await cancelledSwipeRepreparesBothNeighbours(withPendingPreparation: false)
    }

    func testCancelledSwipeWhilePreparationPendingRepreparesBothNeighbours() async throws {
        try await cancelledSwipeRepreparesBothNeighbours(withPendingPreparation: true)
    }

    private func cancelledSwipeRepreparesBothNeighbours(withPendingPreparation pending: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        let left = try XCTUnwrap(monitor.preparedSlides[spaces[0].id])
        let right = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        if pending {
            // Vertical scrolling keeps the warm surfaces but schedules delayed work.
            // The next horizontal claim must cancel that work without wedging the queue.
            monitor.postponePreparation(in: store, by: 0.6, preservingSurfaces: true)
        }
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === right,
                      "The claim must consume the existing right-hand capture")
        XCTAssertTrue(monitor.preparedSlides[spaces[0].id] === left)
        XCTAssertNil(monitor.preparedSlides[spaces[2].id])
        monitor.abort()
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[2].id)
        XCTAssertEqual(Set(monitor.preparedSlides.keys), Set([spaces[0].id, spaces[2].id]),
                       "Returning to the middle Space must warm both directions again")
        let restored = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === restored,
                      "The following swipe must reuse the replacement, rather than build cold")
        monitor.abort()
    }

    func testSearchPresentationAndSuggestionsKeepPreparedSidebars() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        store.palette = .newTab
        store.suggestions = [Suggestion(url: "https://example.com", title: "Example", bookmarked: false)]
        store.clearSuggestions()
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Search state must not discard unchanged hidden sidebars")
        store.palette = nil
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Search dismissal must reuse the same trees, without another expensive layout")
    }

    func testSidebarHideAndRevealReusePreparedSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        for _ in 0..<2 {
            Motion.instant { store.sidebarShown = false }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                          "Hiding chrome must retain unchanged, hidden Space surfaces")
            XCTAssertFalse(monitor.mine(ScrollEvent(window: window, phase: .began), store),
                           "A hidden sidebar cannot claim gestures")
            Motion.instant { store.sidebarShown = true }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                          "Cmd-S must not rebuild the entire neighboring sidebar graph")
        }
        monitor.track(-40, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The reused surface must still be claimable for a real Space switch")
    }

    func testHiddenSidebarStillRevokesStructurallyInvalidPreparedSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        Motion.instant { store.sidebarShown = false }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        store.sidebarPreviewInvalidated.send()
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Protection changes must revoke hidden captures synchronously")
        XCTAssertNil(prepared.superview)
        Motion.instant { store.sidebarShown = true }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === prepared)
        let ready = Array(monitor.preparedSlides.values)
        monitor.remove()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        XCTAssertTrue(ready.allSatisfy { $0.superview == nil },
                      "Full profile/window teardown must still release retained surfaces")
    }

    func testSearchDefersDestructionOfStructurallyInvalidatedHostingTrees() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        weak var retiredCapture = monitor.preparedSlides[spaces[1].id]
        weak var outgoing = monitor.preparedSlides[spaces[1].id]?.outgoing
        XCTAssertNotNil(outgoing)
        store.palette = .newTab
        store.todayShape = Pins(entries: [.init(row: .folder(Folder(name: "Changed during search")))])
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(outgoing, "Opening search must retire eligibility without destroying whole SwiftUI trees on the key event")
        store.palette = nil
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertNil(retiredCapture, "Idle cleanup must release Vane's retired capture ownership")
        // AppKit can retain a detached hosting view until its pending display work
        // drains. Require eventual idle release, rather than same-turn deallocation.
        try await compatibilityWait { outgoing == nil }
        XCTAssertNil(outgoing, "The retired tree must be released once search dismissal settles")
    }

    private func waitForPreparation(_ monitor: SwipeMonitor, target: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while monitor.preparedSlides[target] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func adjacentProfile(to store: TabStore, after space: Space) -> (UUID, Space) {
        let profile = ProfileManager.shared.create(name: "Prepared destination").id
        let target = Space(name: "Remote", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([target], for: profile))
        store.switchTo(space: space)
        store.palette = nil // The empty destination offers search; this fixture tests swipes.
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
        try await waitForPreparation(monitor, target: target.id)
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        _ = peer.newBlankTab(focus: false)
        XCTAssertNil(monitor.preparedSlides[target.id],
                     "A peer mutation must invalidate before a same-turn gesture can claim the capture")
        XCTAssertNil(stale.superview)
        try await waitForPreparation(monitor, target: target.id)
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
        try await waitForPreparation(monitor, target: target.id)
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        // No run-loop turn for preparation/registry observation before the gesture.
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(slide === stale, "A newly live preview supplier changes the frozen row structure")
        XCTAssertNil(stale.superview)
    }

    func testSearchDefersAdjacentPreparationUntilDismissalFinishes() async throws {
        let (store, _, window, monitor) = try fixture()
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.remove()
        monitor.install(store)
        // Opening can race an already queued idle capture. Both scheduling and
        // execution must respect search, including later suggestion publications.
        store.palette = .newTab
        try await Task.sleep(for: .milliseconds(600))
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Hidden Space lists must not be built during search opening")
        SearchSuggestions.enabled = false
        store.suggest("fixture")
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Suggestion updates must not start hidden layout during typing")
        let dismissed = ContinuousClock.now
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if !Motion.reduced, ContinuousClock.now < dismissed + .seconds(Look.appearDuration) {
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Search's dismissal fade must finish before hidden layout resumes")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while monitor.preparedSlides.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "Adjacent Space swipes must be ready again after search closes")
    }

    func testSidebarPreparationWaitsUntilLibraryDragIsIdle() async throws {
        let (store, spaces, _, monitor) = try fixture()
        store.librarySwipeProgress = 0.2
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Background sidebar layout must not interrupt an active Library drag")
        store.librarySwipeProgress = nil
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testHidingTheRetainedSidebarEndsAnUncommittedSwipe() async throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue(store.spaceSwiping)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(store.spaceSwiping, "A hidden retained sidebar must release its gesture")
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    func testFloatingRevealDefersAdjacentSurfacePreparationUntilAfterTravel() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        store.sidebarPeeking = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Laying out adjacent Spaces must not interrupt the floating reveal")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "The settled floating sidebar must still prepare the next swipe")
    }

    func testDockedRevealDefersAdjacentSurfacePreparationUntilAfterTravel() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        store.sidebarShown = true
        window.contentView?.layoutSubtreeIfNeeded()
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(120))
        print("SIDEBAR_DOCK_PREPARATION wait_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) prepared=\(monitor.preparedSlides.count)")
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Adjacent hosting trees must not interrupt the docked opening animation")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testSnapshotBurstWaitsForQuietThenWarmsBothNeighbours() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        let old = Array(monitor.preparedSlides.values)
        // These are real snapshot-revision publications, not a test-only timer API.
        // Every publication must revoke reuse immediately, but a burst should not
        // repeatedly create and destroy complete neighboring hosting trees.
        var prematureCaptures: Set<ObjectIdentifier> = []
        for _ in 0..<4 {
            store.spacesChanged()
            XCTAssertTrue(monitor.preparedSlides.isEmpty)
            try await Task.sleep(for: .milliseconds(130))
            prematureCaptures.formUnion(monitor.preparedSlides.values.map(ObjectIdentifier.init))
        }
        XCTAssertTrue(prematureCaptures.isEmpty, "A continuing mutation burst must produce zero replacement captures")
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        XCTAssertEqual(Set(monitor.preparedSlides.keys), Set([spaces[0].id, spaces[2].id]))
        XCTAssertTrue(old.allSatisfy { $0.superview == nil })
        let right = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === right,
                      "Quiet-time rebuilding must still supply the first directional claim")
        monitor.abort()
    }

    func testPageInputExtendsPendingPreparationWithoutDiscardingWarmSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let warm = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10, phase: .began, x: 290))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === warm,
                      "Input must preserve valid warm first-swipe surfaces")
        store.spacesChanged()
        for index in 0..<4 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10,
                phase: index == 0 ? .began : .changed, x: 290))
            try await Task.sleep(for: .milliseconds(130))
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Pending hidden trees must not rebuild during continuing page/Library input")
        }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended, x: 290))
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === warm)
    }

    func testCreateFormDefersReplacementPreparationUntilDismissed() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        store.creatingSpace = true
        store.spacesChanged()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "The Create Space form must not compete with replacement preview layout")
        store.creatingSpace = false
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testVerticalScrollingDefersAdjacentSurfacePreparationUntilIdle() async throws {
        let (store, _, window, monitor) = try fixture()
        store.sharingReady = false
        store.tabs = (0..<300).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#scroll-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        var gaps: [Double] = []
        for index in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            if index == 10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
            }
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: 0, dy: 20,
                phase: index < 10 ? (index == 0 ? .began : .changed) : [],
                momentum: index < 10 ? [] : (index == 10 ? .began : .changed)))
            try await Task.sleep(for: .milliseconds(20))
            gaps.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Vertical scrolling must not compete with hidden neighboring hosting trees")
        }
        XCTAssertFalse(store.spaceSwiping, "Vertical scrolling must keep its normal recipient")
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: [], momentum: .ended))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "Preparation must resume after scrolling so the next swipe stays ready")
        print("SIDEBAR_SCROLL_PREPARATION max_gap_ms=\(gaps.max() ?? 0)")
    }

    func testMouseWheelScrollingAlsoPostponesHiddenPreparation() async throws {
        let (store, _, window, monitor) = try fixture()
        monitor.schedulePreparation(in: store)
        for _ in 0..<8 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10, phase: [], precise: false))
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(monitor.preparedSlides.isEmpty)
        }
        XCTAssertFalse(store.spaceSwiping)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testFolderDisclosureDefersHiddenSpacePreparationAndDisposal() async throws {
        try await checkFolderDisclosurePreparation(authenticating: false)
    }

    func testSuccessfulFolderUnlockDefersPreviewDisposalBeforeGrantPublication() async throws {
        try await checkFolderDisclosurePreparation(authenticating: true)
    }

    private func checkFolderDisclosurePreparation(authenticating: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        var authenticationReply: FolderAuthentication.Reply?
        store.folderAuthentication = FolderAuthentication { _, reply in
            authenticationReply = reply
            return nil
        }
        try XCTSkipIf(Motion.reduced, "Requires the folder's animated disclosure interval")
        store.sharingReady = false
        // Match the reported outline: four favourites, four loose pins, seven folder
        // children, and eleven Today rows, inside the production native browser host.
        let tabs = (0..<26).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.kind = index < 4 ? .favourite : (index < 15 ? .pinned : .today)
            tab.park(url: URL(string: "about:blank#folder-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.tabs = tabs
        let folder = Folder(name: "Documents", collapsed: true,
                            requiresAuthentication: authenticating ? true : nil)
        store.pins = Pins(entries: tabs[4..<8].map { .init(row: .tab($0.id.uuidString)) }
            + [.init(row: .folder(folder))]
            + tabs[8..<15].map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        store.todayShape = Pins(entries: tabs[15...].map { .init(row: .tab($0.id.uuidString)) })
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        for _ in 0..<2 {
            let stale = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
            store.toggleFolder(folder.id)
            if let reply = authenticationReply {
                authenticationReply = nil
                reply(true)
            }
            XCTAssertFalse(store.isFolderLocked(folder.id))
            XCTAssertTrue(monitor.preparedSlides.isEmpty, "Old disclosure geometry cannot be reused")
            XCTAssertNotNil(stale.superview,
                            "Disposing hidden hosting trees must not block the disclosure input")
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Hidden neighbouring lists must not be built in the folder's middle frames")
            XCTAssertNotNil(stale.superview)
            try await waitForPreparation(monitor, target: spaces[1].id)
            XCTAssertNotNil(monitor.preparedSlides[spaces[1].id], "Preparation resumes after disclosure settles")
            XCTAssertNil(stale.superview, "Idle preparation must drain the old hosting trees")
        }
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testMissingSectionsViewportRejectsPreparedReuse() async throws {
        try await assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: false)
    }

    func testDuplicateSectionsViewportsRejectPreparedReuse() async throws {
        try await assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: true)
    }

    private func assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        func markers(in view: NSView) -> [SidebarSectionsViewport.Marker] {
            (view as? SidebarSectionsViewport.Marker).map { [$0] }
                ?? view.subviews.flatMap { markers(in: $0) }
        }
        let readyMarkers = markers(in: prepared.outgoing)
        XCTAssertEqual(readyMarkers.count, 1, "The real hosted preview must identify one sections viewport")
        let marker = try XCTUnwrap(readyMarkers.first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView)
        let before = scroll.documentVisibleRect.minY
        if duplicate {
            marker.addSubview(SidebarSectionsViewport.Marker(frame: .zero))
        } else {
            marker.removeFromSuperview()
        }
        XCTAssertFalse(prepared.updatePreparedScrollOffset(180),
                       "Missing or ambiguous viewport identity must reject cached reuse")
        XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 0.5,
                       "An invalid marker set must not scroll an arbitrary native view")

        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        let replacement = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(replacement === prepared, "The gesture must fall back to a fresh native cover")
        XCTAssertTrue(replacement.isActive)
        XCTAssertNil(prepared.superview, "The invalid cached cover must be revoked")
        monitor.abort()
    }

    func testScrollingReusesPreparedSurfacesAndRefreshesNativeOffset() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.sharingReady = false
        store.tabs = (0..<60).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#scroll-reuse-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 20, phase: .began))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 20))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Scrolling must not reconstruct two whole hidden hosting trees after every pause")
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: prepared.outgoing))
        // An unrelated native scroller can precede the sections viewport in a
        // hosted sidebar. Keep the real target before inserting that decoy.
        let decoy = NSScrollView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        decoy.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 1000))
        decoy.contentView.scroll(to: NSPoint(x: 0, y: 40))
        decoy.reflectScrolledClipView(decoy.contentView)
        decoy.isHidden = true
        let nativeContainer = try XCTUnwrap(scroll.superview)
        nativeContainer.addSubview(decoy, positioned: .below, relativeTo: scroll)
        defer { decoy.removeFromSuperview() }
        XCTAssertTrue(scrollView(in: prepared.outgoing) === decoy,
                      "The decoy must precede the real sections viewport in native traversal")
        XCTAssertEqual(decoy.documentVisibleRect.minY, 40, accuracy: 1)

        store.spaceGesture.sidebarOffset = 180
        monitor.track(-30, width: SidebarWidth.shared.width, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 180, accuracy: 1,
                       "The reused outgoing sidebar must start at the live scroll position")
        XCTAssertEqual(decoy.documentVisibleRect.minY, 40, accuracy: 1,
                       "Refreshing a reused sidebar must not scroll an unrelated native view")
        monitor.remove()
        XCTAssertNil(prepared.superview)
    }

    func testPageScrollingKeepsThePreparedSidebarReady() async throws {
        let (store, spaces, _, monitor) = try fixture()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        // The fixture is 300pt wide; this point is beyond the default sidebar.
        NSApplication.shared.sendEvent(ScrollEvent(window: try XCTUnwrap(store.window), dy: 20,
                                                   phase: .began, x: 290))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Page scrolling must not discard an unrelated ready-to-use sidebar")
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
        let population = try EmptyNativeSidebarPopulationFixture(store: store, spaceID: spaces[1].id)
        defer { population.close() }
        // A host that has not rendered its new live sidebar cannot acknowledge handoff.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) { store.switchTo(space: spaces[1]) }
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(slide.superview === container,
                      "One display tick alone does not prove the destination live sidebar exists")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[0].id, atRest: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "A stale identity must not uncover the old sidebar")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "The hidden tree still offset by the drag is not ready")
        population.complete()
        XCTAssertTrue(slide.superview === container,
                      "Ready empty population must still wait for the final identity/rest acknowledgement")
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
        let population = try EmptyNativeSidebarPopulationFixture(store: store, spaceID: spaces[1].id)
        defer { population.close() }
        population.complete()
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
        slide.start(duration: 0.16, returning: true) {
            Motion.spaceHandoff {
                completed = true
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
        }
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

    func testQueuedSameProfileSelectionPreservesVisibleProfileLandingBeforeReturning() async throws {
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
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        showing.spaceGesture.monitor.select(local, in: showing)
        XCTAssertTrue(host.spaceSlide === previousSlide,
                      "Already visible incoming profile rows must finish on their original surface")
        XCTAssertTrue(source.spaceGesture.profileSlidesFavorites,
                      "The committed profile's visible favourites must not disappear on the next click")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (source.window !== window || source.currentSpaceID != local.id || source.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(source.window === window)
        XCTAssertEqual(source.currentSpaceID, local.id, "The latest requested local Space must follow the visible profile leg")
        XCTAssertNil(host.spaceSlide)
    }
}

@MainActor private final class ProfileWashSampler: NSObject {
    weak var host: BrowserWindowHost?
    var reds: [Double] = []
    private(set) var unadmittedTransitionCallbacks = 0
    private var samplingTransition = false
    var maxGap: TimeInterval = 0
    private(set) var firstCallbackLatency: TimeInterval?
    private var started: TimeInterval?
    private var last: TimeInterval?
    private var link: CADisplayLink?
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["VANE_DIAG_PROFILE_WASH_SAMPLES"] == "1"
    private var diagnosticFrames: [String] = []
    init(host: BrowserWindowHost) { self.host = host }
    private func presentedSurfaces(in view: NSView) -> [ThemeWashSurface] {
        if let layer = view.layer {
            // The model host switches before its next compositor commit. Mixing
            // model visibility with presentation colors can sample the hidden
            // cached profile's old endpoint and fabricate a full-color reversal.
            guard let presentation = layer.presentation(), !presentation.isHidden,
                  presentation.opacity > 0 else { return [] }
        } else if view.isHidden { return [] }
        if let surface = view as? ThemeWashSurface { return [surface] }
        return view.subviews.flatMap { presentedSurfaces(in: $0) }
    }
    private func visibleSurface(in view: NSView) -> ThemeWashSurface? {
        let candidates = presentedSurfaces(in: view)
        return candidates.count == 1 ? candidates[0] : nil
    }
    func start(on screen: NSScreen) {
        started = ProcessInfo.processInfo.systemUptime
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func beginTransitionSampling() {
        reds.removeAll(keepingCapacity: true)
        diagnosticFrames.removeAll(keepingCapacity: true)
        unadmittedTransitionCallbacks = 0
        samplingTransition = true
        maxGap = 0
        // Include delay before the first transition callback in the gap diagnostic.
        last = ProcessInfo.processInfo.systemUptime
    }
    func stop() { samplingTransition = false; link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstCallbackLatency == nil, let started { firstCallbackLatency = now - started }
        if let last { maxGap = max(maxGap, now - last) }
        last = now
        if diagnosticsEnabled, let host { recordDiagnostics(at: now, in: host) }
        guard let host, let surface = visibleSurface(in: host),
              let cg = (surface.base.presentation()?.colors as? [CGColor])?.first,
              let colour = NSColor(cgColor: cg)?.usingColorSpace(.deviceRGB) else {
            if samplingTransition { unadmittedTransitionCallbacks += 1 }
            return
        }
        reds.append(colour.redComponent)
    }
    func dumpDiagnostics(label: String) {
        guard diagnosticsEnabled else { return }
        print("PROFILE_WASH_DIAGNOSTICS_BEGIN \(label)")
        diagnosticFrames.forEach { print($0) }
        print("PROFILE_WASH_DIAGNOSTICS_END \(label)")
    }
    private func identity(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }
    private func red(_ colors: Any?) -> String {
        guard let cg = (colors as? [CGColor])?.first,
              let color = NSColor(cgColor: cg)?.usingColorSpace(.deviceRGB) else { return "nil" }
        return String(format: "%.6f", Double(color.redComponent))
    }
    private func firstSurface(in view: NSView) -> ThemeWashSurface? {
        if let surface = view as? ThemeWashSurface { return surface }
        return view.subviews.lazy.compactMap { self.firstSurface(in: $0) }.first
    }
    private func recordDiagnostics(at now: TimeInterval, in host: BrowserWindowHost) {
        let selected = visibleSurface(in: host)
        let current = host.window.flatMap { window in TabStore.all.first { $0.window === window } }
        let profile = current?.profileID.uuidString ?? "nil"
        let space = current?.currentSpaceID?.uuidString ?? "nil"
        let slide = host.spaceSlide
        let offset = slide.map { String(format: "%.3f", Double($0.offset)) } ?? "nil"
        var details: [String] = []
        for (index, root) in host.subviews.enumerated() {
            guard let surface = firstSurface(in: root) else { continue }
            let rootPresentation = root.layer?.presentation()
            let surfacePresentation = surface.layer?.presentation()
            let modelRootHidden = root.isHiddenOrHasHiddenAncestor
            let presentationRootHidden = rootPresentation.map { String($0.isHidden) } ?? "nil"
            let presentationRootOpacity = rootPresentation.map { String($0.opacity) } ?? "nil"
            let modelRed = red(surface.base.colors)
            let presentationRed = red(surface.base.presentation()?.colors)
            var ancestors: [String] = []
            var node: NSView? = surface
            while let view = node {
                let presentation = view.layer?.presentation()
                let hidden = presentation.map { String($0.isHidden) } ?? "nil"
                let opacity = presentation.map { String($0.opacity) } ?? "nil"
                ancestors.append("\(identity(view)):modelHidden=\(view.isHidden),presentHidden=\(hidden),presentOpacity=\(opacity)")
                if view === root { break }
                node = view.superview
            }
            details.append("rootIndex=\(index),root=\(identity(root)),surface=\(identity(surface)),selected=\(surface === selected),modelRootHidden=\(modelRootHidden),presentRootHidden=\(presentationRootHidden),presentRootOpacity=\(presentationRootOpacity),modelRed=\(modelRed),presentRed=\(presentationRed),nativeAnimating=\(surface.nativeAnimating),ancestors=[\(ancestors.joined(separator: ";"))]")
            _ = surfacePresentation // Ancestor diagnostics include this layer as well.
        }
        let appActive = NSApp.isActive
        let key = host.window?.isKeyWindow ?? false
        let visible = host.window?.isVisible ?? false
        let compositorVisible = host.window?.occlusionState.contains(.visible) ?? false
        diagnosticFrames.append("PROFILE_WASH_FRAME t=\(now) sampleIndex=\(reds.count) activeProfile=\(profile) activeSpace=\(space) offset=\(offset) slideActive=\(slide?.isActive ?? false) appActive=\(appActive) key=\(key) windowVisible=\(visible) occlusionVisible=\(compositorVisible) roots={\(details.joined(separator: " | "))}")
    }

}

@MainActor private final class SwipeColourSampler: NSObject {
    struct Sample { let time: TimeInterval; let offset: CGFloat; let colour: NSColor }
    weak var host: BrowserWindowHost?
    weak var surface: ThemeWashSurface?
    var samples: [Sample] = []
    var link: CADisplayLink?
    init(host: BrowserWindowHost, surface: ThemeWashSurface) { self.host=host; self.surface=surface }
    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link=nil }
    @objc func tick(_ link: CADisplayLink) {
        guard let slide=host?.spaceSlide, let surface,
              let color=(surface.base.presentation()?.colors as? [CGColor])?.first,
              let rgb=NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return }
        samples.append(Sample(time: ProcessInfo.processInfo.systemUptime, offset: slide.offset, colour: rgb))
    }
}
