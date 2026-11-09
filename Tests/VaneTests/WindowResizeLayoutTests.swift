import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WindowResizeLayoutTests: XCTestCase {
    func testPageViewportFollowsTheNativeFrameBeforeItsNextPresentation() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let store = TabStore(isPrivate: true)
            let sidebarWidth = SidebarWidth.shared.width
            SidebarWidth.shared.width = 228
            defer { SidebarWidth.shared.width = sidebarWidth }
            store.sidebarShown = true
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
            tab.web.loadHTMLString("<html><title>Resize ready</title><style>body{margin:0;background:#17324d}aside{position:fixed;right:0;top:0;width:100px;height:100vh;background:#f04020}</style><body><aside></aside></body></html>", baseURL: nil)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Resize ready" }
            for direct in [false, true] {
                let root: NSView = direct ? WebHost(tab.web) : host
                window.contentView = root
                root.layoutSubtreeIfNeeded()
                try await presentation(tab.web)
                for width: CGFloat in [1100, 800, 1200, 900, 1100, 900] {
                    let started = ProcessInfo.processInfo.systemUptime
                    window.setContentSize(NSSize(width: width, height: 600))
                    let frameMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let earlyWidth = tab.web.bounds.width
                    try await presentation(tab.web)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let viewport = try await tab.web.evaluateJavaScript("window.innerWidth")
                    let expected = direct ? width : width - 239
                    XCTAssertEqual(earlyWidth, expected, accuracy: 1,
                                   "Send WebKit its new viewport before waiting for the next presentation")
                    XCTAssertEqual(try XCTUnwrap(viewport as? NSNumber).doubleValue, expected, accuracy: 1,
                                   "The rendered document must use the requested viewport")
                    print("RESIZE_PRESENT direct=\(direct) request=\(width) early=\(earlyWidth) settled=\(tab.web.bounds.width) viewport=\(String(describing: viewport)) frameMS=\(frameMS) presentedMS=\(elapsed)")
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

    private func presentation(_ web: WKWebView) async throws {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard web.responds(to: selector) else { throw XCTSkip("Presentation diagnostic unavailable") }
        let presented = XCTestExpectation(description: "WebKit presents its next viewport")
        let completion: @convention(block) () -> Void = { presented.fulfill() }
        _ = web.perform(selector, with: completion)
        guard await XCTWaiter.fulfillment(of: [presented], timeout: 5) == .completed else {
            throw NSError(domain: "ResizePresentationTimeout", code: 1)
        }
    }
}
