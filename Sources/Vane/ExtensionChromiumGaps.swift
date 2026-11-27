import os
import WebKit

/// Chromium namespaces an MV3 extension has requested and system WebKit does not have.
/// Without them the extension's first `chrome.notifications.onClicked.addListener(…)`
/// throws and its whole background fails to load. Each stands in with its events, which
/// never fire, and its constants. Its methods stay undefined, so `chrome.notifications?.create`
/// still tells the extension the feature is missing. `downloads` replaces its stand-in with
/// Vane's list (ExtensionDownloads.swift). The exceptions answer truthfully
/// enough to be cheap: `management.getSelf` (from the manifest), `idle.queryState`
/// (always active) and `action.getUserSettings`; and, from the host over `bridgePath`,
/// `runtime.getContexts`. `offscreen` stays absent: WebKit runs an extension page in its
/// worker's process, and suspends that process, worker included, once a hidden page has
/// loaded. A hidden offscreen document froze Claude's worker two seconds after start.
/// A worker's `WebSocket` is Vane's too (`ExtensionWebSockets`): WebKit's own never connects there.
/// So is a credentialed request to a site the extension may access (`ExtensionHost.credentialedFetch`).
/// Vendor resources remain unchanged.
@MainActor enum ExtensionChromiumGaps {
    /// Permission names whose namespace WebKit omits entirely.
    nonisolated static let namespaces = ["debugger", "downloads", "notifications", "tabGroups"]
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_gaps__"
    /// The answer travels back as `tabs.create`'s rejection, as for `identity`; the
    /// marker tells it from WebKit's own errors. JSON: `{value}` or `{error}`.
    nonisolated static let marker = "[vane-gaps] "

    private nonisolated static let runtimeConstants = """
        {OnInstalledReason: {INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update'}, \
        ContextType: {TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS'}}
        """

    /// Chrome 134+ has explicit resource management; JavaScriptCore on macOS 27.0 does not.
    /// TypeScript's `using` helper throws "Symbol.dispose is not defined." without these
    /// symbols (Bitwarden's popup stops after sign-in); it needs nothing else from them.
    // ponytail: the symbols only. Add `DisposableStack` if an extension calls it directly.
    nonisolated static let disposeSymbols = """
        for (const key of ['dispose', 'asyncDispose'])
          if (typeof Symbol[key] !== 'symbol') Object.defineProperty(Symbol, key, {value: Symbol('Symbol.' + key)});
        """

    /// Set ahead of the Chromium scripts in a Safari app extension's worker and pages, whose
    /// code expects Safari's APIs. Those scripts then add nothing; the WebKit repairs in
    /// `script` (worker sockets, credentialed requests) still apply.
    nonisolated static let safariFlag = "globalThis[Symbol.for('vane.safari.extension')] = true;"

    /// Pages share one user content controller, so the flag goes by the page's extension host.
    nonisolated static func safariPageFlag(hosts: Set<String>) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: hosts.sorted())).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "if (\(list).includes(location.host)) " + safariFlag
    }

    /// What a content script sees of the above: `chrome.runtime`'s constants, which
    /// Chrome exposes there too and scripts read at their top level. Run ahead of the
    /// extension's own content scripts by `ExtensionWorkerIdentity.prepare`.
    // ponytail: manifest content scripts of MV3 worker extensions only. Scripts registered
    // through `scripting.registerContentScripts` or `executeScript` go without; wrap those
    // calls if an extension needs the constants there.
    nonisolated static let contentScript = #"""
        ;(() => {
          \#(disposeSymbols)
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
          // A Safari app extension gets Safari's APIs: only the WebKit repairs below apply.
          const safari = globalThis[Symbol.for('vane.safari.extension')] === true;
          if (!safari) {
            \#(disposeSymbols)
          }
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
              if (!safari) for (const name of \#(namespaces)) if (declared.has(name)) define(api, name, namespace());
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
              // Claude's side panel frames claude.ai, whose frame-ancestors admits only Chrome's
              // extension origin, so WebKit blanks the frame and the panel waits on it for
              // ever. Tell the panel what the frame would have: its framed chat is unavailable.
              // Claude then shows its own built-in chat.
              if (!safari && globalThis.document && !globalThis.document.vaneClaudeFrame) {
                globalThis.document.vaneClaudeFrame = true;
                const origin = 'https://claude.ai';
                const watch = frame => {
                  if (!(frame instanceof HTMLIFrameElement) || !frame.src.startsWith(origin + '/cic/') || frame.vaneWatched) return;
                  frame.vaneWatched = true;
                  // A framed claude.ai says it is there by message; a blocked frame never speaks.
                  // Its blank stand-in is sandboxed and cross-origin either way, so silence is
                  // the only sign.
                  let heard = false;
                  globalThis.addEventListener('message', event => { if (event.origin === origin && event.isTrusted) heard = true; });
                  frame.addEventListener('load', () => setTimeout(() => {
                    if (!heard && frame.isConnected)
                      globalThis.dispatchEvent(new MessageEvent('message', {data: {type: 'cic_sidepanel_cowork_unavailable'}, origin}));
                  }, 3000), {once: true});
                };
                new MutationObserver(records => { for (const record of records) for (const node of record.addedNodes) {
                  watch(node); node.querySelectorAll?.('iframe').forEach(watch);
                } }).observe(globalThis.document, {childList: true, subtree: true});
              }
              // Chrome sends a site's cookies, SameSite ones included, with an extension's own
              // credentialed requests to a site it may access; WebKit treats them as
              // cross-site and sends none, so a signed-in user looks signed out. Vane makes
              // those requests with the profile's cookies; everything else stays WebKit's.
              const nativeFetch = typeof globalThis.fetch === 'function' && !globalThis.fetch.vane ? globalThis.fetch.bind(globalThis) : null;
              if (nativeFetch) {
                const encode = buffer => { const bytes = new Uint8Array(buffer); let text = ''; for (let at = 0; at < bytes.length; at += 0x8000) text += String.fromCharCode(...bytes.subarray(at, at + 0x8000)); return btoa(text); };
                const decode = text => Uint8Array.from(atob(text), character => character.charCodeAt(0));
                const fetch = async (input, init) => {
                  const request = new Request(input, init), target = new URL(request.url);
                  if (request.credentials !== 'include' || !/^https?:$/.test(target.protocol) || target.origin === globalThis.location?.origin) return nativeFetch(input, init);
                  request.signal.throwIfAborted();
                  const body = ['GET', 'HEAD'].includes(request.method) ? null : encode(await request.clone().arrayBuffer());
                  const aborted = new Promise((resolve, reject) => request.signal.addEventListener('abort', () => reject(request.signal.reason), {once: true}));
                  const reply = await Promise.race([ask('fetch', {url: request.url, method: request.method, headers: [...request.headers], body, ua: navigator.userAgent}), aborted]);
                  // Not a site the extension may access: WebKit's answer, as before.
                  if (reply === null) return nativeFetch(input, init);
                  const response = new Response([101, 103, 204, 205, 304].includes(reply.status) || request.method === 'HEAD' ? null : decode(reply.body),
                                                {status: reply.status, statusText: reply.statusText, headers: reply.headers});
                  Object.defineProperties(response, {url: {value: reply.url}, redirected: {value: reply.url !== request.url}});
                  return response;
                };
                fetch.vane = true;
                globalThis.fetch = fetch;
              }
              // WebKit runs an extension's service worker on its process's main thread, and
              // its worker WebSocket waits on that same thread to connect: `new WebSocket`
              // never returns and the worker stops for good. Vane holds the socket instead.
              if (typeof ServiceWorkerGlobalScope === 'function' && globalThis instanceof ServiceWorkerGlobalScope
                  && !globalThis.WebSocket?.vane) {
                const states = {CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3};
                // Binary frames cross the bridge as base64.
                const toBase64 = bytes => { let text = ''; for (let at = 0; at < bytes.length; at += 0x8000) text += String.fromCharCode(...bytes.subarray(at, at + 0x8000)); return btoa(text); };
                const fromBase64 = text => Uint8Array.from(atob(text), character => character.charCodeAt(0));
                class WebSocket extends EventTarget {
                  static vane = true;
                  #socket; #sending = Promise.resolve();
                  constructor(url, protocols = []) {
                    super();
                    const target = new URL(url, globalThis.location?.href);
                    if (target.protocol === 'http:' || target.protocol === 'https:') target.protocol = target.protocol === 'http:' ? 'ws:' : 'wss:';
                    if (!['ws:', 'wss:'].includes(target.protocol) || target.hash) throw new DOMException('Invalid WebSocket URL ' + url, 'SyntaxError');
                    Object.assign(this, {url: target.href, readyState: 0, protocol: '', extensions: '', bufferedAmount: 0, binaryType: 'blob',
                                         onopen: null, onmessage: null, onerror: null, onclose: null});
                    const fire = (type, fields = {}) => {
                      const event = type === 'message' ? new MessageEvent('message', {data: fields.data, origin: new URL(this.url).origin}) : Object.assign(new Event(type), fields);
                      this.dispatchEvent(event);
                      try { this['on' + type]?.call(this, event); } catch (error) { console.error(error); }
                    };
                    const closed = (code = 1006, reason = '', wasClean = false) => {
                      if (this.readyState === 3) return;
                      const failed = !wasClean && this.readyState !== 2;
                      this.readyState = 3;
                      if (failed) fire('error');
                      fire('close', {code, reason, wasClean});
                    };
                    ask('ws.open', {url: this.url, protocols: [protocols].flat().map(String), worker: (globalThis.__vaneWorker ??= crypto.randomUUID())}).then(async ({id, protocol}) => {
                      this.#socket = id;
                      if (this.readyState !== 0) { ask('ws.close', {id}).catch(() => {}); return closed(); }
                      Object.assign(this, {readyState: 1, protocol});
                      fire('open');
                      for (;;) {
                        const next = await ask('ws.next', {id});
                        if (!('data' in next) && !('binary' in next)) return closed(next.code, next.reason, next.clean);
                        if (this.readyState !== 1) continue;
                        if ('binary' in next) {
                          const bytes = fromBase64(next.binary);
                          fire('message', {data: this.binaryType === 'arraybuffer' ? bytes.buffer : new Blob([bytes])});
                        } else fire('message', {data: next.data});
                      }
                    }).catch(() => closed());
                  }
                  send(data) {
                    if (this.readyState === 0) throw new DOMException('WebSocket is still connecting.', 'InvalidStateError');
                    if (this.readyState !== 1) return;
                    const id = this.#socket;
                    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
                      : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
                    const blob = data instanceof Blob ? data : null;
                    const size = bytes?.byteLength ?? blob?.size ?? String(data).length;
                    // Copied now: the caller may reuse its buffer before the send goes out.
                    const frame = bytes ? Promise.resolve({binary: toBase64(bytes)})
                      : blob ? blob.arrayBuffer().then(buffer => ({binary: toBase64(new Uint8Array(buffer))})) : Promise.resolve({data: String(data)});
                    this.bufferedAmount += size;
                    this.#sending = this.#sending.then(() => frame).then(fields => ask('ws.send', {id, ...fields})).catch(() => {})
                      .finally(() => { this.bufferedAmount -= size; });
                  }
                  close(code, reason = '') {
                    if (this.readyState >= 2) return;
                    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) throw new DOMException('Invalid close code ' + code, 'InvalidAccessError');
                    this.readyState = 2;
                    const id = this.#socket;
                    if (id !== undefined) this.#sending.then(() => ask('ws.close', {id, code: code ?? 1000, reason: String(reason)})).catch(() => {});
                  }
                }
                for (const [key, value] of Object.entries(states)) { Object.defineProperty(WebSocket, key, {value}); Object.defineProperty(WebSocket.prototype, key, {value}); }
                Object.defineProperty(globalThis, 'WebSocket', {configurable: true, writable: true, value: WebSocket});
              }
              // Everything below is Chrome's API.
              if (safari) continue;
              \#(ExtensionDownloadsAPI.script)
              // Outside a tab WebKit answers getCurrent with null; Chrome with undefined, which
              // extensions test for (`getCurrent() === undefined` means a side panel or popup).
              if (typeof api.tabs?.getCurrent === 'function') {
                const getCurrent = api.tabs.getCurrent.bind(api.tabs);
                Object.defineProperty(api.tabs, 'getCurrent', {configurable: true, value: callback =>
                  answer(Promise.resolve(getCurrent()).then(tab => tab ?? undefined), callback)});
              }
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
              // window IDs are WebKit's to give, which the host cannot name: -1. Some WebKit
              // versions answer natively for the contexts they know; Vane adds the rest.
              const nativeContexts = typeof api.runtime.getContexts === 'function' ? api.runtime.getContexts.bind(api.runtime) : null;
              const contexts = async () => {
                const own = await ask('contexts');
                if (!nativeContexts) return own;
                const known = await nativeContexts({}).catch(() => []);
                const urls = new Set(known.map(context => context.documentUrl)), types = new Set(known.map(context => context.contextType));
                return [...known, ...own.filter(context => !urls.has(context.documentUrl) && !(context.contextType === 'BACKGROUND' && types.has('BACKGROUND')))];
              };
              Object.defineProperty(api.runtime, 'getContexts', {configurable: true, value: (filter, callback) => answer(contexts().then(list => list.filter(context =>
                ['contextTypes', 'contextIds', 'documentUrls', 'documentOrigins', 'tabIds', 'windowIds', 'frameIds'].every(key =>
                  !Array.isArray(filter?.[key]) || filter[key].includes(context[key.slice(0, -1)]))
                && (typeof filter?.incognito !== 'boolean' || filter.incognito === context.incognito))), callback)});
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
              // The rest of Chrome's shape, last so the answers above win: enums, constants and
              // events (which never fire) of each namespace the extension already has, WebKit's
              // or a stand-in. Code that reads them at its top level no longer stops there.
              // No namespace is invented: `chrome.offscreen` or `chrome.userScripts` existing is
              // how extensions choose what to call, and an empty one would mislead them.
              for (const [path, {enums = {}, constants: values = {}, events = []}] of Object.entries(\#(shape))) {
                const owner = path.split('.').reduce((parent, key) => parent?.[key], api);
                // A frozen stand-in (identity, tabGroups) is complete as it is.
                if (owner === undefined || owner === null || typeof owner !== 'object' && typeof owner !== 'function' || !Object.isExtensible(owner)) continue;
                owners.push(owner);
                for (const [key, value] of Object.entries(enums)) constants(owner, key, value);
                for (const [key, value] of Object.entries(values)) {
                  const current = owner[key];
                  // A stand-in answers any capitalised key with an empty enum; a constant replaces it.
                  if (current === undefined || typeof current === 'object' && current !== null && !Object.keys(current).length)
                    Object.defineProperty(owner, key, {configurable: true, value});
                }
                for (const key of events) define(owner, key, event());
              }
            } catch (error) { console.error(error); }
          }
        })();
        """#

    /// Websites an extension lists in `externally_connectable` message it as Chrome has
    /// them: `chrome.runtime.sendMessage(id, …)`. WebKit offers the same calls on every
    /// page as `browser` only, so sign-ins such as claude.ai's never reach the extension.
    /// Only matching pages get `chrome`; elsewhere `window.chrome` stays undefined.
    /// WebKit also answers a message to an extension that isn't installed with
    /// `undefined`, which claude.ai takes for success from Anthropic's internal build
    /// before ever trying the store one. Chrome fails it, and so does this `chrome`.
    // ponytail: patterns are read when a tab's web view is made; a tab open before an
    // install gets them from its next web view.
    nonisolated static func webPageScript(_ extensions: [(id: String, manifest: [String: Any])]) -> String? {
        let entries: [[Any]] = extensions.compactMap { id, manifest in
            let patterns = ((manifest["externally_connectable"] as? [String: Any])?["matches"] as? [String] ?? [])
                .compactMap(pageRegex).sorted()
            return patterns.isEmpty ? nil : [id, patterns]
        }
        guard !entries.isEmpty, let json = try? JSONSerialization.data(withJSONObject: entries, options: .sortedKeys) else { return nil }
        return """
            ;(() => {
              const native = globalThis.browser?.runtime;
              if (globalThis.chrome !== undefined || typeof native?.sendMessage !== 'function') return;
              const ids = \(String(decoding: json, as: UTF8.self))
                .filter(([, patterns]) => patterns.some(pattern => new RegExp(pattern).test(location.href))).map(([id]) => id);
              if (!ids.length) return;
              let lastError;
              const settle = (promise, callback) => {
                if (typeof callback !== 'function') return promise;
                promise.then(value => callback(value), error => {
                  lastError = {message: error?.message ?? String(error)};
                  try { callback(); } finally { lastError = undefined; }
                });
              };
              const runtime = Object.freeze({
                sendMessage(id, message, ...rest) {
                  const callback = typeof rest.at(-1) === 'function' ? rest.pop() : undefined;
                  return settle(ids.includes(id) ? native.sendMessage(id, message, ...rest)
                    : Promise.reject(new Error('Could not establish connection. Receiving end does not exist.')), callback);
                },
                connect: (...args) => native.connect(...args),
                get lastError() { return lastError; }
              });
              Object.defineProperty(globalThis, 'chrome', {configurable: true, writable: true, value: Object.freeze({runtime})});
            })();
            """
    }

    /// A match pattern (`https://*.claude.ai/*`) as a regular expression over a page URL.
    nonisolated static func pageRegex(_ pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<range.lowerBound], rest = pattern[range.upperBound...]
        guard ["*", "http", "https"].contains(scheme), let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]), path = String(rest[slash...])
        // Chrome refuses a wildcard for every host here; so does Vane, or every site would get `chrome`.
        // ponytail: a dot after `*.` refuses `*.com`; a public-suffix list would also refuse `*.co.uk`.
        guard !host.isEmpty, !host.dropFirst().contains("*"),
              !host.hasPrefix("*") || (host.hasPrefix("*.") && host.dropFirst(2).contains(".")) else { return nil }
        let escape = NSRegularExpression.escapedPattern(for:)
        let hostRegex = host.hasPrefix("*.") ? "([^/:]+\\.)?" + escape(String(host.dropFirst(2))) : escape(host)
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
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return nil }
            // `URLSearchParams` writes a space as `+`, which Foundation leaves alone.
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
            guard let operation = value("op") else { return nil }
            self.operation = operation
            arguments = value("args").flatMap {
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

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }
}

/// The sockets extension workers open through the gaps' `WebSocket`, one table per host.
@MainActor final class ExtensionWebSockets {
    private struct Socket { let owner: ObjectIdentifier; let task: URLSessionWebSocketTask }
    private let session = URLSession(configuration: .ephemeral)
    private var sockets: [Int: Socket] = [:]
    private var nextID = 0
    /// Each extension's running worker, by the id it made up when it started. A worker WebKit
    /// stopped leaves its sockets open and polled by no one; its successor's first open
    /// closes them, so the server does not keep talking to the dead one.
    // ponytail: a stopped worker's sockets stay until the next one opens a socket or the
    // extension unloads; close sockets nobody polls if one that never reconnects matters.
    private var workers: [ObjectIdentifier: String] = [:]
    private static let perExtension = 32

    /// `ws.open` → `{id, protocol}` once connected; `ws.next` → `{data}` (text), `{binary}`
    /// (base64) or, once, the close `{code, reason, clean}`; `ws.send` (`data` or `binary`)
    /// and `ws.close` → null.
    // ponytail: the extension's cookies stay behind; its own token travels in its messages.
    func answer(_ operation: String, _ arguments: [String: Any], origin: String, owner: ObjectIdentifier) async throws -> Any? {
        if operation == "ws.open" {
            guard let url = (arguments["url"] as? String).flatMap(URL.init(string:)), ["ws", "wss"].contains(url.scheme) else {
                throw ExtensionHost.Failure("Invalid WebSocket URL.")
            }
            let worker = arguments["worker"] as? String ?? ""
            if workers[owner] != worker {
                close(owner: owner)
                workers[owner] = worker
            }
            guard sockets.values.filter({ $0.owner == owner }).count < Self.perExtension else {
                throw ExtensionHost.Failure("Too many WebSockets are open.")
            }
            var request = URLRequest(url: url)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let protocols = arguments["protocols"] as? [String], !protocols.isEmpty {
                request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
            }
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 64 << 20
            nextID += 1
            let id = nextID
            sockets[id] = Socket(owner: owner, task: task)
            task.resume()
            // The first pong proves the handshake is done: the open event.
            do {
                // Foundation can call a ping's handler twice when the connection drops while
                // it waits (seen: a pong, then "Software caused connection abort"). Only the
                // first call counts.
                let once = OSAllocatedUnfairLock(initialState: false)
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        guard once.withLock({ called in defer { called = true }; return !called }) else { return }
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                }
            } catch { sockets[id] = nil; task.cancel(); throw error }
            let accepted = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? ""
            return ["id": id, "protocol": accepted]
        }
        guard let id = (arguments["id"] as? NSNumber)?.intValue, let socket = sockets[id], socket.owner == owner else {
            throw ExtensionHost.Failure("The WebSocket is closed.")
        }
        switch operation {
        case "ws.send":
            if let binary = arguments["binary"] as? String {
                guard let data = Data(base64Encoded: binary) else { throw ExtensionHost.Failure("Invalid WebSocket frame.") }
                try await socket.task.send(.data(data))
            } else {
                try await socket.task.send(.string(arguments["data"] as? String ?? ""))
            }
            return NSNull()
        case "ws.close":
            let code = URLSessionWebSocketTask.CloseCode(rawValue: (arguments["code"] as? NSNumber)?.intValue ?? 1000) ?? .normalClosure
            socket.task.cancel(with: code, reason: (arguments["reason"] as? String).map { Data($0.utf8) })
            // A `ws.next` in flight keeps its own copy and still reports the close.
            sockets[id] = nil
            return NSNull()
        case "ws.next":
            do {
                switch try await socket.task.receive() {
                case .string(let text): return ["data": text]
                case .data(let data): return ["binary": data.base64EncodedString()]
                @unknown default: return ["data": ""]
                }
            } catch {
                sockets[id] = nil
                let code = socket.task.closeCode
                return ["code": code == .invalid ? 1006 : code.rawValue, "clean": code != .invalid,
                        "reason": String(decoding: socket.task.closeReason ?? Data(), as: UTF8.self)]
            }
        default:
            return nil
        }
    }

    /// An unloaded extension's sockets close with it.
    func close(owner: ObjectIdentifier) {
        for (id, socket) in sockets where socket.owner == owner {
            socket.task.cancel(with: .goingAway, reason: nil)
            sockets[id] = nil
        }
        workers[owner] = nil
    }
}
