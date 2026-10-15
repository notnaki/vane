import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceIndicatorGlyphTests: XCTestCase {
    private final class Selection: ObservableObject {
        @Published var progress = 0.0
    }

    private struct Fixture: View {
        @ObservedObject var selection: Selection
        let icon: String
        var reduced = false
        var body: some View {
            SpaceIndicatorGlyph(icon: icon, lit: selection.progress,
                                layout: SpaceStripLayout(count: 3, availableWidth: 154),
                                dotColor: .gray, reduced: reduced)
                .equatable()
                .frame(width: 80, height: 80)
                .background(.black)
                .environment(\.colorScheme, .dark)
        }
    }

    func testFractionalProgressChangesGeometryBeforeHalfwayAndRetracesIt() async throws {
        let selection = Selection()
        let (host, window) = mounted(selection)
        defer { window.orderOut(nil); window.contentView = nil }
        var frames: [Double: Data] = [:]
        for progress in [0.0, 0.2, 0.35, 0.7, 1.0, 0.7, 0.35, 0.2, 0.0] {
            Motion.instant { selection.progress = progress }
            try await Task.sleep(for: .milliseconds(250))
            let frame = try pixels(host)
            if let earlier = frames[progress] {
                XCTAssertEqual(frame, earlier, "Reversing must retrace the same shape at the same progress")
            }
            frames[progress] = frame
        }
        XCTAssertNotEqual(frames[0], frames[0.2], "A small drag must begin changing the dot geometry immediately")
        XCTAssertNotEqual(frames[0.2], frames[0.35], "There must be no halfway selection threshold")
    }

    func testIntermediateFramesDoNotBalloonIntoAnOversizedFilledDisk() async throws {
        let selection = Selection()
        let (host, window) = mounted(selection)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let dot = area(try pixels(host))
        Motion.instant { selection.progress = 1 }
        try await Task.sleep(for: .milliseconds(400))
        let icon = area(try pixels(host))
        XCTAssertGreaterThan(dot, 20)
        XCTAssertGreaterThan(icon, 20)
        for target in [0.0, 1.0] {
            Motion.instant { selection.progress = target }
            for _ in 0..<22 {
                try await Task.sleep(for: .milliseconds(16))
                XCTAssertLessThanOrEqual(area(try pixels(host)), max(dot, icon) * 1.15,
                                         "A dot/icon handoff must not inflate into a filled white disk")
            }
        }
    }

    func testRenderedFractionalSweepHasBoundedAreaAndJoinsActualSymbols() async throws {
        for icon in ["cloud.fill", "briefcase"] {
            let selection = Selection()
            let (host, window) = mounted(selection, icon: icon)
            defer { window.orderOut(nil); window.contentView = nil }
            Motion.instant { selection.progress = 1 }
            try await Task.sleep(for: .milliseconds(100))
            let endpoint = try pixels(host)
            Motion.instant { selection.progress = 0 }
            try await Task.sleep(for: .milliseconds(50))
            let dot = try pixels(host)
            let maximum = max(area(endpoint), area(dot))
            let sweep = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
            for progress in sweep + sweep.reversed() + [0.001, 0.01, 0.99, 0.999] {
                Motion.instant { selection.progress = progress }
                try await Task.sleep(for: .milliseconds(25))
                let frame = try pixels(host)
                XCTAssertLessThanOrEqual(area(frame), maximum * 1.15, "\(icon) at \(progress) must not inflate")
                if progress > 0, progress <= 0.01 {
                    let difference = relativeInkDifference(frame, dot)
                    print("MORPH_START icon=\(icon) progress=\(progress) difference=\(difference)")
                    XCTAssertLessThan(difference, 0.1, "The first tiny movement must remain continuous with the resting dot")
                }
                if progress >= 0.99 {
                    let difference = relativeInkDifference(frame, endpoint)
                    print("MORPH_ENDPOINT icon=\(icon) progress=\(progress) difference=\(difference)")
                    XCTAssertLessThan(difference, progress >= 0.999 ? 0.02 : 0.1, "The contour must join the actual SF glyph without a final shape swap")
                }
            }
        }
    }

    func testGeometryBoundsAndWarmTwoGlyphCost() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let entries = ["cloud.fill", "briefcase", "star", "square.grid.2x2", "arrow.left"].map {
            SpaceIndicatorGeometryCache.entry(icon: $0, iconSize: 12, dotSize: 8)
        }
        for entry in entries {
            let geometry = entry.geometry
            let bounds = geometry.path(progress: 0, in: rect).boundingRect.union(geometry.path(progress: 1, in: rect).boundingRect).insetBy(dx: -0.4, dy: -0.4)
            for step in 0...100 {
                let path = geometry.path(progress: Double(step) / 100, in: rect)
                XCTAssertTrue(bounds.contains(path.boundingRect), "Intermediate geometry must stay within endpoint bounds")
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for step in 1...100 {
            for entry in entries.prefix(2) { _ = entry.geometry.path(progress: Double(step % 99 + 1) / 100, in: rect) }
        }
        print("MORPH_WARM_TWO_GLYPHS_SECONDS=\((ProcessInfo.processInfo.systemUptime - start) / 100)")
    }

    private func relativeInkDifference(_ a: Data, _ b: Data) -> Double {
        let a = [UInt8](a), b = [UInt8](b)
        var difference = 0.0, ink = 0.0
        for index in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 {
                difference += Double(abs(Int(a[index+c]) - Int(b[index+c])))
                ink += Double(b[index+c])
            }
        }
        return difference / max(1, ink)
    }

    func testReducedMotionPolicyUsesImmediateRestingEndpoints() async throws {
        let selection = Selection()
        let (host, window) = mounted(selection, reduced: true)
        defer { window.orderOut(nil); window.contentView = nil }
        var frames: [Data] = []
        for progress in [0.0, 0.2, 0.49, 0.51, 0.8, 1.0] {
            Motion.instant { selection.progress = progress }
            try await Task.sleep(for: .milliseconds(30))
            frames.append(try pixels(host))
        }
        XCTAssertEqual(frames[0], frames[1])
        XCTAssertEqual(frames[0], frames[2])
        XCTAssertEqual(frames[3], frames[4])
        XCTAssertEqual(frames[3], frames[5])
        XCTAssertNotEqual(frames[0], frames[5])
    }

    private func mounted(_ selection: Selection, icon: String = "briefcase", reduced: Bool = false) -> (NSHostingView<Fixture>, NSWindow) {
        let host = NSHostingView(rootView: Fixture(selection: selection, icon: icon, reduced: reduced))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func area(_ data: Data) -> Double {
        data.withUnsafeBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            return Double(stride(from: 0, to: bytes.count, by: 4).filter {
                max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) > 30
            }.count)
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
