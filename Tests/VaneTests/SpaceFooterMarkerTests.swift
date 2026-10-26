import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceFooterMarkerTests: XCTestCase {
    private func render(emphasis: Double, showIcons: Bool, icon: String = "square.fill") throws -> NSBitmapImageRep {
        TestEnvironment.prepare()
        let layout = SpaceStripLayout(count: 3, availableWidth: 132, showIcons: showIcons)
        let renderer = ImageRenderer(content:
            SpaceFooterMarker(icon: icon, layout: layout, emphasis: emphasis)
                .frame(width: 32, height: 32)
                .environment(\.colorScheme, .dark))
        renderer.scale = 4
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        if let path = ProcessInfo.processInfo.environment["VANE_FOOTER_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to:
                directory.appendingPathComponent("\(showIcons ? "icons" : "dots")-\(icon)-\(emphasis).png"))
        }
        return image
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

    func testIconStaysVisibleAndGrowsThroughoutEmphasisTransfer() throws {
        let samples = try [0.0, 0.25, 0.5, 0.75, 1.0].map {
            coverage(try render(emphasis: $0, showIcons: true))
        }
        XCTAssertGreaterThan(samples[0], 0, "Inactive Spaces must retain their icons")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThan(next, previous, "Every intermediate emphasis must render a larger, brighter icon")
        }
        XCTAssertGreaterThan(samples[0] / samples[4], 0.3,
                             "Inactive icons should remain legible rather than shrinking to tiny glyphs")
    }

    func testDotModeHidesTheInactiveSymbolButIconModeKeepsItsIdentity() throws {
        func pixels(_ icon: String, showIcons: Bool) throws -> Data {
            try XCTUnwrap(render(emphasis: 0, showIcons: showIcons, icon: icon)
                .representation(using: .png, properties: [:]))
        }
        XCTAssertEqual(try pixels("square.fill", showIcons: false),
                       try pixels("triangle.fill", showIcons: false))
        XCTAssertNotEqual(try pixels("square.fill", showIcons: true),
                          try pixels("triangle.fill", showIcons: true))
    }

    func testAnimatedIconGrowthRendersIntermediateSizes() async throws {
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
        func sample() throws -> Double {
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
        var samples = [try sample()]
        state.emphasis = 1
        for _ in 0..<18 {
            try await Task.sleep(for: .milliseconds(30))
            samples.append(try sample())
        }
        let start = try XCTUnwrap(samples.first), end = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(end, start)
        XCTAssertTrue(samples.contains { $0 > start + (end - start) * 0.2 && $0 < start + (end - start) * 0.8 },
                      "Selection must draw intermediate symbol sizes, not snap between its endpoints")
    }
}

@MainActor private final class MarkerState: ObservableObject {
    @Published var emphasis = 0.0
}

private struct AnimatedMarker: View {
    @ObservedObject var state: MarkerState
    var body: some View {
        SpaceFooterMarker(icon: "square.fill", layout: SpaceStripLayout(count: 3, availableWidth: 132),
                          emphasis: state.emphasis)
            .frame(width: 32, height: 32)
            .background(.black)
            .environment(\.colorScheme, .dark)
            .animation(.linear(duration: 0.4), value: state.emphasis)
    }
}
