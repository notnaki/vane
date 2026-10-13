import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class Feel08PageToolsTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func fixture(_ script: String, name: String, world: WKContentWorld = .page,
                         html: String = "<body><main id=root></main></body>") async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let controller = WKUserContentController(), capture = Capture()
        controller.add(capture, contentWorld: world, name: name)
        controller.addUserScript(WKUserScript(source: Self.tracking, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: world))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            web.stopLoading()
            controller.removeAllScriptMessageHandlers()
            window.close()
        }
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://feel08.example.test/")!), responseHTML: html)
        try await compatibilityWait { !web.isLoading && web.url != nil }
        return (web, capture)
    }

    private static let tracking = #"""
    window.__work = {styles:0, queries:0, subtrees:0, values:0, ranges:0, listeners:0, deliveries:0, observers:0};
    const computed = window.getComputedStyle;
    window.getComputedStyle = function(...args) { __work.styles++; return computed.apply(this,args); };
    const query = Document.prototype.querySelectorAll;
    Document.prototype.querySelectorAll = function(...args) { __work.queries++; return query.apply(this,args); };
    const subtree = Element.prototype.querySelectorAll;
    Element.prototype.querySelectorAll = function(...args) { __work.subtrees++; return subtree.apply(this,args); };
    const inputValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');
    Object.defineProperty(HTMLInputElement.prototype,'value', {...inputValue,
      get() { __work.values++; return inputValue.get.call(this); }});
    const range = Document.prototype.createRange;
    Document.prototype.createRange = function(...args) { __work.ranges++; return range.apply(this,args); };
    const listen = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(...args) { __work.listeners++; return listen.apply(this,args); };
    const Observer = window.MutationObserver;
    window.__observers = [];
    window.MutationObserver = class extends Observer {
      constructor(fn) { super((...args) => { __work.deliveries++; fn(...args); }); __observers.push(this); }
      observe(...args) { if (!this.active) __work.observers++; this.active=true; return super.observe(...args); }
      disconnect() { if (this.active) __work.observers--; this.active=false; return super.disconnect(); }
    };
    // Drive rendering boundaries explicitly: other desktop fixtures can occlude this
    // window and suspend WebKit's rAF. DOM/style work still runs in real WebKit.
    let frameSerial=0; const frames=new Map();
    window.requestAnimationFrame = fn => { const id=++frameSerial; frames.set(id,fn); return id; };
    window.cancelAnimationFrame = id => frames.delete(id);
    window.__settle = async () => {
      for(let i=0;i<2;i++) { await Promise.resolve(); const batch=[...frames.values()]; frames.clear(); for(const fn of batch) fn(performance.now()); }
      await Promise.resolve();
    };
    """#

    private func js(_ web: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: world)
    }

    func testBoostUpdatesMeasureOnlyLatestScaleAndPreserveInheritance() async throws {
        let (web, _) = try await fixture(SiteBoostScripts.runtime, name: SiteBoostScripts.messageName,
            world: SiteBoostScripts.world,
            html: "<style>section {font-size:20px} span {font-size:2em}</style><body><section><p id=parent><span id=child>Text</span></p></section></body>")
        let result = try await js(web, """
        __work.styles = 0;
        for (let i=0; i<20; i++) __vaneBoost.apply('', 1 + i/20);
        __vaneBoost.apply('', 1.5);
        await __settle();
        const reads = __work.styles;
        const sizes = ['parent','child'].map(id => getComputedStyle(document.getElementById(id)).fontSize);
        __vaneBoost.apply('', 1);
        return {reads, sizes, restored:getComputedStyle(document.getElementById('child')).fontSize};
        """, world: SiteBoostScripts.world) as? [String: Any]
        XCTAssertEqual(result?["reads"] as? Int, 2, "Superseded Boost updates must not remeasure the same text")
        XCTAssertEqual(result?["sizes"] as? [String], ["30px", "60px"], "Measure all unscaled styles before writing inherited sizes")
        XCTAssertEqual(result?["restored"] as? String, "40px")
    }

    func testBoostStructuralCSSIsRemeasuredAndPendingWorkCanBeDisabled() async throws {
        let (web, _) = try await fixture(SiteBoostScripts.runtime, name: SiteBoostScripts.messageName,
            world: SiteBoostScripts.world,
            html: "<style>p{font-size:20px} p:has(i){font-size:30px} p:empty + p{font-size:40px}</style><body><p id=first>Text</p><p id=second>More</p></body>")
        let result = try await js(web, """
        __vaneBoost.apply('',1.5); await __settle();
        document.getElementById('first').append(document.createElement('i'));
        await __settle();
        const relational = getComputedStyle(document.getElementById('first')).fontSize;
        document.getElementById('first').replaceChildren();
        await __settle();
        const sibling = getComputedStyle(document.getElementById('second')).fontSize;
        __work.styles=0;
        __vaneBoost.apply('',2); __vaneBoost.apply('',1); await __settle();
        return {relational,sibling,reads:__work.styles,remaining:__work.observers,
          restored:getComputedStyle(document.getElementById('second')).fontSize};
        """, world: SiteBoostScripts.world) as? [String: Any]
        XCTAssertEqual(result?["relational"] as? String, "45px", "Non-text descendants can change an existing element's CSS")
        XCTAssertEqual(result?["sibling"] as? String, "60px", "Removals can change sibling selectors")
        XCTAssertEqual(result?["reads"] as? Int, 0)
        XCTAssertEqual(result?["remaining"] as? Int, 0)
        XCTAssertEqual(result?["restored"] as? String, "40px")
    }

    func testRepeatedInstallationAddsNoListenersObserversOrMessages() async throws {
        for (script, name, world) in [(TabAudio.script, TabAudio.messageName, WKContentWorld.page),
            (MediaTray.script, MediaTray.messageName, .page),
            (Autofill.script, "vanepw", Autofill.world),
            (DraftProtection.script, DraftProtection.messageName, DraftProtection.world),
            (SiteBoostScripts.runtime, SiteBoostScripts.messageName, SiteBoostScripts.world)] {
            let (web, capture) = try await fixture(script, name: name, world: world)
            let before = try await js(web, "return __work.listeners;", world: world) as? Int
            let count = capture.messages.count
            _ = try await js(web, script + "; return true;", world: world)
            let after = try await js(web, "return __work.listeners;", world: world) as? Int
            XCTAssertEqual(after, before, "Repeated \(name) installation must reuse the document runtime")
            XCTAssertEqual(capture.messages.count, count)
        }
    }

    func testFindMeasureReusesOneRangeAcrossManyMatches() async throws {
        let (web, _) = try await fixture("", name: "unused", html: "<body><p>" + String(repeating: "needle ", count: 2000) + "</p></body>")
        _ = try await js(web, """
        const r = document.createRange(); r.selectNodeContents(document.querySelector('p'));
        r.collapse(false); getSelection().addRange(r); __work.ranges=0; return true;
        """)
        let pair = try await web.evaluateJavaScript(Find.measureScript("needle")) as? [Int]
        let ranges = try await js(web, "return __work.ranges;") as? Int
        XCTAssertEqual(pair, [2000, 2000])
        XCTAssertLessThanOrEqual(try XCTUnwrap(ranges), 1, "Counting matches should not allocate one DOM Range per match")
    }

    func testAutofillIdleDiscoveryAvoidsDocumentFrameSelectors() async throws {
        let (web, _) = try await fixture(Autofill.script, name: "vanepw", world: Autofill.world)
        let queries = try await js(web, """
        __work.queries=0;
        for(let i=0;i<100;i++) { const card=document.createElement('section'); card.textContent='Card'; document.getElementById('root').append(card); await Promise.resolve(); }
        await new Promise(resolve=>setTimeout(resolve,160));
        return __work.queries;
        """, world: Autofill.world) as? Int
        // One targetPair input selector remains necessary; frame membership needs no selector.
        XCTAssertLessThanOrEqual(try XCTUnwrap(queries), 1)
    }
    func testDetachedAutofillFramesReleaseTheirObserver() async throws {
        let (web, _) = try await fixture(Autofill.script, name: "vanepw", world: Autofill.world,
            html: "<body><iframe id=child srcdoc='<form><input type=password></form>'></iframe></body>")
        try await compatibilityWait {
            try await self.js(web, "return __work.observers;", world: Autofill.world) as? Int ?? 0 >= 2
        }
        let result = try await js(web, """
        const child=document.getElementById('child'); const old=child.contentDocument; child.remove();
        await new Promise(resolve=>setTimeout(resolve,180));
        const observers=__work.observers; __work.deliveries=0;
        old.body.append(old.createElement('input')); await Promise.resolve();
        return {observers, deliveries:__work.deliveries};
        """, world: Autofill.world) as? [String: Any]
        XCTAssertEqual(result?["observers"] as? Int, 1)
        XCTAssertEqual(result?["deliveries"] as? Int, 0, "Detached credential documents must stop discovery")
    }

    func testDraftMutationBurstsCoalesceWithoutLosingScriptEditsOrShadowDrafts() async throws {
        let (web, _) = try await fixture(DraftProtection.script, name: DraftProtection.messageName,
            world: DraftProtection.world, html: "<body><input id=field><main id=root></main><div id=host></div></body>")
        let result = try await js(web, """
        __work.values=0; __work.subtrees=0;
        for(let i=0;i<100;i++) { document.getElementById('root').append(document.createElement('section')); await Promise.resolve(); }
        await __settle();
        const reads=__work.values, scans=__work.subtrees;
        document.getElementById('field').value='script draft';
        const scriptDirty=__vaneDraft.check().dirty;
        document.getElementById('field').value='';
        const host=document.getElementById('host'); host.attachShadow({mode:'open'}).innerHTML='<textarea></textarea>';
        host.shadowRoot.querySelector('textarea').value='shadow draft';
        const shadowDirty=__vaneDraft.check().dirty;
        return {reads,scans,scriptDirty,shadowDirty};
        """, world: DraftProtection.world) as? [String: Any]
        XCTAssertLessThanOrEqual(try XCTUnwrap(result?["reads"] as? Int), 2, "Passive DOM bursts should not repeatedly walk every draft")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result?["scans"] as? Int), 2, "Nested/adjacent additions should share discovery")
        XCTAssertEqual(result?["scriptDirty"] as? Bool, true)
        XCTAssertEqual(result?["shadowDirty"] as? Bool, true)
    }

    func testDraftPageCacheSuspendsAndResumesDiscovery() async throws {
        let (web, _) = try await fixture(DraftProtection.script, name: DraftProtection.messageName,
            world: DraftProtection.world)
        let result = try await js(web, """
        window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));
        __work.deliveries=0;
        document.getElementById('root').append(document.createElement('input')); await Promise.resolve();
        const deliveries=__work.deliveries;
        let retired=false; try { __vaneDraft.check(); } catch { retired=true; }
        window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
        document.getElementById('root').firstChild.value='draft';
        return {deliveries,retired,dirty:__vaneDraft.check().dirty};
        """, world: DraftProtection.world) as? [String: Any]
        XCTAssertEqual(result?["deliveries"] as? Int, 0)
        XCTAssertEqual(result?["retired"] as? Bool, true)
        XCTAssertEqual(result?["dirty"] as? Bool, true)
    }

    func testMediaSessionBurstDeliversLatestStateOnce() async throws {
        let (web, capture) = try await fixture(MediaTray.script, name: MediaTray.messageName)
        _ = try await js(web, "navigator.mediaSession.metadata=new MediaMetadata({title:'initial'}); return true;")
        try await compatibilityWait { capture.messages.last?["title"] as? String == "initial" }
        capture.messages.removeAll()
        _ = try await js(web, """
        for(let i=0;i<200;i++) navigator.mediaSession.metadata=new MediaMetadata({title:'Track '+i});
        navigator.mediaSession.setActionHandler('nexttrack',()=>{});
        return true;
        """)
        try await compatibilityWait { capture.messages.last?["title"] as? String == "Track 199" && capture.messages.last?["next"] as? Bool == true }
        XCTAssertEqual(capture.messages.count, 1, "A synchronous metadata/handler burst needs only its final native report")
    }

    func testAudioEventBurstDeliversLatestStateOnce() async throws {
        let (web, capture) = try await fixture(TabAudio.script, name: TabAudio.messageName,
            html: "<body><video id=player></video></body>")
        _ = try await js(web, """
        const player=document.getElementById('player');
        Object.defineProperties(player,{paused:{value:false},ended:{value:false},volume:{value:0.5,writable:true}});
        player.dispatchEvent(new Event('play')); return true;
        """)
        try await compatibilityWait { capture.messages.last?["volume"] as? Double == 0.5 }
        capture.messages.removeAll()
        _ = try await js(web, """
        const player=document.getElementById('player');
        for(let i=0;i<200;i++) { player.volume=i/200; player.dispatchEvent(new Event('volumechange')); }
        player.volume=0.7; player.dispatchEvent(new Event('volumechange')); return true;
        """)
        try await compatibilityWait { capture.messages.last?["volume"] as? Double == 0.7 }
        XCTAssertEqual(capture.messages.count, 1)
    }

    func testMutedAudioPageCacheCancelsDiscoveryAndRemutesNestedReplacement() async throws {
        let (web, _) = try await fixture(TabAudio.script, name: TabAudio.messageName)
        let result = try await js(web, """
        __vaneMute(true);
        const wrapper=document.createElement('div'); wrapper.innerHTML='<section><video id=replacement></video><audio></audio></section>';
        document.body.append(wrapper); await Promise.resolve();
        window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));
        const sleeping=__work.observers;
        __work.deliveries=0; wrapper.append(document.createElement('span')); await Promise.resolve();
        const deliveries=__work.deliveries;
        window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
        const muted=[...wrapper.getElementsByTagName('video'),...wrapper.getElementsByTagName('audio')].every(e=>e.muted);
        __vaneMute(false);
        return {sleeping,deliveries,muted,remaining:__work.observers};
        """) as? [String: Any]
        XCTAssertEqual(result?["sleeping"] as? Int, 0)
        XCTAssertEqual(result?["deliveries"] as? Int, 0)
        XCTAssertEqual(result?["muted"] as? Bool, true)
        XCTAssertEqual(result?["remaining"] as? Int, 0)
    }

    func testBoostLargeMutationBurstUsesOneFullMeasurement() async throws {
        let html = "<style>span{font-size:20px}</style><body><main id=root>" + String(repeating:"<section><span>Text</span></section>",count:1000) + "</main></body>"
        let (web, _) = try await fixture(SiteBoostScripts.runtime, name: SiteBoostScripts.messageName,
            world: SiteBoostScripts.world, html: html)
        let result = try await js(web, """
        __vaneBoost.apply('',1.5); await __settle(); __work.styles=0; __work.queries=0;
        for(let i=0;i<100;i++) { const p=document.createElement('p'); p.textContent='Added'; document.getElementById('root').append(p); await Promise.resolve(); }
        await __settle();
        const reads=__work.styles, queries=__work.queries;
        const scaled=getComputedStyle(document.getElementById('root').firstElementChild.firstElementChild).fontSize;
        __vaneBoost.apply('',1);
        return {reads,queries,scaled};
        """, world: SiteBoostScripts.world) as? [String: Any]
        XCTAssertEqual(result?["reads"] as? Int, 1100, "Each current text element is measured once, with no unsafe cached sizes")
        XCTAssertEqual(result?["queries"] as? Int, 1, "A mutation burst must share one current-membership scan")
        XCTAssertEqual(result?["scaled"] as? String, "30px")
    }

    func testDraftKeepsTransientScriptEditedControlWithoutRescanningExistingPage() async throws {
        let html="<body><main id=root>" + String(repeating:"<section><span>Existing</span></section>",count:1000) + "</main></body>"
        let (web, _) = try await fixture(DraftProtection.script, name: DraftProtection.messageName,
            world: DraftProtection.world, html: html)
        let result = try await js(web, """
        // Count discovery visits, not only selector calls: a full-parent scan would
        // repeatedly inspect all 2,000 existing elements for one new control.
        let visits=0;
        const editable=Object.getOwnPropertyDescriptor(HTMLElement.prototype,'isContentEditable');
        Object.defineProperty(HTMLElement.prototype,'isContentEditable',{...editable,get(){visits++;return editable.get.call(this);}});
        const field=document.createElement('input'); document.getElementById('root').append(field);
        field.value='unsent'; field.remove(); await __settle();
        const passiveVisits=visits;
        return {passiveVisits,dirty:__vaneDraft.check().dirty};
        """, world: DraftProtection.world) as? [String: Any]
        XCTAssertEqual(result?["dirty"] as? Bool, true, "Removed script-edited controls still represent unsubmitted work")
        XCTAssertLessThanOrEqual(try XCTUnwrap(result?["passiveVisits"] as? Int), 2,
            "Discovery should inspect added subtrees, not their large existing parents")
    }

}
