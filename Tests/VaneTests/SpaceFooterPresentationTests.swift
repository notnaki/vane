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
            layout: SpaceStripLayout(count: 2, availableWidth: 64), hovered: false, scheme: .dark, reduced: true)
        BatterySaver.shared.setMode(.off)
        presentation.activate(stores[1])
        XCTAssertNotNil(cached.marker?.symbol.animation(forKey: "space-selection"),
                        "A parked profile's old saver state must not cancel the new selection")
        XCTAssertNotNil(cached.marker?.symbol.animation(forKey: "space-emphasis"))
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
                            SpaceFooterMarker(icon: icon, layout: layout, emphasis: emphasis, selected: true)
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
