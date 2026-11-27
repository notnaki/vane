import AppKit
import JavaScriptCore
import UserNotifications
import WebKit
import XCTest
@testable import vane

/// Windowless: the Notifications answer store and the page shim, run in a bare JSContext.
@MainActor final class WebNotificationPermissionTests: XCTestCase {
    private var profile = UUID()

    override func setUp() async throws {
        TestEnvironment.prepare()
        profile = UUID()
    }

    override func tearDown() async throws {
        SitePermissions.resetAll(profileID: profile)
    }

    private func scope(_ url: String, privateTab: UUID? = nil) -> SitePermissions.Scope {
        SitePermissions.Scope(url: URL(string: url), profileID: profile, privateTabID: privateTab)!
    }

    func testAnswersAreKeyedByOriginAndProfileAndPrivateOnesStayInTheirTab() {
        let site = scope("https://notify.example"), other = scope("https://notify.example:8443")
        XCTAssertNil(SitePermissions.effective(scope: site, type: .notifications), "Ask until answered")
        SitePermissions.set(scope: site, type: .notifications, answer: true)
        SitePermissions.set(scope: other, type: .notifications, answer: false)
        XCTAssertEqual(SitePermissions.effective(scope: site, type: .notifications), true)
        XCTAssertNil(SitePermissions.effective(scope: scope("http://notify.example"), type: .notifications))
        XCTAssertNil(SitePermissions.effective(scope: SitePermissions.Scope(url: URL(string: "https://notify.example"),
                                                                            profileID: UUID())!, type: .notifications))
        XCTAssertEqual(SitePermissions.notificationAnswers(profileID: profile, privateTabID: nil),
                       ["https://notify.example": true, "https://notify.example:8443": false])
        XCTAssertTrue(SitePermissions.all(profileID: profile).contains { $0.what == "Notifications" && $0.allowed })

        let privateTab = UUID(), privateSite = scope("https://notify.example", privateTab: privateTab)
        XCTAssertNil(SitePermissions.effective(scope: privateSite, type: .notifications), "no regular answer in a private tab")
        SitePermissions.set(scope: privateSite, type: .notifications, answer: true)
        XCTAssertEqual(SitePermissions.notificationAnswers(profileID: profile, privateTabID: privateTab), ["https://notify.example": true])
        XCTAssertEqual(SitePermissions.all(profileID: profile).filter { $0.what == "Notifications" }.count, 2, "private answers are not saved")
        SitePermissions.forgetPrivate(tabID: privateTab)
        XCTAssertTrue(SitePermissions.notificationAnswers(profileID: profile, privateTabID: privateTab).isEmpty)

        SitePermissions.set(scope: site, type: .notifications, answer: nil)
        XCTAssertNil(SitePermissions.effective(scope: site, type: .notifications))
        XCTAssertEqual(SitePermissions.makePrompt(scope: site, type: .notifications).messageText,
                       "Allow notify.example to show notifications?")
    }

    func testSiteControlsHaveANotificationsRow() {
        var model = SiteControlModel(host: "notify.example", scheme: "https")
        XCTAssertEqual(model.rows.first { $0.id == .notifications }?.control, .permission(nil))
        model.notifications = false
        XCTAssertEqual(model.settings.first { $0.id == .notifications }?.value, "Blocked")
    }

    func testStateScriptHandsThePageOnlyItsOwnAnswer() throws {
        let script = WebNotifications.stateScript(["https://a.example": true, "https://b.example": false])
        for (origin, expected) in [("https://a.example", "granted"), ("https://b.example", "denied"), ("https://c.example", nil)] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("var attrs = {}; var location = {origin: '\(origin)'}; var document = {documentElement: {setAttribute: (n, v) => { attrs[n] = v; }}};")
            context.evaluateScript(script)
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("attrs['\(WebNotifications.attribute)']")?.toString(), expected ?? "undefined")
        }
    }

    /// A page world with just enough DOM for the shim.
    private func page(key: String = "secret-key", saved: String? = nil) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail(exception?.toString() ?? "exception") }
        context.evaluateScript("""
            class Event { constructor(type) { this.type = type; } }
            class EventTarget {
              #listeners = {};
              addEventListener(type, listener) { (this.#listeners[type] ??= []).push(listener); }
              dispatchEvent(event) { for (const listener of this.#listeners[event.type] ?? []) listener.call(this, event); return true; }
            }
            var posted = [], events = [], replies = {request: 'granted', show: true, close: null}, active = false;
            var isSecureContext = true, location = {protocol: 'https:', origin: 'https://a.example', href: 'https://a.example/'};
            class Activation { get isActive() { return active; } }
            // Like WebKit's: its accessors refuse anything not made natively.
            globalThis.PermissionStatus = class extends EventTarget { get onchange() { throw new TypeError('Illegal'); } set onchange(v) { throw new TypeError('Illegal'); } }
            var navigator = {userActivation: new Activation(), permissions: {query: () => Promise.resolve('native')}};
            var crypto = {randomUUID: () => 'doc-1'};
            var attrs = \(saved.map { "{'\(WebNotifications.attribute)': '\($0)'}" } ?? "{}");
            var loaded = [];
            var document = {documentElement: {getAttribute: n => attrs[n] ?? null, removeAttribute: n => { delete attrs[n]; }},
                            addEventListener: (type, listener) => { if (type === 'DOMContentLoaded') loaded.push(listener); }};
            var webkit = {messageHandlers: {\(WebNotifications.messageName): {postMessage(m) { posted.push(JSON.parse(JSON.stringify(m))); return Promise.resolve(replies[m.op]); }}}};
            var setTimeout = f => Promise.resolve().then(f);
            var structuredClone = x => x;
            """)
        context.evaluateScript(WebNotifications.shim(key: key))
        return context
    }

    private func value(_ context: JSContext, _ code: String) -> String? { context.evaluateScript(code)?.toString() }

    func testTheHandOffLeavesTheRootAtDOMContentLoadedAndQueryLooksNative() throws {
        let context = try page(saved: "granted")
        context.evaluateScript("loaded.forEach(f => f())")
        XCTAssertEqual(value(context, "Object.keys(attrs).length"), "0", "gone before the page's scripts finish")
        XCTAssertEqual(value(context, "Notification.permission"), "granted")
        context.evaluateScript("""
            var status; navigator.permissions.query({name: 'notifications'}).then(s => {
              status = s; s.onchange = () => events.push('onchange'); s.addEventListener('change', () => events.push('change'));
            });
            """)
        XCTAssertEqual(value(context, "status instanceof PermissionStatus"), "true")
        XCTAssertEqual(value(context, "status.name + ' ' + status.state"), "notifications granted")
        context.evaluateScript("globalThis[Symbol.for('vane.notifications')]('permission', 'denied', 'https://a.example')")
        XCTAssertEqual(value(context, "events.join() + ' ' + status.state"), "change,onchange denied")
        let other = try page()
        other.evaluateScript("var q; navigator.permissions.query({name: 'camera'}).then(v => { q = v; });")
        XCTAssertEqual(value(other, "q"), "native", "other names reach the native query")
    }

    func testIdentifiersNeverCollideAcrossSitesAndClosingATabKeepsAnotherTabsOwn() throws {
        let tag = WebNotifications.identifier
        XCTAssertNotEqual(tag(scope("https://a.example"), "x.y"), tag(scope("https://a.example.x"), "y"))
        XCTAssertEqual(tag(scope("https://a.example"), "t"), tag(scope("https://a.example"), "t"), "a tag replaces its own")
        XCTAssertNotEqual(tag(scope("https://a.example"), ""), tag(scope("https://a.example"), ""))
        let privateTab = UUID()
        XCTAssertTrue(tag(scope("https://a.example", privateTab: privateTab), "t").hasPrefix("web.private."))
        XCTAssertTrue(tag(scope("https://a.example", privateTab: privateTab), "").hasPrefix("web.private."))
        XCTAssertFalse(tag(scope("https://a.example"), "").hasPrefix("web.private."))

        let saved = (WebNotifications.shown, WebNotifications.remove)
        defer { (WebNotifications.shown, WebNotifications.remove) = saved }
        var removed: [Set<String>] = []
        WebNotifications.remove = { removed.append(Set($0)) }
        let a = UUID(), b = UUID(), shared = tag(scope("https://a.example"), "t")
        WebNotifications.shown = [a: [WebNotifications.key("d1", 1): "web.1", WebNotifications.key("d2", 1): "web.2",
                                      WebNotifications.key("d2", 2): shared],
                                  b: [WebNotifications.key("d3", 1): shared, WebNotifications.key("d3", 2): "web.private.p"]]
        WebNotifications.drop(tabID: a)
        XCTAssertEqual(removed, [["web.1", "web.2"]], "both documents' notifications go; the shared tag is tab B's too")
        WebNotifications.terminating()
        XCTAssertEqual(removed.last, ["web.private.p"], "quitting removes private tabs' notifications")
    }

    func testShimReportsTheSavedAnswerAndRefusesWithoutIt() throws {
        let context = try page(saved: "denied")
        XCTAssertEqual(value(context, "Notification.permission"), "denied")
        XCTAssertEqual(value(context, "Object.keys(attrs).length"), "0", "the hand-off is read once and removed")
        context.evaluateScript("var n = new Notification('No'); n.onerror = () => events.push('error');")
        XCTAssertEqual(value(context, "events.join()"), "error")
        XCTAssertEqual(value(context, "posted.length"), "0", "nothing is posted without permission")
        XCTAssertEqual(value(context, "Notification.name"), "Notification")
        XCTAssertEqual(try page().evaluateScript("Notification.permission")?.toString(), "default")
    }

    func testShimPostsWithItsKeyAndHearsVaneBack() throws {
        let context = try page(saved: "granted")
        context.evaluateScript("""
            var n = new Notification('Hi', {body: 'There', tag: 't', silent: true});
            n.onshow = () => events.push('show'); n.onclick = () => events.push('click');
            n.addEventListener('close', () => events.push('close'));
            """)
        XCTAssertEqual(value(context, "JSON.stringify(posted[0])"),
                       #"{"id":1,"document":"doc-1","title":"Hi","body":"There","tag":"t","icon":"","silent":true,"op":"show","key":"secret-key"}"#)
        // A click on what an earlier document in the tab showed is not this page's.
        context.evaluateScript("globalThis[Symbol.for('vane.notifications')]('click', 1, '', 'doc-0')")
        context.evaluateScript("globalThis[Symbol.for('vane.notifications')]('click', 1, '', 'doc-1')")
        context.evaluateScript("n.close(); n.close(); events.push('closing');")
        XCTAssertEqual(value(context, "events.join()"), "show,click,closing,close", "close fires as a task, not inside close()")
        XCTAssertEqual(value(context, "JSON.stringify(posted.filter(m => m.op === 'close'))"),
                       #"[{"id":1,"document":"doc-1","op":"close","key":"secret-key"}]"#)
        context.evaluateScript("new Notification('Bad icon', {icon: 'http://['})")
        XCTAssertEqual(value(context, "posted.at(-1).icon"), "", "an icon that is not a URL is ignored")
        XCTAssertFalse(value(context, "Notification.toString() + Notification.requestPermission.toString()")!.contains("secret-key"),
                       "page code cannot read the key back out of the shim")
    }

    func testRequestPermissionTellsVaneWhetherTheUserActed() throws {
        let context = try page()
        context.evaluateScript("var answers = []; Notification.requestPermission(a => answers.push(a));")
        context.evaluateScript("active = true; Notification.requestPermission().then(a => answers.push(a));")
        XCTAssertEqual(value(context, "posted.map(m => m.gesture).join()"), "false,true")
        XCTAssertEqual(value(context, "answers.join()"), "granted,granted")
        XCTAssertEqual(value(context, "Notification.permission"), "granted")
        // Another origin's answer is not this page's.
        context.evaluateScript("globalThis[Symbol.for('vane.notifications')]('permission', 'denied', 'https://b.example')")
        XCTAssertEqual(value(context, "Notification.permission"), "granted")
        context.evaluateScript("globalThis[Symbol.for('vane.notifications')]('permission', 'denied', 'https://a.example')")
        XCTAssertEqual(value(context, "Notification.permission"), "denied")
    }

    func testShimStaysOutOfInsecurePagesAndANativeNotification() throws {
        let insecure = try XCTUnwrap(JSContext())
        insecure.evaluateScript("var isSecureContext = false, location = {protocol: 'http:'};")
        insecure.evaluateScript(WebNotifications.shim(key: "k"))
        XCTAssertEqual(insecure.evaluateScript("typeof Notification")?.toString(), "undefined")
        let native = try XCTUnwrap(JSContext())
        native.evaluateScript("var Notification = 'native', isSecureContext = true, location = {protocol: 'https:'};")
        native.evaluateScript(WebNotifications.shim(key: "k"))
        XCTAssertEqual(native.evaluateScript("Notification")?.toString(), "native")
    }

    func testExtensionNotificationsAskTheHost() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail(exception?.toString() ?? "exception") }
        context.evaluateScript("""
            // JavaScriptCore alone has no URLSearchParams.
            class URLSearchParams {
              constructor(init) { this.p = typeof init === 'string' ? Object.fromEntries(init.split('&').map(s => s.split('=').map(decodeURIComponent))) : init; }
              get(key) { return this.p[key]; }
              toString() { return Object.entries(this.p).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&'); }
            }
            var asked = [];
            var chrome = {runtime: {id: 'x', getManifest: () => ({manifest_version: 3, name: 'X', version: '1', permissions: ['notifications']}),
                                    getURL: path => 'webkit-extension://x' + path},
                          tabs: {create({url}) {
                            const query = new URLSearchParams(url.split('?')[1]);
                            asked.push(query.get('op') + ' ' + query.get('args'));
                            return Promise.reject(new Error('\(ExtensionChromiumGaps.marker){"value":"n1"}'));
                          }}};
            """)
        context.evaluateScript(ExtensionChromiumGaps.script)
        context.evaluateScript("var created; chrome.notifications.create({title: 'T', message: 'M', buttons: [{title: 'B'}]}, id => { created = id; });")
        XCTAssertEqual(context.evaluateScript("created")?.toString(), "n1")
        XCTAssertEqual(context.evaluateScript("asked[0]")?.toString(),
                       #"notifications.create {"id":"","options":{"title":"T","message":"M","buttons":[{"title":"B"}]}}"#)
        XCTAssertEqual(context.evaluateScript("typeof chrome.notifications.onClicked.addListener")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("typeof chrome.notifications.getPermissionLevel")?.toString(), "function")
    }

    func testTheWorkerKeepsPollingUntilTheHostSaysIdle() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail(exception?.toString() ?? "exception") }
        context.evaluateScript("""
            class URLSearchParams {
              constructor(init) { this.p = typeof init === 'string' ? Object.fromEntries(init.split('&').map(s => s.split('=').map(decodeURIComponent))) : init; }
              get(key) { return this.p[key]; }
              toString() { return Object.entries(this.p).map(([k, v]) => k + '=' + encodeURIComponent(v)).join('&'); }
            }
            function ServiceWorkerGlobalScope() {}
            Object.defineProperty(ServiceWorkerGlobalScope, Symbol.hasInstance, {value: () => true});
            var WebSocket = {vane: true}; // no worker WebSocket stand-in here
            var asked = [], heard = [];
            var replies = [{events: [], idle: false}, {events: [{type: 'clicked', id: 'n1'}], idle: false}, {events: [], idle: true}];
            var chrome = {runtime: {id: 'x', getManifest: () => ({manifest_version: 3, name: 'X', version: '1', permissions: ['notifications']}),
                                    getURL: path => 'webkit-extension://x' + path},
                          tabs: {create({url}) {
                            asked.push(new URLSearchParams(url.split('?')[1]).get('op'));
                            return Promise.reject(new Error('\(ExtensionChromiumGaps.marker)' + JSON.stringify({value: replies.shift()})));
                          }}};
            """)
        context.evaluateScript(ExtensionChromiumGaps.script)
        context.evaluateScript("chrome.notifications.onClicked.addListener(id => heard.push(id));")
        XCTAssertEqual(context.evaluateScript("asked.join()")?.toString(), "notifications.next,notifications.next,notifications.next",
                       "a reply with nothing in it is not idle")
        XCTAssertEqual(context.evaluateScript("heard.join()")?.toString(), "n1")
    }

    func testExtensionNotificationsQueueEventsAndGoIdle() async throws {
        let owner = "\(UUID())/ext"
        defer { ExtensionNotifications.forget(owner: owner) }
        let post = WebNotifications.post
        var shown: [String] = []
        WebNotifications.post = { identifier, content in shown.append(content.subtitle + "|" + content.title); return true }
        defer { WebNotifications.post = post }
        var woke = 0
        let id = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T", "message": "M"]],
                                                         owner: owner, name: "Ext", wake: { woke += 1 }) as? String
        XCTAssertEqual(shown, ["Ext|T"], "shown under the extension's name")
        let all = try await ExtensionNotifications.answer("notifications.getAll", [:], owner: owner, name: "Ext") as? [String: Bool]
        XCTAssertEqual(all, [try XCTUnwrap(id): true])
        ExtensionNotifications.responded(owner: owner, id: try XCTUnwrap(id), action: "button.1")
        XCTAssertEqual(woke, 1, "an event with no poll waiting loads the background")
        let next = try await ExtensionNotifications.answer("notifications.next", [:], owner: owner, name: "Ext") as? [String: Any]
        let event = try XCTUnwrap((next?["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["type"] as? String, "buttonClicked")
        XCTAssertEqual(event["index"] as? Int, 1)
        XCTAssertEqual(next?["idle"] as? Bool, false, "the worker polls again")
        let idle = try await ExtensionNotifications.answer("notifications.next", [:], owner: owner, name: "Ext") as? [String: Any]
        XCTAssertEqual(idle?["idle"] as? Bool, true, "no poll is held once nothing is showing")
        let level = try await ExtensionNotifications.answer("notifications.getPermissionLevel", [:], owner: owner, name: "Ext") as? String
        XCTAssertEqual(level, "denied", "no Notification Center here, so nothing can show")
    }

    func testANewerPollReleasesTheOlderAndClearedOnesStopCounting() async throws {
        let owner = "\(UUID())/ext"
        let saved = (WebNotifications.post, ExtensionNotifications.delivered, ExtensionNotifications.grace)
        defer {
            ExtensionNotifications.forget(owner: owner)
            (WebNotifications.post, ExtensionNotifications.delivered, ExtensionNotifications.grace) = saved
        }
        WebNotifications.post = { _, _ in true }
        /// Whether the poll said idle, and its first event's type.
        func next() async throws -> (idle: Bool?, first: String?) {
            let reply = try await ExtensionNotifications.answer("notifications.next", [:], owner: owner, name: "Ext") as? [String: Any]
            return (reply?["idle"] as? Bool, (reply?["events"] as? [[String: Any]])?.first?["type"] as? String)
        }
        let created = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T"]],
                                                              owner: owner, name: "Ext") as? String
        let id = try XCTUnwrap(created)
        let older = Task { try await next() }
        for _ in 0..<20 { await Task.yield() }
        let newer = Task { try await next() }
        let released = try await older.value
        XCTAssertEqual(released.idle, true, "the older poller stops rather than ping-pong")
        for _ in 0..<20 { await Task.yield() }
        ExtensionNotifications.responded(owner: owner, id: id, action: "clicked")
        let heard = try await newer.value
        XCTAssertEqual(heard.first, "clicked")
        XCTAssertEqual(heard.idle, false)

        // Cleared from Notification Center with no dismissal: polling ends rather than hold for ever.
        _ = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T"]], owner: owner, name: "Ext")
        ExtensionNotifications.delivered = { [] }
        ExtensionNotifications.grace = .zero
        let idle = try await next()
        XCTAssertEqual(idle.idle, true)
        let all = try await ExtensionNotifications.answer("notifications.getAll", [:], owner: owner, name: "Ext") as? [String: Bool]
        XCTAssertEqual(all, [:])
    }

    func testAClickDuringReconcileIsHandedOutNotLeftQueued() async throws {
        let owner = "\(UUID())/ext"
        let saved = (WebNotifications.post, ExtensionNotifications.delivered)
        defer {
            ExtensionNotifications.forget(owner: owner)
            (WebNotifications.post, ExtensionNotifications.delivered) = saved
        }
        WebNotifications.post = { _, _ in true }
        let created = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T"]],
                                                              owner: owner, name: "Ext") as? String
        let id = try XCTUnwrap(created)
        // The click lands while Notification Center is asked, and takes the last live one.
        ExtensionNotifications.delivered = {
            ExtensionNotifications.responded(owner: owner, id: id, action: "clicked")
            return nil
        }
        let reply = try await ExtensionNotifications.answer("notifications.next", [:], owner: owner, name: "Ext") as? [String: Any]
        XCTAssertEqual(reply?["idle"] as? Bool, false)
        XCTAssertEqual((reply?["events"] as? [[String: Any]])?.first?["type"] as? String, "clicked")
    }

    func testAClickHandedToAnUnloadedWorkerReachesTheNextOne() async throws {
        let owner = "\(UUID())/ext"
        let post = WebNotifications.post
        defer { ExtensionNotifications.forget(owner: owner); WebNotifications.post = post }
        WebNotifications.post = { _, _ in true }
        var woke = 0
        func next(_ worker: String) async throws -> [String] {
            let reply = try await ExtensionNotifications.answer("notifications.next", ["worker": worker], owner: owner,
                                                                name: "Ext") as? [String: Any]
            return (reply?["events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        let created = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T"]],
                                                              owner: owner, name: "Ext", wake: { woke += 1 }) as? String
        let first = try XCTUnwrap(created)
        _ = try await ExtensionNotifications.answer("notifications.create", ["options": ["title": "T"]], owner: owner, name: "Ext")
        // Worker A's poll is held, then WebKit unloads A: the click's reply goes nowhere.
        let dead = Task { try await next("A") }
        for _ in 0..<20 { await Task.yield() }
        ExtensionNotifications.responded(owner: owner, id: first, action: "clicked")
        let lost = try await dead.value
        XCTAssertEqual(lost, [first])
        XCTAssertEqual(woke, 1, "releasing a held poll still loads the background")
        let again = try await next("B")
        XCTAssertEqual(again, [first], "the fresh worker gets it again")
        // B polls again: it had them, so they are not handed out a third time (and B is held).
        let held = Task { try await next("B") }
        for _ in 0..<20 { await Task.yield() }
        ExtensionNotifications.forget(owner: owner)
        let none = try await held.value
        XCTAssertEqual(none, [])
    }
}

/// Real WebKit (CI): the shim reports the saved answer at parse time and posts to the bridge.
@MainActor final class WebNotificationWebTests: XCTestCase {
    private var server: CompatibilityServer!
    private var tab: Tab?
    private var window: NSWindow?
    private var profile = UUID()
    private var post: (@MainActor (String, UNMutableNotificationContent) async -> Bool)?
    private var posted: [UNMutableNotificationContent] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try CompatibilityServer()
        try await compatibilityWait { self.server.port != nil }
        post = WebNotifications.post
        WebNotifications.post = { [weak self] _, content in self?.posted.append(content); return true }
    }

    override func tearDown() async throws {
        if let post { WebNotifications.post = post }
        tab?.tearDown()
        window?.close()
        SitePermissions.resetAll(profileID: profile)
        server?.stop()
        tab = nil; window = nil; server = nil
    }

    private func load(_ html: String) async throws -> Tab {
        server.pages["/n"] = "<title>Notify fixture</title>" + html
        server.pages["/frame"] = "<title>Frame</title><script>parent.postMessage(typeof Notification, '*')</script>"
        let tab = Tab(popup: Tab.configuration(profileID: profile), isPrivate: false, profileID: profile)
        self.tab = tab
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
        self.window = window
        tab.go(try server.url("/n"))
        try await compatibilityWait { tab.web.title == "Notify fixture" && !tab.web.isLoading }
        return tab
    }

    private func evaluate(_ tab: Tab, _ code: String) async throws -> Any? {
        try await tab.web.callAsyncJavaScript(code, contentWorld: .page)
    }

    private func site() throws -> SitePermissions.Scope {
        try XCTUnwrap(SitePermissions.Scope(url: try server.url("/"), profileID: profile))
    }

    func testSavedAllowIsReportedAtParseAndShowPostsUnderTheSite() async throws {
        SitePermissions.set(scope: try site(), type: .notifications, answer: true)
        let tab = try await load("""
            <script>window.early = Notification.permission;</script>
            <iframe src="/frame"></iframe>
            <script>window.frameSaw = new Promise(r => addEventListener('message', e => r(e.data)));</script>
            """)
        let early = try await evaluate(tab, "return early") as? String
        XCTAssertEqual(early, "granted")
        let frame = try await evaluate(tab, "return await frameSaw") as? String
        XCTAssertEqual(frame, "undefined", "embedded frames get no Notification")
        let shown = try await evaluate(tab, """
            return await new Promise(resolve => { const n = new Notification('Hello', {body: 'World'});
              n.onshow = () => resolve('show'); n.onerror = () => resolve('error'); });
            """) as? String
        XCTAssertEqual(shown, "show")
        XCTAssertEqual(posted.map(\.title), ["Hello"])
        XCTAssertEqual(posted.first?.body, "World")
        XCTAssertEqual(posted.first?.subtitle, try site().origin, "the site is always named")
        XCTAssertEqual((posted.first?.userInfo["document"] as? String)?.count, 36, "clicks name the document that showed it")
        let forged = try await evaluate(tab, """
            return await webkit.messageHandlers.\(WebNotifications.messageName).postMessage({op: 'show', id: 9, title: 'Forged', key: 'guess'})
              .then(() => 'accepted', () => 'refused');
            """) as? String
        XCTAssertEqual(forged, "refused", "the bridge needs the shim's key")
        XCTAssertEqual(posted.count, 1)
    }

    func testBlockedSiteIsDeniedWithoutAPrompt() async throws {
        SitePermissions.set(scope: try site(), type: .notifications, answer: false)
        let tab = try await load("<p>blocked</p>")
        let answer = try await evaluate(tab, "return await Notification.requestPermission()") as? String
        XCTAssertEqual(answer, "denied")
        XCTAssertNil(SitePermissions.activePrompt(in: try XCTUnwrap(window)))
        let query = try await evaluate(tab, "return (await navigator.permissions.query({name: 'notifications'})).state") as? String
        XCTAssertEqual(query, "denied")
    }

    func testUserGestureRequestPromptsAndAllowShows() async throws {
        let tab = try await load("<p>ask</p>")
        // WebKit evaluates native JavaScript as a user gesture.
        let request = Task { try await self.evaluate(tab, "return await Notification.requestPermission()") as? String }
        try await compatibilityWait { SitePermissions.activePrompt(in: self.window!) != nil }
        try XCTUnwrap(SitePermissions.activePrompt(in: try XCTUnwrap(window))).finish(.alertSecondButtonReturn)
        let answer = try await request.value
        XCTAssertEqual(answer, "granted")
        XCTAssertEqual(SitePermissions.effective(scope: try site(), type: .notifications), true)
    }
}
