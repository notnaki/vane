import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Functional viewport continuity, not an FPS benchmark. Parked tabs are intentional.
@MainActor final class EdgeSidebarScrollContinuityTests: XCTestCase {
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func fixture(left: Bool, activePage: Bool = false) throws -> (TabStore, NSWindow, BrowserWindowHost) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        try XCTSkipIf(Motion.spaceReduced, "Requires animated edge navigation")
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
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
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
            else { XCTAssertTrue(manager.delete(profile.id)) }
            SidebarWidth.shared.width = previousWidth
            BatterySaver.shared.setMode(previousSaver)
        }
        XCTAssertEqual(left ? store.strip.first?.id : store.strip.last?.id, space.id,
                       "Exercise the actual Library/Create boundary, not an ordinary Space neighbor")
        return (store, window, host)
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

    private func scrollDown(_ scroll: NSScrollView, window: NSWindow) async throws {
        let point = scroll.convert(NSPoint(x: 100, y: 80), to: nil)
        NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began))
        for _ in 0..<80 {
            let distance = 180 - scroll.documentVisibleRect.minY
            if abs(distance) < 0.5 { break }
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point,
                dy: -max(-20, min(20, distance))))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .ended))
        try await Task.sleep(for: .milliseconds(200))
        // Native precise-wheel events can coast after fingers-up. Capture the settled
        // departure rather than mistaking that normal vertical travel for an edge jump.
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 100)
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
        let (store, window, host) = try fixture(left: true, activePage: activePage)
        try await Task.sleep(for: .milliseconds(150))
        let live = try sidebarScroll(host)
        live.wantsLayer = true
        try await scrollDown(live, window: window)
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

    func testCreateEdgeNeverShowsAnOutgoingViewportAtTheTop() async throws {
        try await checkCreateEdge(commit: false)
    }

    func testCreateEdgeCommitKeepsScrolledViewportUntilFormTakesOver() async throws {
        try await checkCreateEdge(commit: true)
    }

    private func checkCreateEdge(commit: Bool) async throws {
        let (store, window, host) = try fixture(left: false)
        try await Task.sleep(for: .milliseconds(150))
        let live = try sidebarScroll(host)
        try await scrollDown(live, window: window)
        if ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
            _ = try SidebarSnapshot.pixels(in: host)
        }
        let offset = live.documentVisibleRect.minY, size = live.contentView.bounds.size
        XCTAssertEqual(store.spaceGesture.sidebarOffset, offset, accuracy: 1)
        let existing = Set(descendants(host, NSScrollView.self).map(ObjectIdentifier.init))
        let startingRect = live.convert(live.bounds, to: host)
        var observedGhost = false
        let point = live.convert(NSPoint(x: 100, y: 80), to: nil)
        NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: .began))
        for dx: CGFloat in [-30, -25, 20, commit ? -50 : 0] {
            NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, dx: dx))
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
        NSApp.sendEvent(EdgeContinuityEvent(window: window, point: point, phase: commit ? .ended : .cancelled))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.creatingSpace, commit)
        XCTAssertFalse(store.spaceSwiping)
        if !commit { XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1) }
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
    @MainActor init(window: NSWindow, point: NSPoint, dx: CGFloat = 0, dy: CGFloat = 0,
                    phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []) {
        owner = window; number = window.windowNumber; self.point = point
        self.dx = dx; self.dy = dy; eventPhase = phase
        self.momentum = momentum
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
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
