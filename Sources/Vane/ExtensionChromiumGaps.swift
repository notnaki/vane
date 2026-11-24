import WebKit

/// Chromium namespaces an MV3 extension has requested and system WebKit does not have.
/// Without them the extension's first `chrome.notifications.onClicked.addListener(…)`
/// throws and its whole background fails to load. Each stands in with its events, which
/// never fire, and its constants. Its methods stay undefined, so `chrome.downloads?.download`
/// still tells the extension the feature is missing. The exceptions answer truthfully
/// enough to be cheap: `management.getSelf` (from the manifest), `idle.queryState`
/// (always active) and `action.getUserSettings`; and, from the host over `bridgePath`,
/// `runtime.getContexts`, `tabs.group`/`ungroup` with `tabGroups`, and `offscreen`.
/// Vendor resources remain unchanged.
@MainActor enum ExtensionChromiumGaps {
    /// Permission names whose namespace WebKit omits entirely.
    nonisolated static let namespaces = ["debugger", "downloads", "notifications", "offscreen", "tabGroups"]
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_gaps__"
    /// The answer travels back as `tabs.create`'s rejection, as for `identity`; the
    /// marker tells it from WebKit's own errors. JSON: `{value}` or `{error}`.
    nonisolated static let marker = "[vane-gaps] "

    private nonisolated static let runtimeConstants = """
        {OnInstalledReason: {INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update'}, \
        ContextType: {TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS'}}
        """

    /// What a content script sees of the above: `chrome.runtime`'s constants, which
    /// Chrome exposes there too and scripts read at their top level. Run ahead of the
    /// extension's own content scripts by `ExtensionWorkerIdentity.prepare`.
    // ponytail: manifest content scripts of MV3 worker extensions only. Scripts registered
    // through `scripting.registerContentScripts` or `executeScript` go without; wrap those
    // calls if an extension needs the constants there.
    nonisolated static let contentScript = #"""
        ;(() => {
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              const runtime = api?.runtime;
              if (!runtime) continue;
              // WebKit weakly caches nested API wrappers; keep this one and its additions.
              Object.defineProperty(api, Symbol('Vane Chromium API owners'), {value: runtime});
              for (const [key, value] of Object.entries(\#(runtimeConstants)))
                if (runtime[key] === undefined) Object.defineProperty(runtime, key, {configurable: true, value: Object.freeze(value)});
            } catch (error) { console.error(error); }
          }
        })();
        """#

    nonisolated static let script = #"""
        ;(() => {
          const event = () => Object.freeze({addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false});
          const namespace = () => new Proxy({}, {get(target, key) {
            if (typeof key !== 'string') return undefined;
            if (Object.hasOwn(target, key)) return target[key];
            if (key === 'TAB_GROUP_ID_NONE') return -1;
            // Enumerations such as tabGroups.Color: present, with no members.
            if (/^[A-Z]/.test(key)) return target[key] ??= Object.freeze({});
            if (/^on[A-Z]/.test(key)) return target[key] ??= event();
          }});
          const reply = (callback, value) => {
            if (typeof callback !== 'function') return Promise.resolve(value);
            queueMicrotask(() => callback(value));
          };
          const answer = (promise, callback) => {
            if (typeof callback !== 'function') return promise;
            promise.then(callback, error => { console.error(error); callback(); });
          };
          const constants = (owner, key, value) => {
            // Not `define`: the stand-in answers every capitalised key with an empty enum.
            if (owner && !Object.keys(owner[key] ?? {}).length) Object.defineProperty(owner, key, {configurable: true, value: Object.freeze(value)});
          };
          const localized = text => typeof text === 'string'
            ? text.replace(/^__MSG_(\w+)__$/, (match, key) => globalThis.chrome?.i18n?.getMessage(key) || match) : text;
          const targets = tabs => {
            const listeners = new Set();
            let subscribed = false;
            return Object.freeze({
              addListener(listener) {
                if (typeof listener !== 'function') throw new TypeError('Listener must be a function');
                if (!subscribed) tabs.onCreated.addListener(tab => {
                  if (!Number.isInteger(tab.openerTabId)) return;
                  const details = {sourceTabId: tab.openerTabId, sourceProcessId: -1, sourceFrameId: 0, tabId: tab.id, url: tab.pendingUrl || tab.url || 'about:blank', timeStamp: Date.now()};
                  for (const callback of [...listeners]) try { callback(details); } catch (error) { console.error(error); }
                });
                subscribed = true;
                listeners.add(listener);
              },
              removeListener(listener) { listeners.delete(listener); },
              hasListener: listener => listeners.has(listener),
              hasListeners: () => listeners.size > 0
            });
          };
          const define = (owner, key, value) => {
            if (owner && owner[key] === undefined) Object.defineProperty(owner, key, {configurable: true, value});
          };
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!api?.runtime?.getManifest) continue;
              const manifest = api.runtime.getManifest();
              if (manifest.manifest_version !== 3) continue;
              const declared = new Set(manifest.permissions ?? []);
              for (const name of \#(namespaces)) if (declared.has(name)) define(api, name, namespace());
              // WebKit weakly caches nested API wrappers. Keep the real ones alive so
              // the members added below survive garbage collection.
              const owners = ['runtime', 'storage', 'tabs', 'declarativeNetRequest', 'webRequest', 'scripting', 'webNavigation', 'alarms', 'action']
                .map(key => api[key]).filter(Boolean);
              const marker = '\#(marker)';
              const ask = (op, args = {}) => api.tabs.create({url: api.runtime.getURL('\#(bridgePath)?' + new URLSearchParams({op, args: JSON.stringify(args)})), active: false}).then(
                () => { throw new Error('Vane could not answer ' + op + '.'); },
                error => {
                  const message = String(error?.message ?? error), at = message.indexOf(marker);
                  if (at < 0) throw error;
                  const reply = JSON.parse(message.slice(at + marker.length, message.lastIndexOf('}') + 1));
                  if ('error' in reply) throw new Error(reply.error);
                  return reply.value;
                });
              // WebKit's alarms.create returns nothing; Chrome's returns a promise, which
              // extensions chain on (`create(…).catch(…)`). Keep the native write.
              if (typeof api.alarms?.create === 'function') {
                const create = api.alarms.create.bind(api.alarms);
                Object.defineProperty(api.alarms, 'create', {configurable: true, value: (...args) => {
                  const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
                  return answer(Promise.resolve(create(...args)), callback && (() => callback()));
                }});
              }
              // Vane lists every extension with an action in its toolbar menu.
              if (api.action) define(api.action, 'getUserSettings', callback => reply(callback, {isOnToolbar: true}));
              // Workers, side panels, offscreen documents, popups and extension tabs. Tab and
              // window IDs are WebKit's to give, which the host cannot name: -1.
              define(api.runtime, 'getContexts', (filter, callback) => answer(ask('contexts').then(list => list.filter(context =>
                ['contextTypes', 'contextIds', 'documentUrls', 'documentOrigins', 'tabIds', 'windowIds', 'frameIds'].every(key =>
                  !Array.isArray(filter?.[key]) || filter[key].includes(context[key.slice(0, -1)]))
                && (typeof filter?.incognito !== 'boolean' || filter.incognito === context.incognito))), callback));
              if (declared.has('offscreen')) {
                constants(api.offscreen, 'Reason', Object.fromEntries(['TESTING', 'AUDIO_PLAYBACK', 'IFRAME_SCRIPTING', 'DOM_SCRAPING', 'BLOBS', 'DOM_PARSER',
                  'USER_MEDIA', 'DISPLAY_MEDIA', 'WEB_RTC', 'CLIPBOARD', 'LOCAL_STORAGE', 'WORKERS', 'BATTERY_STATUS', 'MATCH_MEDIA', 'GEOLOCATION'].map(key => [key, key])));
                define(api.offscreen, 'createDocument', (parameters, callback) => answer((async () => {
                  const root = new URL(api.runtime.getURL('/')), url = new URL(String(parameters?.url ?? ''), root);
                  if (url.origin !== root.origin) throw new Error('Offscreen documents must be inside the extension.');
                  return ask('offscreenCreate', {url: url.pathname + url.search});
                })(), callback));
                define(api.offscreen, 'hasDocument', callback => answer(ask('offscreenHas'), callback));
                define(api.offscreen, 'closeDocument', callback => answer(ask('offscreenClose'), callback));
              }
              if (declared.has('tabGroups') && api.tabs?.get && api.tabs.query) {
                // Vane shows no tab groups. The host keeps the extension's own, by WebKit's tab
                // IDs, so its worker and pages agree; Vane's tab strip stays as it is.
                const tabs = api.tabs, groups = api.tabGroups, get = tabs.get.bind(tabs), query = tabs.query.bind(tabs);
                constants(groups, 'Color', Object.fromEntries(['grey', 'blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange'].map(c => [c.toUpperCase(), c])));
                const state = () => ask('groups');
                const grouped = (tab, members) => tab && typeof tab === 'object' ? {...tab, groupId: members[tab.id] ?? -1} : tab;
                // Native callbacks first, so a failure still reports through runtime.lastError.
                Object.defineProperty(tabs, 'get', {configurable: true, value: (id, callback) => {
                  if (typeof callback !== 'function') return get(id).then(tab => state().then(s => grouped(tab, s.members)));
                  get(id, tab => tab ? state().then(s => callback(grouped(tab, s.members)), () => callback(tab)) : callback(tab));
                }});
                Object.defineProperty(tabs, 'query', {configurable: true, value: (info, callback) => {
                  const {groupId, ...rest} = info ?? {};
                  const filtered = (list, members) => list.map(tab => grouped(tab, members)).filter(tab => groupId === undefined || tab.groupId === groupId);
                  if (typeof callback !== 'function') return query(rest).then(list => state().then(s => filtered(list, s.members)));
                  query(rest, list => list ? state().then(s => callback(filtered(list, s.members)), () => callback(list)) : callback(list));
                }});
                let watching = false;
                define(tabs, 'group', (options, callback) => answer((async () => {
                  const tabIds = [options?.tabIds].flat();
                  if (!tabIds.length || !tabIds.every(Number.isInteger)) throw new Error('No tab IDs given.');
                  const found = await Promise.all(tabIds.map(id => get(id)));
                  if (!watching) {
                    watching = true;
                    tabs.onRemoved.addListener(id => { ask('ungroup', {tabIds: [id]}).catch(() => {}); });
                  }
                  return ask('group', {tabIds, groupId: options?.groupId, windowId: options?.createProperties?.windowId ?? found[0].windowId});
                })(), callback));
                define(tabs, 'ungroup', (tabIds, callback) => answer(ask('ungroup', {tabIds: [tabIds].flat()}), callback));
                const find = (list, id) => list.find(group => group.id === id) ?? (() => { throw new Error('No group with id: ' + id + '.'); })();
                define(groups, 'get', (id, callback) => answer(state().then(s => find(s.groups, id)), callback));
                define(groups, 'query', (info, callback) => answer((async () => {
                  const s = await state();
                  let windowId = info?.windowId;
                  if (windowId === -2) windowId = (await api.windows.getCurrent()).id;
                  return s.groups.filter(group => (windowId === undefined || group.windowId === windowId)
                    && ['title', 'color', 'collapsed'].every(key => info?.[key] === undefined || group[key] === info[key]));
                })(), callback));
                define(groups, 'update', (id, properties, callback) => answer(ask('update', {groupId: id, title: properties?.title,
                  color: properties?.color, collapsed: properties?.collapsed}), callback));
                // ponytail: groups have no place in Vane's tab order; moving one changes nothing.
                define(groups, 'move', (id, properties, callback) => answer(state().then(s => find(s.groups, id)), callback));
              }
              Object.defineProperty(api, Symbol('Vane Chromium API owners'), {value: owners});
              // Vane replaces accepted code at once; no update ever waits for a reload.
              define(api.runtime, 'onUpdateAvailable', event());
              for (const [key, value] of Object.entries(\#(runtimeConstants))) define(api.runtime, key, Object.freeze(value));
              // No administrator policy exists in Vane: managed storage is truthfully empty.
              if (declared.has('storage')) define(api.storage, 'managed', Object.freeze({
                get(keys, callback) {
                  if (typeof (callback ?? keys) === 'function') { queueMicrotask(() => (callback ?? keys)({})); return; }
                  return Promise.resolve({});
                },
                onChanged: event()
              }));
              // Chrome answers getSelf without the `management` permission.
              define(api, 'management', namespace());
              define(api.management, 'getSelf', callback => reply(callback, {
                id: api.runtime.id, name: localized(manifest.name), shortName: localized(manifest.short_name ?? manifest.name),
                description: localized(manifest.description ?? ''), version: manifest.version, versionName: manifest.version_name,
                type: 'extension', installType: 'normal', enabled: true, mayDisable: true, isApp: false, offlineEnabled: false,
                homepageUrl: manifest.homepage_url ?? '', updateUrl: manifest.update_url,
                optionsUrl: manifest.options_ui?.page ?? manifest.options_page ? api.runtime.getURL(manifest.options_ui?.page ?? manifest.options_page) : '',
                permissions: (manifest.permissions ?? []).filter(name => !name.includes(':') && name !== '<all_urls>'),
                hostPermissions: manifest.host_permissions ?? [],
                icons: Object.entries(manifest.icons ?? {}).map(([size, path]) => ({size: Number(size), url: api.runtime.getURL(path)}))
              }));
              if (declared.has('idle')) {
                // ponytail: always active. The host's idle time is one bridge away if an
                // extension's behaviour ever depends on "idle" or "locked".
                define(api, 'idle', namespace());
                // Not `define`: the stand-in answers every capitalised key with an empty enum.
                if (!Object.keys(api.idle.IdleState ?? {}).length)
                  Object.defineProperty(api.idle, 'IdleState', {configurable: true, value: Object.freeze({ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked'})});
                define(api.idle, 'queryState', (threshold, callback) => reply(callback, 'active'));
                define(api.idle, 'setDetectionInterval', () => {});
              }
              define(api.scripting, 'ExecutionWorld', Object.freeze({ISOLATED: 'ISOLATED', MAIN: 'MAIN'}));
              // Only the types WebKit accepts in a listener filter: it refuses webtransport and webbundle.
              define(api.webRequest, 'ResourceType', Object.freeze({MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', OTHER: 'other'}));
              // A tab another tab opened. Source frame and process are unknown.
              if (api.webNavigation && api.tabs?.onCreated) define(api.webNavigation, 'onCreatedNavigationTarget', targets(api.tabs));
              // ponytail: never fire. Same-document navigations are invisible to WebKit's
              // extension API; derive them from tab URL changes if an extension needs them.
              for (const key of ['onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onTabReplaced'])
                if (api.webNavigation) define(api.webNavigation, key, event());
              // WebKit refuses a whole listener filter over one ws:// or wss:// pattern, which
              // Chrome accepts. Drop those patterns and keep the rest of the listener.
              for (const key of ['onBeforeRequest', 'onBeforeSendHeaders', 'onSendHeaders', 'onHeadersReceived', 'onAuthRequired',
                                 'onResponseStarted', 'onBeforeRedirect', 'onCompleted', 'onErrorOccurred']) {
                const target = api.webRequest?.[key];
                if (typeof target?.addListener !== 'function') continue;
                owners.push(target);
                const add = target.addListener.bind(target);
                Object.defineProperty(target, 'addListener', {configurable: true, value: (listener, filter, ...rest) => {
                  const urls = filter?.urls?.filter?.(url => !/^wss?:/i.test(url));
                  if (!urls || urls.length === filter.urls.length) return add(listener, filter, ...rest);
                  if (urls.length) return add(listener, {...filter, urls}, ...rest);
                }});
              }
              const rules = api.declarativeNetRequest;
              define(rules, 'RuleActionType', Object.freeze({BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests'}));
              // WebKit sets no static rule limit, only 50 enabled rulesets. Answer Chrome's
              // guaranteed minimum so an extension's budget check passes.
              // ponytail: constant, not net of enabled rules; WebKit would accept more anyway.
              define(rules, 'GUARANTEED_MINIMUM_STATIC_RULES', 30000);
              define(rules, 'getAvailableStaticRuleCount', callback => reply(callback, 30000));
              define(rules, 'HeaderOperation', Object.freeze({APPEND: 'append', SET: 'set', REMOVE: 'remove'}));
              define(rules, 'ResourceType', Object.freeze({MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other'}));
            } catch (error) { console.error(error); }
          }
        })();
        """#

    /// Websites an extension lists in `externally_connectable` message it as Chrome has
    /// them: `chrome.runtime.sendMessage(id, …)`. WebKit offers the same calls on every
    /// page as `browser` only, so sign-ins such as claude.ai's never reach the extension.
    /// Only matching pages get the alias; elsewhere `window.chrome` stays undefined.
    // ponytail: patterns are read when a tab's web view is made; a tab open before an
    // install gets them from its next web view.
    nonisolated static func webPageScript(_ manifests: [[String: Any]]) -> String? {
        let patterns = Set(manifests.flatMap { (($0["externally_connectable"] as? [String: Any])?["matches"] as? [String]) ?? [] })
            .compactMap(pageRegex).sorted()
        guard !patterns.isEmpty, let json = try? JSONSerialization.data(withJSONObject: patterns) else { return nil }
        return """
            ;(() => {
              if (globalThis.chrome !== undefined || typeof globalThis.browser?.runtime?.sendMessage !== 'function') return;
              if (!\(String(decoding: json, as: UTF8.self)).some(pattern => new RegExp(pattern).test(location.href))) return;
              Object.defineProperty(globalThis, 'chrome', {configurable: true, writable: true, value: globalThis.browser});
            })();
            """
    }

    /// A match pattern (`https://*.claude.ai/*`) as a regular expression over a page URL.
    nonisolated static func pageRegex(_ pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<range.lowerBound], rest = pattern[range.upperBound...]
        guard ["*", "http", "https"].contains(scheme), let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]), path = String(rest[slash...])
        guard !host.isEmpty, !host.dropFirst().contains("*"), host == "*" || !host.hasPrefix("*") || host.hasPrefix("*.") else { return nil }
        let escape = NSRegularExpression.escapedPattern(for:)
        let hostRegex = host == "*" ? "[^/:]+" : host.hasPrefix("*.") ? "([^/:]+\\.)?" + escape(String(host.dropFirst(2))) : escape(host)
        let pathRegex = path.split(separator: "*", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: ".*")
        return "^" + (scheme == "*" ? "https?" : String(scheme)) + "://" + hostRegex + "(:\\d+)?" + pathRegex + "$"
    }

    /// One question the stand-ins ask the host over `bridgePath`.
    struct Request {
        let operation: String
        let arguments: [String: Any]

        /// Only the owning extension's bridge URL is a request; anything else is a tab.
        nonisolated init?(_ url: URL?, base: URL) {
            guard let url, url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path == bridgePath,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let operation = items.first(where: { $0.name == "op" })?.value else { return nil }
            self.operation = operation
            arguments = items.first { $0.name == "args" }?.value.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            } ?? [:]
        }
    }

    /// The bridge's reply: `{value}`, or `{error}` for the stand-in to throw.
    nonisolated static func reply(_ result: Result<Any, any Error>) -> String {
        let object: [String: Any] = switch result {
        case .success(let value): ["value": value]
        case .failure(let error): ["error": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data(#"{"error":"Vane could not encode its answer."}"#.utf8)
        return marker + String(decoding: data, as: UTF8.self)
    }

    /// One extension's `tabGroups`, by the tab IDs WebKit gave it. Vane draws no groups.
    struct TabGroups {
        struct Group: Equatable {
            let id: Int
            var title = ""
            var color = "grey"
            var collapsed = false
            let windowId: Int
            var json: [String: Any] {
                ["id": id, "title": title, "color": color, "collapsed": collapsed, "windowId": windowId, "shared": false]
            }
        }

        nonisolated static let colors: Set<String> = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        private(set) var groups: [Int: Group] = [:]
        /// Tab ID to group ID.
        private(set) var members: [Int: Int] = [:]
        private var next = 1

        /// Chrome's `tabs.group`: into `id`, else a new group in `windowId`.
        mutating func group(_ tabs: [Int], into id: Int?, windowId: Int) throws -> Int {
            let target: Int
            if let id {
                guard groups[id] != nil else { throw ExtensionHost.Failure("No group with id: \(id).") }
                target = id
            } else {
                target = next
                next += 1
                groups[target] = Group(id: target, windowId: windowId)
            }
            for tab in tabs { members[tab] = target }
            prune()
            return target
        }

        mutating func ungroup(_ tabs: [Int]) {
            for tab in tabs { members[tab] = nil }
            prune()
        }

        mutating func update(_ id: Int, title: String?, color: String?, collapsed: Bool?) throws -> Group {
            guard var group = groups[id] else { throw ExtensionHost.Failure("No group with id: \(id).") }
            if let color {
                guard Self.colors.contains(color) else { throw ExtensionHost.Failure("Invalid color: \(color).") }
                group.color = color
            }
            if let title { group.title = title }
            if let collapsed { group.collapsed = collapsed }
            groups[id] = group
            return group
        }

        /// As in Chrome, a group lasts only while it holds a tab.
        private mutating func prune() {
            let used = Set(members.values)
            groups = groups.filter { used.contains($0.key) }
        }

        var json: [String: Any] {
            ["groups": groups.values.sorted { $0.id < $1.id }.map(\.json),
             "members": Dictionary(uniqueKeysWithValues: members.map { (String($0.key), $0.value) })]
        }
    }

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }
}
