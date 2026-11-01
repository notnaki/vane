import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SpaceColourTransitionTests: XCTestCase {
    func testSwipeEndpointMatchesDestinationIntensity() {
        let red = ThemeColor(red: 1, green: 0, blue: 0)
        let blue = ThemeColor(red: 0, green: 0, blue: 1)
        let from = ThemeWash(colors: [red], strength: 0.2, opacity: 0.62, grain: 0)
        let to = ThemeWash(colors: [blue], strength: 1, opacity: 0.62, grain: 0)
        let end = from.mixed(towards: to, fraction: 1).colors[0]
        XCTAssertEqual(end.red, 0, accuracy: 1e-6)
        XCTAssertEqual(end.green, 0, accuracy: 1e-6)
        XCTAssertEqual(end.blue, 1, accuracy: 1e-6)
    }
}

extension SpaceColourTransitionTests {
    func testLandingAndCancellationUseTheExactRestingSurface() {
        let source = ThemeWash(colors: [.hsl(h: 0, s: 1, l: 0.5)], strength: 0.2, opacity: 0.62, grain: 0)
        let target = ThemeWash(colors: [.hsl(h: 0.66, s: 1, l: 0.5), .hsl(h: 0.33, s: 1, l: 0.5)],
                               strength: 1, opacity: 0.78, grain: 0.75)
        XCTAssertEqual(source.mixed(towards: target, fraction: 0), source)
        XCTAssertLessThan((source.mixed(towards: target, fraction: 1) - target).magnitudeSquared, 1e-20)
        let middle = source.mixed(towards: target, fraction: 0.5)
        XCTAssertEqual(middle.opacity, 0.7, accuracy: 1e-9)
        XCTAssertEqual(middle.grain, 0.375, accuracy: 1e-9)
        XCTAssertEqual(middle.colors.count, target.colors.count)
        // A reversal can start from the presented midpoint instead of restarting at an endpoint.
        XCTAssertEqual(middle.mixed(towards: source, fraction: 0), middle)
    }

    func testTwoStopGradientKeepsItsMidpointAndVectorArithmeticIsStable() {
        let wash = ThemeWash(colors: [ThemeColor(red: 1, green: 0, blue: 0), ThemeColor(red: 0, green: 0, blue: 1)],
                             strength: 1, opacity: 0.62, grain: 1)
        XCTAssertEqual(wash.colors[1], ThemeColor(red: 0.5, green: 0, blue: 0.5))
        XCTAssertEqual(wash + .zero, wash)
        XCTAssertEqual(wash - wash, .zero)
        var half = wash
        half.scale(by: 0.5)
        XCTAssertEqual(half + half, wash)
    }
}

extension SpaceColourTransitionTests {
    @MainActor func testRenderedColourArrivesWithoutASecondLandingChange() async throws {
        try await checkRenderedLanding(gradient: false)
    }

    @MainActor func testRenderedGradientAndOpacityArriveWithoutASecondLandingChange() async throws {
        try await checkRenderedLanding(gradient: true)
    }

    @MainActor private func checkRenderedLanding(gradient: Bool) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exerciseRenderedLanding(gradient: gradient) } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Colour transition loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    @MainActor private func exerciseRenderedLanding(gradient: Bool) async throws {
        try XCTSkipIf(Motion.spaceReduced, "Requires animated Space navigation")
        let saver = BatterySaver.shared, previousMode = BatterySaver.shared.mode
        saver.setMode(.off)
        defer { saver.setMode(previousMode) }
        let manager = ProfileManager.shared, previous = ProfileManager.shared.active
        let profile = manager.create(name: "Colour transition fixture")
        let first = Space(name: "Dim red", profileID: profile.id, colorHex: "#FF0000", appearance: "dark", tint: 0.2)
        let second = Space(name: "Full blue", profileID: profile.id, colorHex: "#0000FF",
                           appearance: gradient ? "light" : "dark", tint: 1,
                           colors: gradient ? ["#0000FF", "#00FF00"] : nil)
        XCTAssertTrue(manager.saveSpaces([first, second], for: profile.id))
        let store = Windows.open(profile: profile, space: first, focus: false)
        store.palette = nil
        let window = try XCTUnwrap(store.window)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let monitor = store.spaceGesture.monitor
        defer {
            monitor.abort(); window.close()
            _ = manager.delete(profile.id)
            manager.active = previous
        }
        try await LibraryFocusFixture.admitForeground(window)
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            guard let surface = store.spaceGesture.groundSurface,
                  let presented = surface.layer?.presentation(),
                  let root = host.layer?.presentation() else { return false }
            let visible = presented.convert(presented.bounds, to: root).intersection(root.bounds)
            return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                && window.isKeyWindow && window.occlusionState.contains(.visible)
                && window.contentView === host && surface.window === window
                && surface.isDescendant(of: host) && !surface.isHiddenOrHasHiddenAncestor
                && store.spaceGesture.sectionsView?.window === window
                && SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: store, spaceID: first.id))
                && visible.width > 1 && visible.height > 1
        }
        let surface = try XCTUnwrap(store.spaceGesture.groundSurface)
        func pixel() throws -> NSColor {
            // Sample the exposed sidebar, not the ground covered by the page card.
            let sample = CGRect(x: min(Look.sidebarWidth / 2, surface.bounds.width / 2),
                                y: surface.bounds.height / 2, width: 1, height: 1)
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: sample))
            // AppKit's cacheDisplay snapshots model-layer endpoints. Native gradients
            // interpolate on the compositor; sample their presentation tree instead.
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide), y: CGFloat(bitmap.pixelsHigh))
            context.cgContext.translateBy(x: -sample.minX, y: -sample.minY)
            try XCTUnwrap(surface.layer?.presentation()).render(in: context.cgContext)
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.displayP3))
        }
        let start = try pixel()
        let initialGradient = "model=\(String(describing: surface.base.colors)) presented=\(String(describing: surface.base.presentation()?.colors)) tint=\(String(describing: surface.base.superlayer?.presentation()?.opacity)) start=\(start)"
        let began = ProcessInfo.processInfo.systemUptime
        var sampleTimes: [Double] = []
        monitor.select(second, in: store)
        var samples: [NSColor] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            samples.append(try pixel())
            sampleTimes.append(ProcessInfo.processInfo.systemUptime - began)
        } while (store.currentSpaceID != second.id || store.spaceSwiping)
                    && ProcessInfo.processInfo.systemUptime < deadline
        XCTAssertEqual(store.currentSpaceID, second.id)
        let landed = try XCTUnwrap(samples.last)
        try await Task.sleep(for: .milliseconds(150))
        let resting = try pixel()
        XCTAssertEqual(landed.redComponent, resting.redComponent, accuracy: 0.01)
        XCTAssertEqual(landed.blueComponent, resting.blueComponent, accuracy: 0.01)
        XCTAssertGreaterThan(abs(start.redComponent - resting.redComponent), 0.1)
        XCTAssertTrue(samples.contains { abs($0.redComponent - start.redComponent) > 0.02
            && abs($0.redComponent - resting.redComponent) > 0.02 }, "Must render intermediate colours")
        let reds = [start.redComponent] + samples.map(\.redComponent) + [resting.redComponent]
        let largestStep = zip(reds, reds.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        print("COLOUR_TRANSITION_FRAMES: \(samples.count); largest red step: \(largestStep)")
        print("COLOUR_TRANSITION_SAMPLES: \(sampleTimes)")
        print("COLOUR_TRANSITION_REDS: \(reds); INITIAL: \(initialGradient)")
        XCTAssertLessThan(largestStep, abs(start.redComponent - resting.redComponent) * 0.6,
                          "A smooth transition must not replace most of the wash in one frame")
    }
}
