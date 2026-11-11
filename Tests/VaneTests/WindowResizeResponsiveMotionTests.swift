import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import WebKit
import XCTest
@testable import vane

/// Opt-in end-to-end WindowServer geometry measurement on the reported page.
@MainActor final class WindowResizeResponsiveMotionTests: XCTestCase {
    func testResponsivePageKeepsVisibleWindowMovementWithinTheFrameBudget() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VANE_RESIZE_RESPONSIVE_MOTION"] == "1" else { throw XCTSkip("Opt-in real-page motion check") }
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let store = TabStore(isPrivate: true)
        let sidebarWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = 228
        defer { SidebarWidth.shared.width = sidebarWidth }
        store.sidebarShown = true
        let tab = store.newBlankTab()
        store.palette = nil
        let web = tab.web
        var retired = false
        func retireStore() {
            guard !retired else { return }
            retired = true
            web.stopLoading()
            store.librarySwipeMonitor.remove()
            store.spaceGesture.monitor.remove()
            store.dropStashes()
            SharedTabs.release(store.tabs, excluding: store)
            TabStore.all.removeAll { $0 === store }
        }
        defer { retireStore() }
        web.setFrameSize(NSSize(width: 661, height: 600))
        web.load(URLRequest(url: URL(string: "https://github.com/notnaki/vane/pulls")!))
        let loadedBy = ContinuousClock.now + .seconds(45)
        while web.isLoading || web.title?.contains("GitHub") != true {
            guard ContinuousClock.now < loadedBy else { throw NSError(domain: "ResizeMotionPageReadiness", code: 1) }
            try await Task.sleep(for: .milliseconds(25))
        }
        if let stage = environment["VANE_RESIZE_MOTION_STAGE"] {
            try "page-ready\n".write(toFile: stage, atomically: true, encoding: .utf8)
        }
        if let gate = environment["VANE_RESIZE_MOTION_GATE"] {
            let readyBy = ContinuousClock.now + .seconds(150)
            while !FileManager.default.fileExists(atPath: gate) {
                guard ContinuousClock.now < readyBy else { throw NSError(domain: "ResizeMotionGateTimeout", code: 1) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let activeBy = ContinuousClock.now + .seconds(18)
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let host = BrowserWindowHost(shown: ShownStore(store))
            let window = VaneWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(ignoringOtherApps: true)
            defer {
                window.endPageResize()
                window.contentView = nil
                store.window = nil
                window.close()
                retireStore()
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && app.isActive && window.isKeyWindow
                    && window.occlusionState.contains(.visible) && web.window === window && web.bounds.width > 100
            }
            let presented = XCTestExpectation(description: "Initial responsive page presentation")
            let callback: @convention(block) () -> Void = { presented.fulfill() }
            _ = web.perform(NSSelectorFromString("_doAfterNextPresentationUpdate:"), with: callback)
            guard await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed else {
                throw NSError(domain: "ResizeMotionPresentationReadiness", code: 1)
            }
            let owner = ResponsiveMotionOwner()
            let observations = [
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { owner.interrupted = true }
                },
                NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: app, queue: .main) { _ in
                    MainActor.assumeIsolated { owner.interrupted = true }
                }
            ]
            defer { observations.forEach(NotificationCenter.default.removeObserver) }
            let sampler = ResponsiveMotionSampler()
            try await sampler.start(window)
            do {
                let began = CACurrentMediaTime()
                let frameHeight = window.frame.height
                print("RESPONSIVE_INITIAL frame=\(window.frame.size) content=\(window.contentView?.bounds.size ?? .zero) page=\(web.bounds.size)")
                window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.maxY))
                let widths = Array(stride(from: 900, through: 1350, by: 2))
                    + Array(stride(from: 1348, through: 900, by: -2))
                for width in widths {
                    guard ContinuousClock.now < activeBy else { throw NSError(domain: "ResizeMotionActiveBudget", code: 1) }
                    let next = ContinuousClock.now + .milliseconds(8)
                    let accepted = window.proposedPageResize(NSSize(width: CGFloat(width), height: frameHeight))
                    if accepted != window.frame.size {
                        window.setFrame(NSRect(origin: window.frame.origin, size: accepted), display: false)
                    }
                    try await ContinuousClock().sleep(until: next)
                }
                try await compatibilityWait { !window.isPreparingPageResize && abs(window.frame.width - 900) < 1 }
                let ended = CACurrentMediaTime()
                window.endPageResize()
                try await sampler.stop()
                let samples = sampler.samples.values.filter { $0.time >= began && $0.time <= ended }
                var changes = [ResponsiveMotionSamples.Frame(time: began, width: 900)]
                for sample in samples where abs(sample.width - changes.last!.width) > 0.5 { changes.append(sample) }
                let pauses = zip(changes, changes.dropFirst()).map { ($1.time - $0.time) * 1000 }.sorted()
                let steps = zip(changes, changes.dropFirst()).map { abs($1.width - $0.width) }
                let p95 = pauses.isEmpty ? .infinity : pauses[Int(Double(pauses.count - 1) * 0.95)]
                let longest = zip(changes, changes.dropFirst()).map { previous, next in
                    (pause: (next.time - previous.time) * 1000, elapsed: previous.time - began,
                     from: previous.width, to: next.width)
                }.sorted { $0.pause > $1.pause }.prefix(5)
                print("RESPONSIVE_LONGEST \(longest)")
                print("RESPONSIVE_WINDOWSERVER changes=\(changes.count-1) maxPauseMS=\(pauses.last ?? .infinity) p95PauseMS=\(p95) maxStep=\(steps.max() ?? .infinity)")
                XCTAssertFalse(owner.interrupted, "Actual foreground admission must hold throughout capture")
                XCTAssertGreaterThan(changes.count, 10)
                XCTAssertGreaterThanOrEqual(changes.map(\.width).max() ?? 0, 1300)
                XCTAssertLessThanOrEqual(pauses.last ?? .infinity, 80, "Avoid the measured170ms page-layout stalls")
                XCTAssertLessThanOrEqual(p95, 60)
                XCTAssertLessThanOrEqual(steps.max() ?? .infinity, 24)
                XCTAssertEqual(web.pageZoom, 1)
            } catch { try? await sampler.stop(); throw error }
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Motion fixture cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }
}

@MainActor private final class ResponsiveMotionOwner { var interrupted = false }

private final class ResponsiveMotionSamples: @unchecked Sendable {
    struct Frame { let time: Double; let width: Double }
    let queue = DispatchQueue(label: "vane.resize.responsive-motion")
    private let lock = NSLock()
    private var recorded: [Frame] = []
    var values: [Frame] { lock.withLock { recorded } }
    func append(_ frame: Frame) { lock.withLock { recorded.append(frame) } }
}

@MainActor private final class ResponsiveMotionSampler: NSObject, SCStreamOutput {
    nonisolated let samples = ResponsiveMotionSamples()
    private var stream: SCStream?
    func start(_ window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = 1700
        config.height = 800
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 8
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples.queue)
        stream = capture
        do {
            try await capture.startCapture()
            try await compatibilityWait { !self.samples.values.isEmpty }
        } catch { try? await capture.stopCapture(); stream = nil; throw error }
    }
    func stop() async throws {
        if let stream { try await stream.stopCapture(); self.stream = nil; samples.queue.sync {} }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int,
              status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.idle.rawValue,
              let dictionary = info[.screenRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return }
        let time = CMTimeGetSeconds(sample.presentationTimeStamp)
        guard time.isFinite, rect.width > 0 else { return }
        samples.append(.init(time: time, width: rect.width))
    }
}
