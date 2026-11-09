import AppKit
import XCTest
@testable import vane

@MainActor final class WindowResizeLayoutTests: XCTestCase {
    func testPageFollowsEachWindowResizeWithoutWaitingForAnotherLayoutTurn() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let store = TabStore(isPrivate: true)
            let tab = store.newBlankTab()
            store.palette = nil
            _ = tab.web
            let host = BrowserWindowHost(shown: ShownStore(store))
            let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                                    styleMask: [.titled, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(ignoringOtherApps: true)
            defer {
                print("Resize fixture: active=\(app.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) pageWindow=\(tab.web.window === window) pageBounds=\(tab.web.bounds) hostBounds=\(host.bounds)")
                store.librarySwipeMonitor.remove()
                store.spaceGesture.monitor.remove()
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                SharedTabs.release(store.tabs, excluding: store)
                TabStore.all.removeAll { $0 === store }
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                // Geometry needs the owned visible tree, without requiring the
                // CLI test host to win keyboard focus from another application.
                return app.isRunning && window.isVisible
                    && window.occlusionState.contains(.visible) && tab.web.window === window
                    && tab.web.bounds.width > 100
            }
            for shown in [true, false] {
                Motion.instant { store.sidebarShown = shown }
                try await compatibilityWait {
                    host.layoutSubtreeIfNeeded()
                    let page = tab.web.convert(tab.web.bounds, to: host)
                    return abs(page.maxX - (host.bounds.width - Look.cardGap)) < 1
                }
                for width: CGFloat in [1100, 1200, 950, 800, 1000, 900] {
                    var frame = window.frame
                    frame.origin.x += frame.width - width
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                    let page = tab.web.convert(tab.web.bounds, to: host)
                    XCTAssertEqual(page.maxX, host.bounds.width - Look.cardGap, accuracy: 1,
                        "The page must cover the new width in the resize layout pass (sidebar=\(shown), width=\(width))")
                }
            }
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Resize fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }
}
