import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WindowResizeLayoutTests: XCTestCase {
    func testHiddenApplicationIsUnhiddenBeforeResizeAdmission() async throws {
        try await resizeFixture(capture: false, hideBeforeAdmission: true)
    }

    func testMissingPaintMarkerCannotBeAnAdmittedBaseline() {
        XCTAssertFalse(ResizePixelFrames.Frame(time: 0, gap: 10_000, markerGap: 10_000, left: 0, extent: .zero).isPaintedBaseline)
        XCTAssertFalse(ResizePixelFrames.Frame(time: 0, gap: 64, markerGap: 0, left: 0, extent: .zero).isPaintedBaseline)
        XCTAssertFalse(ResizePixelFrames.Frame(time: 0, gap: 0, markerGap: 10_000, left: 0, extent: .zero).isPaintedBaseline)
        XCTAssertTrue(ResizePixelFrames.Frame(time: 0, gap: 1.714, markerGap: 1.714, left: 0, extent: .zero).isPaintedBaseline)
    }

    func testPaintCaptureDoesNotTreatTranslucentPixelsOutsideOpaqueWindowAsAGap() throws {
        let sampler = ResizePixelSampler()
        let pixel = try paintCapturePixel(blankColumns: 0)
        sampler.record(pixel, valid: CGRect(x: 0, y: 0, width: 64, height: 4), pixelsPerPoint: 1, time: 1)
        XCTAssertEqual(sampler.frames.samples.count, 1, "Keep the capture, including a stale wider content rectangle")
        XCTAssertEqual(sampler.frames.last?.gap, 0)
    }

    func testPaintCaptureStillCountsAnOpaqueBlankStrip() throws {
        let sampler = ResizePixelSampler()
        let pixel = try paintCapturePixel(blankColumns: 4)
        sampler.record(pixel, valid: CGRect(x: 0, y: 0, width: 64, height: 4), pixelsPerPoint: 1, time: 1)
        XCTAssertEqual(sampler.frames.last?.gap, 4)
    }

    func testPaintCaptureStillRejectsAnEntirelyMissingPage() throws {
        let sampler = ResizePixelSampler()
        let pixel = try paintCapturePixel(blankColumns: 40)
        sampler.record(pixel, valid: CGRect(x: 0, y: 0, width: 64, height: 4), pixelsPerPoint: 1, time: 1)
        XCTAssertEqual(sampler.frames.last?.gap, 10_000)
    }

    private func paintCapturePixel(blankColumns: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 4, kCVPixelFormatType_32BGRA,
                                          nil, &result), kCVReturnSuccess)
        let pixel = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self))
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<4 {
            for x in 0..<64 {
                let p = y * stride + x * 4
                // The opaque window ends at x=39; SCK's wider extent can retain
                // translucent RGB outside it. Blue body, then an opaque gray gap.
                let colour: [UInt8] = x < 40 - blankColumns ? [77, 50, 23, 254]
                    : x < 40 ? [45, 45, 45, 255] : [90, 90, 90, 128]
                for channel in 0..<4 { bytes[p + channel] = colour[channel] }
            }
        }
        return pixel
    }

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
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced,
                      "Normal-motion sidebar capture requires system Reduce Motion off")
        XCTAssertFalse(Motion.reduced)
        try await resizeFixture(capture: true, slowResize: true, sidebarToggle: true)
    }

    func testClosingSidebarWithReducedMotionKeepsTheExpandingPagePainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        defer { BatterySaver.shared.setMode(mode) }
        XCTAssertTrue(Motion.reduced)
        try await resizeFixture(capture: true, slowResize: true, sidebarToggle: true)
    }

    func testContinuousSidebarDragKeepsThePagePaintedThroughReversals() async throws {
        try await resizeFixture(capture: true, slowResize: true, sidebarDrag: true)
    }

    func testQueuedNativeGeometryBeforeSidebarDragKeepsThePagePainted() async throws {
        try await resizeFixture(capture: true, slowResize: true, sidebarDrag: true, queuedGeometry: true)
    }

    func testCornerResizeKeepsTheShrinkingAxisPaintedWhileTheOtherAxisGrows() async throws {
        try await resizeFixture(capture: true, slowResize: true, mixedAxes: true)
    }

    func testLibraryNavigationKeepsTheResponsiveDocumentPainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced, "Requires normal motion")
        try await resizeFixture(capture: true, libraryNavigation: true)
    }

    func testProductionParentRefreshKeepsLibraryViewportOwnedAndPainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced, "Requires normal motion")
        try await resizeFixture(capture: true, libraryNavigation: true, refreshLibraryParent: true)
    }

    func testWideSidebarLibraryNavigationKeepsTheResponsiveDocumentPainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced, "Requires normal motion")
        try await resizeFixture(capture: true, libraryNavigation: true, librarySidebarWidth: 438)
    }

    func testFloatingLibraryNavigationKeepsTheResponsiveDocumentPainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced, "Requires normal motion")
        try await resizeFixture(capture: true, libraryNavigation: true, libraryFloating: true)
    }

    func testRapidLibraryReversalsKeepTheResponsiveDocumentPainted() async throws {
        TestEnvironment.prepare()
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(mode) }
        try XCTSkipIf(Motion.spaceReduced, "Requires normal motion")
        try await resizeFixture(capture: true, libraryNavigation: true, rapidLibrary: true)
    }

    private func resizeFixture(capture: Bool, slowResize: Bool = false, sidebarToggle: Bool = false,
                               mixedAxes: Bool = false, sidebarDrag: Bool = false,
                               queuedGeometry: Bool = false, hideBeforeAdmission: Bool = false,
                               libraryNavigation: Bool = false, libraryFloating: Bool = false, rapidLibrary: Bool = false,
                               librarySidebarWidth: CGFloat = 228, refreshLibraryParent: Bool = false) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let store = TabStore(isPrivate: true)
            let sidebarWidth = SidebarWidth.shared.width
            SidebarWidth.shared.width = librarySidebarWidth
            defer { SidebarWidth.shared.width = sidebarWidth }
            store.sidebarShown = !libraryFloating
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
            let admittedFrame = window.frame
            if hideBeforeAdmission {
                app.hide(nil)
                try await compatibilityWait { app.isHidden }
            }
            try await ResizeNativeWindowAdmission.wait(window, web: tab.web, layout: true)
            XCTAssertFalse(app.isHidden)
            XCTAssertEqual(window.frame, admittedFrame, "Admission must not prime a different viewport")
            let delay = slowResize ? "<script>addEventListener('resize',()=>{let end=performance.now()+120;while(performance.now()<end){}})</script>" : ""
            let variables = (0..<160).map { "--resize-fixture-\($0):\($0)px;" }.joined()
            let html = "<html><title>Resize ready</title><style>:root{\(variables)}body{margin:0;background:#17324d}aside{position:fixed;right:0;top:0;width:100px;height:100vh;background:#f04020}</style><body><aside></aside>\(delay)</body></html>"
            tab.web.loadHTMLString(html, baseURL: nil)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Resize ready" }
            for direct in [false, true] {
                if (sidebarToggle || sidebarDrag || libraryNavigation) && direct { continue }
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
                if libraryNavigation {
                    if refreshLibraryParent { try await verifyProductionLibraryPermissions(window, store: store, web: page) }
                    try await captureLibraryPixels(window, store: store, web: page, rapid: rapidLibrary,
                                                   refreshParent: refreshLibraryParent)
                } else if sidebarToggle {
                    try await captureSidebarPixels(window, store: store, web: page)
                } else if capture {
                    try await captureResizePixels(window, web: page, direct: direct,
                                                  proposalInterval: slowResize ? .milliseconds(40) : .milliseconds(8),
                                                  mixedAxes: mixedAxes, sidebarStore: sidebarDrag ? store : nil,
                                                  queuedGeometry: queuedGeometry)
                } else {
                    for width: CGFloat in [1100, 470, 800, 1200, 900, 1100, 900] {
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

    private func verifyProductionLibraryPermissions(_ window: VaneWindow, store: TabStore, web: WKWebView) async throws {
#if DEBUG
        var parentEvaluations = 0
        let previousSink = ResizeTimingDiagnostics.sink
        ResizeTimingDiagnostics.sink = { event, time, width, height in
            if event == "sidebar.body.browser" { parentEvaluations += 1 }
            previousSink?(event, time, width, height)
        }
        defer { ResizeTimingDiagnostics.sink = previousSink }
#endif
        Motion.instant { store.librarySwipeProgress = 0.4; store.findOpen = true }
        func pending(_ view: NSView) -> Bool {
            if let bridge = view as? LibraryPaintView { return !bridge.isSettled }
            return view.subviews.contains(where: pending)
        }
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
            return !pending(window.contentView!) && (web.superview as? WebHost)?.resizeLayout.enabled == false
        }
        let host = try XCTUnwrap(web.superview as? WebHost)
        let owner = try XCTUnwrap(host.libraryNavigationPaintOwner)
        let native = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0), apply: { _, _ in })
        XCTAssertNil(native, "Native resize remains excluded during a held Library gesture")
        native?.cancel()
        var paints: [@MainActor @Sendable () -> Void] = []
        let navigation = try XCTUnwrap(LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 0), apply: { _, _ in }),
            "Production parent metadata must permit Library paint ownership while excluding native resize")
        defer { navigation.cancel() }
        navigation.start()
        // Find refreshes BrowserWindow, but unchanged resize metadata can be
        // diff-elided before updateNSView. Observe the production parent itself,
        // not an unrelated representable update or the outcome under assertion.
#if DEBUG
        let evaluation = parentEvaluations
#endif
        Motion.instant { store.findOpen = false }
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
#if DEBUG
            return parentEvaluations > evaluation
#else
            return false
#endif
        }
        XCTAssertTrue(navigation.request(frame: window.frame, sidebarWidth: 0),
                      "Refreshing the production parent must not cancel Library's active viewport")
        XCTAssertEqual(web.autoresizingMask, [])
        XCTAssertNotNil(host.pageResizeOwnershipWillChange)
#if DEBUG
        let spaceEvaluation = parentEvaluations
#endif
        Motion.instant { store.spaceGesture.swiping = true; store.findOpen = true }
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
#if DEBUG
            return parentEvaluations > spaceEvaluation
#else
            return false
#endif
        }
        XCTAssertFalse(host.resizeLayout.enabled)
        XCTAssertFalse(host.resizeLayout.permitsLibraryNavigation)
        XCTAssertFalse(navigation.request(frame: window.frame, sidebarWidth: 0),
                       "A Space handoff must revoke the existing Library paint owner too")
        XCTAssertFalse(navigation.isPreparing)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertNil(host.pageResizeOwnershipWillChange)
        let spaceNavigation = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
            navigation: .init(owner: owner, leading: 0), apply: { _, _ in })
        XCTAssertNil(spaceNavigation, "A Space handoff must still exclude Library viewport ownership")
        spaceNavigation?.cancel()
        Motion.instant { store.spaceGesture.swiping = false; store.findOpen = false; store.librarySwipeProgress = nil }
        try await compatibilityWait { window.contentView?.layoutSubtreeIfNeeded(); return !pending(window.contentView!) }
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertNil(host.pageResizeOwnershipWillChange)
        try await presentation(web)
    }

    private func captureLibraryPixels(_ window: VaneWindow, store: TabStore, web: WKWebView, rapid: Bool, refreshParent: Bool = false) async throws {
        try await ResizeNativeWindowAdmission.wait(window, web: web)
        let owner = ResizeCaptureOwner(window: window, stage: "Library navigation")
        let observations = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("window resigned key") } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("application resigned active") } }
        ]
        defer { observations.forEach(NotificationCenter.default.removeObserver) }
#if DEBUG
        let trace = ProcessInfo.processInfo.environment["VANE_LIBRARY_PAINT_TRACE"] == "1"
        var events: [String] = []
        let previousStateSink = ResizeTimingDiagnostics.stateSink
        let previousSink = ResizeTimingDiagnostics.sink
        if trace {
            ResizeTimingDiagnostics.sink = { event, time, width, height in
                guard events.count < 20000 else { return }
                if event.hasPrefix("library.") || event == "sidebar.body.browser"
                    || event.hasPrefix("buffer.") {
                    events.append("LIBRARY_TIMING t=\(time) event=\(event) width=\(String(describing: width)) height=\(String(describing: height))")
                }
            }
            ResizeTimingDiagnostics.stateSink = { event, time, fields in
                guard events.count < 20000 else { return }
                if event.hasPrefix("library.") || event == "buffer.prepare.before" || event.hasPrefix("buffer.publish") {
                    events.append("LIBRARY_TRACE t=\(time) event=\(event) fields=\(fields.filter { ["requestedSidebar", "publishedSidebar", "pending", "ending", "generation", "page.0.desired", "page.0.prepared", "page.0.painted", "page.0.visible"].contains($0.key) })")
                }
            }
        }
        defer {
            if trace {
                ResizeTimingDiagnostics.stateSink = previousStateSink
                ResizeTimingDiagnostics.sink = previousSink
                events.forEach { print($0) }
            }
        }
#endif
        let sampler = ResizePixelSampler()
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            guard baseline.isPaintedBaseline else { throw NSError(domain:"LibraryPaintAdmission",code:1) }
            let began = CACurrentMediaTime()
            let travel = Library.panelWidth(section: Library.shared.section,
                spaces: ProfileManager.shared.allSpaces.count, private: store.isPrivate,
                available: window.contentView!.bounds.width) - (store.sidebarShown ? SidebarWidth.inWindow(store) : Look.cardGap)
            // Match the existing resize cadence gate's 2pt / 8ms input. The
            // separate rapid case retains the original 20-sample reversals.
            let stepsPerStroke = rapid ? 20 : max(1, Int(ceil(abs(travel) / 2)))
            for _ in 0..<3 {
                for step in 0...stepsPerStroke {
#if DEBUG
                    if trace { events.append("LIBRARY_TIMING t=\(CACurrentMediaTime()) event=library.input width=nil height=nil") }
#endif
                    Motion.instant {
                        store.librarySwipeProgress = CGFloat(step) / CGFloat(stepsPerStroke)
                        if refreshParent && step == stepsPerStroke / 2 { store.findOpen.toggle() }
                    }
                    window.contentView?.layoutSubtreeIfNeeded()
#if DEBUG
                    if trace { events.append("LIBRARY_TIMING t=\(CACurrentMediaTime()) event=library.layout.done width=nil height=nil") }
#endif
                    try await Task.sleep(for:.milliseconds(8))
                }
                for step in (0...stepsPerStroke).reversed() {
#if DEBUG
                    if trace { events.append("LIBRARY_TIMING t=\(CACurrentMediaTime()) event=library.input width=nil height=nil") }
#endif
                    Motion.instant {
                        store.librarySwipeProgress = CGFloat(step) / CGFloat(stepsPerStroke)
                        if refreshParent && step == stepsPerStroke / 2 { store.findOpen.toggle() }
                    }
                    window.contentView?.layoutSubtreeIfNeeded()
#if DEBUG
                    if trace { events.append("LIBRARY_TIMING t=\(CACurrentMediaTime()) event=library.layout.done width=nil height=nil") }
#endif
                    try await Task.sleep(for:.milliseconds(8))
                }
            }
            Motion.instant { store.librarySwipeProgress = nil }
            func pending(_ view: NSView) -> Bool {
                if let bridge = view as? LibraryPaintView { return !bridge.isSettled }
                return view.subviews.contains(where: pending)
            }
            try await compatibilityWait { !pending(window.contentView!) }
            try await presentation(web)
            try await sampler.captureFinalFrame(window)
            try await sampler.stop()
            try sampler.frames.saveImages(prefix:"library-\(ProcessInfo.processInfo.processIdentifier)")
            let samples = sampler.frames.samples.filter { $0.time >= began }
            let maximum = samples.map(\.gap).max() ?? 0
            print("LIBRARY_PIXELS samples=\(samples.count) baselineGap=\(baseline.gap) maxGap=\(maximum)")
            var changes = [ResizePixelFrames.Frame(time: began, gap: baseline.gap,
                markerGap: baseline.markerGap, left: baseline.left, extent: baseline.extent)]
            for sample in samples where abs(sample.left - changes.last!.left) > 0.5 { changes.append(sample) }
            let pauses = zip(changes,changes.dropFirst()).map { ($1.time-$0.time)*1000 }.sorted()
            // SCK's Float content scale introduces sub-micro-point roundoff.
            let steps = zip(changes,changes.dropFirst()).map { (abs($1.left-$0.left) * 1000).rounded() / 1000 }
            let p95 = pauses.isEmpty ? .infinity : pauses[Int(Double(pauses.count-1)*0.95)]
            print("LIBRARY_MOTION rapid=\(rapid) changes=\(changes.count) p95=\(p95) max=\(pauses.last ?? .infinity) step=\(steps.max() ?? .infinity)")
            XCTAssertLessThanOrEqual(p95,25)
            XCTAssertLessThanOrEqual(pauses.last ?? .infinity,80)
            if !rapid { XCTAssertLessThanOrEqual(steps.max() ?? .infinity,24) }
            XCTAssertFalse(owner.interrupted, "Library capture must retain actual foreground ownership")
            XCTAssertGreaterThanOrEqual(changes.map(\.left).max() ?? 0, 368)
            if travel < 0 {
                XCTAssertLessThanOrEqual(changes.map(\.left).min() ?? .infinity, baseline.left + travel + 2)
            }
            XCTAssertEqual(try XCTUnwrap(sampler.frames.last).left, baseline.left, accuracy: 1)
            XCTAssertGreaterThan(samples.count,3)
            XCTAssertLessThanOrEqual(maximum, baseline.gap + 2, "Library movement must keep actual document paint up to the card edge")
            XCTAssertLessThanOrEqual(try XCTUnwrap(sampler.frames.last).markerGap,baseline.markerGap+2)
        } catch { try? await sampler.stop(); throw error }
    }

    private func captureSidebarPixels(_ window: VaneWindow, store: TabStore, web: WKWebView) async throws {
        try await ResizeNativeWindowAdmission.wait(window, web: web)
        let originalFrame = window.frame
        let originalWidth = web.bounds.width
        let owner = ResizeCaptureOwner(window: window, stage: "sidebar stream start")
        let observations = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("window resigned key") } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("application resigned active") } }
        ]
        defer { observations.forEach(NotificationCenter.default.removeObserver) }
        let sampler = ResizePixelSampler()
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            guard baseline.isPaintedBaseline else { throw NSError(domain: "ResizePaintBaselineReadiness", code: 1) }
            let reducedMotion = Motion.reduced
            let began = CACurrentMediaTime()
            owner.stage = "sidebar transition"
            store.toggleSidebar()
            // Capture the whole transition, including frames before its endpoint.
            try await Task.sleep(for: .milliseconds(650))
            let ended = CACurrentMediaTime()
            owner.stage = "sidebar final presentation"
            try await presentation(web)
            try await sampler.captureFinalFrame(window)
            let coverageEnded = CACurrentMediaTime()
            try await sampler.stop()
            try sampler.frames.saveImages(prefix: "sidebar-\(ProcessInfo.processInfo.processIdentifier)")
            let coverage = sampler.frames.samples.filter { $0.time >= began && $0.time <= coverageEnded }
            let samples = coverage.filter { $0.time <= ended }
            let maximum = coverage.map(\.gap).max() ?? 0
            print("SIDEBAR_PIXELS reducedMotion=\(reducedMotion) samples=\(samples.count) baselineGap=\(baseline.gap) maxGap=\(maximum) width=\(originalWidth)->\(web.bounds.width)")
            XCTAssertFalse(owner.interrupted, "Sidebar capture must retain actual foreground ownership")
            if reducedMotion {
                // Static content can stop producing stream callbacks after its
                // immediate update. Keep capturing that update and the final paint.
                XCTAssertFalse(samples.isEmpty, "Capture the immediate reduced-motion update")
            } else {
                XCTAssertGreaterThan(samples.count, 3, "Capture intermediate normal-motion frames")
            }
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
                                     proposalInterval: Duration, mixedAxes: Bool = false, sidebarStore: TabStore? = nil,
                                     queuedGeometry: Bool = false) async throws {
        // Diagnostic reference: the original geometry-only path must remain RED.
        let baselineControl = ProcessInfo.processInfo.environment["VANE_RESIZE_BASELINE"] == "1"
        try await ResizeNativeWindowAdmission.wait(window, web: web)
        let owner = ResizeCaptureOwner(window: window, stage: "resize stream start direct=\(direct) mixed=\(mixedAxes)")
        owner.maxWidth = window.frame.width
        let observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("window resigned key") } },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main) { _ in MainActor.assumeIsolated { owner.lostForeground("application resigned active") } },
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { owner.maxWidth = max(owner.maxWidth, owner.window?.frame.width ?? 0) }
                }
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let trace = environment["CI"] == "true" || environment["VANE_RESIZE_TIMING"] == "1"
            ? ResizePaintTrace(label: "sidebar=\(sidebarStore != nil),direct=\(direct),mixed=\(mixedAxes)") : nil
        trace?.install()
        defer { trace?.stop(); trace?.dump() }
        trace?.append("fixture.capture.begin", time: CACurrentMediaTime(), fields: [
            "window": String(window.windowNumber), "scale": String(Double(window.backingScaleFactor)),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "page": String(describing: ObjectIdentifier(web)), "webFrame": NSStringFromRect(web.frame),
            "zoom": String(Double(web.pageZoom)), "proposalInterval": String(describing: proposalInterval)
        ])
        let sampler = ResizePixelSampler(trace: trace)
#else
        let sampler = ResizePixelSampler()
#endif
        try await sampler.start(window)
        do {
            let baseline = try XCTUnwrap(sampler.frames.last)
            guard baseline.isPaintedBaseline else { throw NSError(domain: "ResizePaintBaselineReadiness", code: 1) }
            let began = CACurrentMediaTime()
            owner.stage = "resize proposals direct=\(direct) mixed=\(mixedAxes)"
            let frameHeight = window.frame.height
            if queuedGeometry {
                // Exercise WebKit's real coalesced geometry queue: a host layout
                // can submit another viewport before the previous IPC replies.
                // Return to the admitted native baseline before starting the drag.
                let size = web.frame.size
                web.setFrameSize(NSSize(width: size.width + 24, height: size.height))
                web.setFrameSize(size)
#if DEBUG
                trace?.append("fixture.queuedGeometry", time: CACurrentMediaTime(), fields: [
                    "intermediate": NSStringFromSize(NSSize(width: size.width + 24, height: size.height)),
                    "baseline": NSStringFromSize(size)
                ])
#endif
            }
            if let sidebarStore { window.beginSidebarResize(sidebarStore) }
            else if !baselineControl {
                window.beginPageResize(at: NSPoint(x: window.frame.maxX,
                    y: mixedAxes ? window.frame.maxY : window.frame.midY))
            }
            defer { window.endPageResize() }
            let widths = sidebarStore != nil
                ? Array(stride(from: 228, through: 500, by: 8))
                    + Array(stride(from: 492, through: 164, by: -8))
                    + Array(stride(from: 172, through: 228, by: 8))
                : Array(stride(from: 900, through: 1300, by: 40))
                    + Array(stride(from: 1260, through: 900, by: -40))
            let sizes = mixedAxes
                ? [NSSize(width: 800, height: frameHeight + 40),
                   NSSize(width: 1100, height: frameHeight - 40),
                   NSSize(width: 800, height: frameHeight + 40),
                   NSSize(width: 900, height: frameHeight)]
                : widths.map { NSSize(width: CGFloat($0), height: frameHeight) }
            for size in sizes {
                let proposalBegan = CACurrentMediaTime()
                let deadline = ContinuousClock.now + proposalInterval
#if DEBUG
                trace?.append("fixture.input", time: CACurrentMediaTime(), fields: ["size": NSStringFromSize(size)])
#endif
                if sidebarStore != nil {
                    let handled = window.updateSidebarResize(size.width)
#if DEBUG
                    trace?.append("fixture.sidebar.route", time: CACurrentMediaTime(), fields: [
                        "bufferHandled": String(handled), "requested": String(Double(size.width))
                    ])
#endif
                    if !handled {
                        SidebarWidth.shared.setLiveWidth(size.width, available: window.contentView?.bounds.width)
                    }
                } else {
                    let accepted = baselineControl ? size : window.proposedPageResize(size)
                    if accepted != window.frame.size {
                        window.setFrame(NSRect(origin: window.frame.origin, size: accepted), display: false)
                    }
                }
#if DEBUG
                trace?.append("fixture.input.returned", time: CACurrentMediaTime(), fields: [
                    "sidebar": String(Double(SidebarWidth.shared.width)), "webFrame": NSStringFromRect(web.frame),
                    "parentBounds": web.superview.map { NSStringFromRect($0.bounds) } ?? "nil",
                    "metadataSidebar": (web.superview as? WebHost).map { String(Double($0.resizeLayout.sidebarWidth)) } ?? "nil",
                    "metadataRevision": (web.superview as? WebHost).map { String($0.resizeLayoutRevision) } ?? "nil"
                ])
#endif
                try await ContinuousClock().sleep(until: deadline)
                if mixedAxes {
                    // Keep sampling through each paint so coalescing cannot skip
                    // the corner geometry this regression is meant to exercise.
                    try await compatibilityWait { !window.isPreparingPageResize && window.frame.size == size }
                    // Admit the actual WindowServer geometry before the next
                    // proposal. Keep every earlier pixel sample, including gaps.
                    try await compatibilityWait {
                        sampler.frames.samples.contains { sample in
                            sample.time >= proposalBegan
                                && abs(sample.extent.width - size.width) < 1
                                && abs(sample.extent.height - size.height) < 1
                        }
                    }
                }
            }
#if DEBUG
            trace?.append("fixture.release", time: CACurrentMediaTime())
#endif
            if sidebarStore != nil {
                let handled = window.endSidebarResize(228, completion: {})
#if DEBUG
                trace?.append("fixture.sidebar.releaseRoute", time: CACurrentMediaTime(), fields: ["bufferHandled": String(handled)])
#endif
                if !handled {
                    SidebarWidth.shared.setLiveWidth(228, available: window.contentView?.bounds.width)
                }
            } else { window.endPageResize() }
            try await compatibilityWait { !window.isPreparingPageResize }
            let ended = CACurrentMediaTime()
            owner.stage = "resize final presentation direct=\(direct) mixed=\(mixedAxes)"
            try await presentation(web)
            try await sampler.captureFinalFrame(window)
            let coverageEnded = CACurrentMediaTime()
            try await sampler.stop()
#if DEBUG
            trace?.append("fixture.capture.stopped", time: CACurrentMediaTime(), fields: [
                "interrupted": String(owner.interrupted), "sidebar": String(Double(SidebarWidth.shared.width)),
                "webFrame": NSStringFromRect(web.frame)
            ])
#endif
            let prefix = "\(direct ? "native" : "browser")-\(ProcessInfo.processInfo.processIdentifier)"
            let imagePrefix = try sampler.frames.saveImages(prefix: prefix)
#if DEBUG
            trace?.append("fixture.artifacts", time: CACurrentMediaTime(), fields: ["prefix": "/tmp/vane-resize-" + imagePrefix])
#endif
            let coverage = sampler.frames.samples.filter { $0.time >= began && $0.time <= coverageEnded }
            let samples = coverage.filter { $0.time <= ended }
            XCTAssertGreaterThan(samples.count, 3, "Capture actual WindowServer frames during resizing")
            XCTAssertFalse(owner.interrupted, "Foreground admission was lost during the native resize capture")
            if sidebarStore == nil {
                XCTAssertGreaterThanOrEqual(owner.maxWidth, 1100, "The window must actually grow during capture")
            } else {
                XCTAssertEqual(SidebarWidth.shared.width, 228)
                XCTAssertEqual(web.frame.width, 661, accuracy: 1)
            }
            XCTAssertEqual(window.frame.width, 900, accuracy: 1, "Commit the latest queued request")
            XCTAssertEqual(window.frame.height, frameHeight, accuracy: 1,
                           "Native width proposals must not repeatedly add the titlebar height")
            let maximum = coverage.map(\.gap).max() ?? 0
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
    weak var window: NSWindow?
    var stage: String

    init(window: NSWindow, stage: String) {
        self.window = window
        self.stage = stage
    }

    func lostForeground(_ reason: String) {
        interrupted = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        print("RESIZE_FOREGROUND \(CACurrentMediaTime()) reason=\(reason) stage=\(stage) active=\(NSApp.isActive) expected=\(String(describing: window?.windowNumber)) isKey=\(window?.isKeyWindow == true) key=\(String(describing: NSApp.keyWindow?.windowNumber)) frontmost=\(frontmost?.bundleIdentifier ?? "nil") pid=\(frontmost?.processIdentifier ?? 0)")
    }
}

@MainActor private final class ResizePixelSampler: NSObject, SCStreamOutput {
    nonisolated let frames = ResizePixelFrames()
    private var stream: SCStream?
#if DEBUG
    nonisolated let trace: ResizePaintTrace?
    init(trace: ResizePaintTrace? = nil) { self.trace = trace; super.init() }
#endif

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
            // A missing marker uses a sentinel gap, not a settled baseline.
            // Admit only the initial fixture paint, before any resize begins.
            try await compatibilityWait { self.frames.last?.isPaintedBaseline == true }
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

    // Static content need not generate a new streaming callback on macOS 26.
    // Capture exactly the filtered window after its final WebKit presentation.
    func captureFinalFrame(_ window: NSWindow) async throws {
        try await stop()
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let bounds = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        guard bounds.width > 0, bounds.height > 0, scale > 0 else {
            throw NSError(domain: "ResizeFinalCaptureGeometry", code: 1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(bounds.width * scale))
        configuration.height = Int(ceil(bounds.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter, configuration: configuration)
        let pixel = try XCTUnwrap(sample.imageBuffer)
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        // Screenshot results do not promise SCStreamFrameInfo attachments. Use
        // the exact filter aspect and capture dimensions, with no padded canvas.
        XCTAssertEqual(width, configuration.width)
        XCTAssertEqual(height, configuration.height)
        print("FINAL_RESIZE_CAPTURE pixels=\(width)x\(height) points=\(bounds.size)")
        let captured = CACurrentMediaTime()
        record(pixel, valid: CGRect(x: 0, y: 0, width: width, height: height),
               pixelsPerPoint: Double(width) / bounds.width, time: captured)
        guard frames.last?.time == captured else {
            throw NSError(domain: "ResizeFinalCaptureFormat", code: 1)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
#if DEBUG
        let received = trace == nil ? nil : CACurrentMediaTime()
#endif
        let time = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard time.isFinite else { return }
        let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = info?.first?[.status] as? Int
#if DEBUG
        trace?.append("capture.received", time: received ?? time, fields: [
            "pts": String(time), "status": status.map(String.init) ?? "nil",
            "previousGap": frames.last.map { String($0.gap) } ?? "nil"
        ])
#endif
        if status == SCFrameStatus.idle.rawValue { frames.repeatFrame(time); return }
        guard status == SCFrameStatus.complete.rawValue, let pixel = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard let rectDictionary = info?.first?[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: rectDictionary as CFDictionary),
              let factor = info?.first?[.scaleFactor] as? NSNumber,
              let contentScale = info?.first?[.contentScale] as? NSNumber else { return }
        let scale = CGFloat(factor.doubleValue)
        let pixelsPerPoint = factor.doubleValue * contentScale.doubleValue
        let valid = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                           width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if frames.last == nil { frames.recordLog("RESIZE_CAPTURE info=\(String(describing: info?.first))") }
        record(pixel, valid: valid, pixelsPerPoint: pixelsPerPoint, time: time)
    }

    nonisolated fileprivate func record(_ pixel: CVPixelBuffer, valid: CGRect,
                                   pixelsPerPoint: Double, time: Double) {
        guard time.isFinite, pixelsPerPoint.isFinite, pixelsPerPoint > 0, !valid.isEmpty,
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        // ScreenCaptureKit can retain pixels from the previously wider window
        // outside this frame's content rectangle. Those are not visible content.
        let row = Int(valid.midY) * CVPixelBufferGetBytesPerRow(pixel)
        var firstRed: Int?, lastRed: Int?, firstPainted: Int?, lastPainted: Int?, rightWindow: Int?
        var rawRightWindow: Int?, rawLastPainted: Int?
        for x in max(0, Int(ceil(valid.minX)))..<min(width, Int(floor(valid.maxX))) {
            let p = row + x * 4
            let b = Int(bytes[p]), g = Int(bytes[p + 1]), r = Int(bytes[p + 2])
            if r + g + b > 40 { rawRightWindow = x }
            let red = r > 180 && g < 110 && b < 100
            let blue = b > r + 20 && b > g + 15 && b < 130 && g > 20 && g < 100
            if red || blue { rawLastPainted = x }
            // This fixture's window and page are opaque. During a shrink SCK
            // can deliver the old contentRect with translucent resampling pixels
            // beyond the new window edge. RGB there is not visible window paint.
            // Allow byte quantization of opaque alpha, not translucent padding;
            // classify gray/unpainted window pixels using the same alpha mask.
            guard bytes[p + 3] >= 250 else { continue }
            if r + g + b > 40 { rightWindow = x }
            if red {
                if firstRed == nil { firstRed = x }
                lastRed = x
            }
            if red || blue { if firstPainted == nil { firstPainted = x }; lastPainted = x }
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
        if snapshot != nil { frames.recordLog("RESIZE_CAPTURE_BOUND time=\(time) rect=\(valid) red=\(String(describing: firstRed))...\(String(describing: lastRed)) right=\(String(describing: rightWindow)) gap=\(gap)") }
        let markerGap = lastRed.flatMap { red in rightWindow.map { Double($0 - red) / pixelsPerPoint } } ?? 10_000
#if DEBUG
        trace?.append("capture.parsed", time: CACurrentMediaTime(), fields: [
            "pts": String(time), "gap": String(gap), "markerGap": String(markerGap),
            "valid": NSStringFromRect(valid), "pixelsPerPoint": String(pixelsPerPoint),
            "pixels": "\(width)x\(height)", "firstRed": firstRed.map(String.init) ?? "nil",
            "lastRed": lastRed.map(String.init) ?? "nil", "lastPainted": lastPainted.map(String.init) ?? "nil",
            "rightWindow": rightWindow.map(String.init) ?? "nil",
            "rawRightWindow": rawRightWindow.map(String.init) ?? "nil",
            "rawLastPainted": rawLastPainted.map(String.init) ?? "nil"
        ])
#endif
        frames.append(time: time, gap: gap, markerGap: markerGap, left: firstPainted.map { Double($0) / pixelsPerPoint } ?? -1,
                      extent: CGSize(width: valid.width / pixelsPerPoint, height: valid.height / pixelsPerPoint), image: snapshot)
    }

}

private final class ResizePixelFrames: @unchecked Sendable {
    struct Frame {
        let time: Double
        let gap: Double
        let markerGap: Double
        let left: Double
        let extent: CGSize
        // These documents paint to the edge apart from the native <=2pt gutter.
        var isPaintedBaseline: Bool { gap >= 0 && gap <= 2 && markerGap >= 0 && markerGap <= 2 }
    }
    struct Image { let data: Data; let width: Int; let height: Int; let stride: Int }
    let queue = DispatchQueue(label: "vane.resize.pixel-capture")
    private let lock = NSLock()
    private var recorded: [Frame] = []
    private var baselineImage: Image?
    private var worstImage: Image?
    private var worstGap = -Double.infinity
    private var logs: [String] = []
    var last: Frame? { lock.withLock { recorded.last } }
    var samples: [Frame] { lock.withLock { recorded } }
    func recordLog(_ line: String) { lock.withLock { if logs.count < 256 { logs.append(line) } } }
    func needsImage(for gap: Double) -> Bool { lock.withLock { baselineImage == nil || gap > worstGap } }
    func append(time: Double, gap: Double, markerGap: Double, left: Double, extent: CGSize, image: Image?) {
        lock.withLock {
            let frame = Frame(time: time, gap: gap, markerGap: markerGap, left: left, extent: extent)
            recorded.append(frame)
            if baselineImage == nil, frame.isPaintedBaseline { baselineImage = image }
            if baselineImage != nil, gap > worstGap { worstGap = gap; worstImage = image }
        }
    }
    func repeatFrame(_ time: Double) {
        lock.withLock { if let last = recorded.last { recorded.append(Frame(time: time, gap: last.gap, markerGap: last.markerGap, left: last.left, extent: last.extent)) } }
    }
    @discardableResult @MainActor func saveImages(prefix: String) throws -> String {
        for line in lock.withLock({ logs }) { print(line) }
        let attemptPrefix = "\(prefix)-\(UUID().uuidString)"
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
            let output = URL(fileURLWithPath: "/tmp/vane-resize-\(attemptPrefix)-\(name).png")
            try data.write(to: output)
            print("RESIZE_ARTIFACT path=\(output.path)")
        }
        return attemptPrefix
    }
}
