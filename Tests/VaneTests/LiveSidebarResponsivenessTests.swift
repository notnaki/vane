import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

/// A loaded document stays mounted while the real browser's sidebar and palette change.
/// Optional timing runs can use a public website instead of the local HTTP document.
@MainActor final class LiveSidebarResponsivenessTests: XCTestCase {
    func testLoadedPageSurvivesDisclosureSearchAndTabSelection() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try NavigationHTTPFixture()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/page"] = """
        <!doctype html><title>Live sidebar document</title>
        <style>body{font:20px system-ui}article{display:grid;grid-template-columns:repeat(4,1fr)}section{padding:24px;background:#ddd;margin:4px}</style>
        <input id="draft" value="keep this draft"><article>
        \((0..<150).map { "<section>Document card \($0)</section>" }.joined())
        </article><script>window.beats=0;setInterval(()=>window.beats++,16)</script>
        """
        let timing = ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1"
        let previousPolicy = NSApp.activationPolicy()
        if timing { NSApp.setActivationPolicy(.accessory) }
        defer { if timing { NSApp.setActivationPolicy(previousPolicy) } }
        let remote = ProcessInfo.processInfo.environment["VANE_LIVE_SITE_URL"].flatMap(URL.init(string:))
        let url = try remote ?? server.url("/page")
        let suggestionsEnabled = SearchSuggestions.enabled
        SearchSuggestions.enabled = false
        defer { SearchSuggestions.enabled = suggestionsEnabled }
        for count in timing ? [28, 300] : [28] {
            let profile = ProfileManager.shared.create(name: "Loaded document fixture").id
            let spaces = ["Work", "Neighbour"].map { Space(name: $0, profileID: profile) }
            XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
            let store = TabStore(profileID: profile, space: spaces[0], session: [])
            store.sharingReady = false
            // The closed Library stays mounted for swipe-in. Populate its archive too,
            // so sidebar interactions exercise that hidden subtree as a real profile does.
            let archive = Archive.shared(for: profile)
            for index in 0..<47 {
                archive.add(url: URL(string: url.absoluteString + "#archived-\(index)")!,
                            title: "Archived document \(index)")
            }
            let tabs = (0..<count).map { index in
                let tab = store.makeBlankTab(as: index < 4 ? .favourite : (index < 15 ? .pinned : .today))
                tab.park(url: URL(string: url.absoluteString + "#tab-\(index)")!, Parked(title: "Live document \(index)"))
                return tab
            }
            store.tabs = tabs
            let folder = Folder(name: "Documents")
            store.pins = Pins(entries: tabs[4..<8].map { .init(row: .tab($0.id.uuidString)) }
                + [.init(row: .folder(folder))]
                + tabs[8..<15].map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
            store.todayShape = Pins(entries: tabs[15...].map { .init(row: .tab($0.id.uuidString)) })
            store.palette = nil
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: timing ? 600 : 750),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            let host = BrowserWindowHost(shown: ShownStore(store))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            if timing { NSApp.activate(ignoringOtherApps: true) }
            SharedTabs.refreshPresentation()
            defer {
                archive.clear()
                store.clearSuggestions()
                store.spaceGesture.monitor.remove()
                store.librarySwipeMonitor.remove()
                window.contentView = nil
                window.close()
                store.window = nil
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                Store.forget(profile)
                ProfileManager.shared.delete(profile)
            }
            // Keep three actual WebKit documents alive, including the visible page.
            for tab in tabs[15..<18] {
                store.current = tab.id
                host.layoutSubtreeIfNeeded()
                try await compatibilityWait {
                    tab.existingWeb?.url != nil && tab.existingWeb?.isLoading == false && !tab.loading
                }
            }
            let active = tabs[17]
            let web = try XCTUnwrap(active.existingWeb)
            XCTAssertTrue(web.window === window)
            XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
            let title = try await web.evaluateJavaScript("document.title") as? String
            XCTAssertFalse(try XCTUnwrap(title).isEmpty)
            if remote == nil {
                let cards = try await web.evaluateJavaScript("document.querySelectorAll('section').length") as? Int
                XCTAssertEqual(cards, 150, "The content must be a rendered document, not a blank parked page")
                _ = try await web.evaluateJavaScript("document.getElementById('draft').value = 'edited draft retained'")
            }
            if timing {
                try XCTSkipUnless(window.occlusionState.contains(.visible),
                    "Timing requires a visible window on an unlocked desktop; discard occluded measurements")
            }
            let cadence = timing ? NativeChromeCadence() : nil
            if let screen = window.screen { cadence?.start(on: screen) }
            defer { cadence?.stop() }
            func scrollFrames(sidebar: Bool) async throws {
                guard timing else { return }
                func scrolls(in view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
                }
                func candidate() -> NSScrollView? { scrolls(in: host).first { scroll in
                    let rect = scroll.convert(scroll.bounds, to: host)
                    let extent = max(scroll.documentView?.bounds.height ?? 0,
                                     scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
                    return extent > 1 && rect.minX >= 0 && rect.height > 100 && (sidebar
                        ? rect.maxX < SidebarWidth.shared.width + 20
                        : rect.width > SidebarWidth.shared.width + 80 && rect.height < 500)
                } }
                try await compatibilityWait { candidate() != nil }
                let viewport = try XCTUnwrap(candidate())
                let limit = max(0, max(viewport.documentView?.bounds.height ?? 0,
                    viewport.documentView?.frame.height ?? 0) - viewport.contentView.bounds.height)
                XCTAssertGreaterThan(limit, 0, "Cadence diagnostics require a genuinely scrollable production list")
                // Keep velocity equal across outline sizes. Sweeping the full content
                // range makes 300 tabs demand vastly more new rows per frame than 28.
                let distance = min(limit, 16 * 44)
                print("CHROME_SCROLL \(sidebar ? "sidebar" : "cmdt") tabs=\(count) viewport=\(viewport.contentView.bounds.height) range=\(limit) distance=\(distance)")
                let point = viewport.convert(CGPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: nil)
                let startingOffset = viewport.contentView.bounds.minY
                var previous: CGFloat = 0
                var furthest = startingOffset
                cadence?.begin()
                for frame in 0..<90 {
                    let progress = CGFloat(frame < 45 ? frame : 89 - frame) / 44
                    let position = distance * progress
                    NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: previous - position,
                        phase: frame == 0 ? .began : .changed, x: point.x, y: point.y))
                    previous = position
                    // Exercise the production local monitors and scroll recipient.
                    // Direct clip-view writes bypass idle-preparation postponement.
                    try await Task.sleep(for: .milliseconds(8))
                    furthest = max(furthest, viewport.contentView.bounds.minY)
                }
                NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
                XCTAssertGreaterThan(furthest - startingOffset, min(distance / 2, 100),
                    "The native event must reach the intended scroll view")
                XCTAssertFalse(store.spaceSwiping, "Vertical input must keep its normal recipient")
                cadence?.report("\(sidebar ? "sidebar_scroll" : "cmdt_scroll") tabs=\(count)")
            }
            for iteration in 0..<3 {
                if timing {
                    try XCTSkipUnless(window.occlusionState.contains(.visible),
                        "The timing window became occluded; discard this run")
                }
                var lastBeat = ProcessInfo.processInfo.systemUptime
                var largestGap = 0.0
                let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = ProcessInfo.processInfo.systemUptime
                        largestGap = max(largestGap, now - lastBeat)
                        lastBeat = now
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                let start = ContinuousClock.now
                store.toggleFolder(folder.id)
                if !timing { host.layoutSubtreeIfNeeded() }
                let disclosure = start.duration(to: .now)
                try await Task.sleep(for: .milliseconds(600))
                if iteration == 0 { try await scrollFrames(sidebar: true) }
                let hide = ContinuousClock.now
                store.sidebarShown = false
                if !timing { host.layoutSubtreeIfNeeded() }
                let hiding = hide.duration(to: .now)
                try await Task.sleep(for: .milliseconds(250))
                let show = ContinuousClock.now
                store.sidebarShown = true
                if !timing { host.layoutSubtreeIfNeeded() }
                let showing = show.duration(to: .now)
                try await Task.sleep(for: .milliseconds(250))
                let open = ContinuousClock.now
                cadence?.begin()
                store.palette = .newTab
                // The timing driver must yield to AppKit's normal display cycle.
                // Forcing a whole-window layout on every input packet adds work that
                // real keyboard/scroll input does not request. Routine correctness
                // checks can still flush layout before inspecting mounted views.
                if !timing { host.layoutSubtreeIfNeeded() }
                let opening = open.duration(to: .now)
                try await compatibilityWait { window.firstResponder is NSTextView }
                let fieldReady = open.duration(to: .now)
                if timing {
                    try await Task.sleep(for: .milliseconds(180))
                    cadence?.report("cmdt_open tabs=\(count) iteration=\(iteration)")
                    cadence?.begin()
                }
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                var typing = Duration.zero
                for text in ["l", "li", "live", "live document"] {
                    let edit = ContinuousClock.now
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    if !timing { host.layoutSubtreeIfNeeded() }
                    typing = max(typing, edit.duration(to: .now))
                    try await Task.sleep(for: .milliseconds(20))
                }
                if timing { cadence?.report("cmdt_typing tabs=\(count) iteration=\(iteration)") }
                if iteration == 0 { try await scrollFrames(sidebar: false) }
                cadence?.begin()
                store.palette = nil
                if !timing { host.layoutSubtreeIfNeeded() }
                try await Task.sleep(for: .milliseconds(250))
                if timing { cadence?.report("cmdt_close tabs=\(count) iteration=\(iteration)") }
                XCTAssertTrue(active.existingWeb === web)
                XCTAssertTrue(web.window === window)
                XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
                if remote == nil {
                    let draft = try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
                    XCTAssertEqual(draft, "edited draft retained", "Disclosure/search must not reload the live document")
                }
                print("LIVE_SIDEBAR tabs=\(count) remote=\(remote != nil) iteration=\(iteration) natural_display=\(timing) disclosure_admission=\(disclosure) hide_admission=\(hiding) show_admission=\(showing) open_admission=\(opening) field_ready=\(fieldReady) typing_admission_max=\(typing) max_gap_ms=\(largestGap * 1000)")
            }
            store.current = tabs[15].id
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(tabs[15].existingWeb?.window === window)
            XCTAssertFalse(try XCTUnwrap(tabs[15].existingWeb).isHiddenOrHasHiddenAncestor)
        }
    }
}

/// Main-thread display callback availability, not a claim of compositor-presented FPS.
@MainActor private final class NativeChromeCadence: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var rate: Float = 0
    func start(on screen: NSScreen) {
        rate = Float(screen.maximumFramesPerSecond)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func begin() { previous = CACurrentMediaTime(); gaps.removeAll(keepingCapacity: true) }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if previous > 0 { gaps.append((now - previous) * 1000) }
        previous = now
    }
    func report(_ phase: String) {
        let sorted = gaps.sorted()
        guard !sorted.isEmpty else { print("CHROME_CADENCE \(phase) callbacks=0 hz=\(rate)"); return }
        let budget = 1000 / Double(rate)
        print("CHROME_CADENCE \(phase) callbacks=\(sorted.count) hz=\(rate) p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) max_ms=\(sorted.last!) over_1_5_frames=\(sorted.filter { $0 > budget * 1.5 }.count)")
    }
    func stop() { link?.invalidate(); link = nil }
}
