import AppKit
import XCTest
@testable import vane

@MainActor final class ThemeWashSurfaceTests: XCTestCase {
    private func wash(_ hex: String) -> ThemeWash {
        ThemeWash(colors: [ThemeColor(hex: hex)!], strength: 1, opacity: 1, grain: 0)
    }

    func testRepeatedDestinationDoesNotInterruptColourBlend() async throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = ThemeWashSurface()
        window.contentView = surface
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let destination = wash("#0000FF")
        surface.apply(wash("#FF0000"), duration: 0)
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        surface.apply(destination, duration: 0.5)
        try await Task.sleep(for: .milliseconds(100))
        let animation = try XCTUnwrap(surface.base.animation(forKey: "colors"))
        surface.apply(destination, duration: 0)
        XCTAssertNotNil(surface.base.animation(forKey: "colors"),
                        "The quarter-point page update must not replace a blend with its endpoint")
        XCTAssertEqual(surface.base.animation(forKey: "colors")?.duration, animation.duration)
        let shown = try XCTUnwrap(surface.base.presentation()?.colors?.first) as! CGColor
        let target = try XCTUnwrap(surface.base.colors?.first) as! CGColor
        XCTAssertNotEqual(shown.components, target.components, "The background must still be between colours")
        surface.finishAnimations()
        XCTAssertNil(surface.base.animation(forKey: "colors"), "Reduce Motion must finish immediately")
    }
}
