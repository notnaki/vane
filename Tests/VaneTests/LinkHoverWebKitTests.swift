import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LinkHoverWebKitTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [Any] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(message.body)
        }
    }

    private func script(_ source: String, handler: String) async throws -> (WKWebView, Capture) {
        let capture = Capture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, name: handler)
        config.userContentController.addUserScript(WKUserScript(source: source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.loadHTMLString("<a id='link' href='https://example.com/article'><span id='child'>Read</span></a>", baseURL: nil)
        try await wait { !web.isLoading }
        try await js(web, "if (!document.getElementById('link')) throw new Error('fixture not ready');")
        addTeardownBlock { @MainActor in
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: handler)
        }
        return (web, capture)
    }

    private func js(_ web: WKWebView, _ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            web.evaluateJavaScript(source) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            if Date.now >= deadline { throw NSError(domain: "LinkHoverFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStatusScriptTracksTargetsAndClearsOnScrollAndClick() async throws {
        let (web, capture) = try await script(StatusBar.script, handler: StatusBar.messageName)
        try await js(web, "document.getElementById('child').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[0]), .init(url: "https://example.com/article", target: .main))
        try await js(web, "document.getElementById('link').target='_blank'; document.getElementById('child').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[1])?.target, .newWindow)
        try await js(web, "window.dispatchEvent(new Event('scroll'));")
        try await wait { capture.messages.count == 3 }
        XCTAssertNil(StatusBar.hover(from: capture.messages[2]))
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true})); document.dispatchEvent(new MouseEvent('mousedown', {bubbles:true}));")
        try await wait { capture.messages.count == 5 }
        XCTAssertNil(StatusBar.hover(from: capture.messages[4]))
    }

    func testNamedPopupAndExistingFrameHaveDifferentHoverTargets() async throws {
        let (web, capture) = try await script(StatusBar.script, handler: StatusBar.messageName)
        try await js(web, "document.getElementById('link').target='details'; document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[0])?.target, .newWindow)
        try await js(web, "var frame=document.createElement('iframe'); frame.name='details'; document.body.appendChild(frame); document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[1])?.target, .subframe)
    }

    func testSyntheticHoverAndModifiersCannotStartPreviews() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName)
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true, shiftKey:true}));")
        try await js(web, "document.dispatchEvent(new KeyboardEvent('keydown', {key:'Shift', shiftKey:true, bubbles:true}));")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(capture.messages.isEmpty, "Synthetic website events must never request preview loads")
    }

    func testTrustedShiftHoverStillRequestsPreview() async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        let capture = Capture(), config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, contentWorld: Previews.world, name: Previews.messageName)
        config.userContentController.addUserScript(WKUserScript(source: Previews.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Previews.world))
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 500, height: 300), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.acceptsMouseMovedEvents = true
        window.contentView = web
        var loop: NativeFixtureApplicationLoop?
        var failure: (any Error)?
        var stage = "admission"
        let previousPointer = CGEvent(source: nil)?.location
        do {
            loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await compatibilityWait {
                try loop?.isReadyForInteraction() == true && window.isKeyWindow && NSApp.isActive
                    && NativeFixtureMountAdmission.surfaceReady(web, in: window)
            }
            stage = "document"
            web.loadHTMLString("<body style='margin:0'><a id='link' style='display:block;width:280px;height:120px' href='https://example.com/article'>Read</a></body>", baseURL: nil)
            try await wait { !web.isLoading }
            let rect = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Double], any Error>) in
                web.evaluateJavaScript("window.hoverTrusted=false; document.addEventListener('mouseover',e=>window.hoverTrusted=e.isTrusted); var r=document.getElementById('link').getBoundingClientRect(); [r.x,r.y,r.width,r.height]") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let rect = value as? [Double], rect.count == 4 { continuation.resume(returning: rect) }
                    else { continuation.resume(throwing: NSError(domain: "LinkHoverGeometry", code: 1)) }
                }
            }
            func move(to local: NSPoint) throws {
                let point = web.convert(local, to: nil)
                let screenPoint = window.convertPoint(toScreen: point)
                let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
                XCTAssertEqual(CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: desktopTop - screenPoint.y)), .success)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                    modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                _ = try XCTUnwrap(web.hitTest(local))
                NSApp.postEvent(event, atStart: false)
            }
            stage = "outside input"
            try move(to: NSPoint(x: web.bounds.maxX - 5, y: web.bounds.midY))
            try await js(web, "window.dispatchEvent(new Event('scroll'));")
            capture.messages.removeAll()
            let cssY = rect[1] + rect[3] / 2
            stage = "inside input"
            try move(to: NSPoint(x: rect[0] + rect[2] / 2, y: web.isFlipped ? cssY : web.bounds.height - cssY))
            try await wait { !capture.messages.isEmpty }
            stage = "trusted event assertion"
            let trusted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                web.evaluateJavaScript("window.hoverTrusted") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? Bool == true) }
                }
            }
            XCTAssertTrue(trusted)
            XCTAssertEqual((capture.messages.first as? [String: Any])?["url"] as? String, "https://example.com/article")
            XCTAssertEqual((capture.messages.first as? [String: Any])?["shift"] as? Bool, true)
            try await js(web, "window.dispatchEvent(new Event('scroll')); window.dispatchEvent(new Event('scroll'));")
            try await wait { capture.messages.count == 2 }
            XCTAssertEqual((capture.messages.last as? [String: Any])?["gone"] as? Bool, true)
        } catch {
            FileHandle.standardError.write(Data("TRUSTED_HOVER_FAILED stage=\(stage) error=\(error)\n".utf8))
            failure = error
        }
        if let previousPointer { _ = CGWarpMouseCursorPosition(previousPointer) }
        web.stopLoading()
        config.userContentController.removeAllScriptMessageHandlers()
        window.orderOut(nil); window.contentView = nil; window.close()
        if let loop {
            do { try await loop.close() } catch { if failure == nil { failure = error } }
        }
        NSApp.setActivationPolicy(policy)
        if let failure { throw failure }
    }
}
