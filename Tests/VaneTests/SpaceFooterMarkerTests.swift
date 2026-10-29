import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceFooterMarkerTests: XCTestCase {
    func testNativeProgressChangesInkWithoutRebuildingItsInteractiveContainer() async throws {
        TestEnvironment.prepare()
        let footer = SpaceFooterProgress()
        let draws = FooterContainerDraws()
        let host = NSHostingView(rootView: CountedFooter(footer: footer, draws: draws))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(80))
        let before = try SidebarSnapshot.pixels(in: host)
        let initialDraws = draws.count
        footer.drag = -50
        try await Task.sleep(for: .milliseconds(40))
        let halfway = try SidebarSnapshot.pixels(in: host)
        footer.drag = -100
        try await Task.sleep(for: .milliseconds(40))
        let arrived = try SidebarSnapshot.pixels(in: host)
        XCTAssertNotEqual(before, halfway)
        XCTAssertNotEqual(halfway, arrived)
        XCTAssertEqual(draws.count, initialDraws,
                       "Display-link samples must stop at marker ink, before menus and input handlers")
    }

    private func render(emphasis: Double, showIcons: Bool, icon: String = "square.fill", selected: Bool = false) async throws -> NSBitmapImageRep {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var captured: NSBitmapImageRep?
        var failure: (any Error)?
        do {
            let layout = SpaceStripLayout(count: 3, availableWidth: 132, showIcons: showIcons)
            let host = NSHostingView(rootView:
                SpaceFooterMarker(icon: icon, layout: layout, emphasis: emphasis, selected: selected)
                    .frame(width: 32, height: 32).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 32, height: 32),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await LibraryFocusFixture.admitForeground(window)
            // Admit the actual presentation owner, not the desired pixel result.
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return window.contentView === host && host.window === window
                    && window.occlusionState.contains(.visible) && host.bounds.size == CGSize(width: 32, height: 32)
                    && host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            host.displayIfNeeded()
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            image.size = CGSize(width: 32, height: 32)
            host.cacheDisplay(in: host.bounds, to: image)
            if let path = ProcessInfo.processInfo.environment["VANE_FOOTER_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.representation(using: .png, properties: [:])?.write(to:
                    directory.appendingPathComponent("\(showIcons ? "icons" : "dots")-\(icon)-\(emphasis)-\(selected).png"))
            }
            captured = image
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Footer render AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
        return try XCTUnwrap(captured)
    }

    private func coverage(_ image: NSBitmapImageRep) -> Double {
        var total = 0.0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                total += Double(image.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return total
    }

    private func glyphWidth(_ image: NSBitmapImageRep) -> Int {
        var columns: [Int] = []
        for x in 0..<image.pixelsWide {
            if (0..<image.pixelsHigh).contains(where: { (image.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.05 }) {
                columns.append(x)
            }
        }
        guard let first = columns.first, let last = columns.last else { return 0 }
        return last - first + 1
    }

    private func sample(_ host: NSView) throws -> Double {
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        var total = 0.0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                total += Double(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0)
            }
        }
        return total
    }

    func testSwipeProgressDoesNotResizeTheIcon() async throws {
        var widths: [Int] = []
        for emphasis in [0.0, 0.25, 0.5, 0.75, 1.0] {
            widths.append(glyphWidth(try await render(emphasis: emphasis, showIcons: true)))
        }
        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 1,
                                 "Swipe progress should blend brightness without controlling icon growth")
    }

    func testIconStaysVisibleAndBrightensThroughoutEmphasisTransfer() async throws {
        var samples: [Double] = []
        for emphasis in [0.0, 0.25, 0.5, 0.75, 1.0] {
            samples.append(coverage(try await render(emphasis: emphasis, showIcons: true)))
        }
        XCTAssertGreaterThan(samples[0], 0, "Inactive Spaces must retain their icons")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThan(next, previous, "Every intermediate emphasis must render a brighter icon")
        }
        XCTAssertGreaterThan(samples[0] / samples[4], 0.3,
                             "Inactive icons should remain legible rather than shrinking to tiny glyphs")
    }

    func testSelectionEnlargesTheIconAtFixedSwipeProgress() async throws {
        let inactive = try await render(emphasis: 0.5, showIcons: true, selected: false)
        let active = try await render(emphasis: 0.5, showIcons: true, selected: true)
        XCTAssertGreaterThan(glyphWidth(active), glyphWidth(inactive),
                             "Selection should enlarge the icon independently of swipe progress")
    }

    func testDotModeHidesTheInactiveSymbolButIconModeKeepsItsIdentity() async throws {
        func pixels(_ icon: String, showIcons: Bool) async throws -> Data {
            let image = try await render(emphasis: 0, showIcons: showIcons, icon: icon)
            return try XCTUnwrap(image.representation(using: .png, properties: [:]))
        }
        let dotSquare = try await pixels("square.fill", showIcons: false)
        let dotTriangle = try await pixels("triangle.fill", showIcons: false)
        let iconSquare = try await pixels("square.fill", showIcons: true)
        let iconTriangle = try await pixels("triangle.fill", showIcons: true)
        XCTAssertEqual(dotSquare, dotTriangle)
        XCTAssertNotEqual(iconSquare, iconTriangle)
    }

    func testSelectionGrowthAnimatesQuicklyDuringInstantProgressUpdates() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "This fixture measures animated icon growth")
        let state = MarkerState()
        let host = NSHostingView(rootView: AnimatedMarker(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 32, height: 32),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60))
        var samples = [try sample(host)]
        Motion.spaceHandoff { state.selected = true }
        for frame in 0..<18 {
            // Native swipe samples arrive without an implicit animation. They must
            // neither drive nor cancel the independent selection animation.
            Motion.instant { state.emphasis = 0.5 + Double(frame % 2) * 0.05 }
            try await Task.sleep(for: .milliseconds(10))
            samples.append(try sample(host))
        }
        let start = try XCTUnwrap(samples.first), end = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(end, start)
        XCTAssertTrue(samples.contains { $0 > start + (end - start) * 0.1 && $0 < start + (end - start) * 0.9 },
                      "Selection must draw intermediate symbol sizes, not snap between its endpoints")
    }

    func testReducedMotionStopsAnInFlightGrowthImmediately() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "This fixture begins with animated icon growth")
        let state = MarkerState()
        let host = NSHostingView(rootView: AnimatedMarker(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 32, height: 32),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60))
        Motion.spaceHandoff { state.selected = true }
        try await Task.sleep(for: .milliseconds(20))
        let moving = try sample(host)
        Motion.instant { state.reducedMotion = true }
        try await Task.sleep(for: .milliseconds(20))
        let reduced = try sample(host)
        try await Task.sleep(for: .milliseconds(200))
        let settled = try sample(host)
        XCTAssertLessThan(moving, settled, "The fixture must interrupt a growth animation")
        XCTAssertEqual(reduced, settled, accuracy: 1,
                       "Reduced motion must draw the selected size immediately, not finish the remaining animation")
    }
}

@MainActor private final class FooterContainerDraws { var count = 0 }

private struct CountedFooter: View {
    let footer: SpaceFooterProgress
    let draws: FooterContainerDraws
    private let origin = UUID()
    private let destination = UUID()

    var body: some View {
        draws.count += 1
        return SpaceFooterEmphasis(footer: footer, icon: "square.fill",
            layout: SpaceStripLayout(count: 3, availableWidth: 132), hovered: false,
            selected: false, reducedMotion: false, spaceID: destination, currentID: origin,
            targetID: destination, fallbackDrag: 0, width: 100, swiping: true, animation: nil)
            .frame(width: 32, height: 32).background(.black).environment(\.colorScheme, .dark)
    }
}

@MainActor private final class MarkerState: ObservableObject {
    @Published var emphasis = 0.5
    @Published var selected = false
    @Published var reducedMotion = false
}

private struct AnimatedMarker: View {
    @ObservedObject var state: MarkerState
    var body: some View {
        SpaceFooterMarker(icon: "square.fill", layout: SpaceStripLayout(count: 3, availableWidth: 132),
                          emphasis: state.emphasis, selected: state.selected, reducedMotion: state.reducedMotion)
            .frame(width: 32, height: 32)
            .background(.black)
            .environment(\.colorScheme, .dark)
    }
}
