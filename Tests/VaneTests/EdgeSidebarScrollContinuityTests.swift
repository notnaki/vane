import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Functional viewport continuity, not an FPS benchmark. Parked tabs are intentional.
@MainActor final class EdgeSidebarScrollContinuityTests: XCTestCase {
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func withFixture(left: Bool, activePage: Bool = false,
                             exercise: @MainActor (TabStore, NSWindow, BrowserWindowHost) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        try XCTSkipIf(Motion.spaceReduced, "Requires animated edge navigation")
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let previousSaver = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        let previousWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = 250
        let manager = ProfileManager.shared
        let profile = left ? manager.profiles[0] : manager.create(name: "Right edge fixture")
        let saved = manager.spaces(for: profile.id)
        let space = Space(name: "Edge", profileID: profile.id)
        XCTAssertTrue(manager.saveSpaces([space], for: profile.id))
        let store = TabStore(profileID: profile.id, space: space, session: [])
        store.sharingReady = false
        store.palette = nil
        store.sidebarShown = true
        store.libraryOpen = false
        let nonce = UUID()
        store.tabs = (0..<31).map { index in
            let tab = Tab(profileID: profile.id)
            tab.park(url: URL(string: "about:blank#edge-\(nonce)-\(index)")!, Parked(title: "Edge row \(index)"))
            return tab
        }
        store.syncShapes()
        if activePage { store.current = store.tabs.first?.id }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        store.window = window
        if activePage { SharedTabs.refreshPresentation(changingSelectionIn: store, previous: nil) }
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        // Explicit activation is required for this command-line native host.
        // Cooperative activate() can leave it in the background indefinitely.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func cleanup() async throws {
            defer {
                SidebarWidth.shared.width = previousWidth
                BatterySaver.shared.setMode(previousSaver)
            }
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            if left { XCTAssertTrue(manager.saveSpaces(saved, for: profile.id)) }
            else {
                try await NativeFixtureProfileCleanup.release([profile.id])
                XCTAssertTrue(manager.delete(profile.id))
            }
        }
        XCTAssertEqual(left ? store.strip.first?.id : store.strip.last?.id, space.id,
                       "Exercise the actual Library/Create boundary, not an ordinary Space neighbor")
        var failure: (any Error)?
        do {
            try await compatibilityWait {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                host.layoutSubtreeIfNeeded()
                guard try loop.isReadyForInteraction(), NSApp.isActive, NSApp.keyWindow === window,
                      window.isVisible, window.occlusionState.contains(.visible),
                      NSApp.modalWindow == nil, window.attachedSheet == nil,
                      store.spaceGesture.monitor.isInstalled,
                      let sections = store.spaceGesture.sectionsView,
                      sections.window === window, !sections.isHiddenOrHasHiddenAncestor,
                      sections.bounds.width > 0, sections.bounds.height > 0,
                      let layer = sections.layer, let presented = layer.presentation(),
                      let root = host.layer, let presentedRoot = root.presentation() else { return false }
                let actual = presented.convert(CGPoint.zero, to: presentedRoot)
                let expected = layer.convert(CGPoint.zero, to: root)
                return abs(actual.x - expected.x) < 0.125 && abs(actual.y - expected.y) < 0.125
            }
            try await exercise(store, window, host)
        } catch {
            let sections = store.spaceGesture.sectionsView
            let layer = sections?.layer
            let root = host.layer
            let presented = layer?.presentation()
            let presentedRoot = root?.presentation()
            print("EDGE_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) unoccluded=\(window.occlusionState.contains(.visible)) owner=\(sections?.window === window) hidden=\(String(describing: sections?.isHiddenOrHasHiddenAncestor)) bounds=\(String(describing: sections?.bounds)) monitor=\(store.spaceGesture.monitor.isInstalled) modal=\(NSApp.modalWindow != nil) sheet=\(window.attachedSheet != nil) layer=\(layer != nil) presented=\(presented != nil) root=\(root != nil) presentedRoot=\(presentedRoot != nil) loop=\(String(describing: try? loop.isReadyForInteraction())) front=\(String(describing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))")
            if let layer, let root, let presented, let presentedRoot {
                print("EDGE_ADMISSION actual=\(presented.convert(CGPoint.zero, to: presentedRoot)) expected=\(layer.convert(CGPoint.zero, to: root))")
            }
            failure = error
        }
        do { try await cleanup() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Edge fixture cleanup also failed: \(error)") }
        }
        // Join in the test task after retiring the native owner, before XCTest
        // starts teardown inside its nested waiter.
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Edge fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func sidebarScroll(_ host: NSView) throws -> NSScrollView {
        let candidates = descendants(host, NSScrollView.self).filter {
            let rect = $0.convert($0.bounds, to: host)
            return !$0.isHiddenOrHasHiddenAncestor && rect.minX >= -1
                && rect.maxX <= SidebarWidth.shared.width + 20 && rect.height > 100
                && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 200
        }
        XCTAssertEqual(candidates.count, 1, "Do not accidentally select Library or a prepared ghost")
        return try XCTUnwrap(candidates.first)
    }

    private func presentedOrigin(_ view: NSView) throws -> CGPoint {
        try XCTUnwrap(view.layer?.presentation()).convert(.zero, to: nil)
    }

    private func scrollDown(_ scroll: NSScrollView, window: NSWindow, store: TabStore) async throws {
        let target: CGFloat = 180
        // Set up the native viewport directly, as in the scroll-invalidation fixtures.
        // Feeding corrections against precise-wheel animation can reverse unfinished
        // travel and mistake a transient target crossing for a settled departure.
        let deadline = ContinuousClock.now + .milliseconds(840) // Previous 80 × 8ms + 200ms budget.
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        var settledSamples = 0
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            let actual = scroll.documentVisibleRect.minY
            let reported = store.spaceGesture.sidebarOffset
            if ContinuousClock.now < deadline,
               abs(actual - target) < 0.5 && abs(reported - actual) < 0.5 {
                settledSamples += 1
                if settledSamples == 2 { break }
            } else { settledSamples = 0 }
            try await Task.sleep(for: .milliseconds(8))
        } while ContinuousClock.now < deadline
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 100)
        guard settledSamples == 2 else {
            XCTFail("Native sidebar must settle at \(target) and report its departure before edge input; actual=\(scroll.documentVisibleRect.minY), reported=\(store.spaceGesture.sidebarOffset)")
            throw NSError(domain: "EdgeViewportAdmission", code: 1)
        }
    }

    func testLibraryEdgePreservesScrolledLiveViewportThroughClaimReversalAndCancel() async throws {
        try await checkLibraryEdge(commit: false)
    }

    func testLibraryEdgeCommitAndCloseRestoreTheScrolledViewport() async throws {
        try await checkLibraryEdge(commit: true)
    }

    func testLibraryDiagonalStartupAndMomentumKeepTheClaimedViewportSteady() async throws {
        try await checkLibraryEdge(commit: false, diagonal: true)
    }

    func testLibraryWithAnActivePageKeepsTheScrolledViewportAndPageWidthSteady() async throws {
        try await checkLibraryEdge(commit: true, activePage: true)
    }

    private func checkLibraryEdge(commit: Bool, diagonal: Bool = false, activePage: Bool = false) async throws {
        try await withFixture(left: true, activePage: activePage) { store, window, host in
            let live = try sidebarScroll(host)
            live.wantsLayer = true
            try await scrollDown(live, window: window, store: store)
            if ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
                _ = try SidebarSnapshot.pixels(in: host)
            }
            var offset = live.documentVisibleRect.minY
            let size = live.contentView.bounds.size
            let startingRect = live.convert(live.bounds, to: window.contentView)
            let presentedStart = try presentedOrigin(live)
            let page = activePage ? store.active?.existingWeb : nil
            let pageWidth = page?.bounds.width
            if activePage {
                XCTAssertTrue(try XCTUnwrap(page).window === window, "Exercise a mounted local WebKit page")
                XCTAssertGreaterThan(try XCTUnwrap(pageWidth), 100)
            }
            let y = startingRect.minY
            let point = live.convert(NSPoint(x: 100, y: 80), to: nil)
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began))
            if diagonal {
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: 3, dy: 2))
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(store.librarySwipeProgress, "Startup noise still belongs to the native scroll view")
                offset = live.documentVisibleRect.minY
            }
            var travel: CGFloat = diagonal ? 3 : 0
            for dx: CGFloat in [30, 25, -20, commit ? 50 : 0] {
                travel += dx
                let start = ProcessInfo.processInfo.systemUptime
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: dx))
                host.layoutSubtreeIfNeeded()
                if ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1" {
                    print("SCROLLED_LIBRARY_LAYOUT offset=\(offset) dx=\(dx) ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
                }
                XCTAssertNotNil(store.librarySwipeProgress, "Library must actually claim the edge gesture")
                for _ in 0..<4 {
                    XCTAssertEqual(live.convert(live.bounds, to: window.contentView).minX - startingRect.minX,
                                   travel, accuracy: 1, "The native sidebar must follow fingers one to one")
                    XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1)
                    XCTAssertEqual(live.contentView.bounds.size, size)
                    XCTAssertEqual(live.convert(live.bounds, to: window.contentView).minY, y, accuracy: 1)
                    if let page, let pageWidth { XCTAssertEqual(page.bounds.width, pageWidth, accuracy: 1) }
                    try await Task.sleep(for: .milliseconds(8))
                }
                try await Task.sleep(for: .milliseconds(20))
                let presented = try presentedOrigin(live)
                XCTAssertEqual(presented.x - presentedStart.x, travel, accuracy: 1,
                               "The compositor must preserve the same scrolled sidebar track")
                XCTAssertEqual(presented.y, presentedStart.y, accuracy: 1)
                if dx == 30, ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
                    _ = try SidebarSnapshot.pixels(in: host)
                }
            }
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: commit ? .ended : .cancelled))
            if diagonal {
                for _ in 0..<4 {
                    NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: 15, dy: 10,
                                                      phase: [], momentum: .changed))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1)
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(store.libraryOpen, commit)
            XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1)
            if commit {
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began))
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: -100))
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .ended))
                try await Task.sleep(for: .milliseconds(350))
            }
            XCTAssertFalse(store.libraryOpen)
            XCTAssertEqual(try sidebarScroll(host), live)
            XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1)
            if let page, let pageWidth { XCTAssertEqual(page.bounds.width, pageWidth, accuracy: 1) }
        }
    }

    func testCreateEdgeNeverShowsAnOutgoingViewportAtTheTop() async throws {
        try await checkCreateEdge(commit: false)
    }

    func testCreateEdgeCommitKeepsScrolledViewportUntilFormTakesOver() async throws {
        try await checkCreateEdge(commit: true)
    }

    func testCreateEdgeCancellationAnimatesTheLiveViewportHome() async throws {
        try await checkCreateEdgeReturn(clickCurrentSpace: false)
    }

    func testClickingCurrentSpaceAtCreateEdgeAnimatesTheLiveViewportHome() async throws {
        try await checkCreateEdgeReturn(clickCurrentSpace: true)
    }

    private func checkCreateEdgeReturn(clickCurrentSpace: Bool) async throws {
        try await withFixture(left: false) { store, window, host in
            let live = try sidebarScroll(host)
            live.wantsLayer = true
            let start = try presentedOrigin(live).x
            let point = live.convert(NSPoint(x: 100, y: 80), to: nil)
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began))
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: -60))
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNil(host.spaceSlide, "The Create edge uses the live SwiftUI track")
            let departure = try presentedOrigin(live).x
            XCTAssertLessThan(departure, start - 5)
            let observer = EdgeReturnObserver(view: live, start: start, departure: departure)
            observer.start(on: try XCTUnwrap(window.screen))
            defer { observer.stop() }
            if clickCurrentSpace {
                store.spaceGesture.monitor.select(try XCTUnwrap(store.swipeSpace), in: store)
            } else {
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .cancelled))
            }
            // A display callback can observe the real intermediate frame while a
            // sleeping task resumes only after the spring has finished. Keep the
            // same 350 ms outcome window and require the same presented geometry.
            observer.arm()
            repeat {
                try await Task.sleep(for: .milliseconds(8))
                if observer.sawIntermediate { break }
            } while ProcessInfo.processInfo.systemUptime < observer.deadline
            observer.stop()
            XCTAssertFalse(observer.missingPresentation,
                           "Return samples must retain the admitted native viewport")
            XCTAssertTrue(observer.sawIntermediate,
                          "Cancellation must animate instead of snapping home; active=\(NSApp.isActive), key=\(window.isKeyWindow), start=\(start), departure=\(departure), times=\(observer.sampleTimes), samples=\(observer.samples)")
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(try presentedOrigin(live).x, start, accuracy: 1)
            XCTAssertFalse(store.spaceSwiping)
        }
    }

    private func checkCreateEdge(commit: Bool) async throws {
        try await withFixture(left: false) { store, window, host in
            let live = try sidebarScroll(host)
            try await scrollDown(live, window: window, store: store)
            if ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
                _ = try SidebarSnapshot.pixels(in: host)
            }
            let offset = live.documentVisibleRect.minY, size = live.contentView.bounds.size
            XCTAssertEqual(store.spaceGesture.sidebarOffset, offset, accuracy: 1)
            let existing = Set(descendants(host, NSScrollView.self).map(ObjectIdentifier.init))
            let startingRect = live.convert(live.bounds, to: host)
            var observedGhost = false
            let point = live.convert(NSPoint(x: 100, y: 80), to: nil)
            let gestureStart = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began, timestamp: gestureStart))
            // Preserve the reversal, then finish a full sidebar-width pull with
            // deliberate timing. The old 85pt gesture no longer meets creation's policy.
            for (index, dx) in [CGFloat(-30), -25, 20, commit ? -215 : 0].enumerated() {
                NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: dx,
                                                  timestamp: gestureStart + Double(index + 1) * 0.1))
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(store.spaceSwiping)
                XCTAssertNil(store.spaceGesture.neighbour, "This must exercise Create Space, not a prepared neighbor")
                XCTAssertNil(host.spaceSlide)
                for _ in 0..<3 {
                    // A fix may retain the live viewport instead of creating a ghost. If it
                    // creates one, the first realized viewport must already match departure.
                    for scroll in descendants(host, NSScrollView.self) where !existing.contains(ObjectIdentifier(scroll)) {
                        let rect = scroll.convert(scroll.bounds, to: host)
                        guard !scroll.isHiddenOrHasHiddenAncestor, rect.maxX > 0,
                              rect.minX < SidebarWidth.shared.width, rect.height > 100 else { continue }
                        observedGhost = true
                        XCTAssertEqual(scroll.documentVisibleRect.minY, offset, accuracy: 1,
                                       "The newly visible outgoing viewport must not flash its first row")
                        XCTAssertEqual(scroll.contentView.bounds.size, size)
                    }
                    XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1)
                    XCTAssertEqual(live.contentView.bounds.size, size)
                    XCTAssertEqual(live.convert(live.bounds, to: host).minY, startingRect.minY, accuracy: 1)
                    try await Task.sleep(for: .milliseconds(8))
                }
                if dx == -30, ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
                    _ = try SidebarSnapshot.pixels(in: host)
                }
            }
            XCTAssertTrue(observedGhost || live.convert(live.bounds, to: host).minX < startingRect.minX - 5,
                          "Observe an actual outgoing surface; a model-only gesture is insufficient")
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: commit ? .ended : .cancelled,
                                              timestamp: gestureStart + 0.5))
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(store.creatingSpace, commit)
            XCTAssertFalse(store.spaceSwiping)
            if !commit { XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1) }
        }
    }
}

/// Observes presentation on display delivery, independent of async task resumption.
@MainActor private final class EdgeReturnObserver: NSObject {
    private weak var view: NSView?
    private let start: CGFloat
    private let departure: CGFloat
    private var link: CADisplayLink?
    private var began: TimeInterval?
    private(set) var deadline: TimeInterval = 0
    private(set) var sawIntermediate = false
    private(set) var missingPresentation = false
    private(set) var samples: [CGFloat] = []
    private(set) var sampleTimes: [TimeInterval] = []

    init(view: NSView, start: CGFloat, departure: CGFloat) {
        self.view = view
        self.start = start
        self.departure = departure
    }

    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func arm() {
        let now = ProcessInfo.processInfo.systemUptime
        began = now
        deadline = now + 0.35
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let began, now <= deadline else { return }
        guard let presentation = view?.layer?.presentation() else {
            missingPresentation = true
            return
        }
        let returning = presentation.convert(.zero, to: nil).x
        samples.append(returning)
        sampleTimes.append(now - began)
        if returning > departure + 0.1, returning < start - 0.1 { sawIntermediate = true }
    }
}

private final class EdgeContinuityEvent: NSEvent, @unchecked Sendable {
    let owner: NSWindow
    let number: Int
    let point: NSPoint
    let dx: CGFloat
    let dy: CGFloat
    let eventPhase: NSEvent.Phase
    let momentum: NSEvent.Phase
    private let fixtureTimestamp: TimeInterval?
    @MainActor init(window: NSWindow, point: NSPoint, dx: CGFloat = 0, dy: CGFloat = 0,
                    phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = [], timestamp: TimeInterval? = nil) {
        owner = window; number = window.windowNumber; self.point = point
        self.dx = dx; self.dy = dy; eventPhase = phase
        self.momentum = momentum
        fixtureTimestamp = timestamp
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { owner }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { fixtureTimestamp ?? ProcessInfo.processInfo.systemUptime }
}
