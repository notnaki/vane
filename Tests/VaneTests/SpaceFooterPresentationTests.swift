import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceFooterPresentationTests: XCTestCase {
    private func fixture() throws -> (SpaceFooterPresentation, [TabStore], [UUID], NSWindow, [NativeSpaceFooterMarkerView]) {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "Requires animated markers")
        let manager = ProfileManager.shared
        let profiles = [manager.create(name: "Footer first"), manager.create(name: "Footer second")]
        let spaces = profiles.map { manager.createSpace(name: "Footer", in: $0.id) }
        let stores = zip(profiles, spaces).map { TabStore(profileID: $0.0.id, space: $0.1, session: []) }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 64, height: 32),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        window.contentView = root
        let views = [0, 1].map { NativeSpaceFooterMarkerView(frame: CGRect(x: $0 * 32, y: 0, width: 32, height: 32)) }
        views.forEach { root.addSubview($0) }
        let presentation = SpaceFooterPresentation()
        presentation.activate(stores[0])
        for (index, view) in views.enumerated() {
            view.presentation = presentation
            presentation.mount(view, owner: stores[0], id: spaces[index].id, icon: "square.fill",
                layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil); window.contentView = nil; window.close()
            for store in stores {
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                Store.forget(store.profileID)
                manager.delete(store.profileID)
            }
        }
        return (presentation, stores, spaces.map(\.id), window, views)
    }

    func testProfileHandoffCarriesTheSameGrowingGlyphAndIgnoresTheParkedRoot() async throws {
        let (presentation, stores, ids, window, views) = try fixture()
        try await Task.sleep(for: .milliseconds(60))
        let glyph = try XCTUnwrap(views[1].marker?.symbol)
        presentation.activate(stores[1])
        let animation = try XCTUnwrap(glyph.animation(forKey: "space-selection") as? CABasicAnimation)
        XCTAssertNotNil(glyph.animation(forKey: "space-emphasis"),
                        "An uncovered selection must animate brightness as well as size")
        let replacement = NativeSpaceFooterMarkerView(frame: views[1].frame)
        replacement.presentation = presentation
        window.contentView?.addSubview(replacement)
        presentation.mount(replacement, owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        XCTAssertTrue(replacement.marker?.symbol === glyph)
        XCTAssertEqual(glyph.animation(forKey: "space-selection")?.beginTime, animation.beginTime,
                       "A new profile root must keep the existing animation clock")
        presentation.mount(views[1], owner: stores[0], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        XCTAssertTrue(replacement.marker?.layer.superlayer === replacement.layer,
                      "Updating a parked root must not take its icon back")
        try await Task.sleep(for: .milliseconds(30))
        let scale = (glyph.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue
        presentation.activate(stores[0])
        let reverse = try XCTUnwrap(glyph.animation(forKey: "space-selection") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(reverse.fromValue as? Double), try XCTUnwrap(scale), accuracy: 0.03)
    }

    func testFingerProgressContinuouslySizesBothIconsBeforeSelectionChanges() throws {
        let (presentation, stores, ids, _, views) = try fixture()
        let first = try XCTUnwrap(views[0].marker?.symbol)
        let second = try XCTUnwrap(views[1].marker?.symbol)
        presentation.track(origin: ids[0], target: ids[1], fraction: 0.25)
        XCTAssertEqual(first.transform.m11, 0.95, accuracy: 0.001)
        XCTAssertEqual(second.transform.m11, 0.85, accuracy: 0.001)
        presentation.track(origin: ids[0], target: ids[1], fraction: 0.5)
        XCTAssertEqual(first.transform.m11, 0.9, accuracy: 0.001)
        XCTAssertEqual(second.transform.m11, 0.9, accuracy: 0.001)
        XCTAssertEqual(stores[0].currentSpaceID, ids[0],
                       "Icon size must follow the fingers before the page selection commits")
    }

    func testCompactHoverCannotReviveTheOutgoingIconAfterLanding() async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let (presentation, stores, ids, window, views) = try fixture()
            window.styleMask = [.titled]
            let view = views[0]
            let layout = SpaceStripLayout(count: 2, availableWidth: 64, showIcons: false)
            func mount(hovered: Bool) {
                presentation.mount(view, owner: stores[0], id: ids[0], icon: "square.fill",
                    layout: layout, hovered: hovered, scheme: .dark, reduced: false)
            }
            mount(hovered: true)
            try await LibraryFocusFixture.admitForeground(window)
            let marker = try XCTUnwrap(view.marker)
            try await compatibilityWait {
                window.contentView?.layoutSubtreeIfNeeded()
                return NSApp.isRunning && window.isKeyWindow && window.occlusionState.contains(.visible)
                    && view.window === window && marker.view === view
                    && marker.layer.superlayer === view.layer && marker.symbol.presentation() != nil
            }
            presentation.track(origin: ids[0], target: ids[1], fraction: 0.5)
            CATransaction.flush()
            // Establish a presented finger position before completing the landing.
            try await compatibilityWait { abs((marker.symbol.presentation()?.opacity ?? -1) - 0.5) < 0.02 }
            let timing = CABasicAnimation(keyPath: "position")
            timing.duration = 0.8
            timing.timingFunction = CAMediaTimingFunction(name: .linear)
            presentation.animate(origin: ids[0], target: ids[1], from: 0.5, to: 1, timing: timing)
            CATransaction.flush()
            // Sample early travel directly; do not wait for an opacity outcome.
            try await Task.sleep(for: .milliseconds(30))
            let earlyOpacity = try XCTUnwrap(marker.symbol.presentation()).opacity
            XCTAssertGreaterThan(earlyOpacity, 0.1)
            XCTAssertLessThan(earlyOpacity, 0.5)
            mount(hovered: false)
            XCTAssertEqual(marker.symbol.animation(forKey: "space-emphasis")?.duration, 0.8,
                           "Compact hover must preserve the landing's original compositor clock")
            presentation.activate(stores[1])
            presentation.finishProgress()
            XCTAssertEqual(marker.symbol.opacity, 0)
            XCTAssertNil(marker.symbol.animation(forKey: "space-emphasis"))
            // SwiftUI can deliver a hover update in the same landing commit.
            // Its presentation layer still contains the pre-landing ink.
            presentation.mount(view, owner: stores[1], id: ids[0], icon: "square.fill",
                layout: layout, hovered: true, scheme: .dark, reduced: false)
            XCTAssertNil(marker.symbol.animation(forKey: "space-emphasis"),
                         "A compact hover change must not fade an already hidden icon out a second time")
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(try XCTUnwrap(marker.symbol.presentation()).opacity, 0, accuracy: 0.02,
                           "The outgoing icon must remain hidden in the first frame after landing")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Footer regression AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testBatterySaverLandingKeepsSpaceProgressOnTheCompositorClock() throws {
        let (presentation, _, ids, _, views) = try fixture()
        let previous = BatterySaver.shared.mode
        defer { BatterySaver.shared.setMode(previous) }
        BatterySaver.shared.setMode(.alwaysOn)
        presentation.track(origin: ids[0], target: ids[1], fraction: 0.25)
        let timing = CABasicAnimation(keyPath: "position")
        timing.duration = 0.8
        timing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        presentation.animate(origin: ids[0], target: ids[1], from: 0.25, to: 1, timing: timing)
        let glyph = try XCTUnwrap(views[1].marker?.symbol)
        let scale = try XCTUnwrap(glyph.animation(forKey: "space-progress-scale") as? CABasicAnimation)
        let ink = try XCTUnwrap(glyph.animation(forKey: "space-emphasis") as? CABasicAnimation)
        XCTAssertEqual(scale.duration, 0.8)
        XCTAssertEqual(ink.timingFunction, timing.timingFunction)
        XCTAssertEqual(scale.beginTime, 0)
    }

    func testBatterySaverCancelsAnUncoveredSelectionPulse() throws {
        let (presentation, stores, ids, _, views) = try fixture()
        presentation.activate(stores[1])
        let glyph = try XCTUnwrap(views[1].marker?.symbol)
        XCTAssertNotNil(glyph.animation(forKey: "space-emphasis"))
        let previous = BatterySaver.shared.mode
        defer { BatterySaver.shared.setMode(previous) }
        BatterySaver.shared.setMode(.alwaysOn)
        // The caller reports system Reduce Motion separately from Battery Saver.
        presentation.mount(views[1], owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        XCTAssertNil(glyph.animation(forKey: "space-selection"))
        XCTAssertNil(glyph.animation(forKey: "space-emphasis"))
    }

    func testDelayedCommitDoesNotExpireFooterEmphasisBeforeSidebarTravelStarts() async throws {
        let (presentation, _, ids, window, views) = try fixture()
        let root = try XCTUnwrap(window.contentView)
        root.wantsLayer = true
        let sidebar = CALayer()
        sidebar.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        root.layer?.addSublayer(sidebar)
        presentation.track(origin: ids[0], target: ids[1], fraction: 0)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let from = sidebar.position
        let to = CGPoint(x: from.x + 100, y: from.y)
        let timing = CABasicAnimation(keyPath: "position")
        timing.duration = 0.8
        timing.fromValue = NSValue(point: from)
        timing.toValue = NSValue(point: to)
        timing.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sidebar.position = to
        sidebar.add(timing, forKey: "test-sidebar")
        presentation.animate(origin: ids[0], target: ids[1], from: 0, to: 1, timing: timing)
        // Model expensive pre-commit layout without letting CA submit this transaction.
        usleep(1_000_000)
        CATransaction.commit()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(35))
        let travel = (try XCTUnwrap(sidebar.presentation()).position.x - from.x) / 100
        let opacity = try XCTUnwrap(views[1].marker?.symbol.presentation()).opacity
        let emphasis = (Double(opacity) - 0.6) / 0.4
        XCTAssertGreaterThan(travel, 0.01)
        XCTAssertLessThan(travel, 0.7, "Sample the actual first part of sidebar travel")
        XCTAssertEqual(emphasis, travel, accuracy: 0.12,
                       "Footer emphasis and sidebar travel must start on the same committed clock")
    }

    func testCachedProfileActivationMovesRegisteredLayersWithoutAViewUpdate() throws {
        let (presentation, stores, ids, window, views) = try fixture()
        let cached = NativeSpaceFooterMarkerView(frame: views[1].frame)
        cached.presentation = presentation
        window.contentView?.addSubview(cached)
        presentation.mount(cached, owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        for _ in 0..<3 {
            presentation.activate(stores[1])
            XCTAssertTrue(cached.marker?.layer.superlayer === cached.layer,
                          "Cached roots must acquire their layers without a SwiftUI update")
            presentation.activate(stores[0])
            XCTAssertTrue(views[1].marker?.layer.superlayer === views[1].layer)
        }
    }

    func testCachedProfileUsesTheCurrentMotionPolicyWhenItReturns() throws {
        let (presentation, stores, ids, window, views) = try fixture()
        let previous = BatterySaver.shared.mode
        defer { BatterySaver.shared.setMode(previous) }
        let cached = NativeSpaceFooterMarkerView(frame: views[1].frame)
        cached.presentation = presentation
        window.contentView?.addSubview(cached)
        BatterySaver.shared.setMode(.alwaysOn)
        presentation.mount(cached, owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: false)
        BatterySaver.shared.setMode(.off)
        presentation.activate(stores[1])
        XCTAssertNotNil(cached.marker?.symbol.animation(forKey: "space-selection"),
                        "A parked profile's old saver state must not cancel the new selection")
        XCTAssertNotNil(cached.marker?.symbol.animation(forKey: "space-emphasis"))
    }

    func testCachedProfilePreservesExplicitEnvironmentReductionOnHandoff() throws {
        let (presentation, stores, ids, window, _) = try fixture()
        let cached = NativeSpaceFooterMarkerView(frame: CGRect(x: 32, y: 0, width: 32, height: 32))
        cached.presentation = presentation
        window.contentView?.addSubview(cached)
        presentation.mount(cached, owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: true)
        presentation.activate(stores[1])
        let symbol = try XCTUnwrap(cached.marker?.symbol)
        XCTAssertNil(symbol.animation(forKey: "space-selection"))
        XCTAssertNil(symbol.animation(forKey: "space-emphasis"))
        XCTAssertEqual(symbol.transform.m11, 1, accuracy: 0.001)
        XCTAssertEqual(symbol.opacity, 1, accuracy: 0.001)
    }

    func testNativeMarkerPreservesLegacyArtworkAndWideSymbolOverhang() throws {
        let (presentation, stores, ids, _, views) = try fixture()
        let view = views[0]
        for scheme in [ColorScheme.light, .dark] {
            for showIcons in [false, true] {
                for (count, icon) in [(3, "cloud"), (3, "triangle.fill"), (12, "cloud"), (12, "triangle.fill")] {
                    let layout = SpaceStripLayout(count: count, availableWidth: 100, showIcons: showIcons)
                    presentation.mount(view, owner: stores[0], id: ids[0], icon: icon, layout: layout,
                                       hovered: false, scheme: scheme, reduced: false)
                    for emphasis in [0.0, 0.5, 1.0] {
                        presentation.track(origin: ids[1], target: ids[0], fraction: emphasis)
                        let layer = try XCTUnwrap(view.marker?.layer)
                        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64,
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.scaleBy(x: 2, y: 2)
                        layer.render(in: context)
                        let actual = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                        let renderer = ImageRenderer(content:
                            SpaceFooterMarker(icon: icon, layout: layout, emphasis: emphasis, selected: true,
                                              sizeEmphasis: emphasis)
                                .frame(width: 32, height: 32).environment(\.colorScheme, scheme))
                        renderer.scale = 2
                        var expected: CGImage?
                        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                            expected = renderer.cgImage
                        }
                        let reference = NSBitmapImageRep(cgImage: try XCTUnwrap(expected))
                        var alphaActual = 0.0, alphaExpected = 0.0, difference = 0.0, colorDifference = 0.0
                        for y in 0..<64 {
                            for x in 0..<64 {
                                let ac = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                                let bc = try XCTUnwrap(reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                                let a = Double(ac.alphaComponent), b = Double(bc.alphaComponent)
                                alphaActual += a; alphaExpected += b; difference += abs(a - b)
                                colorDifference += abs(Double(ac.redComponent) * a - Double(bc.redComponent) * b)
                                    + abs(Double(ac.greenComponent) * a - Double(bc.greenComponent) * b)
                                    + abs(Double(ac.blueComponent) * a - Double(bc.blueComponent) * b)
                            }
                        }
                        let label = "\(scheme) count=\(count) icons=\(showIcons) \(icon) emphasis=\(emphasis)"
                        XCTAssertEqual(alphaActual, alphaExpected, accuracy: max(1, alphaExpected * 0.04), label)
                        XCTAssertLessThan(difference, max(2, alphaExpected * 0.15), label)
                        XCTAssertLessThan(colorDifference, max(6, alphaExpected * 0.45), label)
                    }
                }
            }
        }
    }

    func testHoverAndMarkerModeRetargetUnfinishedEmphasisFromThePresentedInk() async throws {
        let (presentation, stores, ids, _, views) = try fixture()
        let view = views[0]
        func mount(hovered: Bool, icons: Bool) {
            presentation.mount(view, owner: stores[0], id: ids[0], icon: "square.fill",
                layout: SpaceStripLayout(count: 2, availableWidth: 64, showIcons: icons),
                hovered: hovered, scheme: .dark, reduced: false)
        }
        mount(hovered: false, icons: true)
        presentation.track(origin: ids[0], target: ids[1], fraction: 0.25)
        let timing = CABasicAnimation(keyPath: "position")
        timing.duration = 3
        timing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        presentation.animate(origin: ids[0], target: ids[1], from: 0.25, to: 1, timing: timing)
        try await Task.sleep(for: .milliseconds(60))
        let symbol = try XCTUnwrap(view.marker?.symbol)
        let visible = try XCTUnwrap(symbol.presentation()).opacity
        mount(hovered: true, icons: true)
        let hover = try XCTUnwrap(symbol.animation(forKey: "space-emphasis") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(hover.fromValue as? NSNumber).floatValue, visible, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(hover.toValue as? NSNumber).doubleValue, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(hover.duration, 0.15)
        try await Task.sleep(for: .milliseconds(200))
        let sizeDuringHover = try XCTUnwrap(
            symbol.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber).doubleValue
        XCTAssertGreaterThan(sizeDuringHover, 0.85,
                             "Quick hover feedback must not finish icon sizing ahead of the sidebar")
        try await Task.sleep(for: .milliseconds(30))
        mount(hovered: false, icons: true)
        let unhover = try XCTUnwrap(symbol.animation(forKey: "space-emphasis") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(unhover.toValue as? NSNumber).doubleValue, 0.6, accuracy: 0.001)
        XCTAssertGreaterThan(unhover.duration, 0.3, "Unhover must continue the unfinished landing")
        mount(hovered: false, icons: false)
        let compact = try XCTUnwrap(symbol.animation(forKey: "space-emphasis") as? CABasicAnimation)
        XCTAssertEqual(try XCTUnwrap(compact.toValue as? NSNumber).doubleValue, 0, accuracy: 0.001)
        XCTAssertGreaterThan(compact.duration, 0.3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(try XCTUnwrap(symbol.presentation()).opacity, 0.03,
                             "Changing marker mode must not finish its ink ahead of the sidebar")
    }

    func testEmphasisUsesTheSidebarTimingAndReducedMotionCancelsBothAnimations() async throws {
        let (presentation, stores, ids, _, views) = try fixture()
        try await Task.sleep(for: .milliseconds(60))
        presentation.track(origin: ids[0], target: ids[1], fraction: 0.25)
        let timing = CABasicAnimation(keyPath: "position")
        timing.duration = 0.8
        timing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        presentation.animate(origin: ids[0], target: ids[1], from: 0.25, to: 1, timing: timing)
        let glyph = try XCTUnwrap(views[1].marker?.symbol)
        let emphasis = try XCTUnwrap(glyph.animation(forKey: "space-emphasis") as? CABasicAnimation)
        XCTAssertEqual(emphasis.duration, timing.duration)
        XCTAssertEqual(emphasis.timingFunction, timing.timingFunction)
        presentation.activate(stores[1])
        presentation.mount(views[1], owner: stores[1], id: ids[1], icon: "square.fill",
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: true)
        XCTAssertNil(glyph.animation(forKey: "space-emphasis"))
        XCTAssertNil(glyph.animation(forKey: "space-selection"))
        XCTAssertEqual(glyph.opacity, 1)
        XCTAssertEqual(glyph.transform.m11, 1, accuracy: 0.001)
    }
}
