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
            let cls: AnyClass = type(of: root)
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
                        if !layouts.finished, abs(view.bounds.width - (view.window?.frame.width ?? 0)) > 0.5 { layouts.stale += 1 }
                    }
                }
                original(object, selector)
            }
            // The root's specialized class may inherit `layout`; add an override
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
            let drag = try await self.drag(window, speed: 100, travel: 120) { layouts.finished = true }
            XCTAssertGreaterThan(drag.changes.count, 5, "The drag must publish buffered frames")
            XCTAssertGreaterThan(layouts.total, 5)
            XCTAssertEqual(layouts.stale, 0, "No buffered commit may lay the root out at its previous width")
            XCTAssertEqual(root.bounds.width, window.frame.width, accuracy: 0.5)
        }
    }

    /// Opt-in diagnostics: VANE_UI_PERFORMANCE=1 in a release build. No wall-clock
    /// assertions; compare main-thread CPU and published frames per second.
    func testLiveWindowResizeMainThreadCost() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VANE_UI_PERFORMANCE"] == "1")
        let counts = environment["VANE_RESIZE_PERF_COUNTS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [20, 300]
        let modes = environment["VANE_RESIZE_PERF_MODES"].map { $0.split(separator: ",").map(String.init) } ?? ["shown", "hidden"]
        let repeats = environment["VANE_RESIZE_PERF_REPEATS"].flatMap(Int.init) ?? 3
        let speed = environment["VANE_RESIZE_PERF_SPEED"].flatMap(Double.init) ?? 600
        let corner = environment["VANE_RESIZE_PERF_CORNER"] == "1"
        for count in counts {
            for mode in modes {
                try await withFixture(count: count, sidebarShown: mode != "hidden") { window, _ in
                    for attempt in 0..<repeats {
                        let ticks = ResizeDisplayTicks(window)
                        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        let drag = try await self.drag(window, speed: speed, travel: 450, corner: corner)
                        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
                        let gaps = ticks.stop()
                        let interval = 1000 / Double(window.screen?.maximumFramesPerSecond ?? 60)
                        let during = drag.changes.filter { $0 <= drag.ended }
                        let changeGaps = zip(during, during.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
                        func q(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? .nan : values[Int(Double(values.count - 1) * p)] }
                        func f(_ value: Double) -> String { String(format: "%.2f", value) }
                        print("RESIZE_PERF count=\(count) mode=\(mode)\(corner ? "+corner" : "") attempt=\(attempt)"
                              + " main_cpu_ms=\(f(cpu)) cpu_per_change_ms=\(f(cpu / Double(max(1, drag.changes.count))))"
                              + " changes_per_s=\(f(Double(during.count) / (drag.ended - drag.began)))"
                              + " change_gap_p50_ms=\(f(q(changeGaps, 0.5))) change_gap_p95_ms=\(f(q(changeGaps, 0.95)))"
                              + " change_gap_max_ms=\(f(changeGaps.last ?? .nan)) change_stalls=\(changeGaps.filter { $0 > interval * 1.5 }.count)"
                              + " tick_max_ms=\(f(gaps.max() ?? .nan)) ticks_missed=\(gaps.filter { $0 > interval * 1.5 }.count)/\(gaps.count)")
                        try await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
        }
    }

    private struct Drag { let began: Double; let ended: Double; let changes: [Double] }

    /// Pointer samples arrive on their own ~250Hz clock, like a mouse, not after
    /// the main thread finishes a frame, so the app rather than the fixture sets
    /// the cadence. Out and back along the right edge (and bottom, for a corner).
    private func drag(_ window: VaneWindow, speed: Double, travel: Double, corner: Bool = false,
                      beforeRelease: () -> Void = {}) async throws -> Drag {
        let baseline = window.frame
        let record = ResizeLayoutRecord()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                              object: window, queue: .main) { _ in
            MainActor.assumeIsolated { record.changes.append(CACurrentMediaTime()) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let duration = 2 * travel / speed
        let began = CACurrentMediaTime()
        window.beginPageResize(at: NSPoint(x: baseline.maxX, y: corner ? baseline.minY : baseline.midY))
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !record.finished else { return }
                let elapsed = min(CACurrentMediaTime() - began, duration)
                let offset = (elapsed < duration / 2 ? elapsed : duration - elapsed) * speed
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
        try await compatibilityWait { !window.isPreparingPageResize && abs(window.frame.width - baseline.width) < 1 }
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
    var changes: [Double] = []
    var finished = false
    var done: (() -> Void)?
}

/// Display-clock heartbeat: a gap above one refresh interval is a dropped main-thread frame.
@MainActor private final class ResizeDisplayTicks: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []

    init(_ window: NSWindow) {
        super.init()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(window.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { gaps.append((now - last) * 1000) }
        last = now
    }

    func stop() -> [Double] {
        link?.invalidate()
        link = nil
        return gaps
    }
}
