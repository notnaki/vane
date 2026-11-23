import WebKit

/// Chromium namespaces an MV3 extension has requested and system WebKit does not have.
/// Without them the extension's first `chrome.notifications.onClicked.addListener(…)`
/// throws and its whole background fails to load. Each stands in with its events, which
/// never fire, and its constants. Its methods stay undefined, so `chrome.downloads?.download`
/// still tells the extension the feature is missing. The exceptions answer truthfully
/// enough to be cheap: `management.getSelf` (from the manifest) and `idle.queryState`
/// (always active). Vendor resources remain unchanged.
@MainActor enum ExtensionChromiumGaps {
    /// Permission names whose namespace WebKit omits entirely.
    nonisolated static let namespaces = ["debugger", "downloads", "notifications", "offscreen", "tabGroups"]

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
              const owners = ['runtime', 'storage', 'tabs', 'declarativeNetRequest', 'webRequest', 'scripting', 'webNavigation']
                .map(key => api[key]).filter(Boolean);
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

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }
}
