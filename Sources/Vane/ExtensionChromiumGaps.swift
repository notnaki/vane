import WebKit

/// Chromium namespaces an MV3 extension has requested and system WebKit does not have.
/// Without them the extension's first `chrome.notifications.onClicked.addListener(…)`
/// throws and its whole background fails to load. Each stands in with its events, which
/// never fire, and its constants. Its methods stay undefined, so `chrome.downloads?.download`
/// still tells the extension the feature is missing. Vendor resources remain unchanged.
@MainActor enum ExtensionChromiumGaps {
    /// Permission names whose namespace WebKit omits entirely.
    nonisolated static let namespaces = ["debugger", "downloads", "identity", "notifications", "offscreen", "tabGroups"]

    nonisolated static let script = #"""
        ;(() => {
          const event = () => Object.freeze({addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false});
          const namespace = () => new Proxy({}, {get(target, key) {
            if (typeof key !== 'string') return undefined;
            if (key === 'TAB_GROUP_ID_NONE') return -1;
            // Enumerations such as tabGroups.Color: present, with no members.
            if (/^[A-Z]/.test(key)) return target[key] ??= Object.freeze({});
            if (/^on[A-Z]/.test(key)) return target[key] ??= event();
          }});
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
              Object.defineProperty(api, Symbol('Vane Chromium API owners'), {
                value: ['runtime', 'storage', 'tabs', 'declarativeNetRequest'].map(key => api[key]).filter(Boolean)
              });
              // Vane replaces accepted code at once; no update ever waits for a reload.
              define(api.runtime, 'onUpdateAvailable', event());
              define(api.runtime, 'OnInstalledReason', Object.freeze({INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update'}));
              define(api.runtime, 'ContextType', Object.freeze({TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS'}));
              // No administrator policy exists in Vane: managed storage is truthfully empty.
              if (declared.has('storage')) define(api.storage, 'managed', Object.freeze({
                get(keys, callback) {
                  if (typeof (callback ?? keys) === 'function') { queueMicrotask(() => (callback ?? keys)({})); return; }
                  return Promise.resolve({});
                },
                onChanged: event()
              }));
              const rules = api.declarativeNetRequest;
              define(rules, 'RuleActionType', Object.freeze({BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests'}));
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
