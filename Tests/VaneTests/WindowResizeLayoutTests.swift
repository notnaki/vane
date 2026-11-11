import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WindowResizeLayoutTests: XCTestCase {
    func testPageViewportFollowsTheNativeFrameBeforeItsNextPresentation() async throws {
        try await resizeFixture(capture: false)
    }

    func testPaintedPageFollowsNativeResizeProposals() async throws {
        try await resizeFixture(capture: true)
    }

    func testSlowPagePaintStaysCoordinatedDuringResize() async throws {
        try await resizeFixture(capture: true, slowResize: true)
    }

    func testClosingSidebarKeepsTheExpandingPagePainted() async throws {
        try await resizeFixture(capture: true, slowResize: true, sidebarToggle: true)
    }

    func testCornerResizeKeepsTheShrinkingAxisPaintedWhileTheOtherAxisGrows() async throws {
        try await resizeFixture(capture: true, slowResize: true, mixedAxes: true)
    }

    private func resizeFixture(capture: Bool, slowResize: Bool = false, sidebarToggle: Bool = false,
                               mixedAxes: Bool = false) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let store = TabStore(isPrivate: true)
            let sidebarWidth = SidebarWidth.shared.width
            SidebarWidth.shared.width = 228
            defer { SidebarWidth.shared.width = sidebarWidth }
            store.sidebarShown = true
            let tab = store.newBlankTab()
            store.palette = nil
            _ = tab.web
            let host = BrowserWindowHost(shown: ShownStore(store))
            let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                                    styleMask: [.titled, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(ignoringOtherApps: true)
            defer {
                store.librarySwipeMonitor.remove()
                store.spaceGesture.monitor.remove()
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                SharedTabs.release(store.tabs, excluding: store)
                TabStore.all.removeAll { $0 === store }
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && window.isVisible
                    && window.occlusionState.contains(.visible) && tab.web.window === window
                    && tab.web.bounds.width > 100
            }
            let delay = slowResize ? "<script>addEventListener('resize',()=>{let end=performance.now()+120;while(performance.now()<end){}})</script>" : ""
            let variables = (0..<160).map { "--resize-fixture-\($0):\($0)px;" }.joined()
            let html = "<html><title>Resize ready</title><style>:root{\(variables)}body{margin:0;background:#17324d}aside{position:fixed;right:0;top:0;width:100px;height:100vh;background:#f04020}</style><body><aside></aside>\(delay)</body></html>"
            tab.web.loadHTMLString(html, baseURL: nil)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Resize ready" }
            for direct in [false, true] {
                if sidebarToggle && direct { continue }
                // The control has an independent page. Borrowing a page from a
                // retained SwiftUI root lets a later update mount it back there.
                let page: WKWebView
                let root: NSView
                if direct {
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    PageRendering.configure(configuration.preferences)
                    page = WKWebView(frame: .zero, configuration: configuration)
                    root = WebHost(page)
                    root.clipsToBounds = true
                } else {
                    page = tab.web
                    root = host
                }
                window.contentView = root
                root.layoutSubtreeIfNeeded()
                if direct {
                    page.loadHTMLString(html, baseURL: nil)
                    try await compatibilityWait { !page.isLoading && page.title == "Resize ready" }
                }
                defer {
                    if direct { page.stopLoading(); (root as? WebHost)?.removePage() }
                }
                try await presentation(page)
                if sidebarToggle {
                    try await captureSidebarPixels(window, store: store, web: page)
                } else if capture {
                    try await captureResizePixels(window, web: page, direct: direct,
                                                  proposalInterval: slowResize ? .milliseconds(40) : .milliseconds(8),
                                                  mixedAxes: mixedAxes)
                } else {
                    for width: CGFloat in [1100, 800, 1200, 900, 1100, 900] {
                        window.setContentSize(NSSize(width: width, height: 600))
                        let earlyWidth = page.bounds.width
                        try await presentation(page)
                        let viewport = try await page.evaluateJavaScript("window.innerWidth")
                        let expected = direct ? width : width - 239
                        XCTAssertEqual(earlyWidth, expected, accuracy: 1,
                                       "Send WebKit its new viewport before waiting for its next presentation")
                        XCTAssertEqual(try XCTUnwrap(viewport as? NSNumber).doubleValue, expected, accuracy: 1,
                                       "The rendered document must use the requested viewport")
                    }
                }
            }
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Resize fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func captureSidebarPixels(_ window: VaneWindow, store: TabStore, web: WKWebView) async throws {
        try await compatibilityWait { NSApp.isActive && window.isKeyWindow }
        let originalFrame = window.frame
        let originalWidth = web.bounds.width
        let owner = ResizeCaptureOwner()
        let observations = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { _ in MainActor.assumeIsolated { owner.interrupted = true } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { owner.interrupted = true } }
        ]
        defer { observations.forEach(NotificationCenter.default.removeObserver) }
        let sampler = ResizePixelSampler()
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            let began = CACurrentMediaTime()
            store.toggleSidebar()
            // Capture the whole transition, including frames before its endpoint.
            try await Task.sleep(for: .milliseconds(650))
            let ended = CACurrentMediaTime()
            try await presentation(web)
            let presented = CACurrentMediaTime()
            try await compatibilityWait { (sampler.frames.last?.time ?? 0) >= presented }
            try await sampler.stop()
            try sampler.frames.saveImages(prefix: "sidebar-\(ProcessInfo.processInfo.processIdentifier)")
            let samples = sampler.frames.samples.filter { $0.time >= began && $0.time <= ended }
            let maximum = samples.map(\.gap).max() ?? 0
            print("SIDEBAR_PIXELS samples=\(samples.count) baselineGap=\(baseline.gap) maxGap=\(maximum) width=\(originalWidth)->\(web.bounds.width)")
            XCTAssertFalse(owner.interrupted, "Sidebar capture must retain actual foreground ownership")
            XCTAssertGreaterThan(samples.count, 3)
            XCTAssertEqual(window.frame, originalFrame, "Sidebar closing must not resize the window")
            XCTAssertFalse(store.sidebarShown)
            XCTAssertGreaterThan(web.bounds.width, originalWidth + 200)
            XCTAssertEqual(web.pageZoom, 1)
            XCTAssertLessThanOrEqual(maximum, baseline.gap + 2,
                "Closing the sidebar must not expose unpainted page width")
            XCTAssertLessThanOrEqual(try XCTUnwrap(sampler.frames.last).markerGap, baseline.markerGap + 2,
                "The fixed page marker must finish at the expanded viewport edge")
        } catch {
            try? await sampler.stop()
            throw error
        }
    }

    private func captureResizePixels(_ window: VaneWindow, web: WKWebView, direct: Bool,
                                     proposalInterval: Duration, mixedAxes: Bool = false) async throws {
        // Diagnostic reference: the original geometry-only path must remain RED.
        let baselineControl = ProcessInfo.processInfo.environment["VANE_RESIZE_BASELINE"] == "1"
        try await compatibilityWait { NSApp.isActive && window.isKeyWindow }
        let owner = ResizeCaptureOwner()
        owner.maxWidth = window.frame.width
        let observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { _ in MainActor.assumeIsolated { owner.interrupted = true } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { owner.interrupted = true } },
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { owner.maxWidth = max(owner.maxWidth, window.frame.width) }
                }
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let sampler = ResizePixelSampler()
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            let began = CACurrentMediaTime()
            let frameHeight = window.frame.height
            if !baselineControl {
                window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.maxY))
            }
            defer { window.endPageResize() }
            let widths = Array(stride(from: 900, through: 1300, by: 40))
                + Array(stride(from: 1260, through: 900, by: -40))
            let sizes = mixedAxes
                ? [NSSize(width: 800, height: frameHeight + 100),
                   NSSize(width: 1100, height: frameHeight - 100),
                   NSSize(width: 800, height: frameHeight + 100),
                   NSSize(width: 900, height: frameHeight)]
                : widths.map { NSSize(width: CGFloat($0), height: frameHeight) }
            for size in sizes {
                let deadline = ContinuousClock.now + proposalInterval
                let accepted = baselineControl ? size : window.proposedPageResize(size)
                if accepted != window.frame.size {
                    window.setFrame(NSRect(origin: window.frame.origin, size: accepted), display: false)
                }
                try await ContinuousClock().sleep(until: deadline)
                if mixedAxes {
                    print("CORNER_REQUEST target=\(size) actual=\(window.frame) preparing=\(window.isPreparingPageResize) page=\(web.frame) parent=\(String(describing: web.superview?.bounds))")
                    // Keep sampling through each paint so coalescing cannot skip
                    // the corner geometry this regression is meant to exercise.
                    do {
                        try await compatibilityWait { !window.isPreparingPageResize && window.frame.size == size }
                    } catch {
                        print("CORNER_TIMEOUT target=\(size) actual=\(window.frame) preparing=\(window.isPreparingPageResize) page=\(web.frame) parent=\(String(describing: web.superview?.bounds))")
                        throw error
                    }
                }
            }
            try await compatibilityWait { !window.isPreparingPageResize }
            let ended = CACurrentMediaTime()
            try await presentation(web)
            let presented = CACurrentMediaTime()
            try await compatibilityWait { (sampler.frames.last?.time ?? 0) >= presented }
            try await sampler.stop()
            let prefix = "\(direct ? "native" : "browser")-\(ProcessInfo.processInfo.processIdentifier)"
            try sampler.frames.saveImages(prefix: prefix)
            let samples = sampler.frames.samples.filter { $0.time >= began && $0.time <= ended }
            XCTAssertGreaterThan(samples.count, 3, "Capture actual WindowServer frames during resizing")
            XCTAssertFalse(owner.interrupted, "Foreground admission was lost during the native resize capture")
            XCTAssertGreaterThanOrEqual(owner.maxWidth, 1100, "The window must actually grow during capture")
            XCTAssertEqual(window.frame.width, 900, accuracy: 1, "Commit the latest queued request")
            XCTAssertEqual(window.frame.height, frameHeight, accuracy: 1,
                           "Native width proposals must not repeatedly add the titlebar height")
            let maximum = samples.map(\.gap).max() ?? 0
            print("RESIZE_PIXELS baselineControl=\(baselineControl) direct=\(direct) samples=\(samples.count) baselineGap=\(baseline.gap) maxGap=\(maximum)")
            XCTAssertLessThanOrEqual(maximum, baseline.gap + 2,
                                     "Drawn page content must reach the visible window edge without an empty strip")
            XCTAssertLessThanOrEqual(try XCTUnwrap(sampler.frames.last).markerGap, baseline.markerGap + 2,
                                     "The final paint must lay out the fixed marker at the new viewport edge")
        } catch {
            try? await sampler.stop()
            throw error
        }
    }

    private func presentation(_ web: WKWebView) async throws {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard web.responds(to: selector) else { throw XCTSkip("Presentation diagnostic unavailable") }
        let presented = XCTestExpectation(description: "WebKit presents its next viewport")
        let completion: @convention(block) () -> Void = { presented.fulfill() }
        _ = web.perform(selector, with: completion)
        guard await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed else {
            throw NSError(domain: "ResizePresentationTimeout", code: 1)
        }
    }
}

@MainActor private final class ResizeCaptureOwner {
    var interrupted = false
    var maxWidth: CGFloat = 0
}

@MainActor private final class ResizePixelSampler: NSObject, SCStreamOutput {
    nonisolated let frames = ResizePixelFrames()
    private var stream: SCStream?

    func start(_ window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = 1400
        configuration.height = 700
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 8
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: target),
                               configuration: configuration, delegate: nil)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames.queue)
        stream = capture
        do {
            try await capture.startCapture()
            try await compatibilityWait { self.frames.last != nil }
        } catch {
            try? await capture.stopCapture()
            stream = nil
            throw error
        }
    }

    func stop() async throws {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
            frames.queue.sync {}
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let time = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard time.isFinite else { return }
        let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = info?.first?[.status] as? Int
        if status == SCFrameStatus.idle.rawValue { frames.repeatFrame(time); return }
        guard status == SCFrameStatus.complete.rawValue, let pixel = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard let rectDictionary = info?.first?[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: rectDictionary as CFDictionary),
              let factor = info?.first?[.scaleFactor] as? NSNumber,
              let contentScale = info?.first?[.contentScale] as? NSNumber else { return }
        let scale = CGFloat(factor.doubleValue)
        let pixelsPerPoint = factor.doubleValue * contentScale.doubleValue
        guard pixelsPerPoint.isFinite, pixelsPerPoint > 0 else { return }
        let valid = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                           width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !valid.isEmpty else { return }
        // ScreenCaptureKit can retain pixels from the previously wider window
        // outside this frame's content rectangle. Those are not visible content.
        let row = Int(valid.midY) * CVPixelBufferGetBytesPerRow(pixel)
        var firstRed: Int?, lastRed: Int?, lastPainted: Int?, rightWindow: Int?
        for x in max(0, Int(ceil(valid.minX)))..<min(width, Int(floor(valid.maxX))) {
            let p = row + x * 4
            let b = Int(bytes[p]), g = Int(bytes[p + 1]), r = Int(bytes[p + 2])
            if r + g + b > 40 { rightWindow = x }
            let red = r > 180 && g < 110 && b < 100
            let blue = b > r + 20 && b > g + 15 && b < 130 && g > 20 && g < 100
            if red {
                if firstRed == nil { firstRed = x }
                lastRed = x
            }
            if red || blue { lastPainted = x }
        }
        // Measure the actual empty strip, using the stream's point scale.
        // During a native shrink the larger page is clipped until it repaints;
        // both the blue body and red marker are drawn page content. Requiring the
        // fixed marker itself at the edge incorrectly rejects that normal clip.
        // A missing page still fails instead of being excluded from the sequence.
        let gap: Double
        if let lastPainted, let rightWindow {
            gap = Double(rightWindow - lastPainted) / pixelsPerPoint
        } else {
            gap = 10_000
        }
        let snapshot = frames.needsImage(for: gap)
            ? ResizePixelFrames.Image(data: Data(bytes: bytes, count: CVPixelBufferGetBytesPerRow(pixel) * height),
                                      width: width, height: height, stride: CVPixelBufferGetBytesPerRow(pixel)) : nil
        if snapshot != nil { print("RESIZE_CAPTURE_BOUND time=\(time) rect=\(valid) red=\(String(describing: firstRed))...\(String(describing: lastRed)) right=\(String(describing: rightWindow)) gap=\(gap) screen=\(String(describing: info?.first?[.screenRect]))") }
        if frames.last == nil { print("RESIZE_CAPTURE info=\(String(describing: info?.first))") }
        let markerGap = lastRed.flatMap { red in rightWindow.map { Double($0 - red) / pixelsPerPoint } } ?? 10_000
        frames.append(time: time, gap: gap, markerGap: markerGap, image: snapshot)
    }
}

private final class ResizePixelFrames: @unchecked Sendable {
    struct Frame { let time: Double; let gap: Double; let markerGap: Double }
    struct Image { let data: Data; let width: Int; let height: Int; let stride: Int }
    let queue = DispatchQueue(label: "vane.resize.pixel-capture")
    private let lock = NSLock()
    private var recorded: [Frame] = []
    private var baselineImage: Image?
    private var worstImage: Image?
    private var worstGap = -Double.infinity
    var last: Frame? { lock.withLock { recorded.last } }
    var samples: [Frame] { lock.withLock { recorded } }
    func needsImage(for gap: Double) -> Bool { lock.withLock { baselineImage == nil || gap > worstGap } }
    func append(time: Double, gap: Double, markerGap: Double, image: Image?) {
        lock.withLock {
            recorded.append(Frame(time: time, gap: gap, markerGap: markerGap))
            if baselineImage == nil { baselineImage = image }
            if gap > worstGap { worstGap = gap; worstImage = image }
        }
    }
    func repeatFrame(_ time: Double) {
        lock.withLock { if let last = recorded.last { recorded.append(Frame(time: time, gap: last.gap, markerGap: last.markerGap)) } }
    }
    @MainActor func saveImages(prefix: String) throws {
        let images = lock.withLock { [("baseline", baselineImage), ("worst", worstImage)] }
        for (name, snapshot) in images {
            let snapshot = try XCTUnwrap(snapshot)
            let provider = try XCTUnwrap(CGDataProvider(data: snapshot.data as CFData))
            let format = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
            let image = try XCTUnwrap(CGImage(width: snapshot.width, height: snapshot.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: snapshot.stride,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/vane-resize-\(prefix)-\(name).png"))
        }
    }
}
