import AppKit
import Foundation
import WebKit

/// A lease never creates a host or grants access. Its owner supplies the accepted
/// installation/context generation check; each native enqueue rechecks that lease.
@MainActor final class ICloudExtensionStorageLease {
    let namespace: ICloudExtensionNamespace
    let installationID: String
    let context: WKWebExtensionContext
    private let ownerCheck: @MainActor () throws -> Void
    private var revoked = false
    private var observers: [UUID: @MainActor () -> Void] = [:]
    init(namespace: ICloudExtensionNamespace, installationID: String, context: WKWebExtensionContext,
         check: @escaping @MainActor () throws -> Void) {
        self.namespace = namespace; self.installationID = installationID
        self.context = context; ownerCheck = check
    }
    func check() throws {
        try ICloudApplyContext.check()
        try namespace.validate()
        guard !revoked, context.isLoaded,
              context.hasPermission(WKWebExtension.Permission(rawValue: "storage")) else { throw CancellationError() }
        try ownerCheck()
    }
    var isRevoked: Bool { revoked }
    func observeRevocation(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback
        if revoked { callback() }
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func revoke() {
        guard !revoked else { return }
        revoked = true
        let callbacks = Array(observers.values); observers = [:]
        for callback in callbacks { callback() }
    }
}

/// The page contains only constant host HTML/JS and has no window. Public APIs
/// provide get/set/remove, not CAS: checks prevent new stale enqueues, while a
/// storage IPC already admitted to WebKit cannot be recalled. onChanged plus
/// fresh per-key reads preserve observed late edits and detect readback races.
@MainActor final class ICloudExtensionStorageBridge: ICloudExtensionStorageSession {
    private final class Navigation: NSObject, WKNavigationDelegate {
        var finished = false
        var error: (any Error)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { self.error = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { self.error = error }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            error = ICloudFailure.unavailable("The extension sync page stopped. Pending data has been retained.")
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(finished ? .cancel : .allow)
        }
    }
    private final class Reply { var result: Result<Any, any Error>? }
    private let lease: ICloudExtensionStorageLease
    private let timeout: Duration
    private let stateKey = "__vane_sync_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var page: WKWebView?
    private var navigation: Navigation?
    private var observer: UUID?
    private var closed = false
    private var enqueues = 0
    private let deadline: ContinuousClock.Instant

    init(lease: ICloudExtensionStorageLease, timeout: Duration = .seconds(5)) {
        self.lease = lease; self.timeout = timeout
        deadline = ContinuousClock.now + .seconds(30)
        observer = lease.observeRevocation { [weak self] in self?.close() }
    }
    func check() throws {
        guard !closed, ContinuousClock.now < deadline else {
            throw ICloudFailure.unavailable("The extension sync operation expired. Its pending data has been retained.")
        }
        try lease.check()
        if let error = navigation?.error { throw error }
    }
    func close() {
        guard !closed else { return }
        closed = true
        if let observer { lease.removeObserver(observer) }
        observer = nil
        lease.revoke()
        page?.stopLoading(); page?.navigationDelegate = nil; page?.uiDelegate = nil
        page?.removeFromSuperview(); page = nil; navigation = nil
    }
    private func wait(_ until: ContinuousClock.Instant, condition: () -> Bool) async throws {
        while true {
            try check()
            guard ContinuousClock.now < until else {
                throw ICloudFailure.unavailable("The extension did not finish its storage.sync request. Pending data has been retained.")
            }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func call(_ source: String, arguments: [String: Any] = [:]) async throws -> String {
        try check()
        guard let page, enqueues < 2048 else { throw ICloudFailure.limitExceeded }
        enqueues += 1
        let reply = Reply()
        var arguments = arguments
        arguments["stateKey"] = stateKey
        arguments["runtimeID"] = lease.context.uniqueIdentifier
        // No suspension occurs between this admission check and the native enqueue.
        try check()
        page.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { reply.result = $0 }
        try await wait(min(deadline, ContinuousClock.now + timeout)) { reply.result != nil }
        try check()
        let result = try reply.result!.get()
        guard let string = result as? String, string.utf8.count <= ICloudExtensionStorageJSON.namespaceBytes * 8 else {
            throw ICloudFailure.limitExceeded
        }
        return string
    }
    private func ready() async throws {
        try check()
        if page != nil { return }
        guard let configuration = lease.context.webViewConfiguration else { throw CancellationError() }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
        let nav = Navigation(); navigation = nav; page = view
        view.isHidden = true; view.navigationDelegate = nav
        let url = lease.context.baseURL.appendingPathComponent("__vane_sync_" + UUID().uuidString + ".html")
        try check()
        guard view.loadHTMLString("<!doctype html><title>Vane extension sync</title>", baseURL: url) != nil else {
            throw ICloudFailure.unavailable("The extension sync page could not be created.")
        }
        try await wait(min(deadline, ContinuousClock.now + timeout)) { nav.finished && !view.isLoading && view.title == "Vane extension sync" }
        let result = try await call("""
            if (document.readyState !== 'complete' || typeof browser !== 'object' ||
                browser.runtime.id !== runtimeID || !browser.storage?.sync) throw new Error('Extension sync origin is unavailable');
            // JSC's native dictionary conversion assigns keys, invoking the legacy
            // __proto__ setter and dropping primitives or altering nested prototypes.
            // In this constant, unshown page's realm only, receive that assignment
            // as an own data property. Keep the getter and prototype chains intact.
            // Vendor pages/workers have separate realms; none of their globals change.
            const nativeObject = Object;
            const legacy = nativeObject.getOwnPropertyDescriptor(nativeObject.prototype,'__proto__');
            if (legacy?.get && legacy.configurable) {
                nativeObject.defineProperty(nativeObject.prototype,'__proto__',{
                    ...legacy,set(value) {
                        nativeObject.defineProperty(this,'__proto__',{
                            value,writable:true,enumerable:true,configurable:true
                        });
                    }
                });
            }
            const state = {sequence:0, events:[], overflow:false};
            const limit = (value, fallback) => Number.isFinite(value) && value > 0 ? Math.min(value, fallback) : fallback;
            state.itemLimit = limit(browser.storage.sync.QUOTA_BYTES_PER_ITEM, 8192);
            state.byteLimit = limit(browser.storage.sync.QUOTA_BYTES, 102400);
            state.keyLimit = limit(browser.storage.sync.MAX_ITEMS, 512);
            state.listener = (changes, area) => {
                if (area !== 'sync') return;
                for (const key of Object.keys(changes)) {
                    state.sequence++;
                    if (state.events.length >= 1024) { state.overflow = true; break; }
                    state.events.push({sequence:state.sequence,key});
                }
            };
            browser.storage.onChanged.addListener(state.listener);
            Object.defineProperty(globalThis, stateKey, {value:state});
            return JSON.stringify({runtimeID:browser.runtime.id});
            """)
        guard try JSONDecoder().decode([String: String].self, from: Data(result.utf8))["runtimeID"] == lease.context.uniqueIdentifier else {
            throw CancellationError()
        }
        try check()
    }
    private static let readScript = """
        const state = globalThis[stateKey];
        if (!state || browser.runtime.id !== runtimeID) throw new Error('Extension sync lease lost');
        const values = await browser.storage.sync.get(null);
        const keys = Object.keys(values), utf8 = new TextEncoder();
        if (keys.length > state.keyLimit) throw new Error('Extension sync key quota exceeded');
        let bytes = 0;
        for (const key of keys) {
            const count = utf8.encode(key).length + utf8.encode(JSON.stringify(values[key])).length;
            if (count > state.itemLimit) throw new Error('Extension sync item quota exceeded');
            bytes += count;
        }
        if (bytes > state.byteLimit) throw new Error('Extension sync namespace quota exceeded');
        return JSON.stringify(values);
        """
    func read() async throws -> [String: Data] {
        do {
            try await ready()
            let string = try await call(Self.readScript)
            let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
            guard let values = object as? [String: Any] else { throw ICloudFailure.invalid("Invalid extension storage.sync reply.") }
            let data = try values.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
            return try ICloudExtensionStorageJSON.snapshot(data)
        } catch { close(); throw error }
    }
    func apply(_ mutations: [ICloudExtensionStorageMutation]) async throws -> [String: Data] {
        do {
            guard mutations.count <= ICloudExtensionStorageJSON.keyCount else { throw ICloudFailure.limitExceeded }
            try await ready()
            for mutation in mutations {
                try check()
                let desired = try mutation.value.map { try ICloudExtensionStorageJSON.value($0, key: mutation.key) }
                let freshString = try await call("""
                    const state = globalThis[stateKey];
                    if (!state || browser.runtime.id !== runtimeID || state.overflow) throw new Error('Extension sync changed too quickly; retry');
                    const before = state.sequence;
                    const values = await browser.storage.sync.get([key]);
                    return JSON.stringify({present:Object.hasOwn(values,key),value:values[key] ?? null,sequence:before});
                    """, arguments: ["key": mutation.key])
                try check()
                guard let fresh = try JSONSerialization.jsonObject(with: Data(freshString.utf8)) as? [String: Any],
                      let present = fresh["present"] as? Bool, let sequence = fresh["sequence"] as? NSNumber else {
                    throw ICloudFailure.invalid("Invalid extension sync expected-value reply.")
                }
                let current = present ? try JSONSerialization.data(withJSONObject: fresh["value"] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys]) : nil
                if let desired {
                    if current == desired { continue }
                    switch mutation.expected {
                    case .unknown: break
                    case .absent: if current != nil { continue }
                    case .value(let expected): if current != expected { continue }
                    }
                }
                try check()
                _ = try await call("""
                    const state = globalThis[stateKey];
                    if (!state || browser.runtime.id !== runtimeID || state.overflow) throw new Error('Extension sync lease lost');
                    if (!deleting && state.events.some(event => event.sequence > expectedSequence && event.key === key))
                        return JSON.stringify({changed:true});
                    // No await between the last in-page change check and submission.
                    let operation;
                    if (deleting) operation = browser.storage.sync.remove([key]);
                    else {
                        // Never invoke Object.prototype's legacy key setter.
                        const values = {};
                        Object.defineProperty(values,key,{value:JSON.parse(valueJSON),enumerable:true});
                        try { operation = browser.storage.sync.set(values); }
                        catch (error) {
                            if (key !== '__proto__' || !String(error).includes('an object is expected')) throw error;
                            // Older public WebKit bindings compare values.__proto__
                            // to globalThis.Object.prototype, rather than checking
                            // the actual prototype. Scope that comparison to this
                            // one synchronous public call in our constant host page.
                            // This binding is restored before awaiting the operation;
                            // prototype chains and vendor realms do not change.
                            const nativeObject = Object;
                            const descriptor = nativeObject.getOwnPropertyDescriptor(globalThis,'Object');
                            if (!descriptor || descriptor.value !== nativeObject || !descriptor.configurable) throw error;
                            try {
                                nativeObject.defineProperty(globalThis,'Object',{
                                    ...descriptor,value:{prototype:nativeObject.getOwnPropertyDescriptor(values,key).value}
                                });
                                operation = browser.storage.sync.set(values);
                            } finally { nativeObject.defineProperty(globalThis,'Object',descriptor); }
                        }
                    }
                    await operation;
                    return JSON.stringify({applied:true});
                    """, arguments: ["key": mutation.key, "deleting": desired == nil,
                        "valueJSON": desired.map { String(decoding: $0, as: UTF8.self) } ?? "null", "expectedSequence": sequence])
                try check()
            }
            // Detect post-submission edits using native readback. The caller records
            // these genuine local values rather than pretending all remote values won.
            return try await read()
        } catch { close(); throw error }
    }
}
