import AppKit
import XCTest
@testable import vane

@MainActor final class CustomPiPWindowTests: XCTestCase {
    func testFadeDoesNotMoveOrResizeWindow() async {
        _ = NSApplication.shared
        let window = CustomPiPWindow(frame: NSRect(x: 350, y: 260, width: 480, height: 270),
                                     videoView: NSView(), controlsView: NSView())
        defer { window.close() }
        window.orderFront(nil)
        let frame = window.frame
        let done = expectation(description: "Fade completes")
        window.fadeOut { done.fulfill() }
        for _ in 0..<8 {
            XCTAssertEqual(window.frame, frame)
            try? await Task.sleep(for: .milliseconds(30))
        }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertFalse(window.isVisible)
    }

    func testControlsFitCompactAndLargeVideo() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        let controls = PiPPlaybackControls(tab: tab, returnToTab: {}, minimize: {}, close: {})
        func buttons(_ view: NSView) -> [NSControl] {
            if view is NSTextField { return [] }
            return (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        for size in [NSSize(width: 320, height: 180), NSSize(width: 1200, height: 675),
                     NSSize(width: 384, height: 160), NSSize(width: 640, height: 160)] {
            controls.frame = NSRect(origin: .zero, size: size)
            controls.layoutSubtreeIfNeeded()
            let visible = buttons(controls)
            XCTAssertEqual(visible.count, 7)
            let transports = visible.compactMap { $0 as? NSButton }.filter {
                ["vane.pip.backward", "vane.pip.playpause", "vane.pip.forward"].contains($0.identifier?.rawValue ?? "")
            }
            XCTAssertEqual(transports.count, 3)
            XCTAssertTrue(transports.allSatisfy { $0.title.isEmpty }, "Transport icons must not gain a default Button label")
            let play = transports.first { $0.identifier?.rawValue == "vane.pip.playpause" }!
            XCTAssertEqual(play.frame.midX, controls.bounds.midX, accuracy: 0.1)
            let skips = transports.filter { $0 !== play }.sorted { $0.frame.midX < $1.frame.midX }
            XCTAssertEqual(controls.bounds.midX - skips[0].frame.midX, skips[1].frame.midX - controls.bounds.midX, accuracy: 0.1)
            let hostname = controls.subviews.compactMap { $0 as? NSTextField }.first!
            XCTAssertEqual(hostname.frame.midX, controls.bounds.midX, accuracy: 0.1)
            for button in visible {
                let frame = controls.convert(button.bounds, from: button)
                XCTAssertTrue(controls.bounds.contains(frame), "\(button.identifier?.rawValue ?? "control") must fit")
            }
            for (index, button) in visible.enumerated() {
                for other in visible.dropFirst(index + 1) {
                    XCTAssertFalse(controls.convert(button.bounds, from: button).intersects(controls.convert(other.bounds, from: other)))
                }
            }
        }
    }

    func testLiveAndMalformedPlaybackRangesAreHandled() {
        let live = PictureInPicture.Playback(from: ["playing": true, "position": 42.0, "duration": Double.infinity,
                                                   "ranges": [[30.0, 50.0], [70.0, 90.0], [5.0, 2.0]]])
        XCTAssertNil(live?.duration)
        XCTAssertEqual(live?.ranges, [30.0...50.0, 70.0...90.0])
        XCTAssertNil(PictureInPicture.Playback(from: ["playing": false, "position": Double.nan, "ranges": []]))
    }

    func testReopeningKeepsTheLastCustomPlacement() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        UserDefaults.vane.removeObject(forKey: CustomPiPWindow.placementKey)
        let initial = NSRect(x: 20, y: 20, width: 480, height: 270)
        let first = CustomPiPWindow(frame: initial, videoView: NSView(), controlsView: NSView())
        first.show()
        let placed = NSRect(x: 350, y: 260, width: 640, height: 360)
        first.setFrame(placed, display: true)
        first.close()
        let reopened = CustomPiPWindow(frame: initial, videoView: NSView(), controlsView: NSView())
        defer { reopened.close() }
        XCTAssertEqual(reopened.frame, placed, "Reentry must keep the custom position and size rather than the native corner")
        let malformed = NSRect(x: CGFloat.infinity, y: 0, width: 480, height: 270)
        XCTAssertEqual(CustomPiPWindow.initialFrame(initial, saved: malformed, screens: []), initial)
    }

    func testPlayerRecoversWhenItsDisplayDisappears() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let onScreen = NSRect(x: 350, y: 260, width: 480, height: 270)
        XCTAssertEqual(CustomPiPWindow.recoverFrame(onScreen, screens: [screen]), onScreen)
        let lost = NSRect(x: 2000, y: 300, width: 480, height: 270)
        let recovered = CustomPiPWindow.recoverFrame(lost, screens: [screen])
        XCTAssertTrue(screen.contains(recovered))
        XCTAssertEqual(recovered.size, lost.size)
        XCTAssertEqual(CustomPiPWindow.recoverFrame(lost, screens: []), lost)
    }
}
