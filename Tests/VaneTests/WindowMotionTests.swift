import AppKit
import XCTest
@testable import vane

@MainActor final class WindowMotionTests: XCTestCase {
    func testProgressMatchesCoreAnimationCurves() {
        let linear = CAMediaTimingFunction(name: .linear)
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let easeIn = CAMediaTimingFunction(name: .easeIn)
        XCTAssertEqual(WindowMotion.progress(linear, 0.3), 0.3, accuracy: 1e-4)
        XCTAssertEqual(WindowMotion.progress(easeOut, -1), 0)
        XCTAssertEqual(WindowMotion.progress(easeOut, 2), 1)
        // Ease-out leads linear and ease-in trails it; symmetric around the midpoint.
        XCTAssertGreaterThan(WindowMotion.progress(easeOut, 0.5), 0.5)
        XCTAssertLessThan(WindowMotion.progress(easeIn, 0.5), 0.5)
        XCTAssertEqual(WindowMotion.progress(easeOut, 0.5) + WindowMotion.progress(easeIn, 0.5), 1, accuracy: 1e-4)
    }

    func testReplacementKeepsOmittedTargetsAndCompletesAsynchronously() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.alphaValue = 0
        var finished = 0
        WindowMotion.animate(window, alpha: 1, duration: 10) { finished += 1 }
        // A frame-only retarget must not strand the arriving fade.
        WindowMotion.animate(window, frame: NSRect(x: 5, y: 6, width: 70, height: 80),
                             duration: 0) { finished += 1 }
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame, NSRect(x: 5, y: 6, width: 70, height: 80))
        await Task.yield()
        for _ in 0..<10 where finished < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(finished, 2)
    }
}
