import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SiteBoostTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    func testOriginNormalizesPortsAndKeepsSubdomainsAndSchemesSeparate() {
        XCTAssertEqual(SiteBoosts.origin(URL(string: "https://EXAMPLE.com:443/a?q=1")!), "https://example.com")
        XCTAssertEqual(SiteBoosts.origin(URL(string: "http://example.com:80")!), "http://example.com")
        XCTAssertEqual(SiteBoosts.origin(URL(string: "https://example.com:8443")!), "https://example.com:8443")
        XCTAssertNotEqual(SiteBoosts.origin(URL(string: "https://www.example.com")!), SiteBoosts.origin(URL(string: "https://example.com")!))
        XCTAssertNil(SiteBoosts.origin(URL(string: "file:///tmp/example.html")!))
        XCTAssertNil(SiteBoosts.origin(URL(string: "about:blank")!))
    }

    func testProfilePersistenceResetAndMalformedRecords() throws {
        let suite = "boost-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SiteBoostStore(defaults: defaults)
        let profile = UUID(), other = UUID(), origin = "https://example.com"
        defer { defaults.removePersistentDomain(forName: suite) }
        var boost = SiteBoost(); boost.font = "Georgia"; boost.css = "a { color: red }"; boost.script = "window.test = 1"
        store.set(boost, origin: origin, profile: profile)
        XCTAssertEqual(SiteBoostStore(defaults: defaults).get(origin: origin, profile: profile), boost)
        XCTAssertEqual(store.get(origin: origin, profile: other), SiteBoost())
        XCTAssertFalse(store.get(origin: origin, profile: profile).scriptEnabled)
        store.set(SiteBoost(), origin: origin, profile: profile)
        XCTAssertTrue(store.records(profile: profile).isEmpty)
        defaults.set(Data("bad json".utf8), forKey: SiteBoostStore.key(profile))
        XCTAssertEqual(store.get(origin: origin, profile: profile), SiteBoost())
    }

    func testPrivateBoostIsPerTabAndDoesNotInheritSavedScripts() {
        let tab = Tab(isPrivate: true), other = Tab(isPrivate: true)
        let origin = "https://example.com"
        var boost = SiteBoost(); boost.css = "body { color: red }"; boost.scriptEnabled = true
        SiteBoosts.set(boost, origin: origin, tab: tab)
        XCTAssertEqual(SiteBoosts.value(origin: origin, tab: tab), boost)
        XCTAssertEqual(SiteBoosts.value(origin: origin, tab: other), SiteBoost())
        tab.tearDown()
        XCTAssertEqual(SiteBoosts.value(origin: origin, tab: tab), SiteBoost())
        other.tearDown()
    }

    func testSiteControlOffersBoostOnlyForWebPages() {
        XCTAssertTrue(SiteControlModel(host: "example.com", scheme: "https").rows.contains { $0.id == .boost })
        XCTAssertFalse(SiteControlModel(host: "example.com", scheme: "file").rows.contains { $0.id == .boost })
    }
}

@MainActor final class SiteBoostWebTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    private func page(isPrivate: Bool = true, profile: UUID = UUID()) async throws -> Tab {
        let tab = Tab(isPrivate: isPrivate, profileID: profile)
        addTeardownBlock { @MainActor in tab.tearDown() }
        tab.web.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        try await load(tab, origin: "https://boost.test")
        return tab
    }

    private func load(_ tab: Tab, origin: String) async throws {
        tab.web.loadHTMLString("<html><body><div id='ad:one'>Ad</div><a id='link'>Link</a><p id='copy'>Text</p></body></html>", baseURL: URL(string: origin))
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if !tab.web.isLoading, SiteBoosts.document(for: tab)?.origin == origin, SiteBoosts.document(for: tab)?.scriptRan == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try await visual("JSON.stringify({origin:location.origin, secure:isSecureContext, crypto:typeof crypto, random:typeof crypto?.getRandomValues, runtime:typeof window.__vaneBoost})", tab: tab)
        XCTFail("Boost runtime did not attach: currentURL=\(String(describing: tab.currentURL)), state=\(state ?? "nil")"); throw NSError(domain: "fixture", code: 1)
    }

    private func visual(_ code: String, tab: Tab) async throws -> Any? {
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(code, in: nil, in: SiteBoostScripts.world) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    }

    private func documentDiagnostics(_ tab: Tab) async throws -> String {
        let document = SiteBoosts.document(for: tab)
        let state = try await visual("JSON.stringify({stamp:performance.timeOrigin, token:window.__vaneBoost?.documentToken, origin:location.origin, zapping:window.__vaneBoost?.zapping, sheets:document.adoptedStyleSheets.map(s => [...s.cssRules].map(r => r.cssText).join(' '))})", tab: tab)
        let boundary: String = await withCheckedContinuation { continuation in
            tab.web.callAsyncJavaScript("return JSON.stringify({token, origin, tokenMatches:window.__vaneBoost?.documentToken === token, originMatches:location.origin === origin, runtimePresent:!!window.__vaneBoost});", arguments: ["token": document?.token ?? "", "origin": document?.origin ?? ""], in: nil, in: SiteBoostScripts.world) { result in
                continuation.resume(returning: String(describing: result))
            }
        }
        return "native token=\(document?.token ?? "nil"), stamp=\(document?.stamp.description ?? "nil"), origin=\(document?.origin ?? "nil"), acceptsPick=\(SiteBoostEditor.acceptsPick(tab: tab)); runtime=\(state ?? "nil"); bridge=\(boundary)"
    }

    func testVisualResetAndZapCleanupSurviveDocumentClockDrift() async throws {
        let tab = try await page()
        var boost = SiteBoost(); boost.textColor = "#123456"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        SiteBoosts.zap(true, tab: tab)
        try await compatibilityWait {
            try await self.visual("window.__vaneBoost.zapping && getComputedStyle(document.getElementById('copy')).color === 'rgb(18, 52, 86)'", tab: tab) as? Bool == true
        }
        // CI observed the live clock differing from the captured clock in this document.
        _ = try await visual("Object.defineProperty(performance, 'timeOrigin', {value: performance.timeOrigin + 6, configurable:true}); true", tab: tab)
        SiteBoosts.set(SiteBoost(), origin: "https://boost.test", tab: tab)
        SiteBoosts.zap(false, tab: tab)
        try await compatibilityWait {
            try await self.visual("!window.__vaneBoost.zapping && getComputedStyle(document.getElementById('copy')).color !== 'rgb(18, 52, 86)'", tab: tab) as? Bool == true
        }
    }

    func testHTTPDocumentTokenChangesOnSameURLReloadAndRejectsStaleDone() async throws {
        let tab = try await page()
        try await load(tab, origin: "http://boost.local")
        let previous = try XCTUnwrap(SiteBoosts.document(for: tab)?.token)
        try await load(tab, origin: "http://boost.local")
        try await compatibilityWait { SiteBoosts.document(for: tab)?.token != previous }
        let current = try XCTUnwrap(SiteBoosts.document(for: tab)?.token)
        XCTAssertEqual(current.count, 32)
        XCTAssertNotEqual(previous, current)
        let runtimeToken = try await visual("window.__vaneBoost.documentToken", tab: tab) as? String
        XCTAssertEqual(runtimeToken, current)
        let pageWorld = try await tab.web.evaluateJavaScript("typeof window.__vaneBoost") as? String
        XCTAssertEqual(pageWorld, "undefined")
        let window = NSWindow(contentRect: tab.web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in SiteBoostEditor.close(tab: tab); window.close() }
        SiteBoostEditor.open(tab: tab)
        SiteBoostEditor.toggleZap(tab: tab)
        XCTAssertTrue(SiteBoostEditor.acceptsPick(tab: tab))
        // Both messages use the same channel. A stale done must not disable the
        // editor before its current-document pick is handled.
        _ = try await visual("window.webkit.messageHandlers.vaneBoost.postMessage({kind:'done', stamp:performance.timeOrigin, origin:location.origin, token:'\(previous)'}); window.__vaneBoost.post('pick', {selector:'#link'}); true", tab: tab)
        try await compatibilityWait { SiteBoosts.value(origin: "http://boost.local", tab: tab).hidden == ["#link"] }
        XCTAssertTrue(SiteBoostEditor.acceptsPick(tab: tab))
    }

    func testLiveStylesDynamicHidingAndReset() async throws {
        let tab = try await page()
        var boost = SiteBoost(); boost.font = "Georgia"; boost.textColor = "#123456"; boost.background = "#fefefe"
        boost.hidden = ["#ad\\:one"]; boost.css = "#copy { font-weight: 700 !important; }"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(150))
        let result1 = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: tab) as? String
        XCTAssertEqual(result1, "rgb(18, 52, 86)")
        let result2 = try await visual("getComputedStyle(document.getElementById('ad:one')).display", tab: tab) as? String
        XCTAssertEqual(result2, "none")
        _ = try await visual("document.getElementById('ad:one').remove(); const ad=document.createElement('div'); ad.id='ad:one'; document.body.append(ad);", tab: tab)
        let result3 = try await visual("getComputedStyle(document.getElementById('ad:one')).display", tab: tab) as? String
        XCTAssertEqual(result3, "none")
        SiteBoosts.set(SiteBoost(), origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        let result4 = try await visual("getComputedStyle(document.getElementById('ad:one')).display", tab: tab) as? String
        XCTAssertEqual(result4, "block")
    }

    func testScriptOptInErrorsAndOriginIsolation() async throws {
        let tab = try await page()
        var boost = SiteBoost(); boost.script = "window.boostCount = (window.boostCount || 0) + 1;"; boost.css = "body { background: red }"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        let disabled = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(disabled, "Enable JavaScript to run this script.")
        let result5 = try await tab.web.evaluateJavaScript("window.boostCount") as? Int
        XCTAssertNil(result5)
        boost.scriptEnabled = true; SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        let result6 = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(result6, "Script applied.")
        let result7 = try await tab.web.evaluateJavaScript("window.boostCount") as? Int
        XCTAssertEqual(result7, 1)
        boost.script = "throw new Error('fixture error')"; SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        let failedScript = await SiteBoosts.runScript(tab: tab)
        XCTAssertTrue(failedScript.contains("fixture error"))
        try await load(tab, origin: "https://other.test")
        let result8 = try await tab.web.evaluateJavaScript("window.boostCount") as? Int
        XCTAssertNil(result8)
        let result9 = try await visual("getComputedStyle(document.body).backgroundColor", tab: tab) as? String
        XCTAssertNotEqual(result9, "rgb(255, 0, 0)")
    }

    func testCancelledProvisionalNavigationKeepsLiveControls() async throws {
        let tab = try await page()
        let original = try XCTUnwrap(SiteBoosts.document(for: tab))
        let pending = try NavigationHTTPFixture()
        defer { pending.stop() }
        pending.heldPaths.insert("/held")
        try await compatibilityWait { pending.port != nil }
        let generation = tab.readingDocumentGeneration
        tab.go(try pending.url("/held"))
        try await compatibilityWait { tab.loading && tab.readingDocumentGeneration != generation }
        tab.stop()
        try await compatibilityWait { !tab.web.isLoading }
        XCTAssertTrue(SiteBoosts.document(for: tab) === original)
        var boost = SiteBoost(); boost.textColor = "#123456"; boost.scriptEnabled = true; boost.script = "window.afterCancel = 1;"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        let color = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: tab) as? String
        XCTAssertEqual(color, "rgb(18, 52, 86)")
        let result = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(result, "Script applied.")
    }

    func testTimeOriginDriftKeepsLiveControlsOnTheSameDocument() async throws {
        let tab = try await page()
        // macOS 26 WebKit can move this getter by 1 ms without replacing the document.
        let drift = "Object.defineProperty(performance, 'timeOrigin', {value: performance.timeOrigin + 1}); null;"
        _ = try await visual(drift, tab: tab)
        _ = try await tab.web.evaluateJavaScript(drift)
        var boost = SiteBoost(); boost.textColor = "#123456"; boost.scriptEnabled = true
        boost.script = "window.afterDrift = 1;"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        let result = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(result, "Script applied.")
        let ran = try await tab.web.evaluateJavaScript("window.afterDrift") as? Int
        XCTAssertEqual(ran, 1)
        let color = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: tab) as? String
        XCTAssertEqual(color, "rgb(18, 52, 86)")
    }

    func testQueuedScriptRejectsReplacementAtTheSameOrigin() async throws {
        let tab = try await page()
        let old = try XCTUnwrap(SiteBoosts.document(for: tab))
        let token = try XCTUnwrap(old.pageToken)
        try await load(tab, origin: "https://boost.test")
        XCTAssertNotEqual(SiteBoosts.document(for: tab)?.pageToken, token)
        let result: String? = await withCheckedContinuation { continuation in
            tab.web.callAsyncJavaScript(SiteBoostScripts.guardedScript("window.staleBoost = 1;"),
                arguments: ["__vaneOrigin": old.origin, "__vaneToken": token], in: nil, in: .page) { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
        }
        XCTAssertEqual(result, "Page changed. Reload and try again.")
        let ran = try await tab.web.evaluateJavaScript("window.staleBoost")
        XCTAssertNil(ran)
    }

    func testDisablingScriptWhileDocumentTokenIsCapturedPreventsExecution() async throws {
        let tab = try await page()
        let doc = try XCTUnwrap(SiteBoosts.document(for: tab))
        var boost = SiteBoost(); boost.scriptEnabled = true; boost.script = "window.disabledDuringCapture = 1;"
        SiteBoosts.set(boost, origin: doc.origin, tab: tab)
        doc.pageToken = nil
        let running = Task { await SiteBoosts.runScript(tab: tab) }
        let deadline = Date.now.addingTimeInterval(5)
        while doc.tokenCapture == nil, Date.now < deadline { await Task.yield() }
        XCTAssertNotNil(doc.tokenCapture)
        boost.scriptEnabled = false
        SiteBoosts.set(boost, origin: doc.origin, tab: tab)
        let result = await running.value
        XCTAssertEqual(result, "Enable JavaScript to run this script.")
        let ran = try await tab.web.evaluateJavaScript("window.disabledDuringCapture")
        XCTAssertNil(ran)
    }

    func testRestoredRuntimeCapturesImmutablePageMarkerWithoutRerunningSavedScript() async throws {
        let tab = try await page()
        let original = try XCTUnwrap(SiteBoosts.document(for: tab))
        var boost = SiteBoost(); boost.scriptEnabled = true
        boost.script = "window.restoreCount = (window.restoreCount || 0) + 1;"
        SiteBoosts.set(boost, origin: original.origin, tab: tab)
        let first = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(first, "Script applied.")
        _ = try await visual("window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted:true})); null;", tab: tab)
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if let doc = SiteBoosts.document(for: tab), doc !== original, doc.scriptRan, doc.pageToken != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try XCTUnwrap(SiteBoosts.document(for: tab))
        XCTAssertFalse(restored === original)
        XCTAssertTrue(restored.scriptRan)
        XCTAssertEqual(restored.pageToken, original.pageToken)
        let count = try await tab.web.evaluateJavaScript("window.restoreCount") as? Int
        XCTAssertEqual(count, 1)
        let markerIsImmutable = try await tab.web.evaluateJavaScript("""
            (() => {
                const before = document.__vaneBoostPageToken;
                try { Object.defineProperty(document, '__vaneBoostPageToken', {value:'copied'}); } catch (_) {}
                const descriptor = Object.getOwnPropertyDescriptor(document, '__vaneBoostPageToken');
                return document.__vaneBoostPageToken === before && !descriptor.writable && !descriptor.configurable;
            })()
            """) as? Bool
        XCTAssertEqual(markerIsImmutable, true)
        let manual = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(manual, "Script applied.")
    }

    func testSiteResetRemovesBoostForHostAndKeepsOtherHosts() async throws {
        let tab = try await page()
        var boost = SiteBoost(); boost.font = "Georgia"; boost.scriptEnabled = true; boost.script = "window.test=1"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        SiteBoosts.set(boost, origin: "http://boost.test:8080", tab: tab)
        SiteBoosts.set(boost, origin: "https://other.test", tab: tab)
        SiteBoosts.forget(host: "boost.test", tab: tab)
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: tab), SiteBoost())
        XCTAssertEqual(SiteBoosts.value(origin: "http://boost.test:8080", tab: tab), SiteBoost())
        XCTAssertEqual(SiteBoosts.value(origin: "https://other.test", tab: tab), boost)
    }

    func testPersistentResetUpdatesMatchingTabsAndPreservesAnotherProfile() async throws {
        let profile = UUID(), otherProfile = UUID()
        let tab = try await page(isPrivate: false, profile: profile)
        let sibling = try await page(isPrivate: false, profile: profile)
        let other = try await page(isPrivate: false, profile: otherProfile)
        addTeardownBlock { @MainActor in SiteBoosts.forget(profile: profile); SiteBoosts.forget(profile: otherProfile) }
        var boost = SiteBoost(); boost.textColor = "#123456"; boost.scriptEnabled = true
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        SiteBoosts.set(boost, origin: "https://boost.test", tab: other)
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: sibling), boost)
        try await Task.sleep(for: .milliseconds(100))
        let styled = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: sibling) as? String
        XCTAssertEqual(styled, "rgb(18, 52, 86)")
        SiteBoosts.forget(host: "boost.test", tab: tab)
        try await compatibilityWait {
            try await self.visual("getComputedStyle(document.getElementById('copy')).color !== 'rgb(18, 52, 86)'", tab: sibling) as? Bool == true
        }
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: sibling), SiteBoost())
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: other), boost)
        let restored = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: sibling) as? String
        if restored == "rgb(18, 52, 86)" { XCTFail(try await documentDiagnostics(sibling)) }
        XCTAssertNotEqual(restored, "rgb(18, 52, 86)")
    }

    func testScriptsWorkOnPagesWithRestrictiveCSP() async throws {
        let tab = try await page()
        tab.web.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"script-src 'none'; style-src 'none'\"><p id='copy'>Text</p>", baseURL: URL(string: "https://boost.test"))
        try await Task.sleep(for: .milliseconds(200))
        var boost = SiteBoost(); boost.scriptEnabled = true; boost.script = "window.cspBoost = 42;"; boost.textColor = "#123456"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        let result = await SiteBoosts.runScript(tab: tab)
        XCTAssertEqual(result, "Script applied.")
        let value = try await tab.web.evaluateJavaScript("window.cspBoost") as? Int
        XCTAssertEqual(value, 42)
        try await Task.sleep(for: .milliseconds(100))
        let color = try await visual("getComputedStyle(document.getElementById('copy')).color", tab: tab) as? String
        XCTAssertEqual(color, "rgb(18, 52, 86)")
    }

    func testTextSizeScalesFixedPixelFontsAndRestoresThem() async throws {
        let tab = try await page()
        _ = try await visual("document.getElementById('copy').style.fontSize = '20px'", tab: tab)
        var boost = SiteBoost(); boost.textScale = 1.5
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        let large = try await visual("getComputedStyle(document.getElementById('copy')).fontSize", tab: tab)
        XCTAssertEqual(large as? String, "30px")
        boost.enabled = false; SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        let restored = try await visual("getComputedStyle(document.getElementById('copy')).fontSize", tab: tab)
        XCTAssertEqual(restored as? String, "20px")
    }

    func testSavedVisualsAndScriptsReapplyOnNewDocumentsOnly() async throws {
        let tab = try await page()
        var boost = SiteBoost(); boost.background = "#123456"; boost.scriptEnabled = true
        boost.script = "window.boostCount = (window.boostCount || 0) + 1;"
        SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await load(tab, origin: "https://boost.test")
        try await Task.sleep(for: .milliseconds(100))
        let count = try await tab.web.evaluateJavaScript("window.boostCount") as? Int
        XCTAssertEqual(count, 1)
        let background = try await visual("getComputedStyle(document.body).backgroundColor", tab: tab) as? String
        XCTAssertEqual(background, "rgb(18, 52, 86)")
        boost.font = "Georgia"; SiteBoosts.set(boost, origin: "https://boost.test", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        let unchanged = try await tab.web.evaluateJavaScript("window.boostCount") as? Int
        XCTAssertEqual(unchanged, 1)
    }

    func testNativeEditorOwnsZapAndCleansUpOnClose() async throws {
        let tab = try await page()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in SiteBoostEditor.close(tab: tab); window.close() }
        SiteBoostEditor.open(tab: tab)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try XCTUnwrap(window.childWindows?.first)
        XCTAssertEqual(panel.title, "Boost This Site")
        SiteBoostEditor.toggleZap(tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(SiteBoostEditor.acceptsPick(tab: tab))
        _ = try await visual("document.getElementById('ad:one').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: tab).hidden, ["#ad\\:one"])
        SiteBoostEditor.undo(tab: tab)
        _ = try await visual("const frame=document.createElement('iframe'); frame.id='embedded'; frame.srcdoc='<button>Embedded control</button>'; frame.style.cssText='position:absolute;left:200px;top:200px;width:200px;height:100px'; document.body.append(frame);", tab: tab)
        _ = try await visual("const cover=document.querySelector('[data-vane-zap-cover]'); if (cover) cover.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:250,clientY:250}));", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(SiteBoosts.value(origin: "https://boost.test", tab: tab).hidden, ["#embedded"])
        SiteBoostEditor.undo(tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(SiteBoosts.value(origin: "https://boost.test", tab: tab).hidden.isEmpty)
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/vane-boost-editor.png"))
        }
        panel.close()
        // Closing the native panel schedules a WebKit call; CI can take longer than
        // 100 ms to deliver it. Wait for the observable cleanup, not an elapsed guess.
        XCTAssertFalse(SiteBoostEditor.acceptsPick(tab: tab))
        do {
            try await compatibilityWait {
                let active = try await self.visual("window.__vaneBoost.zapping", tab: tab) as? Bool
                return active == false
            }
        } catch {
            XCTFail("panel visible=\(panel.isVisible), delegate=\(String(describing: panel.delegate)); " + (try await documentDiagnostics(tab)))
            throw error
        }
        XCTAssertFalse(SiteBoostEditor.acceptsPick(tab: tab))
    }

    func testZapEscapesSelectorsAndCanUndoAndExit() async throws {
        let tab = try await page()
        let selector = try await visual("window.__vaneBoost.selector(document.getElementById('ad:one'))", tab: tab) as? String
        XCTAssertEqual(selector, "#ad\\:one")
        let result10 = try await visual("window.__vaneBoost.selector(document.body)", tab: tab) as? String
        XCTAssertNil(result10)
        _ = try await visual("window.__vaneBoost.zap(true); document.getElementById('ad:one').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));", tab: tab)
        try await Task.sleep(for: .milliseconds(100))
        // Picking is accepted only while a native editor owns this tab's Zap session.
        XCTAssertTrue(SiteBoosts.value(origin: "https://boost.test", tab: tab).hidden.isEmpty)
        _ = try await visual("window.__vaneBoost.zap(false)", tab: tab)
        let result11 = try await visual("window.__vaneBoost.zapping", tab: tab) as? Bool
        XCTAssertEqual(result11, false)
        let result12 = try await visual("document.querySelector('[data-vane-zap]') === null", tab: tab) as? Bool
        XCTAssertEqual(result12, true)
    }
}
