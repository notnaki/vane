import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageScriptPerformanceTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        var messageCount = 0
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            messageCount += 1
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func fixture(script: String, name: String, world: WKContentWorld = .page,
                         html: String = "<body><div id='root'></div></body>",
                         tracking: String = "",
                         injectionTime: WKUserScriptInjectionTime = .atDocumentEnd) async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let controller = WKUserContentController(), capture = Capture()
        controller.add(capture, contentWorld: world, name: name)
        controller.addUserScript(WKUserScript(source: """
        window.__queries = 0;
        const elementQuery = Element.prototype.querySelector;
        const elementQueryAll = Element.prototype.querySelectorAll;
        const documentQueryAll = Document.prototype.querySelectorAll;
        const documentQuery = Document.prototype.querySelector;
        Element.prototype.querySelector = function(s) { __queries++; return elementQuery.call(this, s); };
        Element.prototype.querySelectorAll = function(s) { __queries++; return elementQueryAll.call(this, s); };
        Document.prototype.querySelectorAll = function(s) { __queries++; return documentQueryAll.call(this, s); };
        Document.prototype.querySelector = function(s) { __queries++; return documentQuery.call(this, s); };
        """ + tracking, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: script, injectionTime: injectionTime,
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
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: world) as Any
    }

    /// Diagnostic timings only: run on a quiet desktop with VANE_PAGE_SCRIPT_PROFILE=1.
    /// Routine CI asserts work counts and behavior below, never machine-dependent times.
    func testInjectedScriptDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["VANE_PAGE_SCRIPT_PROFILE"] == "1" else {
            throw XCTSkip("Opt-in injected-script profiling")
        }
        let tracking = #"""
        window.__styles = 0; window.__cost = 0; window.__callbacks = 0;
        const nativeTimeout = window.setTimeout.bind(window);
        window.__wait = ms => new Promise(resolve => nativeTimeout(resolve, ms));
        const track = fn => function(...args) {
          const start = performance.now();
          try { return fn.apply(this, args); }
          finally { __cost += performance.now() - start; __callbacks++; }
        };
        const MO = window.MutationObserver;
        window.MutationObserver = class extends MO { constructor(fn) { super(track(fn)); } };
        const style = window.getComputedStyle;
        window.getComputedStyle = function(...args) { __styles++; return style.apply(this, args); };
        const listeners = new WeakMap();
        const listen = EventTarget.prototype.addEventListener, unlisten = EventTarget.prototype.removeEventListener;
        EventTarget.prototype.addEventListener = function(name, fn, ...rest) {
          if (typeof fn === 'function' && !listeners.has(fn)) listeners.set(fn, track(fn));
          return listen.call(this, name, listeners.get(fn) || fn, ...rest);
        };
        EventTarget.prototype.removeEventListener = function(name, fn, ...rest) {
          return unlisten.call(this, name, listeners.get(fn) || fn, ...rest);
        };
        window.setTimeout = (fn, ms, ...args) => nativeTimeout(track(fn), ms, ...args);
        const raf = requestAnimationFrame.bind(window);
        window.requestAnimationFrame = fn => raf(track(fn));
        """#
        let scripts: [(String, String, WKContentWorld)] = [
            ("autofill", Autofill.script, Autofill.world),
            ("media", MediaTray.script, .page), ("audio", TabAudio.script, .page),
            ("hover", StatusBar.script, .page), ("previews", Previews.script, .page),
            ("drafts", DraftProtection.script, DraftProtection.world),
            ("boosts", SiteBoostScripts.runtime, SiteBoostScripts.world)
        ]
        let names = ["vanepw", MediaTray.messageName, TabAudio.messageName, StatusBar.messageName,
                     Previews.messageName, DraftProtection.messageName, SiteBoostScripts.messageName]
        let html = "<body><a id='link' href='https://other.test/'><span id='leaf'>Link</span></a><div id='root'>" +
            String(repeating: "<section><span>Text</span></section>", count: 10_000) +
            "</div><form><input autocomplete='username'><input type='password'></form></body>"
        for (index, item) in scripts.enumerated() {
            let (web, capture) = try await fixture(script: item.1, name: names[index], world: item.2,
                                                  html: html, tracking: tracking,
                                                  injectionTime: ["media", "drafts", "boosts"].contains(item.0) ? .atDocumentStart : .atDocumentEnd)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
            defer { window.close() }
            _ = try await js(web, "await __wait(300); return true;", world: item.2)
            func sample(_ label: String, _ body: String) async throws {
                capture.messages.removeAll()
                capture.messageCount = 0
                let metrics = try await js(web, """
                __queries = 0; __styles = 0; __cost = 0; __callbacks = 0;
                const start = performance.now();
                \(body);
                return {queries: __queries, styles: __styles, callbackMS: __cost,
                        callbacks: __callbacks, wallMS: performance.now() - start};
                """, world: item.2)
                print("PAGE_SCRIPT \(item.0) \(label): \(metrics), messages=\(capture.messageCount)")
            }
            try await sample("idle500", "await __wait(500)")
            try await sample("mutations", """
            for (let i = 0; i < 30; i++) {
              const card = document.createElement('section'); card.innerHTML = '<span>More</span>'.repeat(20);
              document.getElementById('root').append(card); await __wait(20);
            }
            await __wait(300);
            """)
            try await sample("pointerScroll", """
            const leaf = document.getElementById('leaf');
            for (let i = 0; i < 1000; i++) {
              leaf.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
              leaf.dispatchEvent(new MouseEvent('mouseout', {bubbles:true, relatedTarget:document.body}));
              window.dispatchEvent(new Event('scroll'));
            }
            await __wait(300);
            """)
            if item.0 == "audio" {
                _ = try await js(web, "__vaneMute(true); __vaneMute(false); return true;", world: item.2)
                try await sample("afterUnmute", """
                for (let i = 0; i < 100; i++) {
                  const card = document.createElement('section'); card.innerHTML = '<span>More</span>'.repeat(100);
                  document.getElementById('root').append(card); await Promise.resolve();
                }
                await __wait(300);
                """)
                _ = try await js(web, "__vaneMute(true); return true;", world: item.2)
                try await sample("mutedMediaBurst", """
                for (let i = 0; i < 100; i++) {
                  const card = document.createElement('section');
                  card.innerHTML = '<span>More</span>'.repeat(100) + (i === 0 ? '<video></video>' : '');
                  document.getElementById('root').append(card); await Promise.resolve();
                }
                await __wait(300);
                """)
            }
            if ["media", "audio"].contains(item.0) {
                try await sample("mediaEvents", """
                const video = document.createElement('video'); document.body.append(video);
                for (let i = 0; i < 500; i++) {
                  video.dispatchEvent(new Event('loadedmetadata')); video.dispatchEvent(new Event('volumechange'));
                }
                await __wait(300);
                """)
            }
            if item.0 == "autofill" {
                try await sample("dynamicForms", """
                for (let i = 0; i < 20; i++) {
                  const form = document.createElement('form');
                  form.innerHTML = '<input autocomplete=username><input type=password>'; document.body.append(form);
                  form.querySelector('input').focus(); await __wait(20); form.remove();
                }
                await __wait(300);
                """)
            }
            if item.0 == "boosts" {
                _ = try await js(web, "__vaneBoost.apply('', 1.2); return true;", world: item.2)
                try await sample("scaledMutations", """
                for (let i = 0; i < 30; i++) {
                  const p = document.createElement('p'); p.textContent = 'More';
                  document.getElementById('root').append(p); await __wait(20);
                }
                await __wait(300);
                """)
                _ = try await js(web, "__vaneBoost.apply('', 1); __vaneBoost.zap(true); return true;", world: item.2)
                try await sample("zapPointer", """
                const leaf = document.getElementById('root').firstElementChild.firstElementChild;
                for (let i = 0; i < 10; i++) leaf.dispatchEvent(new PointerEvent('pointermove', {bubbles:true}));
                await __wait(100);
                """)
            }
            web.stopLoading()
            web.configuration.userContentController.removeAllScriptMessageHandlers()
        }
    }

    func testAudioDiscoveryStopsWhenUnmutedAndRestartsForNewPlayers() async throws {
        let (web, _) = try await fixture(script: TabAudio.script, name: TabAudio.messageName)
        let queries = try await js(web, """
        __vaneMute(true);
        __vaneMute(false);
        __queries = 0;
        for (let i = 0; i < 100; i++) {
            const card = document.createElement('section');
            card.innerHTML = '<div><span>Ordinary framework update</span></div>';
            document.getElementById('root').append(card);
            await Promise.resolve();
        }
        return __queries;
        """) as? Int
        XCTAssertEqual(queries, 0, "Unmuting must stop inspecting unrelated DOM updates")

        _ = try await js(web, """
        __vaneMute(true);
        const wrapper = document.createElement('div');
        wrapper.innerHTML = '<video id="replacement"></video><audio id="sound"></audio>';
        document.body.append(wrapper);
        return true;
        """)
        let deadline = Date.now.addingTimeInterval(3)
        var muted = false
        while !muted && Date.now < deadline {
            muted = try await js(web, "return document.getElementById('replacement').muted && document.getElementById('sound').muted;") as? Bool == true
            if !muted { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(muted, "New nested players must inherit mute after re-enabling it")
        _ = try await js(web, "__vaneMute(false); return true;")
        let unmuted = try await js(web, "return !document.getElementById('replacement').muted && !document.getElementById('sound').muted;") as? Bool
        XCTAssertEqual(unmuted, true)
    }

    func testMutedAudioDiscoveryCoalescesBeforeInspectingMoreSubtrees() async throws {
        let (web, _) = try await fixture(script: TabAudio.script, name: TabAudio.messageName)
        let queries = try await js(web, """
        __vaneMute(true);
        __queries = 0;
        for (let i = 0; i < 100; i++) {
            const card = document.createElement('section');
            card.innerHTML = i === 0 ? '<div><video id="replacement"></video></div>' : '<div><span>Card</span></div>';
            document.getElementById('root').append(card);
            await Promise.resolve();
        }
        return __queries;
        """) as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(queries), 1,
                                "One queued reconciliation already covers the entire mutation burst")
        let deadline = Date.now.addingTimeInterval(3)
        var muted = false
        while !muted && Date.now < deadline {
            muted = try await js(web, "return document.getElementById('replacement').muted;") as? Bool == true
            if !muted { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(muted)
    }

    func testAudioEventsDoNotSearchTheDocument() async throws {
        let (web, _) = try await fixture(script: TabAudio.script, name: TabAudio.messageName,
                                         html: "<body><audio id='first'></audio><video id='second'></video></body>")
        let queries = try await js(web, """
        __queries = 0;
        for (let i = 0; i < 200; i++) {
            document.getElementById('first').dispatchEvent(new Event('volumechange'));
            document.getElementById('second').dispatchEvent(new Event('pause'));
        }
        return __queries;
        """) as? Int
        XCTAssertEqual(queries, 0, "Repeated media events must not search an unchanged large DOM")
    }

    func testZapPointerMovementDoesNotBuildSelectorsUntilPicking() async throws {
        let (web, capture) = try await fixture(script: SiteBoostScripts.runtime,
                                               name: SiteBoostScripts.messageName,
                                               world: SiteBoostScripts.world,
                                               html: "<body><div id='root'><span id='duplicate'>First</span><span id='duplicate'>Second</span></div></body>")
        let queries = try await js(web, """
        __vaneBoost.zap(true);
        const leaf = document.getElementById('root').lastElementChild;
        __queries = 0;
        for (let i = 0; i < 100; i++) {
            leaf.dispatchEvent(new PointerEvent('pointermove', {bubbles: true}));
        }
        return __queries;
        """, world: SiteBoostScripts.world) as? Int
        XCTAssertEqual(queries, 0, "Highlighting needs geometry, not a document-wide unique selector search")
        _ = try await js(web, """
        // A framework can change the path between highlighting and clicking.
        document.getElementById('root').prepend(document.createElement('span'));
        document.getElementById('root').lastElementChild.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
        return true;
        """, world: SiteBoostScripts.world)
        let deadline = Date.now.addingTimeInterval(3)
        while !capture.messages.contains(where: { $0["kind"] as? String == "pick" }) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let selector = try XCTUnwrap(capture.messages.first { $0["kind"] as? String == "pick" }?["selector"] as? String)
        XCTAssertEqual(selector, "body > div:nth-of-type(1) > span:nth-of-type(3)",
                       "Picking validates the current path and handles duplicate IDs")
        _ = try await js(web, "__vaneBoost.zap(false); return true;", world: SiteBoostScripts.world)
    }

    func testBriefHoversDoNotCancelUnrequestedPreviews() async throws {
        let (web, capture) = try await fixture(script: Previews.script, name: Previews.messageName,
                                               html: "<body><a id='link' href='https://other.test/'><span id='leaf'>Link</span></a></body>")
        _ = try await js(web, """
        const leaf = document.getElementById('leaf');
        for (let i = 0; i < 100; i++) {
            leaf.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
            leaf.dispatchEvent(new MouseEvent('mouseout', {bubbles:true, relatedTarget:document.body}));
        }
        // Wait beyond the intentional dwell: canceled hovers must never request a preview.
        await new Promise(resolve => setTimeout(resolve, 250));
        return true;
        """)
        XCTAssertTrue(capture.messages.isEmpty, "Sweeping over links must not send native cancellation work for previews never requested")
        capture.messages.removeAll()
        _ = try await js(web, """
        const leaf = document.getElementById('leaf');
        leaf.dispatchEvent(new MouseEvent('mouseover', {bubbles:true, shiftKey:true}));
        leaf.dispatchEvent(new MouseEvent('mouseout', {bubbles:true, relatedTarget:document.getElementById('link')}));
        window.dispatchEvent(new Event('scroll'));
        window.dispatchEvent(new Event('scroll'));
        return true;
        """)
        let deadline = Date.now.addingTimeInterval(3)
        while capture.messages.count < 2 && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(capture.messages.count, 2, "An announced preview must still be canceled once when scrolling")
        XCTAssertEqual(capture.messages.first?["url"] as? String, "https://other.test/")
        XCTAssertEqual(capture.messages.last?["gone"] as? Bool, true)
    }

    func testEditingFocusSurvivesPageLifecycleWithoutAnUnloadListener() async throws {
        let tracking = """
        window.__focusEvents = [];
        const listen = window.addEventListener.bind(window);
        window.addEventListener = function(name, ...args) {
            __focusEvents.push(name);
            return listen(name, ...args);
        };
        """
        let (web, capture) = try await fixture(script: tracking + PageFocus.script,
                                               name: PageFocus.messageName, world: PageFocus.world,
                                               html: "<body><input id='editor'></body>")
        let hasUnload = try await js(web, "return __focusEvents.includes('unload');",
                                    world: PageFocus.world) as? Bool
        XCTAssertEqual(hasUnload, false, "The focus script must allow WebKit's page cache")

        func waitForEditing(_ editing: Bool) async throws {
            let deadline = Date.now.addingTimeInterval(3)
            while capture.messages.last?["editable"] as? Bool != editing && Date.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(capture.messages.last?["editable"] as? Bool, editing)
        }
        _ = try await js(web, "document.getElementById('editor').focus(); return true;",
                        world: PageFocus.world)
        try await waitForEditing(true)
        let frame = try XCTUnwrap(capture.messages.last?["frame"] as? String)
        _ = try await js(web, "window.dispatchEvent(new PageTransitionEvent('pagehide', {persisted: true})); return true;",
                        world: PageFocus.world)
        try await waitForEditing(false)
        _ = try await js(web, "window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted: true})); return true;",
                        world: PageFocus.world)
        try await waitForEditing(true)
        XCTAssertEqual(capture.messages.last?["frame"] as? String, frame,
                       "Restoring a cached document preserves its frame identity and editing state")
        _ = try await js(web, "document.getElementById('editor').blur(); return true;",
                        world: PageFocus.world)
        try await waitForEditing(false)
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
