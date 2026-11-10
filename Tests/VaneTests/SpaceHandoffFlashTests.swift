import AppKit
import Combine
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceHandoffFlashTests: XCTestCase {
    func testTrackingResetCannotRetireTheReleasedHandoffCapture() {
        let frames = HandoffCaptureFrames()
        frames.append(time: 1, edges: 20)
        // Losing the gesture while fingers are still down is not the final
        // released landing. A subsequent claimed packet can start tracking again.
        frames.reachedEndpoint(at: 2)
        frames.retired(at: 3)
        frames.append(time: 4, edges: 30)
        XCTAssertTrue(frames.samples.isEmpty,
                      "Pre-release tracking must not be classified as landing/retirement")
        frames.release()
        frames.reachedEndpoint(at: 5)
        frames.append(time: 6, edges: 40)
        frames.retired(at: 7)
        frames.append(time: 8, edges: 50)
        XCTAssertEqual(frames.samples.count, 2)
        XCTAssertEqual(frames.samples.map(\.0), [true, false])
        XCTAssertEqual(frames.samples.map(\.1), [40, 50])
    }

    func testCommittedSidebarHandoffDoesNotDoubleCompositeText() async throws {
        try await assertHandoff(returning: false)
    }

    func testCanceledSidebarHandoffDoesNotDoubleCompositeText() async throws {
        try await assertHandoff(returning: true)
    }

    private func assertHandoff(returning: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated handoff")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseHandoff(returning: returning) } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Handoff AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseHandoff(returning: Bool) async throws {
        let profile = ProfileManager.shared.create(name: "Presented sidebar fixture").id
        let spaces = ["First", "Second"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        defer {
            monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        for space in spaces {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank#\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        var admitted = "not sampled"
        defer { print("HANDOFF_ADMISSION \(admitted)") }
        func readyForInput() -> Bool {
            admitted = "running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) anchor=\(store.spaceGesture.sectionsView?.window === window)"
            if !NSApp.isActive || NSApp.keyWindow !== window {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return false
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            guard NSApp.isRunning, window.isVisible, window.occlusionState.contains(.visible),
                  NSApp.modalWindow == nil, window.attachedSheet == nil,
                  let anchor = store.spaceGesture.sectionsView, anchor.window === window,
                  anchor.layer?.presentation() != nil, host.layer?.presentation() != nil else { return false }
            return SidebarNativeReadinessCoordinator.shared.isReady(
                SidebarNativeReadinessScope(store: store, spaceID: spaces[0].id),
                allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled)
        }
        try await compatibilityWait { readyForInput() }
        let sampler = PresentedSidebarSampler(host: host, store: store)
        try await sampler.start(in: window)
        do {
        // Starting ScreenCaptureKit yields to AppKit. Its admission cannot stand
        // in for foreground/presentation ownership at the actual input boundary.
        try await compatibilityWait { readyForInput() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        if returning {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -8))
            try await Task.sleep(for: .milliseconds(100))
        } else {
            for _ in 0..<10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
                try await Task.sleep(for: .milliseconds(8))
            }
        }
        XCTAssertFalse(sampler.interruptedDuringTracking,
                       "An admitted tracking gesture must not reset before its release")
        sampler.release()
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        let animationDeadline = ProcessInfo.processInfo.systemUptime + 1
        while store.spaceSwiping, ProcessInfo.processInfo.systemUptime < animationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.spaceSwiping, "The actual native landing must complete")
        // Retirement waits for SwiftUI's resting-sidebar acknowledgement, separately
        // from landing. Covered endpoint samples cannot stand in for displayed frames
        // after the native cover disappears, especially when callbacks arrive late.
        let handoffDeadline = ProcessInfo.processInfo.systemUptime + 2
        while (host.spaceSlide != nil || sampler.samples.filter { !$0.covered }.count < 4),
              ProcessInfo.processInfo.systemUptime < handoffDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[returning ? 0 : 1].id)
        XCTAssertNil(host.spaceSlide)
        try await sampler.stop()
        print("HANDOFF_CAPTURE \(sampler.diagnostics)")
        let covered = sampler.samples.filter(\.covered)
        let uncovered = sampler.samples.filter { !$0.covered }
        XCTAssertTrue(sampler.observedGesture, "A display callback must observe the actual gesture")
        XCTAssertGreaterThan(uncovered.count, 3, "Sample several displayed frames after retirement")
        print("HANDOFF_EDGES \(sampler.samples.map { ($0.covered, $0.edges) })")
        let settled = try XCTUnwrap(uncovered.last?.edges)
        XCTAssertGreaterThan(settled, 1, "The destination must contain rendered sidebar text")
        for frame in covered + uncovered {
            XCTAssertLessThan(frame.edges, settled * 1.15,
                              "Live and native text must not brighten through double alpha compositing")
            XCTAssertGreaterThan(frame.edges, settled * 0.85,
                                 "Sidebar content must not disappear for a frame at native handoff")
        }
        } catch {
            let primary = error
            do { try await sampler.stop() }
            catch { XCTFail("Handoff capture cleanup also failed: \(error)") }
            throw primary
        }
    }
}

/// Capture WindowServer output: rendering a newly committed layer tree into a
/// CGContext can temporarily omit asynchronously drawn SwiftUI backing contents.
@MainActor private final class PresentedSidebarSampler: NSObject, SCStreamOutput {
    struct Sample { let covered: Bool; let edges: Double }
    private weak var host: BrowserWindowHost?
    private weak var store: TabStore?
    private(set) var observedGesture = false
    private(set) var interruptedDuringTracking = false
    private var released = false
    private var link: CADisplayLink?
    private var stream: SCStream?
    private var capturePulse: NSView?
    private var observation: AnyCancellable?
    private nonisolated let frames = HandoffCaptureFrames()
    private var ticks = 0
    var diagnostics: String { "ticks=\(ticks) \(frames.diagnostics)" }
    var samples: [Sample] { frames.samples.map { Sample(covered: $0.0, edges: $0.1) } }
    func release() { released = true; frames.release() }
    init(host: BrowserWindowHost, store: TabStore) {
        self.host = host
        self.store = store
    }
    func start(in window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let host = try XCTUnwrap(host)
        let crop = CGRect(x: 8, y: 70, width: max(1, SidebarWidth.shared.width - 16), height: 280)
        let screenCrop = window.convertToScreen(host.convert(crop, to: nil))
        configuration.sourceRect = CGRect(x: screenCrop.minX - window.frame.minX,
            y: window.frame.maxY - screenCrop.maxY, width: crop.width, height: crop.height)
        configuration.width = Int(crop.width)
        configuration.height = Int(crop.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let screen = try XCTUnwrap(window.screen)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(screen.maximumFramesPerSecond))
        configuration.queueDepth = 8
        let capture = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames.queue)
        stream = capture
        do {
            try await capture.startCapture()
            // ScreenCaptureKit is change-driven. Keep this fixture's window
            // producing fresh buffers even after the sidebar becomes static.
            // The compositor-only pulse sits outside the measured sidebar crop.
            let pulse = NSView(frame: NSRect(x: host.bounds.maxX - 4, y: host.bounds.minY + 4,
                                            width: 2, height: 2))
            pulse.wantsLayer = true
            pulse.layer?.backgroundColor = NSColor.white.cgColor
            pulse.setAccessibilityElement(false)
            host.addSubview(pulse)
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.25
            animation.toValue = 0.75
            animation.duration = 0.25
            animation.autoreverses = true
            animation.repeatCount = .infinity
            pulse.layer?.add(animation, forKey: "fixture-capture-pulse")
            capturePulse = pulse
            try await compatibilityWait { self.frames.hasRenderedContent }
        } catch {
            try? await capture.stopCapture()
            stream = nil
            capturePulse?.removeFromSuperview()
            capturePulse = nil
            throw error
        }
        observation = store?.spaceGesture.$presentation.sink { [weak self] state in
            guard let self else { return }
            if state.swiping { self.observedGesture = true }
            else if self.observedGesture {
                if !self.released { self.interruptedDuringTracking = true }
                self.frames.reachedEndpoint(at: CACurrentMediaTime())
            }
        }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() async throws {
        defer {
            capturePulse?.layer?.removeAllAnimations()
            capturePulse?.removeFromSuperview()
            capturePulse = nil
        }
        link?.invalidate(); link = nil
        observation = nil
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
            frames.queue.sync {}
        }
    }
    @objc private func tick(_ link: CADisplayLink) {
        ticks += 1
        if observedGesture, host?.spaceSlide == nil { frames.retired(at: CACurrentMediaTime()) }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let time = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard time.isFinite else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? Int
        frames.note(status: status ?? -1, time: time, receipt: CACurrentMediaTime())
        // An idle frame repeats the last displayed content; a blank frame is
        // real missing content and must remain a zero-edge assertion sample.
        if status == SCFrameStatus.idle.rawValue { frames.repeatFrame(at: time); return }
        if status == SCFrameStatus.blank.rawValue { frames.append(time: time, edges: 0); return }
        guard status == SCFrameStatus.complete.rawValue, let pixel = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let strideBytes = CVPixelBufferGetBytesPerRow(pixel)
        var edges = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width - 1, by: 2) {
                let offset = y * strideBytes + x * 4
                for component in 0..<3 {
                    edges += Double(abs(Int(bytes[offset + component]) - Int(bytes[offset + 4 + component]))) / 255
                }
            }
        }
        frames.append(time: time, edges: edges)
    }
}

private final class HandoffCaptureFrames: @unchecked Sendable {
    let queue = DispatchQueue(label: "vane.handoff.capture")
    private let lock = NSLock()
    private var endpoint: Double?
    private var retirement: Double?
    private var released = false
    private var recorded: [(Double, Double)] = []
    private var raw: [(Int, Double, Double)] = []
    var diagnostics: String {
        lock.withLock {
            let statuses = Dictionary(grouping: raw, by: { $0.0 }).mapValues(\.count)
            let lag = raw.map { $0.2 - $0.1 }.max() ?? 0
            return "endpoint=\(String(describing: endpoint)) retirement=\(String(describing: retirement)) raw=\(raw.count) recorded=\(recorded.count) statuses=\(statuses) maxReceiptLag=\(lag)"
        }
    }
    func note(status: Int, time: Double, receipt: Double) {
        lock.withLock { raw.append((status, time, receipt)) }
    }
    var hasRenderedContent: Bool { lock.withLock { recorded.contains { $0.1 > 1 } } }
    var samples: [(Bool, Double)] {
        lock.withLock {
            guard let endpoint else { return [] }
            return recorded.filter { $0.0 >= endpoint }.map { frame in
                (retirement.map { frame.0 < $0 } ?? true, frame.1)
            }
        }
    }
    // Observe only the release being exercised. Native gesture cancellation can
    // publish a resting state before a later tracking packet reclaims the swipe.
    // That earlier reset cannot timestamp this release's landing or retirement.
    func release() { lock.withLock { released = true } }
    func reachedEndpoint(at time: Double) {
        lock.withLock { if released, endpoint == nil { endpoint = time } }
    }
    func retired(at time: Double) {
        lock.withLock { if endpoint != nil, retirement == nil { retirement = time } }
    }
    func append(time: Double, edges: Double) { lock.withLock { recorded.append((time, edges)) } }
    func repeatFrame(at time: Double) {
        lock.withLock { if let last = recorded.last { recorded.append((time, last.1)) } }
    }
}
