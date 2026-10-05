import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageScriptPerformanceTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func fixture(script: String, name: String, world: WKContentWorld = .page,
                         html: String = "<body><div id='root'></div></body>") async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let controller = WKUserContentController(), capture = Capture()
        controller.add(capture, contentWorld: world, name: name)
        controller.addUserScript(WKUserScript(source: """
        window.__queries = 0;
        const elementQuery = Element.prototype.querySelector;
        const elementQueryAll = Element.prototype.querySelectorAll;
        const documentQueryAll = Document.prototype.querySelectorAll;
        Element.prototype.querySelector = function(s) { __queries++; return elementQuery.call(this, s); };
        Element.prototype.querySelectorAll = function(s) { __queries++; return elementQueryAll.call(this, s); };
        Document.prototype.querySelectorAll = function(s) { __queries++; return documentQueryAll.call(this, s); };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: world))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "https://fixture.example.test/"))
        addTeardownBlock { @MainActor in
            web.stopLoading()
            controller.removeAllScriptMessageHandlers()
        }
        let deadline = Date.now.addingTimeInterval(10)
        while web.isLoading || web.url == nil {
            if Date.now > deadline { throw NSError(domain: "PageScriptFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (web, capture)
    }

    private func js(_ web: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Any {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: world)
    }

    func testPasswordDiscoveryCoalescesBusyPageMutations() async throws {
        let (web, capture) = try await fixture(script: Autofill.script, name: "vanepw", world: Autofill.world)
        let queries = try await js(web, """
        __queries = 0;
        const root = document.getElementById('root');
        // A framework mounts separate subtrees over many microtask checkpoints.
        for (let i = 0; i < 100; i++) {
            const card = document.createElement('section');
            card.innerHTML = '<div><span>A video card</span></div>';
            root.appendChild(card);
            await Promise.resolve();
        }
        return __queries;
        """, world: Autofill.world) as? Int
        XCTAssertEqual(queries, 0, "Password discovery must not search subtrees in mutation microtasks")
        _ = try await js(web, """
        const form = document.createElement('form');
        form.innerHTML = '<input autocomplete="username"><input type="password" autocomplete="current-password">';
        document.body.appendChild(form);
        return true;
        """, world: Autofill.world)
        let deadline = Date.now.addingTimeInterval(3)
        while !capture.messages.contains(where: { $0["ready"] as? Bool == true }) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(capture.messages.contains { $0["ready"] as? Bool == true }, "Dynamically mounted logins still announce readiness")
    }

    func testMediaSessionUpdatesDoNotSearchTheDocument() async throws {
        let (web, _) = try await fixture(script: MediaTray.script, name: MediaTray.messageName,
                                         html: "<body><audio id='first'></audio><video id='second'></video></body>")
        let queries = try await js(web, """
        __queries = 0;
        for (let i = 0; i < 200; i++) {
            navigator.mediaSession.playbackState = i % 2 ? 'playing' : 'paused';
        }
        return __queries;
        """) as? Int
        XCTAssertEqual(queries, 0, "Media Session updates must not rescan a large page")
        let first = try await js(web, "return document.getElementById('first').hasAttribute('data-vane-media-source');") as? Bool
        XCTAssertEqual(first, true, "The first paused media element follows document order across audio and video")
        let replacement = try await js(web, """
        document.getElementById('first').remove();
        document.getElementById('second').remove();
        const next = document.createElement('video');
        next.id = 'replacement';
        document.body.appendChild(next);
        navigator.mediaSession.playbackState = 'paused';
        return next.hasAttribute('data-vane-media-source');
        """) as? Bool
        XCTAssertEqual(replacement, true, "A replaced SPA player must be discovered without stale membership")
    }
}
