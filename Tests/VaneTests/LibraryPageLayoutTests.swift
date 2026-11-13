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
        gesture.pageWidth = 508
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
