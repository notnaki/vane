import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class ScrollInvalidationTests: XCTestCase {
    /// Moving an already mounted viewport must not rebuild its stationary header.
    /// Both cutoff lines stay visible throughout this middle-of-content gesture.
    func testSidebarScrollDoesNotRebuildStationaryHeader() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let builds = BuildCount()
        let offset = OffsetValue()
        let geometry = NativeFixtureGeometry()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpaceSectionsLayout(animatesCutoffs: false, retainsRows: true, reportOffset: { offset.value = $0 }) {
            self.countedHeader(builds)
        } rows: {
            ForEach(0..<48) { index in
                Text("Row \(index)").frame(height: 30)
                    .background(NativeFixtureGeometryProbe(id: String(index), geometry: geometry))
            }
        })
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        defer { attachment?.cancel(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        let viewport = try await admitViewport(root: host, window: window, geometry: geometry,
            minimumHeight: 48 * 30 + 47 * Look.rowGap, spacing: Look.rowGap)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 80))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return offset.value >= 0 && abs(offset.value - viewport.documentVisibleRect.minY) < 1
                && NativeFixtureMountAdmission.populated(viewport, by: geometry.views,
                    root: host, window: window, spacing: Look.rowGap)
        }
        let before = builds.value
        let start = viewport.contentView.bounds.minY
        let contentHeight = try XCTUnwrap(viewport.documentView).frame.height
        XCTAssertGreaterThan(start, 1, "Begin with the top cutoff already visible")
        XCTAssertLessThan(start + viewport.contentView.bounds.height, contentHeight - 1,
            "Begin with the bottom cutoff already visible")
        let point = try XCTUnwrap(NativeFixtureMountAdmission.scrollPoint(viewport, root: host, window: window))
        let trace = ScrollTrace(scroll: viewport, root: host, window: window, point: point)
        defer { trace.close() }
        trace.capture("admitted", reported: offset.value, builds: builds.value)
        for sample in 0..<8 {
            trace.capture("before-\(sample)", reported: offset.value, builds: builds.value)
            NSApp.sendEvent(ScrollEvent(window: window, dy: -8,
                phase: sample == 0 ? .began : .changed, x: point.x, y: point.y))
            trace.capture("after-\(sample)", reported: offset.value, builds: builds.value)
            try await Task.sleep(for: .milliseconds(16))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(80))
        trace.capture("outcome80ms", reported: offset.value, builds: builds.value)
        XCTAssertGreaterThan(viewport.contentView.bounds.minY - start, 20,
            "The gesture must actually move the mounted viewport")
        XCTAssertLessThan(viewport.contentView.bounds.maxY, contentHeight - 1,
            "The gesture must not change either cutoff")
        XCTAssertEqual(builds.value, before,
            "User scroll-position writes must stay below the stationary header")
    }

    func testSidebarRestoresInitialOffsetAndReportsIt() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let offset = OffsetValue()
        let geometry = NativeFixtureGeometry()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpaceSectionsLayout(initialOffset: 120,
            animatesCutoffs: false, retainsRows: true, reportOffset: { offset.value = $0 }) {
                Text("Space header").frame(height: 30)
            } rows: {
                ForEach(0..<48) { index in
                Text("Row \(index)").frame(height: 30)
                    .background(NativeFixtureGeometryProbe(id: String(index), geometry: geometry))
            }
            })
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        defer { attachment?.cancel(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        _ = try await admitViewport(root: host, window: window, geometry: geometry,
            minimumHeight: 48 * 30 + 47 * Look.rowGap, spacing: Look.rowGap)
        // This 250ms is the original restoration outcome sample, not readiness.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(offset.value, 120, accuracy: 1,
            "A prepared Space viewport must restore and report its saved position")
    }

    func testResetReturnsToViewportTopWithPadding() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let request = ResetRequest()
        let geometry = NativeFixtureGeometry()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ResetList(request: request, geometry: geometry))
        host.sizingOptions = []
        let attachment = NativeFixtureMountAdmission.attach(host, to: window)
        defer { attachment?.cancel(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        let viewport = try await admitViewport(root: host, window: window, geometry: geometry,
            minimumHeight: 48 * 30, spacing: nil, topInset: 17)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 150))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(viewport.contentView.bounds.minY, 100)
        request.value += 1
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(viewport.contentView.bounds.minY, 0, accuracy: 1,
            "Search reset must keep the list's top padding inside the viewport")
    }

    private func admitViewport(root: NSView, window: NSWindow, geometry: NativeFixtureGeometry,
                               minimumHeight: CGFloat, spacing: CGFloat?, topInset: CGFloat = 0) async throws -> NSScrollView {
        func scroll(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        var admitted: NSScrollView?
        try await compatibilityWait {
            guard NativeFixtureMountAdmission.surfaceReady(root, in: window) else { return false }
            guard let viewport = scroll(in: root),
                  NativeFixtureMountAdmission.scrollReady(viewport, root: root, window: window, minimumHeight: minimumHeight),
                  let first = geometry["0"], let second = geometry["1"], let document = viewport.documentView
            else { return false }
            let firstRect = first.convert(first.bounds, to: document)
            let secondRect = second.convert(second.bounds, to: document)
            let gap = spacing ?? max(0, abs(secondRect.minY - firstRect.minY) - firstRect.height)
            guard NativeFixtureMountAdmission.populated(viewport, by: geometry.views,
                root: root, window: window, spacing: gap, topInset: topInset) else { return false }
            admitted = viewport
            return true
        }
        return try XCTUnwrap(admitted)
    }

    @MainActor private final class ScrollTrace {
        let scroll: NSScrollView
        let root: NSView
        let window: NSWindow
        let point: NSPoint
        private var records: [String] = []
        private var observers: [NSObjectProtocol] = []
        private var monitor: Any?
        private var applicationEvents = 0
        private let postedBounds: Bool
        init(scroll: NSScrollView, root: NSView, window: NSWindow, point: NSPoint) {
            self.scroll = scroll; self.root = root; self.window = window; self.point = point
            postedBounds = scroll.contentView.postsBoundsChangedNotifications
            scroll.contentView.postsBoundsChangedNotifications = true
            for (name, owner) in [(NSView.boundsDidChangeNotification, scroll.contentView as AnyObject),
                                  (NSScrollView.willStartLiveScrollNotification, scroll as AnyObject),
                                  (NSScrollView.didLiveScrollNotification, scroll as AnyObject),
                                  (NSScrollView.didEndLiveScrollNotification, scroll as AnyObject)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated {
                        guard let self else { return }
                        self.records.append("notification=\(name.rawValue) clip=\(self.scroll.contentView.bounds) uptime=\(ProcessInfo.processInfo.systemUptime)")
                    }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window {
                        self.applicationEvents += 1
                        self.records.append("application-event phase=\(event.phase.rawValue) point=\(event.locationInWindow) timestamp=\(event.timestamp)")
                    }
                }
                return event
            }
        }
        func capture(_ phase: String, reported: CGFloat, builds: Int) {
            let local = root.superview?.convert(point, from: nil) ?? point
            let hit = root.hitTest(local)
            records.append("phase=\(phase) scroll=\(ObjectIdentifier(scroll)) hit=\(hit.map { String(describing: type(of: $0)) + String(describing: ObjectIdentifier($0)) } ?? "nil") routedScroll=\(hit === scroll || hit?.enclosingScrollView === scroll) point=\(point) contentOwner=\(window.contentView === root) rootWindow=\(root.window === window) visible=\(window.isVisible) rootBounds=\(root.bounds) scrollFrame=\(scroll.frame) scrollBounds=\(scroll.bounds) clipFrame=\(scroll.contentView.frame) physicalClip=\(scroll.contentView.convert(scroll.contentView.bounds, to: root)) magnification=\(scroll.magnification) finishedLaunching=\(NSRunningApplication.current.isFinishedLaunching) appRunning=\(NSApp.isRunning) appActive=\(NSApp.isActive) key=\(window.isKeyWindow) clip=\(scroll.contentView.bounds) document=\(String(describing: scroll.documentView?.bounds)) viewport=\(scroll.documentVisibleRect) reported=\(reported) builds=\(builds) applicationEvents=\(applicationEvents) uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            scroll.contentView.postsBoundsChangedNotifications = postedBounds
            records.forEach { print("NATIVE_SCROLL_TRACE " + $0) }
        }
    }

    private final class BuildCount { var value = 0 }
    private final class OffsetValue { var value: CGFloat = -1 }
    private final class ResetRequest: ObservableObject { @Published var value = 0 }
    private struct ResetList: View {
        @ObservedObject var request: ResetRequest
        let geometry: NativeFixtureGeometry
        var body: some View {
            ScrollView {
                VStack {
                    ForEach(0..<48) { index in
                        Text("Row \(index)").frame(height: 30)
                            .background(NativeFixtureGeometryProbe(id: String(index), geometry: geometry))
                    }
                }
                    .padding(.top, 17)
            }
            .modifier(ScrollViewportPosition(resetRequest: request.value))
        }
    }
    private func countedHeader(_ count: BuildCount) -> some View {
        count.value += 1
        return Text("Stationary Space header").frame(height: 30)
    }
}
