import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import WebKit
import XCTest
@testable import vane

/// Opt-in end-to-end WindowServer geometry measurement on the reported page.
@MainActor final class WindowResizeResponsiveMotionTests: XCTestCase {
    func testResponsivePageKeepsVisibleWindowMovementWithinTheFrameBudget() async throws {
        try await responsiveMotion(sidebar: false)
    }

    func testResponsivePageKeepsVisibleSidebarMovementWithinTheFrameBudget() async throws {
        try await responsiveMotion(sidebar: true)
    }

    private func observe(_ script: String, in web: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: PageResizeStyle.world) { result in
                continuation.resume(with: result.flatMap { value in
                    guard let value = value as? String else {
                        return .failure(NSError(domain: "ResizeMotionObservation", code: 1))
                    }
                    return .success(value)
                })
            }
        }
    }

    private func baselineSnapshot(_ web: WKWebView) async throws -> (ResizeMotionBaselineSnapshot, String) {
        let width = web.bounds.width, height = web.bounds.height, zoom = web.pageZoom
        let insets = web.safeAreaInsets
        let json: String = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("""
            (()=>{const s=globalThis.__vaneResizeStyle,root=document.documentElement;
              const computed=root?getComputedStyle(root):[];
              const application=\(ResizeMotionDocumentAdmission.script);
              return JSON.stringify({visibilityState:document.visibilityState,readyState:document.readyState,
                visibilityEvents:globalThis.__vaneMotionVisibility??[],observedAt:performance.now(),
                appReady:application.loaded,pendingRoots:application.pendingRoots,pendingSheets:application.pendingSheets,
                appCommits:performance.getEntriesByName('react-root:commit:repo').map(e=>e.startTime),
                active:Boolean(s?.active),
                sheetAdopted:Boolean(s && document.adoptedStyleSheets.includes(s.sheet)),
                sheetDisabled:!s || s.sheet.disabled,
                targetWidth:s?.width??null,targetHeight:s?.height??null,
                innerWidth,innerHeight,documentWidth:root?.getBoundingClientRect().width??0,
                customProperties:Array.from(computed).filter(k=>k.startsWith('--')).length,
                nativeWidth:\(width),nativeHeight:\(height),pageZoom:\(zoom),
                safeAreaTop:\(insets.top),safeAreaLeft:\(insets.left),
                safeAreaBottom:\(insets.bottom),safeAreaRight:\(insets.right)});})()
            """, in: nil, in: PageResizeStyle.world) { result in
                continuation.resume(with: result.flatMap { value in
                    guard let json = value as? String else { return .failure(NSError(domain: "ResizeMotionBaselineSnapshot", code: 1)) }
                    return .success(json)
                })
            }
        }
        return (try JSONDecoder().decode(ResizeMotionBaselineSnapshot.self, from: Data(json.utf8)), json)
    }

    private func admitResizeBaseline(_ web: WKWebView, window: NSWindow, sidebar: Bool) async throws {
        // Baseline admission precedes capture timing. No drag or prime starts here.
        // Each eager GitHub application/partial adds .loaded after its initial
        // React commit, visible rAF, and idle callback. The surrounding chrome
        // and its stylesheets can still initialize after the repo root is ready.
        let readyBy = ContinuousClock.now + .seconds(5)
        PageResizeStyle.warm(web)
        var (snapshot, json) = try await baselineSnapshot(web)
        print("RESPONSIVE_BASELINE sidebar=\(sidebar) stage=initial snapshot=\(json)")
        while true {
            guard ContinuousClock.now < readyBy, NSApp.isActive, window.isKeyWindow, NSApp.keyWindow === window else {
                print("RESPONSIVE_BASELINE sidebar=\(sidebar) stage=unadmitted snapshot=\(json)")
                throw NSError(domain: "ResizeMotionBaselineReadiness", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Baseline viewport/hints were not admitted: \(json)"])
            }
            if snapshot.isReady { break }
            // A host layout can supersede the first warm request. Re-target only
            // when that actual native viewport differs; otherwise observe its ack.
            if !snapshot.targetMatchesNative { PageResizeStyle.warm(web) }
            try await Task.sleep(for: .milliseconds(10))
            (snapshot, json) = try await baselineSnapshot(web)
        }
        print("RESPONSIVE_BASELINE sidebar=\(sidebar) stage=ready snapshot=\(json)")
    }

    private func responsiveMotion(sidebar: Bool) async throws {
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
        _ = try await observe("""
        (()=>{globalThis.__vaneMotionVisibility=[{state:document.visibilityState,time:performance.now()}];
          document.addEventListener('visibilitychange',()=>{
            if(globalThis.__vaneMotionVisibility.length<16)
              globalThis.__vaneMotionVisibility.push({state:document.visibilityState,time:performance.now()});
          });return 'ready';})()
        """, in: web)
        if environment["VANE_RESIZE_PROPERTY_PROBE"] == "1" {
            _ = try await observe("""
            (()=>{const samples=globalThis.__vaneMotionProperties=[];
              addEventListener('resize',()=>{if(samples.length>=4)return;
                const began=performance.now(),style=getComputedStyle(document.documentElement);
                const names=Array.from(style).filter(k=>k.startsWith('--'));
                samples.push({width:innerWidth,height:innerHeight,began,ended:performance.now(),
                  count:names.length,hints:names.filter(k=>k.startsWith('--vane-resize-')).length,
                  visibility:document.visibilityState});});return 'ready';})()
            """, in: web)
        }
        if sidebar {
            // A fixture-only marker lets WindowServer pixels measure the page seam.
            _ = try await web.evaluateJavaScript("""
            (()=>{const marker=document.createElement('div');marker.id='vane-motion-fixture-seam';marker.style.cssText=
              'position:fixed;left:0;top:0;bottom:0;width:3px;background:rgb(255,0,255);z-index:2147483647;pointer-events:none';
              document.documentElement.append(marker);return true;})()
            """)
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
            // Admit an existing resize-ready surface, independent of AppKit's
            // initial show animation. The first buffer still begins in timing.
            window.animationBehavior = .none
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
            try await ResizeNativeWindowAdmission.wait(window, web: web, layout: true)
            let owner = ResponsiveMotionOwner()
            let observations = [
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        owner.interrupted = true
                        print("RESPONSIVE_FOREGROUND time=\(CACurrentMediaTime()) active=\(app.isActive) hidden=\(app.isHidden) key=\(window.isKeyWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
                    }
                },
                NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: app, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        owner.interrupted = true
                        print("RESPONSIVE_FOREGROUND time=\(CACurrentMediaTime()) active=\(app.isActive) hidden=\(app.isHidden) key=\(window.isKeyWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
                    }
                }
            ]
            defer { observations.forEach(NotificationCenter.default.removeObserver) }
#if DEBUG
            let timing = ResizeMotionTimingLog(sidebar: sidebar)
            let traceTiming = environment["VANE_RESIZE_TIMING"] == "1"
            if traceTiming { ResizeTimingDiagnostics.sink = { timing.append($0, time: $1, width: $2, height: $3) } }
            defer {
                if traceTiming { ResizeTimingDiagnostics.sink = nil; timing.dump() }
            }
#else
            let traceTiming = false
#endif
            try await admitResizeBaseline(web, window: window, sidebar: sidebar)
            let presented = XCTestExpectation(description: "Initial responsive page presentation")
            let callback: @convention(block) () -> Void = { presented.fulfill() }
            _ = web.perform(NSSelectorFromString("_doAfterNextPresentationUpdate:"), with: callback)
            guard await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed else {
                throw NSError(domain: "ResizeMotionPresentationReadiness", code: 1)
            }
            let sampler = ResponsiveMotionSampler(sidebar: sidebar, traceTiming: traceTiming)
            defer { if traceTiming { sampler.samples.dumpTiming(sidebar: sidebar) } }
            let profile = try ResizeMotionProfile.begin(environment: environment, web: web, sidebar: sidebar)
            try await sampler.start(window)
            do {
                guard !owner.interrupted, app.isActive, window.isKeyWindow,
                      app.keyWindow === window, web.window === window,
                      window.occlusionState.contains(.visible) else {
                    throw NSError(domain: "ResizeMotionForegroundReadiness", code: 1)
                }
                // Recheck only scalar document state here; do not force a layout
                // or warm another viewport immediately before timing the drag.
                let appJSON = try await observe("JSON.stringify(\(ResizeMotionDocumentAdmission.script))", in: web)
                print("RESPONSIVE_APP sidebar=\(sidebar) stage=predrag state=\(appJSON)")
                let documentJSON = try await observe("JSON.stringify([document.visibilityState,document.readyState])", in: web)
                print("RESPONSIVE_DOCUMENT sidebar=\(sidebar) stage=predrag state=\(documentJSON)")
                guard try JSONDecoder().decode([String].self, from: Data(documentJSON.utf8)) == ["visible", "complete"],
                      (try JSONSerialization.jsonObject(with: Data(appJSON.utf8)) as? [String: Any])?["loaded"] as? Bool == true,
                      !owner.interrupted, app.isActive, window.isKeyWindow, app.keyWindow === window,
                      web.window === window, window.occlusionState.contains(.visible) else {
                    throw NSError(domain: "ResizeMotionDocumentReadiness", code: 1)
                }
                let baselineWidth = try XCTUnwrap(sampler.samples.values.last).width
                let began = CACurrentMediaTime()
#if DEBUG
                if traceTiming { timing.append("fixture.began", time: began, width: baselineWidth) }
                let nativeObservation = traceTiming ? NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            ResizeTimingDiagnostics.record("fixture.native.didResize", width: store.window?.frame.width)
                        }
                    } : nil
                defer { if let nativeObservation { NotificationCenter.default.removeObserver(nativeObservation) } }
#endif
                let frameHeight = window.frame.height
                print("RESPONSIVE_INITIAL frame=\(window.frame.size) content=\(window.contentView?.bounds.size ?? .zero) page=\(web.bounds.size)")
                if sidebar { window.beginSidebarResize(store) }
                else { window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.midY)) }
#if DEBUG
                ResizeTimingDiagnostics.record("fixture.begin.returned")
#endif
                let widths = sidebar
                    ? Array(stride(from: 228, through: 500, by: 2))
                        + Array(stride(from: 498, through: 164, by: -2))
                        + Array(stride(from: 166, through: 228, by: 2))
                    : Array(stride(from: 900, through: 1350, by: 2))
                        + Array(stride(from: 1348, through: 900, by: -2))
                for width in widths {
                    guard ContinuousClock.now < activeBy else { throw NSError(domain: "ResizeMotionActiveBudget", code: 1) }
                    let next = ContinuousClock.now + .milliseconds(8)
#if DEBUG
                    ResizeTimingDiagnostics.record("fixture.input", width: CGFloat(width))
#endif
                    if sidebar {
                        if !window.updateSidebarResize(CGFloat(width)) {
                            SidebarWidth.shared.setLiveWidth(CGFloat(width), available: host.bounds.width)
                        }
                    }
                    else {
                        let accepted = window.proposedPageResize(NSSize(width: CGFloat(width), height: frameHeight))
                        if accepted != window.frame.size {
                            window.setFrame(NSRect(origin: window.frame.origin, size: accepted), display: false)
                        }
                    }
#if DEBUG
                    ResizeTimingDiagnostics.record("fixture.input.returned", width: window.frame.width,
                                                   height: SidebarWidth.shared.width)
#endif
                    try await ContinuousClock().sleep(until: next)
                }
                if sidebar {
                    if !window.endSidebarResize(228, completion: {}) {
                        SidebarWidth.shared.setLiveWidth(228, available: host.bounds.width)
                    }
                } else { window.endPageResize() }
                try await compatibilityWait {
                    if sidebar { return !window.isPreparingPageResize && abs(web.bounds.width - 661) < 1 }
                    return !window.isPreparingPageResize && abs(window.frame.width - 900) < 1
                }
                let ended = CACurrentMediaTime()
#if DEBUG
                if traceTiming { timing.append("fixture.ended", time: ended) }
#endif
                window.endPageResize()
                try await sampler.stop()
                try await profile?.finish(began: began, ended: ended, web: web)
                if environment["VANE_RESIZE_PROPERTY_PROBE"] == "1" {
                    let counts = try await observe("JSON.stringify(globalThis.__vaneMotionProperties)", in: web)
                    print("RESPONSIVE_PROPERTIES sidebar=\(sidebar) samples=\(counts)")
                }
                let finalAppJSON = try await observe("JSON.stringify(\(ResizeMotionDocumentAdmission.script))", in: web)
                print("RESPONSIVE_APP sidebar=\(sidebar) stage=afterdrag state=\(finalAppJSON)")
                let samples = sampler.samples.values.filter { $0.time >= began && $0.time <= ended }
                var changes = [ResponsiveMotionSamples.Frame(time: began, width: baselineWidth)]
                for sample in samples where abs(sample.width - changes.last!.width) > 0.5 { changes.append(sample) }
                let pauses = zip(changes, changes.dropFirst()).map { ($1.time - $0.time) * 1000 }.sorted()
                let steps = zip(changes, changes.dropFirst()).map { abs($1.width - $0.width) }
                let p95 = pauses.isEmpty ? .infinity : pauses[Int(Double(pauses.count - 1) * 0.95)]
                let longest = zip(changes, changes.dropFirst()).map { previous, next in
                    (pause: (next.time - previous.time) * 1000, elapsed: previous.time - began,
                     from: previous.width, to: next.width)
                }.sorted { $0.pause > $1.pause }.prefix(5)
                print("RESPONSIVE_LONGEST \(longest)")
                print("RESPONSIVE_WINDOWSERVER sidebar=\(sidebar) changes=\(changes.count-1) maxPauseMS=\(pauses.last ?? .infinity) p95PauseMS=\(p95) maxStep=\(steps.max() ?? .infinity)")
                XCTAssertFalse(owner.interrupted, "Actual foreground admission must hold throughout capture")
                XCTAssertGreaterThan(changes.count, 10)
                if sidebar {
                    XCTAssertGreaterThanOrEqual(changes.map(\.width).max() ?? 0, 490)
                    XCTAssertLessThanOrEqual(changes.map(\.width).min() ?? 1000, 180)
                    XCTAssertEqual(window.frame.width, 900)
                } else { XCTAssertGreaterThanOrEqual(changes.map(\.width).max() ?? 0, 1300) }
                XCTAssertLessThanOrEqual(pauses.last ?? .infinity, 80, "Avoid the measured170ms page-layout stalls")
                XCTAssertLessThanOrEqual(p95, 25)
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

#if DEBUG
@MainActor private final class ResizeMotionTimingLog {
    private struct Entry {
        let event: String
        let time: Double
        let width: CGFloat?
        let height: CGFloat?
    }
    private let sidebar: Bool
    private var entries: [Entry] = []
    private var dropped = 0
    init(sidebar: Bool) { self.sidebar = sidebar; entries.reserveCapacity(8192) }
    func append(_ event: String, time: Double, width: CGFloat? = nil, height: CGFloat? = nil) {
        guard entries.count < 20000 else { dropped += 1; return }
        entries.append(Entry(event: event, time: time, width: width, height: height))
    }
    func dump() {
        for entry in entries {
            print("RESIZE_TIMING sidebar=\(sidebar) t=\(entry.time) event=\(entry.event) width=\(entry.width.map { String(Double($0)) } ?? "nil") height=\(entry.height.map { String(Double($0)) } ?? "nil")")
        }
        print("RESIZE_TIMING_END sidebar=\(sidebar) events=\(entries.count) dropped=\(dropped)")
    }
}
#endif

private final class ResponsiveMotionSamples: @unchecked Sendable {
    struct Frame { let time: Double; let width: Double }
    let queue = DispatchQueue(label: "vane.resize.responsive-motion")
    private let lock = NSLock()
    private var recorded: [Frame] = []
    private struct CaptureTiming {
        let time: Double
        let received: Double
        let status: Int
        let width: Double?
    }
    private var captureTiming: [CaptureTiming] = []
    private var droppedTiming = 0
    var values: [Frame] { lock.withLock { recorded } }
    func append(_ frame: Frame) { lock.withLock { recorded.append(frame) } }
    func recordTiming(time: Double, received: Double, status: Int, width: Double?) {
        lock.withLock {
            guard captureTiming.count < 20000 else { droppedTiming += 1; return }
            captureTiming.append(CaptureTiming(time: time, received: received, status: status, width: width))
        }
    }
    func dumpTiming(sidebar: Bool) {
        let (capture, parsed, dropped) = lock.withLock { (captureTiming, recorded, droppedTiming) }
        for sample in capture {
            print("RESIZE_CAPTURE sidebar=\(sidebar) pts=\(sample.time) received=\(sample.received) status=\(sample.status) windowWidth=\(sample.width.map(String.init(describing:)) ?? "nil")")
        }
        for sample in parsed {
            print("RESIZE_CAPTURE_PARSED sidebar=\(sidebar) pts=\(sample.time) width=\(sample.width)")
        }
        print("RESIZE_CAPTURE_END sidebar=\(sidebar) samples=\(capture.count) parsed=\(parsed.count) dropped=\(dropped)")
    }
}

@MainActor private final class ResponsiveMotionSampler: NSObject, SCStreamOutput {
    nonisolated let samples = ResponsiveMotionSamples()
    private var stream: SCStream?
    nonisolated let sidebar: Bool
    nonisolated let traceTiming: Bool
    init(sidebar: Bool, traceTiming: Bool) {
        self.sidebar = sidebar; self.traceTiming = traceTiming; super.init()
    }
    func start(_ window: NSWindow) async throws {
#if DEBUG
        ResizeTimingDiagnostics.record("capture.start.begin")
#endif
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = 1700
        config.height = 800
        config.showsCursor = false
        config.captureDynamicRange = .SDR
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 8
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples.queue)
        stream = capture
        do {
            try await capture.startCapture()
#if DEBUG
            ResizeTimingDiagnostics.record("capture.start.returned")
#endif
            try await compatibilityWait { !self.samples.values.isEmpty }
#if DEBUG
            ResizeTimingDiagnostics.record("capture.firstSample.admitted")
#endif
        } catch { try? await capture.stopCapture(); stream = nil; throw error }
    }
    func stop() async throws {
        if let stream { try await stream.stopCapture(); self.stream = nil; samples.queue.sync {} }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let received = traceTiming ? CACurrentMediaTime() : 0
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { return }
        if traceTiming {
            let rect = (info[.screenRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            samples.recordTiming(time: CMTimeGetSeconds(sample.presentationTimeStamp), received: received,
                                 status: status, width: rect.map { Double($0.width) })
        }
        guard status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.idle.rawValue,
              let dictionary = info[.screenRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return }
        let time = CMTimeGetSeconds(sample.presentationTimeStamp)
        guard time.isFinite, rect.width > 0 else { return }
        if sidebar {
            guard let pixel = sample.imageBuffer,
                  let content = info[.contentRect] as? NSDictionary,
                  let valid = CGRect(dictionaryRepresentation: content as CFDictionary),
                  let scale = info[.scaleFactor] as? NSNumber,
                  let contentScale = info[.contentScale] as? NSNumber else { return }
            let pixelsPerPoint = scale.doubleValue * contentScale.doubleValue
            guard pixelsPerPoint > 0 else { return }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return }
            let origin = valid.minX * scale.doubleValue
            let left = max(0, Int(ceil(origin)))
            let right = min(CVPixelBufferGetWidth(pixel), Int(floor(valid.maxX * scale.doubleValue)))
            let y = Int(valid.midY * scale.doubleValue)
            guard y >= 0, y < CVPixelBufferGetHeight(pixel), left < right else { return }
            let row = y * CVPixelBufferGetBytesPerRow(pixel)
            for x in left..<right {
                let p = row + x * 4
                if Int(bytes[p]) > Int(bytes[p + 1]) + 80 && Int(bytes[p + 2]) > Int(bytes[p + 1]) + 80 {
                    samples.append(.init(time: time, width: (Double(x) - origin) / pixelsPerPoint))
                    return
                }
            }
        } else { samples.append(.init(time: time, width: rect.width)) }
    }
}

/// Public page initialization, separate from the resized outcome under test.
enum ResizeMotionDocumentAdmission {
    static let script = """
    (()=>{
      const roots=Array.from(document.querySelectorAll('react-app,react-partial'))
        .filter(e=>e.getAttribute('data-lazy')!=='true');
      const pendingRoots=roots.filter(e=>!e.classList.contains('loaded'))
        .map(e=>e.getAttribute('app-name')??e.getAttribute('partial-name'));
      const pendingSheets=Array.from(document.querySelectorAll('link[rel="stylesheet"]'))
        .filter(e=>e.href && !e.disabled && e.sheet===null).map(e=>e.href);
      return {loaded:Boolean(document.querySelector('react-app[app-name="repo"].loaded')) &&
        pendingRoots.length===0 && pendingSheets.length===0,
        pendingRoots:pendingRoots.slice(0,16),pendingSheets:pendingSheets.slice(0,16),
        sheets:document.styleSheets.length,
        commits:performance.getEntriesByName('react-root:commit:repo').slice(-16).map(e=>e.startTime),
        now:performance.now()};
    })()
    """
}

/// Observable baseline readiness, including native-to-CSS pixel rounding. A failed
/// sample is diagnostic evidence, never permission to measure an unadmitted drag.
struct ResizeMotionBaselineSnapshot: Decodable {
    let visibilityState: String
    let readyState: String
    let appReady: Bool
    let active: Bool
    let sheetAdopted: Bool
    let sheetDisabled: Bool
    let targetWidth: Double?
    let targetHeight: Double?
    let innerWidth: Double
    let innerHeight: Double
    let documentWidth: Double
    let customProperties: Int
    let nativeWidth: Double
    let nativeHeight: Double
    let pageZoom: Double
    let safeAreaTop: Double
    let safeAreaLeft: Double
    let safeAreaBottom: Double
    let safeAreaRight: Double

    var targetMatchesNative: Bool {
        guard let targetWidth, let targetHeight,
              let viewport = PageResizeStyle.viewportSize(NSSize(width: nativeWidth, height: nativeHeight),
                insets: NSEdgeInsets(top: safeAreaTop, left: safeAreaLeft, bottom: safeAreaBottom, right: safeAreaRight),
                zoom: pageZoom) else { return false }
        return abs(targetWidth - viewport.width) < 0.001
            && abs(targetHeight - viewport.height) < 0.001
    }

    var isReady: Bool {
        guard let targetWidth, let targetHeight else { return false }
        return visibilityState == "visible" && readyState == "complete" && appReady
            && active && sheetAdopted && !sheetDisabled && targetMatchesNative
            // innerWidth/innerHeight expose integer CSS pixels even when AppKit's
            // viewport divided by page zoom has a fractional native pixel.
            && abs(innerWidth - targetWidth) <= 1 && abs(innerHeight - targetHeight) <= 1
            && documentWidth > 0
    }
}
