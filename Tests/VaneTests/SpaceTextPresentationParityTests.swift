import AppKit
import Combine
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import vane

/// Standalone section snapshots omit the search scrim. Capture the compositor's
/// complete window when comparing settled and native swipe text instead.
@MainActor final class SpaceTextPresentationParityTests: XCTestCase {
    private var nativeProfiles: Set<UUID> = []

    override func tearDown() async throws {
        let profiles = nativeProfiles
        nativeProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(profiles)
    }

    func testSynchronousReadersSeeTheCompleteGesturePublication() {
        let gesture = SpaceGesture()
        var publications = 0
        let observation = gesture.$presentation.dropFirst().sink { state in
            publications += 1
            XCTAssertEqual(gesture.profileSliding, state.profileSliding)
            XCTAssertEqual(gesture.swiping, state.swiping)
            XCTAssertEqual(gesture.drag, state.drag)
        }
        defer { observation.cancel() }
        gesture.withPresentationUpdate {
            gesture.swiping = true
            gesture.profileSliding = true
            gesture.drag = -20
        }
        gesture.profileSliding = false
        gesture.swiping = false
        gesture.drag = 0
        XCTAssertEqual(publications, 4)
    }

    func testSynchronousFollowupWritesSurviveTheCurrentPublication() {
        for nestedBatch in [false, true] {
            let gesture = SpaceGesture()
            var changed = false
            var publications: [SpaceGesture.Presentation] = []
            let observation = gesture.$presentation.dropFirst().sink { state in
                publications.append(state)
                guard state.swiping, !changed else { return }
                changed = true
                if nestedBatch {
                    gesture.withPresentationUpdate { gesture.drag = 20 }
                } else {
                    gesture.drag = 20
                }
            }
            gesture.withPresentationUpdate { gesture.swiping = true }
            observation.cancel()
            XCTAssertTrue(changed)
            XCTAssertTrue(gesture.swiping)
            XCTAssertEqual(gesture.drag, 20, "Publication must retain a synchronous follow-up write (nested=\(nestedBatch))")
            XCTAssertEqual(gesture.presentation.drag, 20)
            XCTAssertEqual(publications.map(\.drag), [0, 20])
        }
    }

    func testPublicationKeepsAReentrantBatchOpenUntilItsOwnerClosesIt() {
        let gesture = SpaceGesture()
        var opened = false
        var publications: [SpaceGesture.Presentation] = []
        let observation = gesture.$presentation.dropFirst().sink { state in
            publications.append(state)
            guard !opened else { return }
            opened = true
            gesture.beginPresentationUpdate()
        }
        gesture.swiping = true
        XCTAssertTrue(opened)
        gesture.drag = 20
        gesture.endPresentationUpdate()
        observation.cancel()
        XCTAssertTrue(gesture.presentation.swiping)
        XCTAssertEqual(gesture.presentation.drag, 20)
        XCTAssertEqual(publications.map(\.drag), [0, 20])
    }

    func testSearchDimmedFloatingTextKeepsItsContrastDuringNativeTravel() async throws {
        try await checkTextPresentation(palette: .newTab, floating: true)
    }

    func testDockedAddressSearchKeepsThePresentedScrimClear() async throws {
        try await checkTextPresentation(palette: .address, floating: false)
    }

    func testOrdinarySpaceTravelKeepsItsTextContrast() async throws {
        try await checkTextPresentation(palette: nil, floating: false)
    }

    func testOrdinarySpaceTravelKeepsItsTextContrastDuringSynchronousPublicationFlush() async throws {
        try await checkTextPresentation(palette: nil, floating: false, flushDuringPublication: true)
    }

    func testOrdinarySpaceTravelAndRetirementKeepTheirTextDuringSynchronousPublicationFlushes() async throws {
        try await checkTextPresentation(palette: nil, floating: false,
                                        flushDuringPublication: true, flushEveryPublication: true)
    }

    func testDismissingSearchDuringNativeTrackingKeepsTextAndGroundInStep() async throws {
        try await checkTextPresentation(palette: .newTab, floating: true, dismissWhileTracking: true)
    }

    func testCenteredSearchOccludesNativeSidebarPreview() async throws {
        try await checkTextPresentation(palette: .newTab, floating: false, checkOcclusion: true)
    }

    func testAddressSearchOccludesNativeSidebarPreview() async throws {
        try await checkTextPresentation(palette: .address, floating: false, checkOcclusion: true)
    }

    private func checkTextPresentation(palette: PaletteMode?, floating: Bool,
                                       dismissWhileTracking: Bool = false, checkOcclusion: Bool = false,
                                       flushDuringPublication: Bool = false,
                                       flushEveryPublication: Bool = false) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires native swipe presentation")
        let saver = BatterySaver.shared
        let previousSaverMode = saver.mode
        saver.setMode(.off)
        defer { saver.setMode(previousSaverMode) }
        let speedKey = UIAnimation.surfaces.key
        let previousSpeed = UserDefaults.vane.object(forKey: speedKey)
        if dismissWhileTracking { UserDefaults.vane.set(0.25, forKey: speedKey) }
        defer {
            if let previousSpeed { UserDefaults.vane.set(previousSpeed, forKey: speedKey) }
            else { UserDefaults.vane.removeObject(forKey: speedKey) }
        }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            try await checkTextContrast(palette: palette, floating: floating,
                                        dismissWhileTracking: dismissWhileTracking, checkOcclusion: checkOcclusion,
                                        flushDuringPublication: flushDuringPublication,
                                        flushEveryPublication: flushEveryPublication)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Text contrast fixture cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkTextContrast(palette: PaletteMode?, floating: Bool,
                                   dismissWhileTracking: Bool, checkOcclusion: Bool,
                                   flushDuringPublication: Bool,
                                   flushEveryPublication: Bool) async throws {
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Text contrast fixture").id
        nativeProfiles.insert(profile)
        // Identical content and identical default washes isolate text rendering
        // from title changes, background interpolation and moving-glyph sampling.
        let spaces = (0..<2).map { _ in
            Space(name: "MMMMMMMM", profileID: profile,
                  appearance: "dark", grain: 0)
        }
        XCTAssertTrue(manager.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        if checkOcclusion {
            store.tabs = (0..<5).map { index in
                let tab = Tab(profileID: profile)
                tab.park(url: URL(string: "https://search.fixture/\(index)")!,
                         Parked(title: "Search result \(index)", needsRecovery: true))
                return tab
            }
            store.syncShapes()
        }
        store.palette = palette
        store.sidebarShown = !floating
        store.sidebarPeeking = floating
        let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: checkOcclusion ? 800 : 1280, height: 650),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        let host = BrowserWindowHost(shown: ShownStore(store))
        store.window = window
        window.contentView = host
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        defer {
            monitor.remove()
            host.cancelSpaceSlide()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            manager.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var admission = "not sampled"
        defer { print("SPACE_TEXT_ADMISSION \(admission)") }
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            admission = "running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) anchor=\(store.spaceGesture.sectionsView != nil) presented=\(host.layer?.presentation() != nil) prepared=\(monitor.preparedSlides[spaces[1].id]?.preparedPopulationReady == true)"
            if !NSApp.isActive || NSApp.keyWindow !== window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return false
            }
            guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  NSApp.modalWindow == nil, window.attachedSheet == nil,
                  let anchor = store.spaceGesture.sectionsView, anchor.window === window,
                  anchor.bounds.width > 150, anchor.bounds.height > 100,
                  host.layer?.presentation() != nil else { return false }
            return SidebarNativeReadinessCoordinator.shared.isReady(
                SidebarNativeReadinessScope(store: store, spaceID: spaces[0].id),
                allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled)
        }
        try await displayFrames(in: window)
        let anchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        let sections = anchor.convert(anchor.bounds, to: host)
        // Inline search suggestions cover these label regions. Check their actual
        // clear scrim instead of comparing unrelated popup text with sidebar text.
        if checkOcclusion {
            func field(in view: NSView) -> CommandField.BarField? {
                if let input = view as? CommandField.BarField,
                   input.accessibilityLabel() == palette?.title { return input }
                return view.subviews.lazy.compactMap { field(in: $0) }.first
            }
            let input = try XCTUnwrap(field(in: host))
            var fieldAdmission = "not sampled"
            defer { print("SEARCH_FIELD_ADMISSION \(fieldAdmission)") }
            try await compatibilityWait {
                // NSTextField can hide its own backing while the field editor draws.
                // Admit the enclosing presentation, which owns the bar's fade/scale.
                var ancestor = input.superview
                while ancestor?.layer == nil, ancestor != nil { ancestor = ancestor?.superview }
                guard let presented = ancestor?.layer?.presentation() else {
                    fieldAdmission = "enclosingPresentation=false"
                    return false
                }
                var layer: CALayer? = presented
                var opacity: Float = 1
                var hidden = false
                while let current = layer {
                    opacity *= current.opacity
                    hidden = hidden || current.isHidden
                    layer = current.superlayer
                }
                let focused = window.firstResponder === input.currentEditor()
                fieldAdmission = "focused=\(focused) opacity=\(opacity) hidden=\(hidden)"
                return focused && !hidden && opacity >= 0.999
            }
            // Compare the actual result surface where it crosses the sidebar. The
            // stationary preview must not add a second set of labels over search.
            let fieldRect = input.convert(input.bounds, to: host)
            let region = NSRect(x: max(fieldRect.minX, sections.minX + 40),
                                y: fieldRect.minY - 160, width: 100, height: 120)
            XCTAssertTrue(sections.intersects(region), "The fixture must cover sidebar content")
            let baseline = try await capturePixels(in: host, region: region)
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: -12))
            NSApp.sendEvent(ScrollEvent(window: window, dx: -8))
            let slide = try XCTUnwrap(host.spaceSlide)
            slide.track(drag: 0)
            try await compatibilityWait { slide.preparedPopulationReady && slide.window === window }
            try await displayFrames(in: window)
            let covered = try await capturePixels(in: host, region: region)
            let difference = zip(baseline, covered).reduce(0.0) { $0 + abs($1.0 - $1.1) }
                / Double(baseline.count)
            print("SEARCH_OCCLUSION mode=\(String(describing: palette)) difference=\(difference)")
            XCTAssertLessThan(difference, 0.004,
                              "Native sidebar labels must remain behind the search surface")
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            try await compatibilityWait { !store.spaceSwiping && host.spaceSlide == nil }
            return
        }
        let inlineAddress = palette == .address && !floating
        let baseline = inlineAddress ? nil : try await capture(in: host, sections: sections)
        if inlineAddress { XCTAssertEqual(store.spaceGesture.presentedPaletteScrimOpacity, 0) }

        var flushCount = 0
        let publicationFlush = flushDuringPublication ? store.spaceGesture.$presentation.dropFirst().sink { state in
            guard flushEveryPublication || state.profileSliding && flushCount == 0 else { return }
            flushCount += 1
            self.windowDisplay(host)
        } : nil
        defer { publicationFlush?.cancel() }

        NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApp.sendEvent(ScrollEvent(window: window, dx: -12))
        NSApp.sendEvent(ScrollEvent(window: window, dx: -8))
        let slide = try XCTUnwrap(host.spaceSlide, "The actual monitor must claim a native preview")
        slide.track(drag: 0)
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return store.spaceGesture.profileSliding && slide.preparedPopulationReady
                && abs(slide.offset) < 0.01 && slide.window === window
        }
        try await displayFrames(in: window)
        guard let baseline else {
            XCTAssertEqual(store.spaceGesture.presentedPaletteScrimOpacity, 0,
                           "Inline address editing must leave the sidebar ground undimmed during travel")
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            try await compatibilityWait { !store.spaceSwiping && host.spaceSlide == nil }
            XCTAssertEqual(store.currentSpaceID, spaces[0].id)
            XCTAssertEqual(store.spaceGesture.presentedPaletteScrimOpacity, 0)
            return
        }
        let covered = try await capture(in: host, sections: sections)
        let position = try XCTUnwrap(slide.outgoing.layer).position
        let fractional = CABasicAnimation(keyPath: "position")
        let shifted = NSValue(point: CGPoint(x: position.x - 0.25, y: position.y))
        fractional.fromValue = shifted
        fractional.toValue = shifted
        fractional.duration = 60
        slide.outgoing.layer?.add(fractional, forKey: "text-fractional-probe")
        try await displayFrames(in: window)
        let fractionalContrast = try await capture(in: host, sections: sections)

        slide.outgoing.layer?.removeAnimation(forKey: "text-fractional-probe")
        print("SPACE_TEXT_TAKEOVER baseline=\(baseline) native=\(covered) fractional=\(fractionalContrast)")

        if flushDuringPublication {
            slide.isHidden = true
            try await displayFrames(in: window)
            let liveUnderlay = try await capture(in: host, sections: sections)
            slide.isHidden = false
            try await displayFrames(in: window)
            print("SPACE_TEXT_UNDERLAY \(liveUnderlay) flushes=\(flushCount) sliding=\(store.spaceGesture.profileSliding)")
            XCTAssertGreaterThan(flushCount, 0)
            for contrast in liveUnderlay.contrast {
                XCTAssertLessThan(contrast, 20, "The live labels must be hidden while the native preview owns them")
            }
        }

        var dismissal: [TextCapture] = []
        if dismissWhileTracking {
            store.palette = nil
            let deadline = ContinuousClock.now + .seconds(Look.appearDuration + 0.2)
            repeat {
                dismissal.append(try await capture(in: host, sections: sections))
            } while ContinuousClock.now < deadline
        }

        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await compatibilityWait {
            !store.spaceSwiping && host.spaceSlide == nil
                && store.currentSpaceID == spaces[0].id
        }
        try await displayFrames(in: window)
        let retired = try await capture(in: host, sections: sections)
        print("SPACE_TEXT_CONTRAST baseline=\(baseline) native=\(covered) fractional=\(fractionalContrast) retired=\(retired)")
        for index in baseline.contrast.indices {
            let label = index == 0 ? "Space title" : "New Tab"
            XCTAssertGreaterThan(baseline.contrast[index], 20, "\(label) ROI must contain rendered text")
            XCTAssertEqual(covered.contrast[index], baseline.contrast[index], accuracy: baseline.contrast[index] * 0.05,
                           "\(label) contrast must survive native preview takeover")
            XCTAssertEqual(fractionalContrast.contrast[index], baseline.contrast[index], accuracy: baseline.contrast[index] * 0.05,
                           "\(label) contrast must survive fractional compositor travel")
            if dismissWhileTracking {
                XCTAssertTrue(dismissal.contains {
                    $0.ground[index] > baseline.ground[index] + 0.005
                        && $0.ground[index] < retired.ground[index] - 0.005
                }, "Observe an intermediate scrim frame before checking its endpoint")
                for sample in dismissal {
                    let expected = retired.contrast[index] * sample.ground[index] / retired.ground[index]
                    XCTAssertEqual(sample.contrast[index], expected, accuracy: retired.contrast[index] * 0.05,
                                   "\(label) must fade with the actual presented scrim")
                }
            } else {
                XCTAssertEqual(retired.contrast[index], baseline.contrast[index], accuracy: baseline.contrast[index] * 0.05,
                               "\(label) contrast must survive native preview retirement")
            }
        }
    }

    private struct TextCapture {
        let contrast: [Double]
        let ground: [Double]
    }

    /// Sum foreground contrast over each label, excluding icons and trailing
    /// controls. An adjacent empty strip supplies the ground independently for
    /// every capture; no assumed RGB value or foreground-color token is used.
    private func capture(in host: NSView, sections: NSRect) async throws -> TextCapture {
        let bitmap = try await captureBitmap(in: host)
        let window = try XCTUnwrap(host.window)
        let sx = CGFloat(bitmap.pixelsWide) / window.frame.width
        let sy = CGFloat(bitmap.pixelsHigh) / window.frame.height
        let labelX = sections.minX + Look.rowInset + Look.tileIcon + Look.rowSpacing
        let labelWidth = min(115, sections.maxX - labelX - Look.rowTarget)
        XCTAssertGreaterThan(labelWidth, 80)
        func mean(_ x: Int, _ y: Int) throws -> Double {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let rows = try [CGFloat(0), Look.rowHeight + Look.rowGap].map { top -> (Double, Double) in
            // BrowserWindowHost is unflipped; bitmap scanlines run top to bottom.
            let upper = window.frame.height - sections.maxY + top
            let x0 = Int((labelX - host.bounds.minX) * sx)
            let x1 = Int((labelX - host.bounds.minX + labelWidth) * sx)
            let y0 = Int((upper + 3) * sy)
            let y1 = Int((upper + Look.rowHeight - 3) * sy)
            let groundY = Int((upper + 2) * sy)
            var ground = 0.0
            for x in x0..<x1 { ground += try mean(x, groundY) }
            ground /= Double(x1 - x0)
            var contrast = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 { contrast += max(0, try mean(x, y) - ground) }
            }
            return (contrast, ground)
        }
        return TextCapture(contrast: rows.map(\.0), ground: rows.map(\.1))
    }

    private func captureBitmap(in host: NSView) async throws -> NSBitmapImageRep {
        windowDisplay(host)
        let window = try XCTUnwrap(host.window)
        let content = try await SCShareableContent.currentProcess
        let capturedWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSBitmapImageRep(cgImage: image)
    }

    private func capturePixels(in host: NSView, region: NSRect) async throws -> [Double] {
        let bitmap = try await captureBitmap(in: host)
        let window = try XCTUnwrap(host.window)
        let sx = CGFloat(bitmap.pixelsWide) / window.frame.width
        let sy = CGFloat(bitmap.pixelsHigh) / window.frame.height
        var pixels: [Double] = []
        for y in Int((window.frame.height - region.maxY) * sy)..<Int((window.frame.height - region.minY) * sy) {
            for x in Int(region.minX * sx)..<Int(region.maxX * sx) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                pixels.append(contentsOf: [color.redComponent, color.greenComponent, color.blueComponent])
            }
        }
        return pixels
    }

    private func windowDisplay(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        CATransaction.flush()
    }

    private func displayFrames(in window: NSWindow) async throws {
        let frames = SpaceTextDisplayFrames()
        frames.start(on: try XCTUnwrap(window.screen))
        defer { frames.stop() }
        try await compatibilityWait { frames.count >= 3 }
    }
}

@MainActor private final class SpaceTextDisplayFrames: NSObject {
    private var link: CADisplayLink?
    private(set) var count = 0
    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) { count += 1 }
}
