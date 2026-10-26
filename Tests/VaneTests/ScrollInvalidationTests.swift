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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpaceSectionsLayout(animatesCutoffs: false, retainsRows: true) {
            self.countedHeader(builds)
        } rows: {
            ForEach(0..<48) { index in Text("Row \(index)").frame(height: 30) }
        })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        func scroll(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let viewport = try XCTUnwrap(scroll(in: host))
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 80))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(250))
        let before = builds.value
        let start = viewport.contentView.bounds.minY
        let contentHeight = try XCTUnwrap(viewport.documentView).frame.height
        XCTAssertGreaterThan(start, 1, "Begin with the top cutoff already visible")
        XCTAssertLessThan(start + viewport.contentView.bounds.height, contentHeight - 1,
            "Begin with the bottom cutoff already visible")
        let point = viewport.convert(NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: nil)
        for sample in 0..<8 {
            NSApp.sendEvent(ScrollEvent(window: window, dy: -8,
                phase: sample == 0 ? .began : .changed, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(16))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(80))
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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpaceSectionsLayout(initialOffset: 120,
            animatesCutoffs: false, retainsRows: true, reportOffset: { offset.value = $0 }) {
                Text("Space header").frame(height: 30)
            } rows: {
                ForEach(0..<48) { index in Text("Row \(index)").frame(height: 30) }
            })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(offset.value, 120, accuracy: 1,
            "A prepared Space viewport must restore and report its saved position")
    }

    func testResetReturnsToViewportTopWithPadding() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let request = ResetRequest()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ResetList(request: request))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func scroll(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let viewport = try XCTUnwrap(scroll(in: host))
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 150))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(viewport.contentView.bounds.minY, 100)
        request.value += 1
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(viewport.contentView.bounds.minY, 0, accuracy: 1,
            "Search reset must keep the list's top padding inside the viewport")
    }

    private final class BuildCount { var value = 0 }
    private final class OffsetValue { var value: CGFloat = -1 }
    private final class ResetRequest: ObservableObject { @Published var value = 0 }
    private struct ResetList: View {
        @ObservedObject var request: ResetRequest
        var body: some View {
            ScrollView {
                VStack { ForEach(0..<48) { index in Text("Row \(index)").frame(height: 30) } }
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
