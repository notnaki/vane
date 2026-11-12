import WebKit

/// uBlock's Chromium adapter eagerly reads ChromeSetting methods before it can
/// handle an unsupported setting. Expose only explicit failures, never pretend
/// to change browser privacy preferences. Vendor resources remain unchanged.
@MainActor enum ExtensionMV2Compatibility {
    private static let idleWorlds = NSMapTable<WKUserContentController, NSMutableSet>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// A cooperative timer fallback, not an assertion that WebKit reported idle.
    static let idleScript = #"""
        (() => {
            if (typeof self.requestIdleCallback === 'function') return;
            const schedule = self.setTimeout.bind(self), cancel = self.clearTimeout.bind(self);
            const now = () => performance.now();
            Object.defineProperty(self, 'requestIdleCallback', {configurable:true, writable:true, value:(callback, options) => {
                if (typeof callback !== 'function') throw new TypeError('Idle callback must be a function');
                const queued = now(), supplied = Number(options?.timeout);
                const timeout = Number.isFinite(supplied) ? Math.max(0, supplied) : Infinity;
                return schedule(() => {
                    const start = now();
                    callback({didTimeout:start - queued >= timeout, timeRemaining:() => Math.max(0, 8 - (now() - start))});
                }, 0);
            }});
            Object.defineProperty(self, 'cancelIdleCallback', {configurable:true, writable:true, value:cancel});
        })();
        """#

    static let script = #"""
        (() => {
            const primary = self.chrome ?? self.browser;
            if (!primary?.runtime?.getManifest) return;
            const manifest = primary.runtime.getManifest();
            if (manifest.manifest_version !== 2 || manifest.name !== 'uBlock Origin') return;
            \#(idleScript)
            // WebKit weakly caches nested API wrappers. Keep the real wrappers
            // alive so their compatibility members survive module-loading GC.
            for (const api of new Set([self.chrome, self.browser])) {
                if (!api) continue;
                Object.defineProperty(api, Symbol('Vane MV2 API owners'), {
                    value:['runtime','webRequest','webNavigation','alarms'].map(key => api[key]).filter(Boolean)
                });
            }
            const runtimes = new Set();
            for (const api of new Set([self.chrome, self.browser])) {
                if (!api?.runtime || runtimes.has(api.runtime)) continue;
                runtimes.add(api.runtime);
                // Chromium permits borrowed runtime methods; WebKit requires its
                // native receiver. uBlock stores getURL on its own vAPI object.
                Object.defineProperty(api.runtime, 'getURL', {value:api.runtime.getURL.bind(api.runtime), configurable:true});
                // Vane reviews and replaces accepted contexts immediately. There
                // is no deferred Chrome update waiting for runtime.reload().
                if (api.runtime.onUpdateAvailable === undefined) {
                    const updateListeners = new Set();
                    Object.defineProperty(api.runtime, 'onUpdateAvailable', {configurable:true, value:Object.freeze({
                        addListener(fn) { if (typeof fn !== 'function') throw new TypeError('Listener must be a function'); updateListeners.add(fn); },
                        removeListener(fn) { updateListeners.delete(fn); },
                        hasListener(fn) { return updateListeners.has(fn); },
                        hasListeners() { return updateListeners.size > 0; }
                    })});
                }
            }
            for (const api of new Set([self.chrome, self.browser])) {
                // WebKit has no blocking-listener decision cache to invalidate.
                if (api.webRequest && api.webRequest.handlerBehaviorChanged === undefined)
                    Object.defineProperty(api.webRequest, 'handlerBehaviorChanged', {configurable:true, value:callback => {
                        if (typeof callback === 'function') { queueMicrotask(callback); return; }
                        return Promise.resolve();
                    }});
                // This WebKit accepts alarm creation as a promise but rejects
                // Chromium's legacy trailing callback. Use the real native write.
                if (typeof api.alarms?.create === 'function') {
                    const alarms = api.alarms, create = alarms.create.bind(alarms);
                    Object.defineProperty(alarms, 'create', {configurable:true, value:(...args) => {
                        const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
                        const result = create(...args);
                        if (!callback) return result;
                        Promise.resolve(result).then(() => callback(), error => { console.error(error); callback(); });
                    }});
                }
            }
            const listeners = new Set();
            let subscribed = false;
            const targetEvent = Object.freeze({
                addListener(listener) {
                    if (typeof listener !== 'function') throw new TypeError('Listener must be a function');
                    listeners.add(listener);
                    if (subscribed) return;
                    subscribed = true;
                    primary.tabs.onCreated.addListener(tab => {
                        if (!Number.isInteger(tab.openerTabId)) return;
                        const details = {sourceTabId:tab.openerTabId, tabId:tab.id, url:tab.pendingUrl ?? tab.url ?? '', timeStamp:Date.now()};
                        for (const callback of [...listeners]) {
                            try { callback(details); } catch (error) { console.error(error); }
                        }
                    });
                },
                removeListener(listener) { listeners.delete(listener); },
                hasListener(listener) { return listeners.has(listener); },
                hasListeners() { return listeners.size > 0; }
            });
            for (const api of new Set([self.chrome, self.browser])) {
                if (api?.webNavigation && api.webNavigation.onCreatedNavigationTarget === undefined)
                    Object.defineProperty(api.webNavigation, 'onCreatedNavigationTarget', {value:targetEvent, configurable:true});
            }
            const unavailable = () => { throw new Error('Vane does not support extension control of browser privacy settings'); };
            const setting = () => Object.freeze({get:unavailable, set:unavailable, clear:unavailable});
            for (const api of new Set([self.chrome, self.browser])) {
                if (!api || api.privacy !== undefined) continue;
                Object.defineProperty(api, 'privacy', {value:Object.freeze({
                    network:Object.freeze({networkPredictionEnabled:setting(), webRTCIPHandlingPolicy:setting()}),
                    websites:Object.freeze({hyperlinkAuditingEnabled:setting()})
                }), configurable:true});
            }
        })();
        """#

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }

    static func configureContentWorld(_ controller: WKUserContentController, context: WKWebExtensionContext) {
        let world = "WebExtension-" + context.uniqueIdentifier
        let configured = idleWorlds.object(forKey: controller) ?? NSMutableSet()
        guard !configured.contains(world) else { return }
        configured.add(world)
        idleWorlds.setObject(configured, forKey: controller)
        // WebKit names its extension content worlds by this installation ID.
        // The fallback reads no page data and exposes no extension permissions.
        controller.addUserScript(WKUserScript(source: idleScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: .world(name: world)))
    }
}
