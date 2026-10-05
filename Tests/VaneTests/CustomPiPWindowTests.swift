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

    func testBatterySaverMakesPiPTransitionsImmediate() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let mode = BatterySaver.shared.mode
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer {
            BatterySaver.shared.setMode(mode)
            UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey)
        }
        BatterySaver.shared.setMode(.alwaysOn)
        let source = NSRect(x: 120, y: 120, width: 480, height: 270)
        let destination = NSRect(x: 350, y: 260, width: 640, height: 360)
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        let controls = PiPPlaybackControls(tab: tab, returnToTab: {}, minimize: {}, close: {})
        let window = CustomPiPWindow(frame: source, videoView: NSView(), controlsView: controls)
        defer { window.close() }
        window.show()
        XCTAssertEqual(window.frame, destination, "Battery Saver opens directly at the saved placement")
        XCTAssertEqual(window.alphaValue, 1)
        controls.updateVisibility(pointer: NSPoint(x: -1000, y: -1000))
        XCTAssertTrue(controls.isHidden, "Battery Saver hides controls without a pending fade")
        XCTAssertEqual(controls.alphaValue, 0)
        controls.updateVisibility(pointer: NSPoint(x: window.frame.midX, y: window.frame.midY))
        XCTAssertFalse(controls.isHidden)
        XCTAssertEqual(controls.alphaValue, 1)
        window.prepareReturn()
        var returned = false
        window.animateReturn(to: source) { returned = true }
        XCTAssertTrue(returned, "Battery Saver completes return without waiting for a flight or fade")
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, destination, "Immediate return must preserve floating placement")
    }

    func testEntryMovesFromSourceToSavedFrameInOneMotion() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let source = NSRect(x: 120, y: 120, width: 480, height: 270)
        let destination = NSRect(x: 350, y: 260, width: 640, height: 360)
        guard TestEnvironment.supportsPiPMotion(in: [source, destination]) else {
            throw XCTSkip("Intermediate entry frames require motion enabled and visible source/destination screens")
        }
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        let window = CustomPiPWindow(frame: source, videoView: NSView(), controlsView: NSView())
        defer { window.close() }
        window.show()
        XCTAssertEqual(window.frame, source, "Entry starts at the source video before moving to its remembered placement")
        var moved = false
        var lastProgress: CGFloat = 0
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(25))
            let frame = window.frame
            let x = (frame.minX - source.minX) / (destination.minX - source.minX)
            let y = (frame.minY - source.minY) / (destination.minY - source.minY)
            let size = (frame.width - source.width) / (destination.width - source.width)
            if x > 0.01 && x < 0.99 { moved = true }
            XCTAssertEqual(x, y, accuracy: 0.015, "Both axes must move together instead of taking separate turns")
            XCTAssertEqual(x, size, accuracy: 0.015, "Resizing shares the same progress as movement")
            XCTAssertGreaterThanOrEqual(x + 0.015, lastProgress, "The motion must not bounce or reverse")
            lastProgress = x
        }
        XCTAssertTrue(moved, "Entry must have intermediate frames rather than teleporting")
        XCTAssertEqual(window.frame, destination)
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testReturningDuringEntryKeepsTheSavedDestination() async {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let destination = NSRect(x: 350, y: 260, width: 640, height: 360)
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        let window = CustomPiPWindow(frame: NSRect(x: 120, y: 120, width: 480, height: 270),
                                     videoView: NSView(), controlsView: NSView())
        window.show()
        try? await Task.sleep(for: .milliseconds(30))
        let interrupted = window.frame
        if TestEnvironment.supportsPiPMotion(in: [NSRect(x: 120, y: 120, width: 480, height: 270), destination]) {
            XCTAssertNotEqual(interrupted, destination)
        } else {
            XCTAssertEqual(interrupted, destination, "No-motion entry uses the saved placement immediately")
        }
        let done = expectation(description: "Interrupted entry fades in place")
        window.fadeOut { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(window.frame, interrupted)
        window.close()
        let remembered = UserDefaults.vane.string(forKey: CustomPiPWindow.placementKey).map(NSRectFromString)
        XCTAssertEqual(remembered, destination, "An early return must not save a temporary frame along the flight")
    }

    func testManualPlacementStopsEntryWithoutFightingTheUser() async {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        UserDefaults.vane.set(NSStringFromRect(NSRect(x: 350, y: 260, width: 640, height: 360)),
                              forKey: CustomPiPWindow.placementKey)
        let window = CustomPiPWindow(frame: NSRect(x: 120, y: 120, width: 480, height: 270),
                                     videoView: NSView(), controlsView: NSView())
        defer { window.close() }
        window.show()
        try? await Task.sleep(for: .milliseconds(30))
        let placed = NSRect(x: 200, y: 200, width: 480, height: 270)
        window.setFrame(placed, display: true)
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(window.frame, placed)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(window.controlsView.alphaValue, 1)
    }

    func testTransportClickDuringEntryFinishesWindowOpacity() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        UserDefaults.vane.set(NSStringFromRect(NSRect(x: 350, y: 260, width: 640, height: 360)),
                              forKey: CustomPiPWindow.placementKey)
        let window = CustomPiPWindow(frame: NSRect(x: 120, y: 120, width: 480, height: 270),
                                     videoView: NSView(), controlsView: EntryFixtureControl())
        defer { window.close() }
        window.show()
        try? await Task.sleep(for: .milliseconds(30))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(window.alphaValue, 1, "Continuing playback must not freeze the panel at partial opacity")
    }

    func testEntryStartsAtTheActualTinyMediaRectangle() async {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let destination = NSRect(x: 350, y: 260, width: 640, height: 360)
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        let source = NSRect(x: 120, y: 120, width: 128, height: 72)
        let window = CustomPiPWindow(frame: source, videoView: NSView(), controlsView: NSView())
        defer { window.close() }
        window.show()
        if TestEnvironment.supportsPiPMotion(in: [source, destination]) {
            XCTAssertEqual(window.frame, source, "Minimum size applies to the final player, not the original media")
        } else {
            XCTAssertEqual(window.frame, destination, "No-motion entry opens directly at the saved placement")
        }
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(window.frame, destination)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 280)
    }

    func testTinySourceTransportClickRestoresUsablePlayerSize() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let destination = NSRect(x: 350, y: 260, width: 640, height: 360)
        UserDefaults.vane.set(NSStringFromRect(destination), forKey: CustomPiPWindow.placementKey)
        let window = CustomPiPWindow(frame: NSRect(x: 120, y: 120, width: 128, height: 72),
                                     videoView: NSView(), controlsView: EntryFixtureControl())
        defer { window.close() }
        window.show()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        XCTAssertEqual(window.frame, destination)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 280)
        XCTAssertEqual(window.alphaValue, 1)
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

    func testUpwardScrubbingIsMorePreciseWithoutJumping() {
        let ordinary = PiPSeekSlider.scrubValue(50, delta: 100, lift: 0, width: 500, range: 0...100)
        let precise = PiPSeekSlider.scrubValue(50, delta: 100, lift: 120, width: 500, range: 0...100)
        XCTAssertEqual(PiPSeekSlider.scrubValue(50, delta: 100, lift: 80, width: 500, range: 0...100), 55)
        XCTAssertEqual(PiPSeekSlider.scrubValue(50, delta: 100, lift: 120, width: 500, range: 0...100), 52.5)
        XCTAssertGreaterThan(ordinary, precise)
        XCTAssertGreaterThan(precise, 50)
        XCTAssertEqual(PiPSeekSlider.scrubValue(50, delta: 0, lift: 200, width: 500, range: 0...100), 50)
        XCTAssertEqual(PiPSeekSlider.scrubValue(99, delta: 500, lift: 0, width: 500, range: 0...100), 100)
        XCTAssertEqual(PiPSeekSlider.scrubValue(1, delta: -500, lift: 0, width: 500, range: 0...100), 0)
    }

    func testScrubbingShowsItsActualPrecisionInPlaceOfTransportButtons() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        let controls = PiPPlaybackControls(tab: tab, returnToTab: {}, minimize: {}, close: {})
        let window = ScrubFixtureWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = controls
        controls.layoutSubtreeIfNeeded()
        let state = try XCTUnwrap(PictureInPicture.Playback(from: ["playing": true, "position": 50.0, "duration": 100.0, "ranges": [[0.0, 100.0]]]))
        controls.update(state)
        let slider = try XCTUnwrap(controls.subviews.compactMap { $0 as? PiPSeekSlider }.first)
        let precision = try XCTUnwrap(controls.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "vane.pip.precision" })
        let transports = controls.subviews.compactMap { $0 as? NSButton }
        let knob = try XCTUnwrap(slider.cell as? NSSliderCell).knobRect(flipped: slider.isFlipped)
        let point = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ position: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        window.events = [try event(.leftMouseDragged, NSPoint(x: point.x, y: point.y + 80)),
                         try event(.leftMouseUp, NSPoint(x: point.x, y: point.y + 80))]
        var observed: [String] = []
        window.beforeNext = {
            observed.append(precision.stringValue)
            XCTAssertEqual(precision.isHidden, observed.count == 1, "Normal seeking has no precision caption")
            XCTAssertTrue(transports.allSatisfy(\.isHidden))
            XCTAssertEqual(precision.frame.midX, controls.bounds.midX, accuracy: 0.1)
            XCTAssertEqual(precision.frame.midY, controls.bounds.midY, accuracy: 0.1)
        }
        slider.mouseDown(with: try event(.leftMouseDown, point))
        XCTAssertEqual(observed, ["", "4× precision"])
        XCTAssertTrue(precision.isHidden)
        XCTAssertTrue(transports.allSatisfy { !$0.isHidden })
        XCTAssertEqual(slider.doubleValue, 50, "Lifting changes precision without seeking by itself")
    }

    func testCornerResizeTargetsAreGenerousAndKeepTheOppositeCornerFixed() {
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 360)
        XCTAssertEqual(CustomPiPWindow.resizeCorner(at: NSPoint(x: 20, y: 340), in: bounds), .topLeft)
        XCTAssertEqual(CustomPiPWindow.resizeCorner(at: NSPoint(x: 620, y: 340), in: bounds), .topRight)
        XCTAssertEqual(CustomPiPWindow.resizeCorner(at: NSPoint(x: 20, y: 20), in: bounds), .bottomLeft)
        XCTAssertEqual(CustomPiPWindow.resizeCorner(at: NSPoint(x: 620, y: 20), in: bounds), .bottomRight)
        XCTAssertNil(CustomPiPWindow.resizeCorner(at: NSPoint(x: 32, y: 332), in: bounds), "Header icons must keep their own hit targets")
        XCTAssertNil(CustomPiPWindow.resizeCorner(at: NSPoint(x: 320, y: 180), in: bounds))
        let original = NSRect(x: 100, y: 200, width: 640, height: 360)
        let minimum = NSSize(width: 320, height: 180)
        let delta = NSSize(width: 160, height: 90)
        XCTAssertEqual(CustomPiPWindow.resizedFrame(original, corner: .topRight, delta: delta, aspect: 16.0 / 9, minimum: minimum),
                       NSRect(x: 100, y: 200, width: 800, height: 450))
        XCTAssertEqual(CustomPiPWindow.resizedFrame(original, corner: .topLeft, delta: NSSize(width: -160, height: 90), aspect: 16.0 / 9, minimum: minimum),
                       NSRect(x: -60, y: 200, width: 800, height: 450))
        XCTAssertEqual(CustomPiPWindow.resizedFrame(original, corner: .bottomLeft, delta: NSSize(width: -160, height: -90), aspect: 16.0 / 9, minimum: minimum),
                       NSRect(x: -60, y: 110, width: 800, height: 450))
        XCTAssertEqual(CustomPiPWindow.resizedFrame(original, corner: .bottomRight, delta: NSSize(width: 160, height: -90), aspect: 16.0 / 9, minimum: minimum),
                       NSRect(x: 100, y: 110, width: 800, height: 450))
        XCTAssertEqual(CustomPiPWindow.resizedFrame(original, corner: .topLeft, delta: NSSize(width: 1000, height: -1000), aspect: 16.0 / 9, minimum: minimum),
                       NSRect(x: 420, y: 200, width: 320, height: 180))
    }

    func testCornerTargetsDoNotStealHeaderClicksOrEndKnobScrubbing() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let held = UserDefaults.vane.object(forKey: CustomPiPWindow.placementKey)
        defer { UserDefaults.vane.set(held, forKey: CustomPiPWindow.placementKey) }
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        let controls = PiPPlaybackControls(tab: tab, returnToTab: {}, minimize: {}, close: {})
        let window = CustomPiPWindow(frame: NSRect(x: 100, y: 100, width: 640, height: 360), videoView: NSView(), controlsView: controls)
        defer { window.close() }
        window.show()
        window.setFrame(NSRect(x: 100, y: 100, width: 640, height: 360), display: true)
        controls.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(window.contentView)
        root.updateTrackingAreas()
        XCTAssertTrue(root.trackingAreas.contains { $0.options.contains([.mouseMoved, .activeAlways]) },
                      "Resize feedback must work while the floating panel is inactive")
        func click(_ point: NSPoint) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + (type == .leftMouseUp ? 1 : 0),
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
        }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        for id in ["vane.pip.restore", "vane.pip.close"] {
            let button = try XCTUnwrap(buttons(controls).first { $0.identifier?.rawValue == id })
            let point = button.convert(NSPoint(x: id == "vane.pip.restore" ? 8 : button.bounds.maxX - 8,
                                              y: button.bounds.maxY - 8), to: nil)
            let buttonFrame = button.convert(button.bounds, to: controls)
            XCTAssertEqual(id == "vane.pip.restore" ? buttonFrame.minX : controls.bounds.maxX - buttonFrame.maxX, 14,
                           "Top controls should retain their old edge spacing")
            let hit = window.contentView?.hitTest(point)
            XCTAssertTrue(hit === button, "Header event must reach its actual button")
            XCTAssertNil(window.resizeCorner(at: point), "Header padding must not start a resize")
            try click(point)
        }
        let slider = try XCTUnwrap(controls.subviews.compactMap { $0 as? PiPSeekSlider }.first)
        var scrubStarts = 0
        let notify = slider.onPrecisionChange
        slider.onPrecisionChange = { factor in
            if factor != nil { scrubStarts += 1 }
            notify?(factor)
        }
        for position in [0.0, 100.0] {
            controls.update(try XCTUnwrap(PictureInPicture.Playback(from: ["playing": true, "position": position, "duration": 100.0, "ranges": [[0.0, 100.0]]])))
            let knob = try XCTUnwrap(slider.cell as? NSSliderCell).knobRect(flipped: slider.isFlipped)
            try click(slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil))
        }
        XCTAssertEqual(scrubStarts, 2, "The seek knob must work at both ends of the timeline")
        XCTAssertEqual(window.frame, NSRect(x: 100, y: 100, width: 640, height: 360))
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
        let tiny = CustomPiPWindow.initialFrame(NSRect(x: 100, y: 100, width: 150, height: 80), saved: nil, screens: [screen])
        XCTAssertGreaterThanOrEqual(tiny.width, 280)
        XCTAssertGreaterThanOrEqual(tiny.height, 160)
        XCTAssertEqual(tiny.width / tiny.height, 150.0 / 80, accuracy: 0.001)
        let landscape = NSRect(x: 100, y: 125, width: 1200, height: 675)
        let portrait = CustomPiPWindow.initialFrame(NSRect(x: 0, y: 0, width: 360, height: 640),
                                                   saved: landscape, screens: [screen])
        XCTAssertTrue(screen.contains(portrait), "Aspect changes must not put bottom controls offscreen")
        XCTAssertEqual(portrait.width / portrait.height, 9.0 / 16, accuracy: 0.001)
        let smallerScreen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let resized = CustomPiPWindow.recoverFrame(landscape, screens: [smallerScreen])
        XCTAssertTrue(smallerScreen.contains(resized))
        XCTAssertEqual(resized.width / resized.height, landscape.width / landscape.height, accuracy: 0.001)
    }
}

@MainActor private final class EntryFixtureControl: NSControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
}

@MainActor private final class ScrubFixtureWindow: NSWindow {
    var events: [NSEvent] = []
    var beforeNext: (() -> Void)?
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue flag: Bool) -> NSEvent? {
        beforeNext?()
        return events.isEmpty ? nil : events.removeFirst()
    }
}
