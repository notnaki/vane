import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import vane

/// Standalone section snapshots omit the search scrim. Capture the compositor's
/// complete window when comparing settled and native swipe text instead.
@MainActor final class SpaceTextPresentationParityTests: XCTestCase {
    func testSearchDimmedFloatingTextKeepsItsContrastDuringNativeTravel() async throws {
        try await checkTextPresentation(palette: .newTab, floating: true)
    }

    func testDockedAddressSearchDoesNotDimNativeText() async throws {
        try await checkTextPresentation(palette: .address, floating: false)
    }

    func testOrdinarySpaceTravelKeepsItsTextContrast() async throws {
        try await checkTextPresentation(palette: nil, floating: false)
    }

    private func checkTextPresentation(palette: PaletteMode?, floating: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires native swipe presentation")
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkTextContrast(palette: palette, floating: floating) } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Text contrast fixture cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkTextContrast(palette: PaletteMode?, floating: Bool) async throws {
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Text contrast fixture").id
        // Identical content and identical default washes isolate text rendering
        // from title changes, background interpolation and moving-glyph sampling.
        let spaces = (0..<2).map { _ in
            Space(name: "MMMMMMMM", profileID: profile,
                  appearance: "dark", grain: 0)
        }
        XCTAssertTrue(manager.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        store.palette = palette
        store.sidebarShown = !floating
        store.sidebarPeeking = floating
        let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 650),
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        var admission = "not sampled"
        defer { print("SPACE_TEXT_ADMISSION \(admission)") }
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            admission = "running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) anchor=\(store.spaceGesture.sectionsView != nil) presented=\(host.layer?.presentation() != nil) prepared=\(monitor.preparedSlides[spaces[1].id]?.preparedPopulationReady == true)"
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
        let baseline = try await contrast(in: host, sections: sections)

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
        let covered = try await contrast(in: host, sections: sections)
        let position = try XCTUnwrap(slide.outgoing.layer).position
        let fractional = CABasicAnimation(keyPath: "position")
        let shifted = NSValue(point: CGPoint(x: position.x - 0.25, y: position.y))
        fractional.fromValue = shifted
        fractional.toValue = shifted
        fractional.duration = 60
        slide.outgoing.layer?.add(fractional, forKey: "text-fractional-probe")
        try await displayFrames(in: window)
        let fractionalContrast = try await contrast(in: host, sections: sections)

        slide.outgoing.layer?.removeAnimation(forKey: "text-fractional-probe")

        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await compatibilityWait {
            !store.spaceSwiping && host.spaceSlide == nil
                && store.currentSpaceID == spaces[0].id
        }
        try await displayFrames(in: window)
        let retired = try await contrast(in: host, sections: sections)
        print("SPACE_TEXT_CONTRAST baseline=\(baseline) native=\(covered) fractional=\(fractionalContrast) retired=\(retired)")
        for index in baseline.indices {
            let label = index == 0 ? "Space title" : "New Tab"
            XCTAssertGreaterThan(baseline[index], 20, "\(label) ROI must contain rendered text")
            XCTAssertEqual(covered[index], baseline[index], accuracy: baseline[index] * 0.05,
                           "\(label) contrast must survive native preview takeover")
            XCTAssertEqual(fractionalContrast[index], baseline[index], accuracy: baseline[index] * 0.05,
                           "\(label) contrast must survive fractional compositor travel")
            XCTAssertEqual(retired[index], baseline[index], accuracy: baseline[index] * 0.05,
                           "\(label) contrast must survive native preview retirement")
        }
    }

    /// Sum foreground contrast over each label, excluding icons and trailing
    /// controls. An adjacent empty strip supplies the ground independently for
    /// every capture; no assumed RGB value or foreground-color token is used.
    private func contrast(in host: NSView, sections: NSRect) async throws -> [Double] {
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
        let bitmap = NSBitmapImageRep(cgImage: image)
        let sx = CGFloat(bitmap.pixelsWide) / window.frame.width
        let sy = CGFloat(bitmap.pixelsHigh) / window.frame.height
        let labelX = sections.minX + Look.rowInset + Look.tileIcon + Look.rowSpacing
        let labelWidth = min(115, sections.maxX - labelX - Look.rowTarget)
        XCTAssertGreaterThan(labelWidth, 80)
        func mean(_ x: Int, _ y: Int) throws -> Double {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        return try [CGFloat(0), Look.rowHeight + Look.rowGap].map { top in
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
            return contrast
        }
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
