import AppKit
import UserNotifications
import WebKit

/// Web notifications on a WebKit that has none: macOS WKWebView exposes no `Notification`
/// and no permission hook. A page-world shim gives the main frame of a secure http(s)
/// page `Notification`, and the Notifications site permission (`SitePermissions`) decides
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
          if ('Notification' in globalThis || !globalThis.isSecureContext || !/^https?:$/.test(location.protocol)) return;
          const handler = globalThis.webkit?.messageHandlers?.\#(messageName);
          if (!handler) return;
          const send = handler.postMessage.bind(handler), define = Object.defineProperty;
          // Nothing the page can patch later touches the key: a spread, not `Object.assign`.
          const ask = (op, fields = {}) => send({...fields, op, key});
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
              const fields = {title: String(title), body: String(o.body ?? ''), tag: String(o.tag ?? ''),
                icon: o.icon ? new URL(String(o.icon), location.href).href : '', silent: o.silent ?? null,
                dir: o.dir ?? 'auto', lang: String(o.lang ?? ''), badge: '', image: '', renotify: Boolean(o.renotify),
                requireInteraction: Boolean(o.requireInteraction), timestamp: Number(o.timestamp ?? Date.now()),
                actions: Object.freeze([]), data: o.data === undefined ? null : structuredClone(o.data)};
              for (const [name, value] of Object.entries(fields)) define(this, name, {value, enumerable: true});
              this.onclick = this.onshow = this.onclose = this.onerror = null;
              if (permission() !== 'granted') { setTimeout(() => fire(this, 'error')); return; }
              // A tag replaces its earlier notification, which then hears nothing more.
              if (fields.tag) for (const [other, shown] of live) if (shown.tag === fields.tag) live.delete(other);
              live.set(id, this);
              ask('show', {id, title: fields.title, body: fields.body, tag: fields.tag, icon: fields.icon, silent: fields.silent === true})
                .then(shown => shown === true, () => false)
                .then(shown => { if (!shown) live.delete(id); fire(this, shown ? 'show' : 'error'); });
            }
            close() {
              const id = this.#id;
              if (!live.delete(id)) return;
              ask('close', {id}).catch(() => {});
              fire(this, 'close');
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
              status.onchange = null;
            }
            return Promise.resolve(status);
          }});
          // Vane's way back in: a new answer, or what happened to a notification.
          define(globalThis, Symbol.for('vane.notifications'), {value: (kind, value, origin) => {
            if (kind === 'permission') { if (origin === location.origin) settle(value); return; }
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
    private static var generation = 0
    /// The answers generation each tab's scripts were built from.
    private static var built: [UUID: Int] = [:]
    /// Page id → notification identifier, per tab, for `close()` and tab closure.
    private static var shown: [UUID: [Int: String]] = [:]

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
        built[tab.id] = generation
        let key = UUID().uuidString
        controller.addUserScript(WKUserScript(source: stateScript(saved), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: shim(key: key), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addScriptMessageHandler(Bridge(tab: tab, key: key), contentWorld: .page, name: messageName)
    }

    /// A tab whose scripts predate an answer change gets the right answer at each commit.
    static func committed(_ tab: Tab) {
        if built[tab.id] != generation { push(tab) }
    }

    static func permissionChanged() {
        answers.removeAll()
        generation += 1
        for tab in TabStore.all.flatMap(\.everyTab) where tab.existingWeb != nil { push(tab) }
    }

    private static func push(_ tab: Tab) {
        guard let web = tab.existingWeb, let scope = SitePermissions.scope(for: tab) else { return }
        let answer = SitePermissions.effective(scope: scope, type: .notifications, tabID: tab.id)
        dispatch(web, "permission", state(answer) as NSString, origin: scope.origin)
    }

    private static func dispatch(_ web: WKWebView, _ kind: String, _ value: Any, origin: String = "") {
        web.callAsyncJavaScript("globalThis[Symbol.for('vane.notifications')]?.(kind, value, origin)",
                                arguments: ["kind": kind, "value": value, "origin": origin],
                                in: nil, in: .page, completionHandler: nil)
    }

    /// A closed tab's notifications go with it, and its clicks would have nowhere to land.
    static func drop(tabID: UUID) {
        built[tabID] = nil
        guard let identifiers = shown.removeValue(forKey: tabID)?.values, !identifiers.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
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
                    guard answer() == true, let id = (body["id"] as? NSNumber)?.intValue else { replyHandler(false, nil); return }
                    let content = UNMutableNotificationContent()
                    content.title = String((body["title"] as? String ?? "").prefix(256))
                    content.body = String((body["body"] as? String ?? "").prefix(2048))
                    // Always the site: a page must not pass for another app or site.
                    content.subtitle = scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
                    if body["silent"] as? Bool != true { content.sound = .default }
                    content.userInfo = ["tab": tab.id.uuidString, "page": id, "generation": Int(tab.permissionGeneration)]
                    let tag = body["tag"] as? String ?? ""
                    let identifier = tag.isEmpty ? "web." + UUID().uuidString
                        : "web.\(scope.profileID).\(scope.privateTabID?.uuidString ?? "").\(scope.origin).\(tag)"
                    shown[tab.id, default: [:]][id] = identifier
                    let tabID = tab.id
                    Task { @MainActor in
                        if let icon = (body["icon"] as? String).flatMap(URL.init(string:)),
                           let attachment = await Self.attachment(icon) { content.attachments = [attachment] }
                        // A tab closed while its icon loaded shows nothing.
                        guard WebNotifications.tab(tabID) != nil else { replyHandler(false, nil); return }
                        replyHandler(await WebNotifications.post(identifier, content), nil)
                    }
                case "close":
                    if let id = (body["id"] as? NSNumber)?.intValue, let identifier = shown[tab.id]?.removeValue(forKey: id) {
                        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
                    }
                    replyHandler(nil, nil)
                default:
                    replyHandler(nil, "Unknown notification request.")
                }
            }
        }

        /// Best effort: an http(s) or data image of up to 1 MB, fetched without cookies.
        private static func attachment(_ url: URL) async -> UNNotificationAttachment? {
            guard ["http", "https", "data"].contains(url.scheme?.lowercased()) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
                  data.count <= 1 << 20, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
                  let type = response.mimeType, type.hasPrefix("image/") else { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(String(type.dropFirst("image/".count).prefix(8)))
            guard (try? data.write(to: file)) != nil else { return nil }
            return try? UNNotificationAttachment(identifier: "icon", url: file)
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
        let page = info["page"] as? Int, generation = info["generation"] as? Int
        let owner = info["extension"] as? String, notificationID = info["id"] as? String
        await MainActor.run {
            if let owner, let notificationID {
                ExtensionNotifications.responded(owner: owner, id: notificationID, action: action)
                return
            }
            guard let tabID, let page else { return }
            Self.responded(tabID: tabID, page: page, generation: generation, identifier: identifier,
                           dismissed: action == UNNotificationDismissActionIdentifier)
        }
    }

    /// A click brings back the tab that showed it and tells the page, if it is still the same
    /// document; a dismissal only tells the page. A closed tab's notification is dropped.
    private static func responded(tabID: UUID, page: Int, generation: Int?, identifier: String, dismissed: Bool) {
        guard let tab = tab(tabID) else { return }
        if shown[tabID]?[page] == identifier { shown[tabID]?[page] = nil }
        let current = generation == Int(tab.permissionGeneration) ? tab.existingWeb : nil
        if !dismissed, let store = TabStore.all.first(where: { $0.everyTab.contains { $0 === tab } }),
           Windows.reveal(tab, in: store), let window = store.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if let current { dispatch(current, dismissed ? "close" : "click", page) }
    }
}

/// `chrome.notifications` for MV3 extensions, over the gaps bridge (`ExtensionChromiumGaps`).
/// Shown under the extension's name. Events reach the worker by long poll
/// (`notifications.next`), which runs only while the extension has notifications out.
// ponytail: events go to the background worker only, and a worker polling keeps WebKit
// from suspending it while its notifications are up. Chrome wakes the worker instead.
// ponytail: no images or templates beyond basic text; list items and progress become text.
@MainActor enum ExtensionNotifications {
    private struct Owner {
        var live: [String: [String: Any]] = [:]
        var events: [[String: Any]] = []
        var waiter: CheckedContinuation<Void, Never>?
    }
    private static var owners: [String: Owner] = [:]

    /// `owner` is the profile and the extension's unique identifier; `name` its display name.
    static func answer(_ operation: String, _ arguments: [String: Any], owner: String, name: String) async throws -> Any {
        let id = arguments["id"] as? String ?? ""
        switch operation {
        case "notifications.create", "notifications.update":
            let creating = operation.hasSuffix("create")
            if !creating && owners[owner]?.live[id] == nil { return false }
            let given = arguments["options"] as? [String: Any] ?? [:]
            let options = creating ? given : (owners[owner]?.live[id] ?? [:]).merging(given) { $1 }
            let notificationID = creating && id.isEmpty ? UUID().uuidString : id
            owners[owner, default: Owner()].live[notificationID] = options
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
            WebNotifications.center?.removeDeliveredNotifications(withIdentifiers: [identifier(owner, id)])
            return true
        case "notifications.getAll":
            return (owners[owner]?.live.keys).map { Dictionary(uniqueKeysWithValues: $0.map { ($0, true) }) } ?? [:]
        case "notifications.next":
            if owners[owner]?.events.isEmpty != false {
                guard owners[owner]?.live.isEmpty == false else { return ["events": [], "idle": true] }
                // One poller: a newer one (a restarted worker) releases the older.
                owners[owner]?.waiter?.resume()
                await withCheckedContinuation { continuation in
                    owners[owner]?.waiter = continuation
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(25))
                        wake(owner)
                    }
                }
            }
            let events = owners[owner]?.events ?? []
            owners[owner]?.events = []
            return ["events": events]
        default:
            throw ExtensionHost.Failure("Vane does not answer \(operation).")
        }
    }

    private static func identifier(_ owner: String, _ id: String) -> String { "ext.\(owner).\(id)" }

    private static func wake(_ owner: String) {
        owners[owner]?.waiter?.resume()
        owners[owner]?.waiter = nil
    }

    static func responded(owner: String, id: String, action: String) {
        guard owners[owner]?.live.removeValue(forKey: id) != nil else { return }
        let event: [String: Any] = switch action {
        case UNNotificationDismissActionIdentifier: ["type": "closed", "id": id, "byUser": true]
        case let button where button.hasPrefix("button."): ["type": "buttonClicked", "id": id, "index": Int(button.dropFirst(7)) ?? 0]
        default: ["type": "clicked", "id": id]
        }
        owners[owner]?.events.append(event)
        wake(owner)
    }

    /// An unloaded extension's notifications go with it.
    static func forget(owner: String) {
        guard let gone = owners.removeValue(forKey: owner) else { return }
        gone.waiter?.resume()
        WebNotifications.center?.removeDeliveredNotifications(withIdentifiers: gone.live.keys.map { identifier(owner, $0) })
    }
}
