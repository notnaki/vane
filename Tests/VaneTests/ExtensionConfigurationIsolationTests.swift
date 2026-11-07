import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionConfigurationIsolationTests: XCTestCase {
    private func color(in web: WKWebView) async throws -> NSColor {
        let image = try await web.takeSnapshot(configuration: nil)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }

    func testVisitedLinksCannotCrossProfileOrPrivateBoundaries() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let profiles = [UUID(), UUID(), Profile.incognito.id]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        var views: [WKWebView] = []
        var failure: (any Error)?
        do {
            for (index, profile) in profiles.enumerated() {
                let configuration = try XCTUnwrap(ExtensionHost.host(for: profile).controller.configuration.webViewConfiguration)
                let web = WKWebView(frame: NSRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100), configuration: configuration)
                views.append(web)
                content.addSubview(web)
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            try await compatibilityWait {
                app.isRunning && app.isActive && window.isKeyWindow && window.isVisible
                    && !window.isMiniaturized && window.contentView === content
                    && views.allSatisfy { $0.window === window && !$0.visibleRect.isEmpty }
            }
            let nonce = UUID().uuidString
            let base = try XCTUnwrap(URL(string: "https://visited-fixture.invalid/start-\(nonce)"))
            let target = "/visited-\(nonce)"
            let html = """
                <style>html,body{margin:0}a{display:block;width:100px;height:100px;background:rgb(0,0,255)}
                a:visited{background:rgb(255,0,0)}</style><a href="\(target)">link</a>
                """
            for web in views { web.loadHTMLString(html, baseURL: base) }
            for web in views {
                try await compatibilityWait {
                    guard !web.isLoading else { return false }
                    return (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('a')")) as? Bool == true
                }
                try await compatibilityWait {
                    let pixel = try await self.color(in: web)
                    return pixel.blueComponent > 0.8 && pixel.redComponent < 0.2
                }
            }
            // Use native history processing. JavaScript computed styles deliberately
            // hide :visited, so inspect the actual public WebKit snapshot instead.
            _ = try await views[0].evaluateJavaScript("history.pushState(null, '', '\(target)'); history.replaceState(null, '', '\(base.path)')")
            try await compatibilityWait {
                let pixel = try await self.color(in: views[0])
                return pixel.redComponent > 0.8 && pixel.blueComponent < 0.2
            }
            for web in views.dropFirst() {
                _ = try await web.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);", arguments: [:], in: nil, contentWorld: .page)
                let pixel = try await color(in: web)
                XCTAssertGreaterThan(pixel.blueComponent, 0.8, "Another profile must keep the unvisited rendering")
                XCTAssertLessThan(pixel.redComponent, 0.2)
            }
        } catch { failure = error }
        for web in views { web.stopLoading(); web.removeFromSuperview() }
        views.removeAll()
        window.contentView = nil
        window.close()
        for profile in profiles { ExtensionHost.forget(profile) }
        do { try await NativeFixtureProfileCleanup.release(Set(profiles.dropLast())) }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Profile cleanup also failed: \(error)") }
        }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("AppKit cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }
}
