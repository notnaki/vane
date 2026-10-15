import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceIndicatorGlyphTests: XCTestCase {
    private final class Selection: ObservableObject {
        @Published var selected = false
    }

    private struct Fixture: View {
        @ObservedObject var selection: Selection
        var body: some View {
            SpaceIndicatorGlyph(icon: "cloud.fill", selected: selection.selected,
                                layout: SpaceStripLayout(count: 3, availableWidth: 154),
                                dotColor: .gray, reduced: false)
                .equatable()
                .frame(width: 80, height: 80)
                .background(.black)
        }
    }

    func testSymbolReplacementAnimatesInsideInstantNativeProgressUpdates() async throws {
        try XCTSkipIf(Motion.spaceReduced, "Requires animated symbol replacement")
        let selection = Selection()
        let host = NSHostingView(rootView: Fixture(selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120))
        for selected in [true, false] {
            let origin = try pixels(host)
            Motion.instant { selection.selected = selected }
            var frames: [Data] = []
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(16))
                frames.append(try pixels(host))
            }
            let destination = try XCTUnwrap(frames.last)
            XCTAssertNotEqual(origin, destination, "Dot and icon must render different shapes")
            XCTAssertTrue(frames.contains { $0 != origin && $0 != destination },
                          "Each direction must display intermediate frames despite the native instant transaction")
        }
    }

    private func pixels(_ host: NSView) throws -> Data {
        let layer = try XCTUnwrap(host.layer?.presentation())
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 160,
            bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return Data(bytes: try XCTUnwrap(context.data), count: 160 * 640)
    }
}
