import AppKit
import QuartzCore
import WebKit
import XCTest
@testable import vane

/// Opt-in native input experiment, not a presented-frame-rate measurement. The
/// same public document, store and window survive the OFF/ON/ON/OFF sequence.
@MainActor final class BufferedSidebarPerformanceTests: XCTestCase {
    private var expectedPointerInside: Bool?
    private struct InvalidRun: Error { let reason: String }
    private struct Controls {
        let mounted: Int
        let visible: [String]
    }
    private struct Leg {
        let durationMS: Double
        let admissionsMS: [Double]
        let gapsMS: [Double]
        let offsets: [CGFloat]
    }

    private func require(_ valid: Bool, _ reason: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        guard valid else {
            XCTFail("Invalid buffered-sidebar measurement: \(reason)", file: file, line: line)
            throw InvalidRun(reason: reason)
        }
    }

    private func foreground(_ window: NSWindow) -> Bool {
        NSApp.isActive && window.isKeyWindow && window.isVisible
            && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func pointerInside(_ scroll: NSScrollView, window: NSWindow) -> Bool {
        let point = scroll.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return scroll.bounds.contains(point) && scroll.visibleRect.contains(point)
    }

    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }

    private func controls(in scroll: NSScrollView, titles: Set<String>) -> Controls {
        guard let document = scroll.documentView else { return Controls(mounted: 0, visible: []) }
        let anchors = descendants(document, TabTooltipAnchorView.self).filter {
            $0.window === scroll.window && !$0.isHiddenOrHasHiddenAncestor
                && titles.contains($0.title)
        }
        return Controls(mounted: anchors.count, visible: anchors.filter {
            $0.enabled && $0.visibleRect.intersection($0.bounds).height > Look.rowHeight / 2
        }.map(\.title).sorted())
    }

    /// Enumerating controls is deliberately outside the measured wheel spans.
    private func scroll(in store: TabStore) -> NSScrollView? {
        guard let root = store.window?.contentView else { return nil }
        // A single Space has one explicit live sections marker; do not choose an
        // arbitrary first NSScrollView from the page or hidden Library.
        return SidebarSectionsViewport.scrollView(in: root)
    }

    private func confirmPainted(_ web: WKWebView) async throws {
        let facts = try await web.evaluateJavaScript("""
        ({ title: document.title, text: document.body.innerText,
           width: innerWidth, height: innerHeight,
           ready: document.readyState })
        """) as? [String: Any]
        let title = facts?["title"] as? String ?? ""
        let text = facts?["text"] as? String ?? ""
        try require(title.localizedCaseInsensitiveContains("Swift"), "public Swift document title was not loaded: \(title)")
        try require(text.contains("Documentation") && text.count > 200,
                    "the public document must contain its real visible content")
        try require(((facts?["width"] as? NSNumber)?.doubleValue ?? 0) > 100,
                    "the loaded document must have a real viewport")
        try require(web.window != nil && !web.isHiddenOrHasHiddenAncestor,
                    "the loaded WebKit document must be mounted and visible")
        let snapshot = try await web.takeSnapshot(configuration: nil)
        let data = try XCTUnwrap(snapshot.tiffRepresentation)
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: data))
        var minimum = CGFloat(1), maximum = CGFloat(0)
        for y in stride(from: 0, to: pixels.pixelsHigh, by: max(1, pixels.pixelsHigh / 64)) {
            for x in stride(from: 0, to: pixels.pixelsWide, by: max(1, pixels.pixelsWide / 64)) {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                minimum = min(minimum, luminance); maximum = max(maximum, luminance)
            }
        }
        try require(maximum - minimum > 0.1, "the real WebKit snapshot must contain painted contrast")
    }

    private func measure(window: NSWindow, scroll: NSScrollView, distance: CGFloat,
                         direction: CGFloat, cadence: BufferedSidebarCadence) async throws -> Leg {
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let pointerInside = pointerInside(scroll, window: window)
        if let expectedPointerInside {
            try require(pointerInside == expectedPointerInside, "actual pointer hover workload changed between arms")
        } else { expectedPointerInside = pointerInside }
        print("BUFFERED_SIDEBAR_POINTER inside_viewport=\(pointerInside)")
        let start = CACurrentMediaTime()
        var admissions: [Double] = [], offsets: [CGFloat] = []
        let packets = Int(ceil(distance / 8))
        admissions.reserveCapacity(packets + 1); offsets.reserveCapacity(packets)
        cadence.begin()
        var previous: CGFloat = 0
        for packet in 0..<packets {
            try require(foreground(window), "focus/visibility changed during wheel packet \(packet)")
            try require(self.pointerInside(scroll, window: window) == pointerInside,
                        "actual pointer crossed the viewport during wheel packet \(packet)")
            let next = min(distance, CGFloat(packet + 1) * 8)
            let event = ScrollEvent(window: window, dy: -direction * (next - previous),
                phase: packet == 0 ? .began : .changed, x: point.x, y: point.y)
            let admission = CACurrentMediaTime()
            NSApp.sendEvent(event)
            admissions.append((CACurrentMediaTime() - admission) * 1_000)
            previous = next
            // No layout/display call, row enumeration or DOM work inside this span.
            try await Task.sleep(for: .milliseconds(8))
            offsets.append(scroll.contentView.bounds.minY)
        }
        let admission = CACurrentMediaTime()
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        admissions.append((CACurrentMediaTime() - admission) * 1_000)
        let duration = (CACurrentMediaTime() - start) * 1_000
        // Include the same bounded end-of-gesture tail in callback observations.
        try await Task.sleep(for: .milliseconds(80))
        let gaps = cadence.finish()
        try require(foreground(window) && !cadence.lostForeground,
                    "focus/visibility changed during the display callback interval")
        try require(gaps.count >= 10, "main display-link callbacks were unavailable")
        return Leg(durationMS: duration, admissionsMS: admissions, gapsMS: gaps, offsets: offsets)
    }

    private func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "n=0" }
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        return "n=\(values.count),p50=\(percentile(0.5)),p95=\(percentile(0.95)),max=\(sorted.last!)"
    }

    func testPublicDocumentBufferedSidebarABBA() async throws {
        useLegacySidebarMountingPolicy()
        guard ProcessInfo.processInfo.environment["VANE_BUFFERED_SIDEBAR_PERFORMANCE"] == "1" else {
            throw XCTSkip("Opt in with VANE_BUFFERED_SIDEBAR_PERFORMANCE=1; requires an active visible native window and public network")
        }
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let tooltipFlag = "VANE_DIAG_REBUILD_TOOLTIP_TRACKING"
        let oldFlag = ProcessInfo.processInfo.environment[flag]
        let oldTooltipFlag = ProcessInfo.processInfo.environment[tooltipFlag]
        let suggestions = SearchSuggestions.enabled
        SearchSuggestions.enabled = false
        setenv(tooltipFlag, "1", 1) // Hold the legacy-tooltip factor constant.
        defer {
            if let oldFlag { setenv(flag, oldFlag, 1) } else { unsetenv(flag) }
            if let oldTooltipFlag { setenv(tooltipFlag, oldTooltipFlag, 1) } else { unsetenv(tooltipFlag) }
            SearchSuggestions.enabled = suggestions
            NSApp.setActivationPolicy(policy)
        }

        let manager = ProfileManager.shared
        let profile = manager.create(name: "Buffered public document measurement").id
        addTeardownBlock { @MainActor in
            try await NativeFixtureProfileCleanup.release([profile])
            _ = manager.delete(profile)
        }
        let space = Space(name: "Public documents", profileID: profile)
        try require(manager.saveSpaces([space], for: profile), "isolated fixture Space could not be saved")
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        let urls = ["https://www.swift.org/documentation/",
                    "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
                    "https://en.wikipedia.org/wiki/Swift_(programming_language)"]
        let tabs: [vane.Tab] = (0..<100).map { index in
            let tab = store.makeBlankTab(as: .today)
            tab.park(url: URL(string: urls[index % urls.count] + "#buffered-fixture-\(index)")!,
                     Parked(title: "Public document \(index)"))
            return tab
        }
        store.tabs = tabs
        store.pins = Pins(entries: [])
        store.todayShape = Pins(entries: tabs.map { .init(row: .tab($0.id.uuidString)) })
        store.current = tabs[0].id
        store.palette = nil
        let window = VaneWindow(contentRect: NSRect(x: 80, y: 80, width: 1_100, height: 650),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        // Match the production drag/titlebar surface; a plain titled test window
        // would omit the full-size content responder/layout path being measured.
        window.title = WindowTitle.current(in: store)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "VaneEmpty")
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        store.window = window
        let shown = ShownStore(store)
        var host: BrowserWindowHost?
        let cadence = BufferedSidebarCadence(window: window)
        // NativeFixtureProfileCleanup records retirement when the wrapper contract
        // is present, otherwise removes only this disposable isolated backend.
        addTeardownBlock { @MainActor in
            cadence.stop()
            store.clearSuggestions()
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            (window.contentView as? BrowserWindowHost)?.cancelSpaceSlide()
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            tabs.forEach { $0.tearDown() }
        }

        setenv(flag, "0", 1)
        host = BrowserWindowHost(shown: shown)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        SharedTabs.refreshPresentation()
        try await compatibilityWait { self.foreground(window) }
        // This is one actual public network navigation, not 100 blank WebViews.
        let deadline = ContinuousClock.now + .seconds(60)
        while (tabs[0].existingWeb?.isLoading != false || tabs[0].loading
               || tabs[0].existingWeb?.title?.contains("Swift") != true), ContinuousClock.now < deadline {
            try require(foreground(window), "focus/visibility changed while the public document loaded")
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = try XCTUnwrap(tabs[0].existingWeb)
        try await confirmPainted(web)
        let documentToken = UUID().uuidString
        _ = try await web.evaluateJavaScript("window.__vaneBufferedMeasurement = '\(documentToken)'")
        let originalTitle = web.title
        let titles = Set(tabs.map { TidyTitles.title(for: $0) })
        try require(titles.count == 100, "fixture row titles must be independently identifiable")
        try require(tabs.allSatisfy { $0.currentURL?.scheme == "https" }, "all 100 tabs must retain real public website URLs")
        cadence.start(on: try XCTUnwrap(window.screen))

        let distance = 48 * (Look.rowHeight + Look.rowGap) // Six 8-row batches each way.
        var originalExtent: CGFloat?
        for (arm, buffered) in [false, true, true, false].enumerated() {
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            host?.cancelSpaceSlide()
            window.contentView = nil
            host = nil
            setenv(flag, buffered ? "1" : "0", 1)
            try require(BufferedSidebarRowsExperiment.enabled == buffered,
                        "the experiment flag did not change for this newly captured host")
            let nextHost = BrowserWindowHost(shown: shown)
            host = nextHost
            window.contentView = nextHost
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            SharedTabs.refreshPresentation()
            try await compatibilityWait { self.foreground(window) && self.scroll(in: store) != nil }
            let viewport = try XCTUnwrap(scroll(in: store))
            viewport.contentView.scroll(to: .zero)
            viewport.reflectScrolledClipView(viewport.contentView)
            nextHost.layoutSubtreeIfNeeded() // Setup only, never per wheel packet.
            try await Task.sleep(for: .milliseconds(500))
            try require(foreground(window), "arm \(arm) did not settle in the foreground")
            try require(tabs[0].existingWeb === web && web.window === window && !web.isHiddenOrHasHiddenAncestor,
                        "the same live page must be mounted after replacing the browser host")
            let token = try await web.evaluateJavaScript("window.__vaneBufferedMeasurement") as? String
            try require(token == documentToken && web.title == originalTitle,
                        "host recreation must preserve the actual loaded document")
            let document = try XCTUnwrap(viewport.documentView)
            let extent = max(document.bounds.height, document.frame.height)
            if let originalExtent { XCTAssertEqual(extent, originalExtent, accuracy: 1) }
            else { originalExtent = extent }
            try require(extent - viewport.contentView.bounds.height > distance + 50,
                        "the fixed motion needs room to cross six buffer boundaries")
            let initial = viewport.contentView.bounds.minY
            try require(abs(initial) < 2, "the native viewport must start at its origin")
            let before = controls(in: viewport, titles: titles)
            try require(!before.visible.isEmpty, "no real tab controls were initially visible")
            try require(buffered ? before.mounted < 60 : before.mounted == 100,
                        "arm \(arm) did not realize its expected buffered/eager policy: \(before.mounted)")

            let outward = try await measure(window: window, scroll: viewport, distance: distance,
                                            direction: 1, cadence: cadence)
            let middle = viewport.contentView.bounds.minY
            let crossedBatches = Set(outward.offsets.map { Int(max(0, $0 - initial) / (8 * (Look.rowHeight + Look.rowGap))) })
            try require(crossedBatches.count >= 5, "actual native offsets did not traverse multiple eight-row batches")
            try require(middle - initial > distance * 0.8,
                        "native wheel input did not cross the intended buffer boundaries")
            let atTurn = controls(in: viewport, titles: titles)
            try require(!atTurn.visible.isEmpty && Set(before.visible).isDisjoint(with: atTurn.visible),
                        "the destination must show a different set of real tab controls")
            let returning = try await measure(window: window, scroll: viewport, distance: distance,
                                              direction: -1, cadence: cadence)
            try await compatibilityWait { abs(viewport.contentView.bounds.minY - initial) < 2 }
            let after = controls(in: viewport, titles: titles)
            try require(!after.visible.isEmpty && !Set(before.visible).isDisjoint(with: after.visible),
                        "return input must restore the initial visible control range")
            try require(!store.spaceSwiping && store.current == tabs[0].id && store.tabs.count == 100 && store.palette == nil,
                        "vertical input must preserve page selection and Space state")
            let finalToken = try await web.evaluateJavaScript("window.__vaneBufferedMeasurement") as? String
            try require(finalToken == documentToken, "the live document was replaced during an arm")
            let gaps = outward.gapsMS + returning.gapsMS
            let admissions = outward.admissionsMS + returning.admissionsMS
            print("BUFFERED_SIDEBAR_ABBA arm=\(arm) buffered=\(buffered) tooltip_legacy=1 tabs=100 screen_hz=\(cadence.rate) packets=\(admissions.count) distance_each_way=\(distance) input_duration_ms=\(outward.durationMS + returning.durationMS) offsets=\(initial),\(middle),\(viewport.contentView.bounds.minY) mounted=\(before.mounted),\(atTurn.mounted),\(after.mounted) display_callback_gaps_ms={\(summary(gaps))} send_event_ms={\(summary(admissions))} NOT_PRESENTED_FPS")
            // Preserve the actual observations for analysis, without a performance
            // threshold that could turn scheduling noise into a correctness pass.
            print("BUFFERED_SIDEBAR_RAW arm=\(arm) gaps_ms=\(gaps) admission_ms=\(admissions) outward_offsets=\(outward.offsets) return_offsets=\(returning.offsets)")
        }
    }
}

@MainActor private final class BufferedSidebarCadence: NSObject {
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var previous: CFTimeInterval = 0
    private var collecting = false
    private var gaps: [Double] = []
    private(set) var rate: Float = 0
    private(set) var lostForeground = false

    init(window: NSWindow) { self.window = window }
    func start(on screen: NSScreen) {
        rate = Float(screen.maximumFramesPerSecond)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func begin() {
        gaps.removeAll(keepingCapacity: true)
        previous = CACurrentMediaTime()
        lostForeground = false
        collecting = true
    }
    func finish() -> [Double] { collecting = false; return gaps }
    @objc private func tick(_ link: CADisplayLink) {
        guard collecting else { return }
        let now = CACurrentMediaTime()
        if previous > 0 { gaps.append((now - previous) * 1_000) }
        previous = now
        if let window {
            lostForeground = lostForeground || !NSApp.isActive || !window.isKeyWindow
                || !window.isVisible || window.isMiniaturized || !window.occlusionState.contains(.visible)
        } else { lostForeground = true }
    }
    func stop() { collecting = false; link?.invalidate(); link = nil }
}
