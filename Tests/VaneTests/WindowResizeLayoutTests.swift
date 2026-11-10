import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WindowResizeLayoutTests: XCTestCase {
    func testPageViewportFollowsTheNativeFrameBeforeItsNextPresentation() async throws {
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
                print("Resize fixture: active=\(app.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) pageWindow=\(tab.web.window === window) pageBounds=\(tab.web.bounds) hostBounds=\(host.bounds)")
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
                // Geometry needs the owned visible tree, without requiring the
                // CLI test host to win keyboard focus from another application.
                return app.isRunning && window.isVisible
                    && window.occlusionState.contains(.visible) && tab.web.window === window
                    && tab.web.bounds.width > 100
            }
            tab.web.loadHTMLString("<html><title>Resize ready</title><style>body{margin:0;background:#17324d}aside{position:fixed;right:0;top:0;width:100px;height:100vh;background:#f04020}</style><body><aside></aside></body></html>", baseURL: nil)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Resize ready" }
            var ancestor: NSView? = tab.web
            while let view = ancestor {
                print("RESIZE_TREE type=\(type(of: view)) frame=\(view.frame) mask=\(view.autoresizingMask.rawValue) autoSubviews=\(view.autoresizesSubviews) translates=\(view.translatesAutoresizingMaskIntoConstraints)")
                ancestor = view.superview
            }
            let paths = ProcessInfo.processInfo.environment["VANE_RESIZE_DRAWING"] == "native-drag"
                ? [false] : [false, true]
            for direct in paths {
                let root: NSView = direct ? WebHost(tab.web) : host
                window.contentView = root
                root.layoutSubtreeIfNeeded()
                try await presentation(tab.web)
                if ProcessInfo.processInfo.environment["VANE_RESIZE_PIXELS"] == "1" {
                    try await captureResizePixels(window, web: tab.web, direct: direct)
                    continue
                }
                for width: CGFloat in [1100, 800, 1200, 900, 1100, 900] {
                    let started = ProcessInfo.processInfo.systemUptime
                    window.setContentSize(NSSize(width: width, height: 600))
                    let frameMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let earlyWidth = tab.web.bounds.width
                    print("RESIZE_VISIBLE direct=\(direct) bounds=\(tab.web.bounds) visible=\(tab.web.visibleRect)")
                    if !direct && width == 1200 {
                        var layer = tab.web.layer
                        while let current = layer {
                            print("RESIZE_LAYER type=\(type(of: current)) bounds=\(current.bounds) presented=\(String(describing: current.presentation()?.bounds)) masks=\(current.masksToBounds) mask=\(String(describing: current.mask?.bounds)) animations=\(current.animationKeys() ?? [])")
                            layer = current.superlayer
                        }
                    }
                    try await presentation(tab.web)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let viewport = try await tab.web.evaluateJavaScript("window.innerWidth")
                    let expected = direct ? width : width - 239
                    XCTAssertEqual(earlyWidth, expected, accuracy: 1,
                                   "Send WebKit its new viewport before waiting for the next presentation")
                    XCTAssertEqual(try XCTUnwrap(viewport as? NSNumber).doubleValue, expected, accuracy: 1,
                                   "The rendered document must use the requested viewport")
                    print("RESIZE_PRESENT direct=\(direct) request=\(width) early=\(earlyWidth) settled=\(tab.web.bounds.width) viewport=\(String(describing: viewport)) frameMS=\(frameMS) presentedMS=\(elapsed)")
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

    private func captureResizePixels(_ window: VaneWindow, web: WKWebView, direct: Bool) async throws {
        let drawing = ProcessInfo.processInfo.environment["VANE_RESIZE_DRAWING"] ?? "ordinary"
        let sampler = ResizePixelSampler()
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            let began = CACurrentMediaTime()
            let widths = Array(stride(from: 900, through: 1300, by: 40))
                + Array(stride(from: 1260, through: 900, by: -40))
            if drawing == "native-drag" {
                let ended = XCTestExpectation(description: "Owned window native resize ends")
                let token = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                    object: window, queue: .main) { _ in ended.fulfill() }
                defer { NotificationCenter.default.removeObserver(token) }
                print("RESIZE_NATIVE_READY window=\(window.windowNumber) frame=\(window.frame)")
                guard await XCTWaiter.fulfillment(of: [ended], timeout: 25) == .completed else {
                    throw NSError(domain: "NativeResizeDragTimeout", code: 1)
                }
                XCTAssertGreaterThan(abs(window.frame.width - 900), 50, "Exercise a real native edge drag")
                try await compatibilityWait { !window.isPreparingPageResize }
            }
            for width in drawing == "native-drag" ? [] : widths {
                let deadline = ContinuousClock.now + .milliseconds(8)
                let size = NSSize(width: width, height: 600)
                if drawing == "production" {
                    var frame = window.frame
                    frame.size.width += size.width - (window.contentView?.bounds.width ?? window.frame.width)
                    if !window.preparePageResize(frame: frame, display: true) { window.setContentSize(size) }
                } else if drawing.hasPrefix("prepare") {
                    // Diagnostic only: submit the next document viewport first,
                    // then commit the matching native window geometry inside the
                    // presentation callback, before WebKit's CA transaction closes.
                    let viewport = NSSize(width: CGFloat(width) - (direct ? 0 : 239),
                                          height: web.frame.height)
                    let mask = web.autoresizingMask
                    web.autoresizingMask = []
                    let previousSize = web.frame.size
                    let resizedChildren = web.autoresizesSubviews
                    if drawing == "prepare-children-held" { web.autoresizesSubviews = false }
                    let oldBounds = web.layer?.bounds
                    let oldPosition = web.layer?.position
                    var oldLayers: [(CALayer, CGRect, CGPoint)] = []
                    func remember(_ layer: CALayer) {
                        oldLayers.append((layer, layer.bounds, layer.position))
                        layer.sublayers?.forEach(remember)
                        if let mask = layer.mask { remember(mask) }
                    }
                    if drawing == "prepare-trace", width == 1260, let layer = web.layer {
                        remember(layer)
                    }
                    web.setFrameSize(viewport)
                    web.prepareContent(in: NSRect(origin: .zero, size: viewport))
                    for (layer, oldBounds, oldPosition) in oldLayers
                    where layer.bounds != oldBounds || layer.position != oldPosition {
                        print("RESIZE_GEOMETRY direct=\(direct) layer=\(type(of: layer)) name=\(layer.name ?? "-") masks=\(layer.masksToBounds) bounds=\(oldBounds)->\(layer.bounds) position=\(oldPosition)->\(layer.position)")
                    }
                    let nextBounds = web.layer?.bounds
                    let nextPosition = web.layer?.position
                    if drawing == "prepare-held" {
                        if let oldBounds { web.layer?.bounds = oldBounds }
                        if let oldPosition { web.layer?.position = oldPosition }
                    }
                    do {
                        try await presentation(web) {
                            window.setContentSize(size)
                            web.setFrameSize(viewport)
                            if drawing == "prepare-held" {
                                if let nextBounds { web.layer?.bounds = nextBounds }
                                if let nextPosition { web.layer?.position = nextPosition }
                            }
                            if drawing == "prepare-children-held" {
                                web.autoresizesSubviews = resizedChildren
                                if resizedChildren { web.resizeSubviews(withOldSize: previousSize) }
                            }
                        }
                    } catch {
                        web.autoresizingMask = mask
                        web.autoresizesSubviews = resizedChildren
                        throw error
                    }
                    web.autoresizingMask = mask
                    print("RESIZE_STEP direct=\(direct) width=\(width) time=\(CACurrentMediaTime()) web=\(web.frame.size) window=\(window.contentView?.frame.size ?? .zero)")
                } else {
                    window.setContentSize(size)
                    if drawing == "flush" { CATransaction.flush() }
                }
                try await ContinuousClock().sleep(until: deadline)
            }
            if drawing == "production" {
                try await compatibilityWait { !window.isPreparingPageResize }
            }
            let ended = CACurrentMediaTime()
            try await presentation(web)
            try await compatibilityWait { (sampler.frames.last?.time ?? 0) >= ended }
            try await sampler.stop()
            try sampler.frames.saveImages(prefix: direct ? "native" : "browser")
            let samples = sampler.frames.samples.filter { $0.time >= began && $0.time <= ended }
            XCTAssertGreaterThan(samples.count, 3, "Capture actual WindowServer frames during resizing")
            let gaps = samples.map(\.gap)
            print("RESIZE_PIXELS drawing=\(drawing) direct=\(direct) duration=\(ended - began) baselineGap=\(baseline.gap) gaps=\(gaps) worstTime=\(samples.max(by: { $0.gap < $1.gap })?.time ?? 0)")
            XCTAssertLessThanOrEqual(gaps.max() ?? 0, baseline.gap + 2,
                                     "The rendered right-edge marker must follow the visible window edge")
        } catch {
            try? await sampler.stop()
            throw error
        }
    }

    private func presentation(_ web: WKWebView, beforeCommit: (@MainActor @Sendable () -> Void)? = nil) async throws {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard web.responds(to: selector) else { throw XCTSkip("Presentation diagnostic unavailable") }
        let presented = XCTestExpectation(description: "WebKit presents its next viewport")
        let completion: @convention(block) () -> Void = {
            MainActor.assumeIsolated { beforeCommit?() }
            presented.fulfill()
        }
        _ = web.perform(selector, with: completion)
        guard await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed else {
            throw NSError(domain: "ResizePresentationTimeout", code: 1)
        }
    }
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
              let factor = info?.first?[.scaleFactor] as? NSNumber else { return }
        let scale = CGFloat(factor.doubleValue)
        let valid = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                           width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !valid.isEmpty else { return }
        // ScreenCaptureKit can retain pixels from the previously wider window
        // outside this frame's content rectangle. Those are not visible content.
        let row = Int(valid.midY) * CVPixelBufferGetBytesPerRow(pixel)
        var firstRed: Int?, lastRed: Int?, rightWindow: Int?
        for x in max(0, Int(ceil(valid.minX)))..<min(width, Int(floor(valid.maxX))) {
            let p = row + x * 4
            let b = Int(bytes[p]), g = Int(bytes[p + 1]), r = Int(bytes[p + 2])
            if r + g + b > 40 { rightWindow = x }
            if r > 180 && g < 110 && b < 100 {
                if firstRed == nil { firstRed = x }
                lastRed = x
            }
        }
        // The CSS marker is 100 points wide. Normalize by its captured width so
        // stream scaling and letterboxing cannot manufacture a resize gap.
        // Losing the marker during a shrink is also a stale viewport; retain that
        // frame rather than silently excluding it from the measured sequence.
        let gap: Double
        if let firstRed, let lastRed, let rightWindow, lastRed > firstRed {
            gap = Double(rightWindow - lastRed) * 100 / Double(lastRed - firstRed + 1)
        } else {
            gap = 10_000
        }
        let snapshot = frames.needsImage(for: gap)
            ? ResizePixelFrames.Image(data: Data(bytes: bytes, count: CVPixelBufferGetBytesPerRow(pixel) * height),
                                      width: width, height: height, stride: CVPixelBufferGetBytesPerRow(pixel)) : nil
        if snapshot != nil { print("RESIZE_CAPTURE_BOUND time=\(time) rect=\(valid) red=\(String(describing: firstRed))...\(String(describing: lastRed)) right=\(String(describing: rightWindow)) gap=\(gap)") }
        if frames.last == nil { print("RESIZE_CAPTURE info=\(String(describing: info?.first))") }
        frames.append(time: time, gap: gap, image: snapshot)
    }
}

private final class ResizePixelFrames: @unchecked Sendable {
    struct Frame { let time: Double; let gap: Double }
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
    func append(time: Double, gap: Double, image: Image?) {
        lock.withLock {
            recorded.append(Frame(time: time, gap: gap))
            if baselineImage == nil { baselineImage = image }
            if gap > worstGap { worstGap = gap; worstImage = image }
        }
    }
    func repeatFrame(_ time: Double) {
        lock.withLock { if let last = recorded.last { recorded.append(Frame(time: time, gap: last.gap)) } }
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
