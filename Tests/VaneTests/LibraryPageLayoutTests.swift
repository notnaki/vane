import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LibraryPageLayoutTests: XCTestCase {
    private struct PageProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private struct CardProbe: View {
        let view: NSView
        var body: some View {
            WebCard().overlayPreferenceValue(PeekContentBounds.self) { anchor in
                GeometryReader { geometry in
                    if let anchor {
                        let bounds = geometry[anchor]
                        PageProbe(view: view)
                            .frame(width: bounds.width, height: bounds.height)
                            .offset(x: bounds.minX, y: bounds.minY)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    func testLibraryDocumentFollowsTheVisibleCardWithoutAnEndpointWidthJump() async throws {
        try await documentCardBounds(animated: false)
    }

    func testFindCannotPushTheRealCardOverLibraryOrBeyondWindow() async throws {
        try await documentCardBounds(animated: false, findOpen: true)
    }

    func testSplitDocumentsStayInsideTheCardThroughoutLibraryMovement() async throws {
        try await documentCardBounds(animated: false, split: true)
    }

    func testFloatingLibraryGutterReachesItsEndpointBeforeTheGestureClears() async throws {
        try await documentCardBounds(animated: false, floating: true)
    }

    func testAnimatedDocumentKeepsThePresentedCardInsideTheWindow() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.reduced, "Requires animated card presentation")
        try await documentCardBounds(animated: true)
    }

    private func documentCardBounds(animated: Bool, findOpen: Bool = false, split: Bool = false, floating: Bool = false) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        do { try await checkDocumentCardBounds(animated: animated, findOpen: findOpen, split: split, floating: floating) }
        catch { try await loop.close(); throw error }
        try await loop.close()
    }

    private func checkDocumentCardBounds(animated: Bool, findOpen: Bool, split: Bool, floating: Bool) async throws {
#if DEBUG
        let traceLayout = ProcessInfo.processInfo.environment["VANE_LIBRARY_LAYOUT_TRACE"] == "1"
        let previousSink = ResizeTimingDiagnostics.stateSink
        var layoutEvents: [String] = []
        if traceLayout {
            ResizeTimingDiagnostics.stateSink = { event, time, fields in
                let keys = ["buffer", "requestedSidebar", "publishedSidebar", "pending", "ending", "active",
                            "page.0.desired", "page.0.prepared", "page.0.painted", "page.0.visible",
                            "page.0.parentBounds", "page.1.desired", "page.1.prepared", "page.1.painted",
                            "page.1.visible", "page.1.parentBounds"]
                let values = keys.compactMap { key in fields[key].map { "\(key)=\($0)" } }.joined(separator: " ")
                layoutEvents.append("LIBRARY_LAYOUT t=\(time) event=\(event) \(values)")
                if layoutEvents.count > 120 { layoutEvents.removeFirst() }
            }
        }
        defer {
            if traceLayout {
                ResizeTimingDiagnostics.stateSink = previousSink
                layoutEvents.forEach { print($0) }
            }
        }
#endif
        let store = TabStore(isPrivate: true, session: [])
        let tab = store.newBlankTab(loading: URL(string: "about:blank"))
        store.sidebarShown = !floating
        store.libraryOpen = true
        store.palette = nil
        store.findOpen = findOpen
        let second = split ? store.newBlankTab(focus: false) : nil
        if let second { store.splits = [try XCTUnwrap(Split(tabs: [tab.id, second.id]))] }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let gesture = LibraryGesture()
        gesture.pageLeadingInset = 0
        gesture.progress = 0
        let card = NSView()
        card.wantsLayer = true
        let host = NSHostingView(rootView: LibraryNavigationLayout(gesture: gesture,
            libraryOpen: true, sidebarShown: !floating, floating: floating, panelWidth: 392,
            palettePresented: false, monitor: LibrarySwipeMonitor(),
            page: CardProbe(view: card), sidebar: Color.clear, panel: Color.clear)
            .environmentObject(store).environmentObject(ProfileManager.shared))
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        defer {
            attachment?.cancel()
            store.librarySwipeMonitor.remove(); store.spaceGesture.monitor.remove()
            window.orderOut(nil); window.contentView = nil; store.window = nil; window.close()
            store.dropStashes(); SharedTabs.release(store.tabs, excluding: store)
            TabStore.all.removeAll { $0 === store }
        }
        appActivate(window)
        try await compatibilityWait {
            NativeFixtureMountAdmission.surfaceReady(host, in: window)
                && card.window === window && card.bounds.width > 100 && tab.web.window === window
                && card.layer?.presentation() != nil && host.layer?.presentation() != nil
        }
        func presentedCardBounds() throws -> CGRect {
            let presented = try XCTUnwrap(card.layer?.presentation())
            let root = try XCTUnwrap(host.layer?.presentation())
            return presented.convert(presented.bounds, to: root)
        }
        var intermediatePositions = 0
        for progress: CGFloat in [0, 0.25, 0.5, 0.75, 0.9999, 1, 0.5, 0] {
            if animated {
                let start = try presentedCardBounds().minX
                let target = 228 + 164 * progress
                withAnimation(.linear(duration: 0.12)) { gesture.progress = progress }
                for _ in 0..<8 {
                    try await Task.sleep(for: .milliseconds(20))
                    let bounds = try presentedCardBounds()
                    XCTAssertEqual(bounds.maxX, 629, accuracy: 1,
                        "The visible rim must not drift during navigation")
                    XCTAssertGreaterThanOrEqual(bounds.minX, 227)
                    XCTAssertLessThanOrEqual(bounds.minX, 393)
                    if bounds.minX > min(start, target) + 1 && bounds.minX < max(start, target) - 1 {
                        intermediatePositions += 1
                    }
                }
            } else { Motion.instant { gesture.progress = progress } }
            host.layoutSubtreeIfNeeded()
            // Admit the update without awaiting the bounds under assertion.
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            if !animated {
                // This is an endpoint geometry check. Admit the completed native
                // paint transaction; animated samples above remain unawaited.
                func pending(_ view: NSView) -> Bool {
                    if let bridge = view as? LibraryPaintView { return !bridge.isSettled }
                    return view.subviews.contains(where: pending)
                }
                try await compatibilityWait { !pending(host) }
            }
            let bounds = card.convert(card.bounds, to: host)
            XCTAssertEqual(bounds.minX, floating ? 11 + 381 * progress : 228 + 164 * progress, accuracy: 1,
                "The real card must start after navigation, during navigation")
            XCTAssertEqual(bounds.maxX, 629, accuracy: 1,
                "The real card's rim must stay eleven points inside the narrow window")
            if let second {
                let firstBounds = tab.web.convert(tab.web.bounds, to: host)
                let secondBounds = second.web.convert(second.web.bounds, to: host)
                XCTAssertEqual(firstBounds.minX, bounds.minX, accuracy: 1)
                XCTAssertEqual(secondBounds.maxX, bounds.maxX, accuracy: 1)
                XCTAssertEqual(firstBounds.width + secondBounds.width + Look.splitGap, bounds.width, accuracy: 1)
            } else {
                XCTAssertEqual(tab.web.bounds.width, bounds.width, accuracy: 1,
                    "The document must fill the visible card during movement, not jump to its width at release")
            }
        }
        if animated { XCTAssertGreaterThan(intermediatePositions, 0, "Observe real intermediate presentation") }
    }

    func testClosingLibraryKeepsPageRightEdgeAtWindowInset() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        do {
            try await checkPageRightEdge()
        } catch {
            try await loop.close()
            throw error
        }
        try await loop.close()
    }

    private func checkPageRightEdge() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let gesture = LibraryGesture()
        gesture.progress = 1
        let page = NSView()
        let host = NSHostingView(rootView: LibraryNavigationLayout(gesture: gesture,
            libraryOpen: true, sidebarShown: true, floating: false, panelWidth: 392,
            palettePresented: false, monitor: LibrarySwipeMonitor(),
            page: PageProbe(view: page), sidebar: Color.clear, panel: Color.clear))
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        defer {
            attachment?.cancel()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        appActivate(window)
        try await compatibilityWait {
            NativeFixtureMountAdmission.surfaceReady(host, in: window)
                && page.window === window && page.bounds.width > 100
        }
        for progress: CGFloat in [1, 0.75, 0.5, 0.25, 0] {
            Motion.instant { gesture.progress = progress }
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                let expectedLeft = 228 + 164 * progress
                return abs(page.convert(page.bounds, to: host).minX - expectedLeft) < 1
            }
            let rect = page.convert(page.bounds, to: host)
            XCTAssertEqual(rect.maxX, 900, accuracy: 1,
                "The card's right edge must stay anchored while Library closes (progress \(progress))")
            XCTAssertEqual(window.frame.width, 900, accuracy: 1)
        }
    }

    private func appActivate(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
