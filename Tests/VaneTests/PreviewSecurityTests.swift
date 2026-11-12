import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PreviewSecurityTests: XCTestCase {
    private func js(_ web: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool == true)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func withTab(_ body: (Tab) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let tab = Tab(isPrivate: true)
        var failure: (any Error)?
        do {
            try await compatibilityWait { try loop.isReadyForInteraction() }
            tab.web.loadHTMLString("<a id='link' href='https://example.test/article'>Article</a>", baseURL: nil)
            try await compatibilityWait { !tab.web.isLoading }
            _ = try await js(tab.web, "document.getElementById('link').id")
            try await body(tab)
        } catch { failure = error }
        Previews.shared.cancel(); tab.tearDown()
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    func testWebsiteCannotAccessPreviewBridge() async throws {
        try await withTab { tab in
            let exposed = try await self.js(tab.web,
                "!!(window.webkit && webkit.messageHandlers && webkit.messageHandlers.vanepreview)")
            XCTAssertEqual(exposed, false, "A website must not be able to request privileged preview loads")
        }
    }

    func testWebsiteCannotAccessStatusOrAudioBridges() async throws {
        try await withTab { tab in
            let exposed = try await self.js(tab.web,
                "!!(window.webkit && webkit.messageHandlers && (webkit.messageHandlers.vanehover || webkit.messageHandlers.vaneaudio))")
            XCTAssertFalse(exposed, "Websites must not spoof native hover destinations or fallback audio state")
        }
    }

    func testDetachedSourceCannotRequestPreviewEvenThroughIsolatedBridge() async throws {
        try await withTab { tab in
            let enabled = Previews.enabled, mode = BatterySaver.shared.mode
            Previews.enabled = true; BatterySaver.shared.setMode(.off)
            defer { Previews.enabled = enabled; BatterySaver.shared.setMode(mode) }
            // This deliberately exercises the native gate independently of script trust.
            // Tests can enter an isolated world; websites cannot.
            _ = try await self.js(tab.web,
                "webkit.messageHandlers.vanepreview.postMessage({url:'https://example.test/article', x:0,y:0,w:100,h:20}); true",
                world: WKContentWorld.world(name: "vane-link-previews"))
            _ = try await self.js(tab.web, "0", world: WKContentWorld.world(name: "vane-link-previews"))
            XCTAssertNil(Previews.shared.preview(for: tab), "A detached/background source has no native hover authority")
        }
    }
}
