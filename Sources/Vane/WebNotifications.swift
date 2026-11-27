import AppKit
import UserNotifications
import WebKit

/// Web notifications on a WebKit that cannot grant them: macOS WKWebView exposes a native
/// `Notification` but no public permission hook, so it stays at "default" forever. A
/// page-world shim replaces it in the main frame of a secure http(s) page, a frame script
/// removes it from embedded frames, and the Notifications site permission (`SitePermissions`) decides
/// what reaches `UNUserNotificationCenter`. Embedded frames get no `Notification` at all,
/// like Vane's camera and location policy: a frame cannot be tied to its original document.
///
/// The shim cannot ask synchronously, so `Notification.permission` at load comes from a
/// per-web-view script in an isolated world holding this profile's saved answers, which
/// the page cannot read; it hands the page its own origin's answer only. Changes reach
/// open pages by push. Each web view's shim carries a random key in its closure, so page
/// code cannot post to the bridge itself and skip the user-gesture check.
/// Service-worker `showNotification` and Push are absent: they need Apple push delivery.
@MainActor final class WebNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebNotifications()
    nonisolated static let messageName = "vaneNotifications"
    static let world = WKContentWorld.world(name: "vane-notifications")
    nonisolated static let attribute = "data-vane-notification-permission"

    /// The answer as the page names it.
    nonisolated static func state(_ answer: Bool?) -> String {
        answer.map { $0 ? "granted" : "denied" } ?? "default"
    }

    /// Isolated world, document start, main frame: this origin's saved answer onto the root
    /// element, where the shim reads it once and removes it. Most sites have none and get nothing.
    nonisolated static func stateScript(_ answers: [String: Bool]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: answers.mapValues(state), options: .sortedKeys))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "(() => { const a = \(json)[location.origin]; if (a) document.documentElement?.setAttribute('\(attribute)', a); })();"
    }

    nonisolated static func shim(key: String) -> String {
        #"""
        (() => {
          const key = '\#(key)';
          // WebKit's own `Notification` is replaced: without a private UI delegate it can never be granted.
          if (!globalThis.isSecureContext || !/^https?:$/.test(location.protocol)) return;
          const handler = globalThis.webkit?.messageHandlers?.\#(messageName);
          if (!handler) return;
          const send = handler.postMessage.bind(handler), define = Object.defineProperty;
          // Nothing the page can patch later touches the key: a spread, not `Object.assign`.
          const ask = (op, fields = {}) => send({...fields, op, key});
          // This document's own name: Vane hands it back with a click, so a later document in
          // the tab ignores what an earlier one showed. A back-forward restore keeps it.
          const doc = crypto.randomUUID();
          // Safari's rule: only a click or key press may prompt. Captured before the page runs.
          const activation = navigator.userActivation;
          const getter = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), 'isActive')?.get;
          const active = getter && Function.prototype.call.bind(getter);
          const gesture = () => active ? active(activation) === true : false;
          let state, status;
          const permission = () => {
            if (state === undefined) {
              const root = document.documentElement, saved = root?.getAttribute('\#(attribute)');
              root?.removeAttribute('\#(attribute)');
              state = saved === 'granted' || saved === 'denied' ? saved : 'default';
            }
            return state;
          };
          // The hand-off leaves the root element before the page's own scripts are done.
          document.addEventListener?.('DOMContentLoaded', () => permission(), {once: true});
          const fire = (target, type) => {
            const event = new Event(type);
            target.dispatchEvent(event);
            const listener = target['on' + type];
            if (typeof listener === 'function') try { listener.call(target, event); } catch (error) { queueMicrotask(() => { throw error; }); }
          };
          const settle = value => {
            if (permission() === value || !['granted', 'denied', 'default'].includes(value)) return;
            state = value;
            if (status) fire(status, 'change');
          };
          const live = new Map();
          let serial = 0;
          class Notification extends EventTarget {
            #id = ++serial;
            constructor(title, options = undefined) {
              super();
              if (!arguments.length) throw new TypeError("Failed to construct 'Notification': 1 argument required.");
              const o = options ?? {}, id = this.#id;
              // An icon that is not a URL is ignored, as the spec says.
              let icon = '';
              if (o.icon) try { icon = new URL(String(o.icon), location.href).href; } catch {}
              const fields = {title: String(title), body: String(o.body ?? ''), tag: String(o.tag ?? ''),
                icon, silent: o.silent ?? null,
                dir: o.dir ?? 'auto', lang: String(o.lang ?? ''), badge: '', image: '', renotify: Boolean(o.renotify),
                requireInteraction: Boolean(o.requireInteraction), timestamp: Number(o.timestamp ?? Date.now()),
                actions: Object.freeze([]), data: o.data === undefined ? null : structuredClone(o.data)};
              for (const [name, value] of Object.entries(fields)) define(this, name, {value, enumerable: true});
              this.onclick = this.onshow = this.onclose = this.onerror = null;
              if (permission() !== 'granted') { setTimeout(() => fire(this, 'error')); return; }
              // A tag replaces its earlier notification, which then hears nothing more.
              if (fields.tag) for (const [other, shown] of live) if (shown.tag === fields.tag) live.delete(other);
              live.set(id, this);
              ask('show', {id, document: doc, title: fields.title, body: fields.body, tag: fields.tag, icon: fields.icon, silent: fields.silent === true})
                .then(shown => shown === true, () => false)
                .then(shown => { if (!shown) live.delete(id); fire(this, shown ? 'show' : 'error'); });
            }
            close() {
              const id = this.#id;
              if (!live.delete(id)) return;
              ask('close', {id, document: doc}).catch(() => {});
              setTimeout(() => fire(this, 'close'));
            }
            static get permission() { return permission(); }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              const result = ask('request', {gesture: gesture()}).then(value => { settle(value); return permission(); }, () => permission());
              if (typeof callback === 'function') result.then(value => callback(value));
              return result;
            }
          }
          define(globalThis, 'Notification', {value: Notification, writable: true, configurable: true});
          const permissions = navigator.permissions, query = permissions?.query;
          if (typeof query === 'function') define(permissions, 'query', {configurable: true, writable: true, value: function (descriptor) {
            if (descriptor?.name !== 'notifications') return query.apply(this, arguments);
            if (!status) {
              status = new EventTarget();
              define(status, 'name', {value: 'notifications', enumerable: true});
              define(status, 'state', {get: () => ({granted: 'granted', denied: 'denied'})[permission()] ?? 'prompt', enumerable: true});
              define(status, 'onchange', {value: null, writable: true, enumerable: true});
              // Still a real EventTarget underneath; its own fields shadow the native getters.
              if (globalThis.PermissionStatus?.prototype) Object.setPrototypeOf(status, PermissionStatus.prototype);
            }
            return Promise.resolve(status);
          }});
          // Vane's way back in: a new answer, or what happened to a notification.
          define(globalThis, Symbol.for('vane.notifications'), {value: (kind, value, origin, from) => {
            if (kind === 'permission') { if (origin === location.origin) settle(value); return; }
            if (from !== doc) return;
            const shown = live.get(value);
            if (!shown) return;
            if (kind === 'close') live.delete(value);
            if (kind === 'click' || kind === 'close') fire(shown, kind);
          }});
        })();
        """#
    }

    // MARK: Tabs

    /// The saved answers each profile's next web view reports. Cleared on any change.
    private static var answers: [UUID: [String: Bool]] = [:]
    /// `key(document, id)` → notification identifier, per tab, for `close()` and tab closure.
    static var shown: [UUID: [String: String]] = [:]
    /// Tabs with an icon loading.
    private static var loadingIcon: Set<UUID> = []
    /// The newest show per identifier, so a tagged show that waited on its icon can't
    /// replace a newer one that posted first.
    private static var latest: [String: String] = [:]

    nonisolated static func key(_ document: String, _ id: Int) -> String { "\(document)\u{1F}\(id)" }

    /// A tag replaces the same site's notification with that tag, in this profile (or this
    /// private tab). `\u{1F}` cannot appear in an origin, so no two sites share one.
    /// Private tabs' carry `web.private.`, which goes at quit.
    nonisolated static func identifier(scope: SitePermissions.Scope, tag: String) -> String {
        let prefix = scope.privateTabID == nil ? "web." : "web.private."
        guard !tag.isEmpty else { return prefix + UUID().uuidString }
        return prefix + [scope.profileID.uuidString, scope.privateTabID?.uuidString ?? "", scope.origin, tag]
            .joined(separator: "\u{1F}")
    }

    /// From `Tab.attach`, on each fresh web view (and so each fresh content controller).
    static func attach(_ tab: Tab, _ web: WKWebView) {
        let controller = web.configuration.userContentController
        let saved: [String: Bool]
        if tab.isPrivate {
            saved = SitePermissions.notificationAnswers(profileID: tab.profileID, privateTabID: tab.id)
        } else {
            saved = answers[tab.profileID] ?? SitePermissions.notificationAnswers(profileID: tab.profileID, privateTabID: nil)
            answers[tab.profileID] = saved
        }
        let key = UUID().uuidString
        controller.addUserScript(WKUserScript(source: stateScript(saved), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: shim(key: key), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(Bridge(tab: tab, key: key), contentWorld: .page, name: messageName)
        controller.addUserScript(WKUserScript(source: frameScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
    }

    /// Embedded frames lose WebKit's native `Notification` (see the type comment).
    nonisolated static let frameScript = "if (window !== window.top) delete globalThis.Notification;"


    /// A tab's scripts may predate an answer change, so each commit gets the current answer.
    static func committed(_ tab: Tab) { push(tab) }

    /// A Notifications answer changed (or every answer was reset).
    static func permissionChanged() {
        answers.removeAll()
        for tab in TabStore.all.flatMap(\.everyTab) where tab.existingWeb != nil { push(tab) }
    }

    private static func push(_ tab: Tab) {
        guard let web = tab.existingWeb, let scope = SitePermissions.scope(for: tab) else { return }
        let answer = SitePermissions.effective(scope: scope, type: .notifications, tabID: tab.id)
        dispatch(web, "permission", state(answer) as NSString, origin: scope.origin)
    }

    private static func dispatch(_ web: WKWebView, _ kind: String, _ value: Any, origin: String = "", document: String = "") {
        web.callAsyncJavaScript("globalThis[Symbol.for('vane.notifications')]?.(kind, value, origin, document)",
                                arguments: ["kind": kind, "value": value, "origin": origin, "document": document],
                                in: nil, in: .page, completionHandler: nil)
    }

    /// A closed tab's notifications go with it, and its clicks would have nowhere to land.
    /// One another tab replaced by tag is that tab's now, and stays.
    static func drop(tabID: UUID) {
        guard let gone = shown.removeValue(forKey: tabID)?.values else { return }
        let kept = Set(shown.values.flatMap(\.values))
        let identifiers = Set(gone).subtracting(kept)
        if !identifiers.isEmpty { remove(Array(identifiers)) }
    }

    /// Private tabs' notifications must not outlive the app (`AppLifecycle`).
    static func terminating() {
        let identifiers = shown.values.flatMap(\.values).filter { $0.hasPrefix("web.private.") }
        guard !identifiers.isEmpty else { return }
        remove(identifiers)
        // The removal is asynchronous; a request queued behind it lets it land before exit.
        guard let center else { return }
        let done = DispatchSemaphore(value: 0)
        center.getDeliveredNotifications { _ in done.signal() }
        _ = done.wait(timeout: .now() + 0.3)
    }

    /// A crash skips `terminating`, and nothing from an earlier run can be clicked through, so
    /// launch clears every web and extension notification it left.
    static func clearAtLaunch() {
        guard let center else { return }
        let launched = Date()
        Task {
            // Only an earlier run's: this run's first ones may already be up.
            let stale = await center.deliveredNotifications().filter { $0.date < launched }.map(\.request.identifier)
                .filter { $0.hasPrefix("web.") || $0.hasPrefix("ext.") }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    private static func tab(_ id: UUID) -> Tab? {
        TabStore.all.lazy.flatMap(\.everyTab).first { $0.id == id && !$0.tornDown }
    }

    /// The page's messages. Every one is checked here: the shim's own checks are a courtesy.
    final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        private let key: String
        init(tab: Tab, key: String) { self.tab = tab; self.key = key }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated {
                guard let tab, let web = message.webView, tab.existingWeb === web, message.frameInfo.isMainFrame,
                      let body = message.body as? [String: Any], body["key"] as? String == key,
                      let scope = SitePermissions.scope(for: tab),
                      SitePermissions.Scope(scheme: message.frameInfo.securityOrigin.protocol,
                                            host: message.frameInfo.securityOrigin.host,
                                            port: message.frameInfo.securityOrigin.port, profileID: tab.profileID,
                                            privateTabID: scope.privateTabID) == scope
                else { replyHandler(nil, "Notifications are unavailable."); return }
                let answer = { SitePermissions.effective(scope: scope, type: .notifications, tabID: tab.id) }
                switch body["op"] as? String {
                case "request":
                    guard answer() == nil, body["gesture"] as? Bool == true else { replyHandler(state(answer()), nil); return }
                    SitePermissions.handle(origin: message.frameInfo.securityOrigin, frame: message.frameInfo,
                                           type: .notifications, tab: tab, web: web) { decision in
                        if decision == .grant { WebNotifications.authorize() }
                        replyHandler(decision == .grant ? "granted" : state(answer()), nil)
                    }
                case "show":
                    guard answer() == true, let id = (body["id"] as? NSNumber)?.intValue,
                          let document = body["document"] as? String else { replyHandler(false, nil); return }
                    let content = UNMutableNotificationContent()
                    content.title = String((body["title"] as? String ?? "").prefix(256))
                    content.body = String((body["body"] as? String ?? "").prefix(2048))
                    // Always the site: a page must not pass for another app or site.
                    content.subtitle = scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
                    if body["silent"] as? Bool != true { content.sound = .default }
                    content.userInfo = ["tab": tab.id.uuidString, "page": id, "document": document, "origin": scope.origin]
                    let identifier = WebNotifications.identifier(scope: scope, tag: body["tag"] as? String ?? "")
                    let key = WebNotifications.key(document, id), tabID = tab.id, generation = tab.permissionGeneration
                    // ponytail: evicts an arbitrary entry, not the oldest; it loses close(), and its
                    // notification is removed now unless another entry still shares its identifier.
                    if shown[tabID, default: [:]].count >= 100, let first = shown[tabID]?.keys.first,
                       let gone = shown[tabID]?.removeValue(forKey: first),
                       !shown.values.contains(where: { $0.values.contains(gone) }) {
                        remove([gone])
                    }
                    shown[tabID, default: [:]][key] = identifier
                    latest[identifier] = key
                    Task { @MainActor in
                        var file: URL?
                        // One icon load per tab at a time: a page showing many at once gets the rest without.
                        if let icon = (body["icon"] as? String).flatMap(URL.init(string:)), loadingIcon.insert(tabID).inserted {
                            file = await Self.iconFile(icon)
                            loadingIcon.remove(tabID)
                        }
                        defer { if let file { try? FileManager.default.removeItem(at: file) } }
                        if let attachment = file.flatMap({ try? UNNotificationAttachment(identifier: "icon", url: $0) }) {
                            content.attachments = [attachment]
                        }
                        // A newer show with the same tag already posted while this icon loaded.
                        if latest[identifier] != key { replyHandler(true, nil); return }
                        latest[identifier] = nil
                        // The tab closed, the page went, the answer changed or the entry was evicted
                        // (untracked, it could outlive the tab) while the icon loaded.
                        guard shown[tabID]?[key] == identifier, WebNotifications.tab(tabID) != nil, tab.existingWeb === web,
                              tab.permissionGeneration == generation, answer() == true,
                              await WebNotifications.post(identifier, content) else {
                            if shown[tabID]?[key] == identifier { shown[tabID]?[key] = nil }
                            replyHandler(false, nil)
                            return
                        }
                        replyHandler(true, nil)
                    }
                case "close":
                    if let id = (body["id"] as? NSNumber)?.intValue, let document = body["document"] as? String,
                       let identifier = shown[tab.id]?.removeValue(forKey: WebNotifications.key(document, id)) {
                        remove([identifier])
                    }
                    replyHandler(nil, nil)
                default:
                    replyHandler(nil, "Unknown notification request.")
                }
            }
        }

        private static let iconSession: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            return URLSession(configuration: configuration)
        }()

        /// Best effort: an http(s) or data image of up to 1 MB, fetched without cookies, into
        /// a temporary file the caller deletes. A bigger body is cut off as it streams.
        nonisolated static func iconFile(_ url: URL) async -> URL? {
            guard ["http", "https", "data"].contains(url.scheme?.lowercased()) else { return nil }
            let limit = 1 << 20
            guard let (bytes, response) = try? await iconSession.bytes(for: URLRequest(url: url)) else { return nil }
            defer { bytes.task.cancel() }
            guard response.expectedContentLength <= limit, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let type = response.mimeType, type.hasPrefix("image/") else { return nil }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > limit { return nil }
                }
            } catch { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(String(type.dropFirst("image/".count).prefix(8)))
            return (try? data.write(to: file)) != nil ? file : nil
        }
    }

    // MARK: Notification Center

    /// Nil outside a real app bundle (`swift run`, XCTest): Notification Center needs one.
    static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = shared }
        return center
    }

    /// Asks macOS once, the first time a site is allowed or something is shown.
    static func authorize() { Task { _ = await authorized() } }
    private static func authorized() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static var categories: Set<UNNotificationCategory> = []
    /// Every notification reports its dismissal; buttons, when an extension has them.
    static func category(buttons: [String] = []) -> String {
        let id = (["vane"] + buttons).joined(separator: "\u{1F}")
        if !categories.contains(where: { $0.identifier == id }) {
            let actions = buttons.prefix(2).enumerated().map {
                UNNotificationAction(identifier: "button.\($0.offset)", title: $0.element, options: [])
            }
            categories.insert(UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [],
                                                     options: .customDismissAction))
            center?.setNotificationCategories(categories)
        }
        return id
    }

    /// Replaceable in tests, which have no Notification Center.
    static var remove: @MainActor ([String]) -> Void = { center?.removeDeliveredNotifications(withIdentifiers: $0) }

    /// What `chrome.notifications.getPermissionLevel` reports: denied once macOS says no.
    static func permissionLevel() async -> String {
        guard let center else { return "denied" }
        return await center.notificationSettings().authorizationStatus == .denied ? "denied" : "granted"
    }

    /// Replaceable in tests, which have no Notification Center.
    static var post: @MainActor (String, UNMutableNotificationContent) async -> Bool = { identifier, content in
        guard let center, await authorized() else { return false }
        if content.categoryIdentifier.isEmpty { content.categoryIdentifier = category() }
        return (try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))) != nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier, action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let tabID = (info["tab"] as? String).flatMap(UUID.init(uuidString:))
        let page = info["page"] as? Int, document = info["document"] as? String, origin = info["origin"] as? String
        let owner = info["extension"] as? String, notificationID = info["id"] as? String
        await MainActor.run {
            if let owner, let notificationID {
                ExtensionNotifications.responded(owner: owner, id: notificationID, action: action)
                return
            }
            guard let tabID, let page else { return }
            Self.responded(tabID: tabID, page: page, document: document, origin: origin, identifier: identifier,
                           dismissed: action == UNNotificationDismissActionIdentifier)
        }
    }

    /// A click brings back the tab that showed it and tells the page, if it is still the same
    /// document; a dismissal only tells the page. A closed tab's notification is dropped.
    private static func responded(tabID: UUID, page: Int, document: String?, origin: String?, identifier: String,
                                  dismissed: Bool) {
        guard let tab = tab(tabID), let document, let origin else { return }
        let key = key(document, page)
        if shown[tabID]?[key] == identifier { shown[tabID]?[key] = nil }
        if !dismissed, let store = TabStore.all.first(where: { $0.everyTab.contains { $0 === tab } }),
           Windows.reveal(tab, in: store), let window = store.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        // Only into the same site: another site's page could hook `Symbol.for` and listen.
        // The shim ignores it unless `document` is the one still loaded.
        if let web = tab.existingWeb, SitePermissions.scope(for: tab)?.origin == origin {
            dispatch(web, dismissed ? "close" : "click", page, document: document)
        }
    }
}

/// `chrome.notifications` for MV3 extensions, over the gaps bridge (`ExtensionChromiumGaps`).
/// Shown under the extension's name. Events reach the worker by long poll
/// (`notifications.next`), held while the extension has notifications showing; one that
/// arrives with no poll waiting loads the background, whose listeners start polling.
// ponytail: a worker that is running but idle (its notifications came from its popup) is
// not woken: `loadBackgroundContent` does nothing to a loaded worker, so the event waits for
// its next poll (any listener added or notification it creates). Chrome dispatches directly.
// ponytail: no images or templates beyond basic text; list items and progress become text.
@MainActor enum ExtensionNotifications {
    private struct Owner {
        var live: [String: (options: [String: Any], shown: ContinuousClock.Instant)] = [:]
        var events: [[String: Any]] = []
        /// Handed to `poller`'s last poll; dropped when that worker polls again, or handed out
        /// again to another worker (one that started after WebKit unloaded the old mid-poll).
        var pending: [[String: Any]] = []
        var poller = ""
        /// Resumed with `true` when a newer poll takes over.
        var waiter: CheckedContinuation<Bool, Never>?
        var wake: @MainActor () -> Void = {}
    }
    private static var owners: [String: Owner] = [:]

    /// Notification Center's delivered identifiers; nil without one. Replaceable in tests.
    static var delivered: @MainActor () async -> Set<String>? = {
        guard let center = WebNotifications.center else { return nil }
        return Set(await center.deliveredNotifications().map(\.request.identifier))
    }
    /// How long a new notification counts as showing before Notification Center lists it.
    static var grace: Duration = .seconds(10)

    /// `owner` is the profile and the extension's unique identifier; `name` its display name;
    /// `wake` loads its background.
    static func answer(_ operation: String, _ arguments: [String: Any], owner: String, name: String,
                       wake: (@MainActor () -> Void)? = nil) async throws -> Any {
        let id = arguments["id"] as? String ?? ""
        if let wake { owners[owner, default: Owner()].wake = wake }
        switch operation {
        case "notifications.create", "notifications.update":
            let creating = operation.hasSuffix("create")
            if !creating && owners[owner]?.live[id] == nil { return false }
            let given = arguments["options"] as? [String: Any] ?? [:]
            let options = creating ? given : (owners[owner]?.live[id]?.options ?? [:]).merging(given) { $1 }
            let notificationID = creating && id.isEmpty ? UUID().uuidString : id
            owners[owner, default: Owner()].live[notificationID] = (options, .now)
            let content = UNMutableNotificationContent()
            content.title = String((options["title"] as? String ?? "").prefix(256))
            content.subtitle = name
            let items = (options["items"] as? [[String: Any]] ?? []).map { "\($0["title"] ?? ""): \($0["message"] ?? "")" }
            content.body = String(([options["message"] as? String ?? "", options["contextMessage"] as? String ?? ""] + items)
                .filter { !$0.isEmpty }.joined(separator: "\n").prefix(2048))
            if options["silent"] as? Bool != true { content.sound = .default }
            let buttons = (options["buttons"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            content.categoryIdentifier = WebNotifications.category(buttons: buttons)
            content.userInfo = ["extension": owner, "id": notificationID]
            guard await WebNotifications.post(identifier(owner, notificationID), content) else {
                owners[owner]?.live[notificationID] = nil
                throw ExtensionHost.Failure("Notifications are turned off for Vane in System Settings.")
            }
            return creating ? notificationID : true
        case "notifications.clear":
            guard owners[owner]?.live.removeValue(forKey: id) != nil else { return false }
            WebNotifications.remove([identifier(owner, id)])
            return true
        case "notifications.getAll":
            return (owners[owner]?.live.keys).map { Dictionary(uniqueKeysWithValues: $0.map { ($0, true) }) } ?? [:]
        case "notifications.getPermissionLevel":
            return await WebNotifications.permissionLevel()
        case "notifications.next":
            let worker = arguments["worker"] as? String ?? ""
            // One poller: a newer one (a restarted worker) releases the older, which stops.
            owners[owner]?.waiter?.resume(returning: true)
            owners[owner]?.waiter = nil
            if var state = owners[owner] {
                if state.poller != worker { state.events = state.pending + state.events }
                state.pending = []
                owners[owner] = state
            }
            // Before looking at events: a click during it removes from `live` and queues one.
            await reconcile(owner)
            if owners[owner]?.events.isEmpty != false {
                guard owners[owner]?.live.isEmpty == false else { return ["events": [], "idle": true] }
                owners[owner]?.waiter?.resume(returning: true)
                let superseded = await withCheckedContinuation { continuation in
                    owners[owner]?.waiter = continuation
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(25))
                        release(owner)
                    }
                }
                if superseded { return ["events": [], "idle": true] }
            }
            let events = owners[owner]?.events ?? []
            owners[owner]?.events = []
            owners[owner]?.pending = events
            owners[owner]?.poller = worker
            return ["events": events, "idle": false]
        default:
            throw ExtensionHost.Failure("Vane does not answer \(operation).")
        }
    }

    private static func identifier(_ owner: String, _ id: String) -> String { "ext.\(owner).\(id)" }

    private static func release(_ owner: String) {
        owners[owner]?.waiter?.resume(returning: false)
        owners[owner]?.waiter = nil
    }

    /// Ones cleared from Notification Center without a dismissal (Clear All) stop counting,
    /// so they do not keep the worker polling. With "Show in Notification Center" off for Vane,
    /// macOS may not list ones still on screen, so those stop counting after `grace` too.
    private static func reconcile(_ owner: String) async {
        guard let delivered = await delivered() else { return }
        let settled = ContinuousClock.now - grace
        for (id, entry) in owners[owner]?.live ?? [:] where entry.shown <= settled && !delivered.contains(identifier(owner, id)) {
            owners[owner]?.live[id] = nil
        }
    }

    static func responded(owner: String, id: String, action: String) {
        guard owners[owner]?.live.removeValue(forKey: id) != nil else { return }
        let event: [String: Any] = switch action {
        case UNNotificationDismissActionIdentifier: ["type": "closed", "id": id, "byUser": true]
        case let button where button.hasPrefix("button."): ["type": "buttonClicked", "id": id, "index": Int(button.dropFirst(7)) ?? 0]
        default: ["type": "clicked", "id": id]
        }
        owners[owner]?.events.append(event)
        // The held poll may belong to a worker WebKit has since unloaded: wake loads a fresh one,
        // whose first poll gets the event again (and does nothing to a running one).
        release(owner)
        owners[owner]?.wake()
    }

    /// An unloaded extension's notifications go with it.
    static func forget(owner: String) {
        guard let gone = owners.removeValue(forKey: owner) else { return }
        gone.waiter?.resume(returning: true)
        WebNotifications.remove(gone.live.keys.map { identifier(owner, $0) })
    }
}
