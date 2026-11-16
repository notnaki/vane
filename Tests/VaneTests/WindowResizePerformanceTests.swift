import AppKit
import ObjectiveC
import QuartzCore
import WebKit
import XCTest
@testable import vane

/// Live window-edge drags through the page-resize buffer with a populated sidebar.
@MainActor final class WindowResizePerformanceTests: XCTestCase {
    /// `NSWindow.setFrame` lays the tree out between resizing its theme frame and
    /// its content view. A root dirtied by the first step was laid out there at the
    /// old width, then again at the new one, on every published drag frame.
    func testBufferedCommitsLayTheRootOutOnlyAtItsNewWidth() async throws {
        try await withFixture(count: 20, sidebarShown: true) { window, root in
            // SwiftUI's own pass: the root holds `layout()` calls inside a commit.
            let cls: AnyClass = try XCTUnwrap(class_getSuperclass(type(of: root)))
            let selector = #selector(NSView.layout)
            let method = try XCTUnwrap(class_getInstanceMethod(cls, selector))
            typealias Layout = @convention(c) (AnyObject, Selector) -> Void
            let inherited = method_getImplementation(method)
            let original = unsafeBitCast(inherited, to: Layout.self)
            let layouts = ResizeLayoutRecord()
            let block: @convention(block) (AnyObject) -> Void = { object in
                if let view = object as? NSView, view === root {
                    MainActor.assumeIsolated {
                        layouts.total += 1
                        if !layouts.finished, abs(view.bounds.width - (view.window?.frame.width ?? 0)) > 0.5 {
                            layouts.stale += 1
                            // Name the caller, so a runner-only failure says which path laid it out.
                            if layouts.staleCaller == nil {
                                let committing = (view.window as? VaneWindow)?.isCommittingBufferedPageResize == true
                                layouts.staleCaller = "bounds \(view.bounds.width), window \(view.window?.frame.width ?? 0), "
                                    + "committing buffered \(committing)\n" + Thread.callStackSymbols.dropFirst().prefix(48)
                                    .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                                    .joined(separator: "\n")
                            }
                        }
                    }
                }
                original(object, selector)
            }
            // The hosting class may inherit `layout`; add an override
            // there, or replace and later restore its own implementation.
            let added = class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            let previous = added ? nil : method_setImplementation(method, imp_implementationWithBlock(block))
            defer {
                if let previous { method_setImplementation(method, previous) }
                else if let own = class_getInstanceMethod(cls, selector) { method_setImplementation(own, inherited) }
            }
            // The release commit after `endPageResize` keeps its own eager path.
            // Buffered commits wait for WebKit to paint their coverage, which takes
            // up to ~300ms on CI's paravirtual GPU; a 0.4s drag ended before any.
            // A root already dirty when a commit begins (an earlier commit's release,
            // a state change) must wait for the new frame as well.
            let dirty = Timer(timeInterval: 0.002, repeats: true) { _ in MainActor.assumeIsolated { root.needsLayout = true } }
            RunLoop.main.add(dirty, forMode: .common)
            defer { dirty.invalidate() }
            let drag = try await self.drag(window, speed: 100, travel: 120) { layouts.finished = true }
            XCTAssertGreaterThan(drag.changes.count, 5, "The drag must publish buffered frames")
            XCTAssertGreaterThan(layouts.total, 5)
            XCTAssertEqual(layouts.stale, 0, "No buffered commit may lay the root out at its previous width; first:\n\(layouts.staleCaller ?? "")")
            XCTAssertEqual(root.bounds.width, window.frame.width, accuracy: 0.5)
        }
    }

    /// The sidebar stored its own and its scroll viewport's height as state, so
    /// each frame of a vertical resize rebuilt it, and SwiftUI rebuilt the whole
    /// key-view loop each time a focusable control moved.
    func testVerticalResizeRebuildsNeitherTheSidebarNorTheKeyViewLoop() async throws {
        try await withFixture(count: 20, sidebarShown: true) { window, _ in
            var bodies: [String: Int] = [:]
            ResizeTimingDiagnostics.sink = { event, _, _, _ in bodies[event, default: 0] += 1 }
            defer { ResizeTimingDiagnostics.sink = nil }
            XCTAssertFalse(window.autorecalculatesKeyViewLoop)
            var deferred = false
            // Slow enough for a paravirtual GPU to paint coverage before the release.
            let drag = try await self.drag(window, speed: 100, travel: 120, corner: true) {
                deferred = window.autorecalculatesKeyViewLoop
            }
            XCTAssertGreaterThan(drag.changes.count, 5, "The drag must publish buffered frames")
            XCTAssertTrue(deferred, "A live resize marks the key-view loop stale instead of rebuilding it")
            XCTAssertFalse(window.autorecalculatesKeyViewLoop, "The window's own setting returns with the release")
            XCTAssertEqual(bodies["sidebar.body.sidebar", default: 0], 0)
            XCTAssertEqual(bodies["sidebar.body.sections", default: 0], 0)
        }
    }

    /// Deferring the rebuild must leave the loop SwiftUI's own eager updates would
    /// have: the same views, in the same order, and the same Tab cycle through them.
    func testDeferredKeyViewLoopMatchesAnEagerlyMaintainedOne() async throws {
        try await withFixture(count: 20, sidebarShown: true) { window, _ in
            @MainActor func chain(_ next: @MainActor (NSView) -> NSView?) -> [String] {
                var views: [String] = [], seen = Set<ObjectIdentifier>()
                var view = window.contentView.flatMap(next)
                while let current = view, seen.insert(ObjectIdentifier(current)).inserted, views.count < 2000 {
                    let frame = current.convert(current.bounds, to: nil)
                    views.append("\(type(of: current)) \(Int(frame.minX.rounded())),\(Int((window.frame.height - frame.maxY).rounded())) \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))")
                    view = next(current)
                }
                return views
            }
            // The whole loop, then the cycle Tab walks from no first responder.
            @MainActor func loops() async throws -> [[String]] {
                try await Task.sleep(for: .milliseconds(200))
                return [chain { $0.nextKeyView }, chain { $0.nextValidKeyView }]
            }
            // Eager: ordinary resizes, outside any live resize, along the drag's path
            // to the size it will end at. SwiftUI orders its loop by the frames that
            // led there (one jump to the same size orders it differently), and a drag
            // that never rebuilt would still carry the starting geometry.
            let frame = window.frame
            for step in 1...12 {
                let offset = CGFloat(step * 10)
                window.setFrame(NSRect(origin: frame.origin, size: NSSize(width: frame.width + offset, height: frame.height + (offset / 3).rounded())), display: true)
                try await Task.sleep(for: .milliseconds(20))
            }
            let eager = try await loops()
            XCTAssertGreaterThan(eager[0].count, 3, "The fixture must have a key-view loop to compare")
            XCTAssertGreaterThan(eager[1].count, 3, "The fixture must have a Tab cycle to compare")
            window.setFrame(frame, display: true)
            let start = try await loops()
            XCTAssertNotEqual(start[0], eager[0], "The starting loop must differ, or the comparison proves nothing")
            _ = try await self.drag(window, speed: 100, travel: 120, corner: true, returns: false)
            let deferred = try await loops()
            XCTAssertEqual(deferred[0], eager[0])
            XCTAssertEqual(deferred[1], eager[1])
        }
    }

    /// Rebuilding the loop after the release resizes the window's root and back.
    /// No page may follow that: no `resize` event, ResizeObserver callback, media
    /// query flip, frame at another size, or lost bottom-of-page scroll position.
    func testKeyViewLoopRebuildAfterReleaseIsInvisibleToThePage() async throws {
        try await withFixture(count: 20, sidebarShown: true) { window, _ in
            let web = try XCTUnwrap(window.contentView.flatMap(Self.page))
            struct Probe: Decodable { var size: String, resize: [String], observed: Int, flips: Int, painted: [String], bottom: Double }
            @MainActor func read() async throws -> Probe {
                let json = try await web.evaluateJavaScript("""
                    JSON.stringify({size: innerWidth + 'x' + innerHeight, resize: __probe.resize, observed: __probe.observed,
                        flips: __probe.flips, painted: __probe.painted,
                        bottom: document.documentElement.scrollHeight - innerHeight - scrollY})
                    """) as? String
                return try JSONDecoder().decode(Probe.self, from: Data(try XCTUnwrap(json).utf8))
            }
            // Counts from here on, with a media query one pixel above the current
            // width and the page scrolled to its end.
            @MainActor func arm() async throws {
                try await Task.sleep(for: .milliseconds(300))
                _ = try await web.evaluateJavaScript("""
                    __probe.resize = []; __probe.observed = 0; __probe.flips = 0; __probe.painted = [];
                    __probe.query = matchMedia('(min-width: ' + (innerWidth + 1) + 'px)');
                    __probe.query.addEventListener('change', () => __probe.flips++);
                    scrollTo(0, document.documentElement.scrollHeight); 0
                    """)
                try await Task.sleep(for: .milliseconds(100))
            }
            _ = try await web.evaluateJavaScript("""
                const p = window.__probe = {resize: [], observed: 0, flips: 0, painted: []};
                addEventListener('resize', () => p.resize.push(innerWidth + 'x' + innerHeight));
                new ResizeObserver(() => p.observed++).observe(document.documentElement);
                let last = innerWidth + 'x' + innerHeight;
                (function frame() {
                    const size = innerWidth + 'x' + innerHeight;
                    if (size !== last) { last = size; p.painted.push(size) }
                    requestAnimationFrame(frame)
                })(); 0
                """)

            // A real drag: the page ends at the released size, having arrived once.
            try await arm()
            _ = try await self.drag(window, speed: 100, travel: 120, corner: true, returns: false)
            try await Task.sleep(for: .milliseconds(500))
            let dragged = try await read()
            XCTAssertGreaterThan(dragged.resize.count, 0, "The drag must resize the page")
            XCTAssertEqual(dragged.resize.last, dragged.size)
            XCTAssertEqual(dragged.resize.filter { $0 == dragged.size }.count, 1,
                           "The page reached its released size once: \(dragged.resize)")
            XCTAssertEqual(dragged.painted.last, dragged.size)
            XCTAssertEqual(dragged.painted.filter { $0 == dragged.size }.count, 1,
                           "The page painted its released size once: \(dragged.painted)")

            // A press and release that moves nothing still defers and rebuilds the
            // loop. The buffer shows the page its lookahead size and back, as it
            // does without the rebuild; nothing may follow that.
            try await arm()
            window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.minY))
            XCTAssertTrue(window.autorecalculatesKeyViewLoop)
            try await Task.sleep(for: .milliseconds(300))
            window.endPageResize()
            try await compatibilityWait { !window.isPreparingPageResize }
            try await Task.sleep(for: .milliseconds(500))
            let rebuilt = try await read()
            XCTAssertEqual(rebuilt.size, dragged.size)
            XCTAssertLessThanOrEqual(rebuilt.resize.count, 2, "\(rebuilt.resize)")
            XCTAssertLessThanOrEqual(rebuilt.resize.filter { $0 == rebuilt.size }.count, 1, "\(rebuilt.resize)")
            XCTAssertLessThanOrEqual(rebuilt.observed, 2)
            XCTAssertLessThanOrEqual(rebuilt.flips, 2)
            XCTAssertLessThanOrEqual(rebuilt.painted.count, 2, "\(rebuilt.painted)")
            XCTAssertLessThanOrEqual(rebuilt.painted.filter { $0 == rebuilt.size }.count, 1, "\(rebuilt.painted)")
            // Only the lookahead's own extra height may have scrolled out of reach.
            @MainActor func height(_ size: String?) -> Double { size?.split(separator: "x").last.flatMap { Double($0) } ?? 0 }
            let lookahead = rebuilt.resize.isEmpty ? 0 : height(rebuilt.resize.first) - height(rebuilt.size)
            XCTAssertEqual(rebuilt.bottom, lookahead, accuracy: 0.5)
        }
    }

    /// A drag cut short by the window miniaturising, closing or losing its content
    /// restores the window's setting without resizing its chrome.
    /// The release's key-view-loop rebuild must not move a scroll view sitting at
    /// its end: a grown viewport clamps the offset, and shrinking back keeps it.
    func testReleaseKeepsScrollViewsAtTheirEnd() async throws {
        try await withFixture(count: 120, sidebarShown: true) { window, _ in
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
            }
            let scrolling = scrollViews(window.contentView!).filter {
                ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 20
            }
            XCTAssertFalse(scrolling.isEmpty, "The fixture must have a scrolling sidebar")
            for view in scrolling {
                let end = (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height
                view.contentView.scroll(to: NSPoint(x: 0, y: view.documentView?.isFlipped == true ? end : 0))
                view.reflectScrolledClipView(view.contentView)
            }
            try await Task.sleep(for: .milliseconds(200))
            let before = scrolling.map(\.contentView.bounds.origin)
            window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.minY))
            window.endPageResize()
            try await compatibilityWait { !window.isPreparingPageResize }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(scrolling.map(\.contentView.bounds.origin), before,
                           "Press and release on the resize edge must leave every scroll view where it was")
        }
    }

    func testCancelledResizeDoesNotResizeTheChrome() async throws {
        try await withFixture(count: 20, sidebarShown: true) { window, root in
            var sizes: [NSSize] = []
            let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                  object: root, queue: nil) { _ in
                MainActor.assumeIsolated { sizes.append(root.frame.size) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            root.postsFrameChangedNotifications = true
            // An ordinary release does: there and back.
            window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.minY))
            window.endPageResize()
            try await compatibilityWait { !window.isPreparingPageResize }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(sizes.count, 2)
            XCTAssertEqual(sizes.last, root.frame.size)
            sizes = []

            window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.minY))
            XCTAssertTrue(window.autorecalculatesKeyViewLoop)
            window.endPageResize(rebuildingKeyViewLoop: false)
            try await compatibilityWait { !window.isPreparingPageResize }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(window.autorecalculatesKeyViewLoop)
            XCTAssertEqual(sizes, [])

            // Released, with the rebuild still waiting on the buffer, then replaced.
            window.beginPageResize(at: NSPoint(x: window.frame.maxX, y: window.frame.minY))
            window.endPageResize()
            let content = window.contentView
            window.contentView = nil
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(sizes, [])
            window.contentView = content
        }
    }

    private static func page(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView, !web.isHiddenOrHasHiddenAncestor { return web }
        return view.subviews.lazy.compactMap(page).first
    }

    /// Opt-in diagnostics: VANE_UI_PERFORMANCE=1 in a release build. No wall-clock
    /// assertions. Each drag prints its own frame-interval and main-thread-gap
    /// percentiles; each configuration then prints them pooled over its drags
    /// (RESIZE_TAIL), with every slow frame attributed to what it waited on.
    func testLiveWindowResizeMainThreadCost() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VANE_UI_PERFORMANCE"] == "1")
        let counts = environment["VANE_RESIZE_PERF_COUNTS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [20, 300]
        let modes = environment["VANE_RESIZE_PERF_MODES"].map { $0.split(separator: ",").map(String.init) } ?? ["shown", "hidden", "floating"]
        let repeats = environment["VANE_RESIZE_PERF_REPEATS"].flatMap(Int.init) ?? 3
        let laps = environment["VANE_RESIZE_PERF_LAPS"].flatMap(Int.init) ?? 3
        let speed = environment["VANE_RESIZE_PERF_SPEED"].flatMap(Double.init) ?? 600
        let corners = environment["VANE_RESIZE_PERF_CORNER"].map { $0.split(separator: ",").map { $0 == "1" } } ?? [false, true]
        let stacks = environment["VANE_RESIZE_PERF_STACKS"]
        func q(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? .nan : values[Int(Double(values.count - 1) * p)] }
        func f(_ value: Double) -> String { String(format: "%.2f", value) }
        func quantiles(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return "mean=\(f(sorted.reduce(0, +) / Double(max(1, sorted.count)))) p50=\(f(q(sorted, 0.5))) p95=\(f(q(sorted, 0.95))) p99=\(f(q(sorted, 0.99))) max=\(f(sorted.last ?? .nan))"
        }
        for count in counts {
            for mode in modes {
                try await withFixture(count: count, sidebarShown: mode == "shown") { window, _ in
                    let store = TabStore.all.first { $0.window === window }
                    if mode == "floating" {
                        store?.sidebarPeeking = true
                        try await Task.sleep(for: .milliseconds(600))
                    }
                    let interval = 1000 / Double(window.screen?.maximumFramesPerSecond ?? 60)
                    for corner in corners {
                        let label = "count=\(count) mode=\(mode)\(corner ? "+corner" : "")"
                        var frames: [Double] = [], ticks: [Double] = [], p99s: [Double] = [], paints: [Double] = []
                        var publishes: [Double] = [], commits: [Double] = [], cpus: [Double] = []
                        var causes: [String: Int] = [:], slowTime: [String: Double] = [:], timeouts = 0
                        var timelines = environment["VANE_RESIZE_PERF_TIMELINES"].flatMap(Int.init) ?? 0
                        for attempt in 0..<repeats {
                            let trace = ResizeFrameTrace(window, sampling: stacks != nil)
                            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                            let drag = try await self.drag(window, speed: speed, travel: 450, corner: corner, laps: laps)
                            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
                            trace.stop()
                            let during = drag.changes.filter { $0 <= drag.ended }
                            let changeGaps = zip(during, during.dropFirst()).map { ($1 - $0) * 1000 }
                            let tickGaps = zip(trace.ticks, trace.ticks.dropFirst()).filter { $1 <= drag.ended }.map { ($1 - $0) * 1000 }
                            // A slow frame is one that missed at least half a refresh.
                            for (from, to) in zip(during, during.dropFirst()) where (to - from) * 1000 > interval * 1.5 {
                                let cause = trace.cause(from: from, to: to, interval: interval)
                                causes[cause, default: 0] += 1
                                slowTime[cause, default: 0] += (to - from) * 1000 - interval
                                trace.mark(from: from, to: to, cause)
                                if timelines > 0 { timelines -= 1; print("RESIZE_SLOW \(label) \(cause) gap=\(f((to - from) * 1000)): \(trace.timeline(from: from, to: to))") }
                            }
                            if let stacks { trace.writeStacks(to: stacks, label: "\(label) attempt=\(attempt)") }
                            frames += changeGaps; ticks += tickGaps; paints += trace.paints
                            publishes += trace.spans("publish").map(\.1); commits += trace.spans("busy").map(\.1)
                            timeouts += trace.count("buffer.timeout")
                            p99s.append(q(changeGaps.sorted(), 0.99))
                            cpus.append(cpu / Double(max(1, drag.changes.count)))
                            print("RESIZE_PERF \(label) attempt=\(attempt) cpu_per_change_ms=\(f(cpus.last!))"
                                  + " changes_per_s=\(f(Double(during.count) / (drag.ended - drag.began)))"
                                  + " frame_ms \(quantiles(changeGaps)) main_gap_ms \(quantiles(tickGaps))"
                                  + " slow=\(changeGaps.filter { $0 > interval * 1.5 }.count)/\(changeGaps.count)")
                            try await Task.sleep(for: .milliseconds(400))
                        }
                        let slow = frames.filter { $0 > interval * 1.5 }.count
                        print("RESIZE_TAIL \(label) peeking=\(store?.sidebarPeeking == true) drags=\(repeats) frames=\(frames.count)"
                              + " fps=\(f(1000 * Double(frames.count) / max(1, frames.reduce(0, +))))"
                              + " cpu_per_change_ms=\(f(cpus.reduce(0, +) / Double(max(1, cpus.count))))"
                              + " frame_ms \(quantiles(frames)) per_drag_p99=\(p99s.map(f).joined(separator: ","))"
                              + " main_gap_ms \(quantiles(ticks)) slow=\(slow)"
                              + " causes=\(causes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)/\(f(slowTime[$0.key] ?? 0))ms" }.joined(separator: ","))"
                              + " paint_ms \(quantiles(paints)) publish_ms \(quantiles(publishes)) busy_ms \(quantiles(commits)) timeouts=\(timeouts)")
                    }
                }
            }
        }
    }

    private struct Drag { let began: Double; let ended: Double; let changes: [Double] }

    /// Pointer samples arrive on their own ~250Hz clock, like a mouse, not after
    /// the main thread finishes a frame, so the app rather than the fixture sets
    /// the cadence. Out and back along the right edge (and bottom, for a corner).
    private func drag(_ window: VaneWindow, speed: Double, travel: Double, corner: Bool = false, laps: Int = 1,
                      returns: Bool = true, beforeRelease: () -> Void = {}) async throws -> Drag {
        let baseline = window.frame
        let record = ResizeLayoutRecord()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                              object: window, queue: .main) { _ in
            MainActor.assumeIsolated { record.changes.append(CACurrentMediaTime()) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let lap = 2 * travel / speed
        let duration = lap * Double(laps)
        let began = CACurrentMediaTime()
        window.beginPageResize(at: NSPoint(x: baseline.maxX, y: corner ? baseline.minY : baseline.midY))
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !record.finished else { return }
                let elapsed = min(CACurrentMediaTime() - began, duration)
                let phase = elapsed >= duration ? 0 : elapsed.truncatingRemainder(dividingBy: lap)
                // One way, a drag ends `travel` past where it began instead of returning.
                let offset = returns ? (phase < lap / 2 ? phase : lap - phase) * speed : travel * elapsed / duration
                let size = NSSize(width: (baseline.width + CGFloat(offset)).rounded(),
                                  height: corner ? (baseline.height + CGFloat(offset / 3)).rounded() : baseline.height)
                let accepted = window.proposedPageResize(size)
                if accepted != window.frame.size {
                    window.setFrame(NSRect(origin: window.frame.origin, size: accepted), display: false)
                }
                if elapsed >= duration { record.finished = true; record.done?() }
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            record.done = { done.resume() }
            RunLoop.main.add(timer, forMode: .common)
        }
        timer.invalidate()
        let ended = CACurrentMediaTime()
        beforeRelease()
        window.endPageResize()
        let target = baseline.width + (returns ? 0 : CGFloat(travel))
        try await compatibilityWait { !window.isPreparingPageResize && abs(window.frame.width - target) < 1 }
        return Drag(began: began, ended: ended, changes: record.changes)
    }

    /// A titled window with a loaded responsive page and `count` sidebar rows.
    private func withFixture(count: Int, sidebarShown: Bool,
                             _ body: (VaneWindow, NSView) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            // A private store owns its pages outright, so the selected page mounts here.
            let store = TabStore(isPrivate: true)
            store.palette = nil
            store.tabs = (0..<count).map { index in
                let tab = Tab(isPrivate: true, profileID: store.profileID)
                tab.kind = index < max(2, count / 3) ? .pinned : .today
                tab.park(url: URL(string: "about:blank#fixture-\(index)")!, Parked(title: "Fixture \(index)"))
                return tab
            }
            store.syncShapes()
            let live = store.newBlankTab()
            store.palette = nil
            store.sidebarShown = sidebarShown
            let web = live.web
            let cards = (0..<400).map { "<div class=c>Card \($0)<p>Responsive text that wraps with the viewport width.</p></div>" }.joined()
            web.loadHTMLString("<html><title>Resize fixture</title><style>body{margin:0;font:14px system-ui;background:#f4f4f4;display:flex;flex-wrap:wrap}.c{flex:1 1 180px;margin:6px;padding:8px;background:#fff;border-radius:6px}</style><body>\(cards)</body></html>", baseURL: nil)
            let host = BrowserWindowHost(shown: ShownStore(store))
            // Keep the grown frame below the menu bar, which would move it.
            let top = NSScreen.screens.first?.visibleFrame.maxY ?? 740
            let window = VaneWindow(contentRect: NSRect(x: 60, y: min(80, top - 900), width: 900, height: 600),
                                    styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            store.window = window
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(ignoringOtherApps: true)
            defer {
                window.endPageResize()
                web.stopLoading()
                store.librarySwipeMonitor.remove()
                store.spaceGesture.monitor.remove()
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs, excluding: store)
            }
            let loadedBy = ContinuousClock.now + .seconds(10)
            while web.isLoading || web.title != "Resize fixture" {
                guard ContinuousClock.now < loadedBy else { throw NSError(domain: "ResizeFixturePageReadiness", code: 1) }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await ResizeNativeWindowAdmission.wait(window, web: web, layout: true)
            func browserRoot(_ view: NSView) -> NSView? {
                if NSStringFromClass(type(of: view)).contains("BrowserHostingView") { return view }
                return view.subviews.lazy.compactMap(browserRoot).first
            }
            let root = try XCTUnwrap(browserRoot(host))
            try await Task.sleep(for: .milliseconds(300))
            try await body(window, root)
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
}

@MainActor private final class ResizeLayoutRecord {
    var total = 0
    var stale = 0
    var staleCaller: String?
    var changes: [Double] = []
    var finished = false
    var done: (() -> Void)?
}

/// One drag's timeline: display-clock heartbeats on the main thread, the buffer's
/// own events, the run loop's display-cycle-and-commit phase, and (opt-in) main
/// thread stacks, so a slow frame can be attributed to what it waited on.
@MainActor private final class ResizeFrameTrace: NSObject {
    private var link: CADisplayLink?
    private(set) var ticks: [Double] = []
    private var events: [(String, Double)] = []
    private var observers: [CFRunLoopObserver] = []
    private var marks: [(Double, Double, String)] = []
    private let sampler: MainThreadStackSampler?

    init(_ window: NSWindow, sampling: Bool) {
        sampler = sampling ? MainThreadStackSampler() : nil
        super.init()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        ResizeTimingDiagnostics.sink = { [weak self] event, time, _, _ in self?.events.append((event, time)) }
        // Bracket every busy stretch of the main run loop.
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.events.append((activity == .beforeWaiting ? "sleep" : "wake", CACurrentMediaTime())) }
        }!
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        observers.append(observer)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        ticks.append(now)
        events.append((String(format: "tick late=%.2f target=+%.2f", (now - link.timestamp) * 1000, (link.targetTimestamp - now) * 1000), now))
    }

    /// Everything recorded around one frame gap, in milliseconds from its start.
    func timeline(from: Double, to: Double) -> String {
        events.filter { $0.1 > from - 0.010 && $0.1 < to + 0.004 }
            .map { String(format: "%+.2f ", ($0.1 - from) * 1000) + $0.0.replacingOccurrences(of: "buffer.", with: "") }.joined(separator: " | ")
    }

    func stop() {
        link?.invalidate()
        link = nil
        ResizeTimingDiagnostics.sink = nil
        observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        sampler?.stop()
    }

    func count(_ event: String) -> Int { events.filter { $0.0 == event }.count }

    /// (start, milliseconds) of each publish or display-cycle-and-commit phase.
    func spans(_ kind: String) -> [(Double, Double)] {
        let (opens, closes) = kind == "publish" ? ("buffer.publish.begin", "buffer.publish.end") : ("wake", "sleep")
        var result: [(Double, Double)] = [], began = 0.0
        for (event, time) in events {
            if event == opens { began = time }
            else if event == closes, began > 0 { result.append((began, (time - began) * 1000)) }
        }
        return result
    }

    /// Request-to-presentation time of each WebKit paint the buffer asked for.
    var paints: [Double] {
        var result: [Double] = [], began: Double?
        for (event, time) in events {
            if event == "buffer.presentation.request" { began = began ?? time }
            else if event == "buffer.presentation.callback", let start = began { result.append((time - start) * 1000); began = nil }
        }
        return result
    }

    /// Why no frame was published between two consecutive ones.
    func cause(from: Double, to: Double, interval: Double) -> String {
        let inside = events.filter { $0.1 > from && $0.1 < to }
        // The buffer held back geometry its painted page did not cover yet.
        if inside.contains(where: { $0.0 == "buffer.uncovered" }) { return "paint-wait" }
        let beats = [from] + ticks.filter { $0 > from && $0 < to } + [to]
        guard zip(beats, beats.dropFirst()).contains(where: { ($1 - $0) * 1000 > interval * 1.5 }) else {
            return inside.contains { $0.0 == "buffer.request" } ? "unpublished" : "no-input"
        }
        // The main thread missed a heartbeat: name its longest phase.
        let publish = spans("publish").filter { $0.0 >= from - 0.0005 && $0.0 < to }.map(\.1).max() ?? 0
        let busy = spans("busy").filter { $0.0 >= from - 0.0005 && $0.0 < to }.map(\.1).max() ?? 0
        if busy < interval { return "tick-skipped" }
        return publish > busy / 2 ? "main-publish" : "main-busy"
    }

    func mark(from: Double, to: Double, _ cause: String) { marks.append((from, to, cause)) }

    /// Folded stacks, one line per sample: `label;cause;outermost;…;innermost 1`.
    func writeStacks(to path: String, label: String) {
        guard let sampler else { return }
        var lines = ""
        for (time, stack) in sampler.symbolicated() {
            let cause = marks.first { time >= $0.0 && time <= $0.1 }?.2 ?? "fast"
            lines += "\(cause);" + stack.joined(separator: ";") + " 1\n"
        }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(("# " + label + "\n" + lines).utf8)); try? handle.close()
        } else { try? ("# " + label + "\n" + lines).write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Samples the main thread's frame-pointer chain from another thread about every
/// millisecond. Nothing may allocate while the main thread is suspended (it can
/// hold the allocator's lock), so samples go into storage reserved up front.
private final class MainThreadStackSampler: @unchecked Sendable {
    private static let depth = 96, capacity = 40_000
    private let main = mach_thread_self()
    private let low: UInt, high: UInt
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: depth * capacity)
    private let times = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
    private let depths = UnsafeMutablePointer<Int>.allocate(capacity: capacity)
    private var count = 0
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    init() {
        let thread = pthread_self()
        high = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        low = high - UInt(pthread_get_stacksize_np(thread))
        Thread.detachNewThread { [self] in
            while running, count < Self.capacity { sample(); usleep(700) }
            finished.signal()
        }
    }

    private func sample() {
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let stack = frames + count * Self.depth
        guard thread_suspend(main) == KERN_SUCCESS else { return }
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(main, ARM_THREAD_STATE64, $0, &size) }
        }
        var depth = 0
        if result == KERN_SUCCESS {
            stack[0] = UInt(state.__pc); depth = 1
            var frame = UInt(state.__fp)
            while depth < Self.depth, frame >= low, frame < high - 16, frame & 7 == 0 {
                let record = UnsafePointer<UInt>(bitPattern: frame)!
                stack[depth] = record[1] & 0x0000_007f_ffff_ffff; depth += 1
                guard record[0] > frame else { break }
                frame = record[0]
            }
        }
        thread_resume(main)
        times[count] = CACurrentMediaTime(); depths[count] = depth
        count += 1
    }

    func stop() { running = false; finished.wait() }

    /// (time, outermost-to-innermost symbol names).
    func symbolicated() -> [(Double, [String])] {
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let known = names[address] { return known }
            var info = Dl_info()
            var text = "?"
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let symbol = info.dli_sname {
                text = String(cString: symbol)
            } else if let image = info.dli_fname { text = URL(fileURLWithPath: String(cString: image)).lastPathComponent + "+?" }
            names[address] = text
            return text
        }
        return (0..<count).map { index in
            (times[index], (0..<depths[index]).reversed().map { name(frames[index * Self.depth + $0]) })
        }
    }

    deinit { frames.deallocate(); times.deallocate(); depths.deallocate() }
}
