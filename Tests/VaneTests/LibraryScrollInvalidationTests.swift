import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LibraryScrollInvalidationTests: XCTestCase {
    private final class Builds { var value = 0 }
    private final class Rows: ObservableObject { @Published var count = 48 }

    private struct Fixture: View {
        @ObservedObject var rows: Rows
        let builds: Builds
        var body: some View {
            LibraryScrollView { countedRows(rows.count) }
        }
        private func countedRows(_ count: Int) -> some View {
            builds.value += 1
            return LazyVStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Text("Library row \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 30)
                }
            }
        }
    }

    private func mount(rows: Rows, builds: Builds) async throws -> (NSWindow, NSHostingView<Fixture>, NSScrollView) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 300),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Fixture(rows: rows, builds: builds))
        window.contentView = host
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            NSApp.setActivationPolicy(policy)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func scrolls(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
        }
        try await compatibilityWait { scrolls(in: host).count == 1 }
        let viewport = try XCTUnwrap(scrolls(in: host).first)
        try await compatibilityWait { (viewport.documentView?.frame.height ?? 0) > 1200 }
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 80))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(builds.value, 0)
        XCTAssertGreaterThan(viewport.documentVisibleRect.minY, 40)
        return (window, host, viewport)
    }

    func testNativeLibraryScrollingDoesNotReinvokeContentBuilder() async throws {
        let builds = Builds()
        let (window, _, viewport) = try await mount(rows: Rows(), builds: builds)
        let before = builds.value
        let start = viewport.documentVisibleRect.minY
        let point = viewport.convert(NSPoint(x: viewport.bounds.midX, y: viewport.bounds.midY), to: nil)
        for sample in 0..<8 {
            NSApp.sendEvent(ScrollEvent(window: window, dy: -8,
                phase: sample == 0 ? .began : .changed, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(16))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertGreaterThan(viewport.documentVisibleRect.minY - start, 20,
                             "The native gesture must actually move the mounted Library viewport")
        XCTAssertEqual(builds.value, before,
                       "Scroll metrics and rail interaction must not rerun the Library content builder")
    }

    func testParentContentChangesStillUpdateMountedLibraryAndKeepViewport() async throws {
        let builds = Builds()
        let rows = Rows()
        let (_, host, viewport) = try await mount(rows: rows, builds: builds)
        let before = builds.value
        let height = try XCTUnwrap(viewport.documentView).frame.height
        let offset = viewport.documentVisibleRect.minY

        rows.count = 72
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { (viewport.documentView?.frame.height ?? 0) > height + 500 }

        XCTAssertGreaterThan(builds.value, before, "Changed Library data must rebuild the stored content")
        XCTAssertTrue(viewport.isDescendant(of: host), "The existing native viewport must remain mounted")
        XCTAssertEqual(viewport.documentVisibleRect.minY, offset, accuracy: 1,
                       "Appending content must preserve the user's current Library position")
    }
}
