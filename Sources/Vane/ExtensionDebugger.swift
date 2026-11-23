import AppKit
import JavaScriptCore
import SwiftUI
import WebKit

/// `chrome.debugger` for system WebKit, which has no such API: the part of the Chrome
/// DevTools Protocol that page-driving extensions use, answered by the host with public
/// WebKit calls. Also `runtime.getContexts`. Vendor resources remain unchanged.
@MainActor enum ExtensionDebuggerAPI {
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_bridge__"
    nonisolated static let permission = "debugger"

    // A request is a `tabs.create` for a reserved URL in the extension's own origin, as
    // for the side panel. The answer comes back as the "tab" that call resolves to, whose
    // title is JSON; a failure is the call's own error, so `runtime.lastError` is set by
    // WebKit for Chrome's callback style. Events are fetched with a call the host holds
    // open until there is something to deliver.
    // ponytail: a context fetches events only while it has listeners and has seen the
    // host report an attached tab since. A context that never attached itself hears
    // nothing of another context's session until it sends a command or adds a listener.
    nonisolated static let script = #"""
        ;(() => {
          const listeners = {event: new Set(), detach: new Set()};
          let port = null, polling = false, cursor;
          const event = set => Object.freeze({
            addListener(listener) { if (typeof listener === 'function') { set.add(listener); poll(); } },
            removeListener(listener) { set.delete(listener); },
            hasListener: listener => set.has(listener),
            hasListeners: () => set.size > 0
          });
          const request = (op, tabId, values) => {
            const properties = {url: port.runtime.getURL('/__vane_bridge__?' + new URLSearchParams({op, ...values})), active: false};
            if (Number.isInteger(tabId)) properties.openerTabId = tabId;
            return properties;
          };
          const answer = tab => JSON.parse(tab.title).result;
          const call = (op, tabId, values, callback, shape = result => result) => {
            if (typeof callback === 'function') {
              // On failure WebKit calls back with `runtime.lastError` set; the caller's
              // callback runs inside, where it can still read it.
              port.tabs.create(request(op, tabId, values), tab => tab === undefined ? callback() : callback(shape(answer(tab))));
              return;
            }
            return port.tabs.create(request(op, tabId, values)).then(tab => shape(answer(tab)), error => {
              // WebKit wraps the host's message in its own sentence.
              throw new Error(String(error?.message ?? error).replace(/^Invalid call to tabs\.create\(\)\. /, '').replace(/\}\.$/, '}'));
            });
          };
          const poll = async () => {
            if (polling || !port || !(listeners.event.size + listeners.detach.size)) return;
            polling = true;
            try {
              for (;;) {
                const reply = await call('events', undefined, cursor === undefined ? {} : {after: String(cursor)});
                cursor = reply.cursor;
                for (const item of reply.events) {
                  const source = {tabId: item.tabId};
                  for (const listener of [...(item.reason ? listeners.detach : listeners.event)]) {
                    try { item.reason ? listener(source, item.reason) : listener(source, item.method, item.params); }
                    catch (error) { console.error(error); }
                  }
                }
                if (reply.idle || !(listeners.event.size + listeners.detach.size)) break;
              }
            } catch (error) {} finally { polling = false; }
          };
          const tabOf = target => Number.isInteger(target?.tabId) ? target.tabId
            : /^vane-tab-\d+$/.test(target?.targetId ?? '') ? Number(target.targetId.slice(9)) : NaN;
          const api = Object.freeze({
            attach(target, version, callback) {
              const tabId = tabOf(target);
              return call('attach', tabId, {tabId: String(tabId)}, callback, result => { cursor ??= result.cursor; poll(); });
            },
            detach(target, callback) {
              const tabId = tabOf(target);
              return call('detach', tabId, {tabId: String(tabId)}, callback, () => {});
            },
            sendCommand(target, method, params, callback) {
              if (typeof params === 'function') [params, callback] = [undefined, params];
              const tabId = tabOf(target);
              poll();
              return call('sendCommand', tabId, {tabId: String(tabId), method: String(method), params: JSON.stringify(params ?? {})}, callback);
            },
            getTargets(callback) {
              const targets = Promise.all([port.tabs.query({}), call('targets')]).then(([tabs, attached]) => tabs.map(tab => ({
                id: 'vane-tab-' + tab.id, type: 'page', tabId: tab.id, title: tab.title ?? '', url: tab.url ?? '',
                attached: attached.includes(tab.id), ...(tab.favIconUrl ? {faviconUrl: tab.favIconUrl} : {})
              })));
              if (typeof callback !== 'function') return targets;
              targets.then(callback, error => { console.error(error); callback([]); });
            },
            onEvent: event(listeners.event),
            onDetach: event(listeners.detach)
          });
          const plural = {contextTypes: 'contextType', contextIds: 'contextId', documentIds: 'documentId', documentOrigins: 'documentOrigin',
                          documentUrls: 'documentUrl', frameIds: 'frameId', tabIds: 'tabId', windowIds: 'windowId'};
          const getContexts = (filter, callback) => call('contexts', undefined, {}, callback, contexts => contexts.filter(context =>
            Object.entries(filter ?? {}).every(([key, wanted]) => key === 'incognito' ? context.incognito === wanted
              : !plural[key] || !Array.isArray(wanted) || wanted.includes(context[plural[key]]))));
          for (const candidate of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!candidate?.tabs?.create || !candidate.runtime?.getManifest) continue;
              port ??= candidate;
              const runtime = candidate.runtime, manifest = runtime.getManifest();
              // WebKit weakly caches nested API wrappers; keep this one and its addition.
              Object.defineProperty(candidate, Symbol('Vane bridge owners'), {value: runtime});
              if (manifest.manifest_version === 3 && runtime.getContexts === undefined)
                Object.defineProperty(runtime, 'getContexts', {configurable: true, value: getContexts});
              if (candidate.debugger === undefined && manifest.permissions?.includes('debugger'))
                Object.defineProperty(candidate, 'debugger', {configurable: true, value: api});
            } catch (error) { console.error(error); }
          }
        })();
        """#

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }

    /// Required, not optional: the install review is where the user accepts it.
    nonisolated static func declared(_ manifest: [String: Any]) -> Bool {
        (manifest["permissions"] as? [String])?.contains(permission) == true
    }

    struct Request {
        let operation: String
        let values: [String: String]

        /// Only the owning extension's bridge URL is a request; anything else is a tab.
        nonisolated init?(_ url: URL?, base: URL) {
            guard let url, url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path == bridgePath,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return nil }
            // `URLSearchParams` writes a space as `+`, which Foundation leaves alone.
            var values: [String: String] = [:]
            for item in items {
                values[item.name] = (item.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            guard let operation = values["op"] else { return nil }
            self.operation = operation
            self.values = values
        }
    }

    /// A protocol failure in Chrome's shape: `lastError.message` is this JSON.
    nonisolated static func failure(_ code: Int, _ message: String) -> ExtensionHost.Failure {
        let data = try? JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [.sortedKeys])
        return ExtensionHost.Failure(data.map { String(decoding: $0, as: UTF8.self) } ?? message)
    }

    // MARK: Runtime.evaluate

    // Chrome evaluates with REPL semantics: top-level `await`, and the value of the last
    // expression. WebKit offers an async function body, where `await` works and only
    // `return` yields a value, so the last expression statement is rewritten to return.
    // No `eval`: a page's Content Security Policy would refuse it.
    // ponytail: a tokenizer, not a parser. It finds statement ends by `;`, by a block's
    // closing brace and by line breaks that end a statement; what it misreads fails to
    // compile and runs unchanged (no value). `var` and function declarations stay local
    // to the call. A real parser is the upgrade if either matters.
    private nonisolated static let rewriter = #"""
        (source, box) => {
          const n = source.length;
          const beforeRegex = /^(?:return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await)$/;
          const word = /[\w$\u0080-￿]+/y;
          // One token at i: [end, kind, text]. s literal, n line break, c blank, w word, p punctuation.
          const read = (i, prev) => {
            const c = source[i];
            if (c === '\n') return [i + 1, 'n'];
            if (/\s/.test(c)) return [i + 1, 'c'];
            if (source.startsWith('//', i)) { const e = source.indexOf('\n', i); return [e < 0 ? n : e, 'c']; }
            if (source.startsWith('/*', i)) {
              const e = source.indexOf('*/', i + 2), to = e < 0 ? n : e + 2;
              return [to, source.slice(i, to).includes('\n') ? 'n' : 'c'];
            }
            if (c === '"' || c === "'") {
              let j = i + 1;
              for (; j < n && source[j] !== c && source[j] !== '\n'; j++) if (source[j] === '\\') j++;
              return [Math.min(j + 1, n), 's'];
            }
            if (c === '`') {
              let j = i + 1;
              for (; j < n && source[j] !== '`'; j++) {
                if (source[j] === '\\') j++;
                else if (source[j] === '$' && source[j + 1] === '{') j = balanced(j + 1) - 1;
              }
              return [Math.min(j + 1, n), 's'];
            }
            if (c === '/' && (!prev || (prev[1] === 'p' && !')]'.includes(prev[2])) || (prev[1] === 'w' && beforeRegex.test(prev[2])))) {
              let j = i + 1, set = false;
              for (; j < n && source[j] !== '\n' && (set || source[j] !== '/'); j++) {
                if (source[j] === '\\') j++; else if (source[j] === '[') set = true; else if (source[j] === ']') set = false;
              }
              for (j++; j < n && /[a-z]/i.test(source[j]); j++);
              return [Math.min(j, n), 's'];
            }
            word.lastIndex = i;
            const found = word.exec(source);
            return found ? [i + found[0].length, 'w', found[0]] : [i + 1, 'p', c];
          };
          // From an opening bracket at i to just past its closer.
          const balanced = i => {
            let depth = 0, prev = null;
            while (i < n) {
              const t = read(i, prev);
              if (t[1] === 'p') { if ('([{'.includes(t[2])) depth++; else if (')]}'.includes(t[2]) && --depth === 0) return t[0]; }
              if (t[1] !== 'c' && t[1] !== 'n') prev = t;
              i = t[0];
            }
            return n;
          };
          const joinsNext = /^(?:in|of|instanceof|typeof|new|delete|void|else|do|try|finally|await|yield|case|extends|const|let|var|async|function|class|return|throw)$/;
          const joinsPrevious = /^(?:in|of|instanceof|else|catch|finally)$/;
          const blockish = /^(?:if|for|while|switch|try|function|class|async|with|do)$/;
          // The statements of the list in [from, to), each with its first token.
          const split = (from, to) => {
            const list = [];
            let start = -1, end = -1, first = null, prev = null, broke = false, i = from;
            const flush = () => { if (start >= 0) list.push({from: start, to: end, first}); start = -1; first = prev = null; };
            while (i < to) {
              let t = read(i, prev);
              if (t[1] === 'c') { i = t[0]; continue; }
              if (t[1] === 'n') { broke = true; i = t[0]; continue; }
              if (start >= 0) {
                const open = prev[1] === 'p' ? !')]}'.includes(prev[2]) : prev[1] === 'w' && joinsNext.test(prev[2]);
                const joins = t[1] === 'p' ? '.,=+-*/%<>&|^?:)]}(['.includes(t[2]) || (t[2] === '{' && prev[2] === ')')
                  : t[1] === 'w' && joinsPrevious.test(t[2]);
                const closed = prev[2] === '}' && (first.text === '{' || (first.kind === 'w' && blockish.test(first.text)))
                  && !(t[1] === 'w' && /^(?:else|catch|finally|while)$/.test(t[2]));
                if ((broke && !open && !joins) || (closed && !(t[1] === 'p' && '.,=)]('.includes(t[2])))) flush();
              }
              broke = false;
              if (t[1] === 'p' && t[2] === ';') { flush(); i = t[0]; continue; }
              const at = i, opener = t[1] === 'p' && '([{'.includes(t[2]) ? t[2] : null;
              if (opener) t = [Math.min(balanced(i), to), 'p', {'(': ')', '[': ']', '{': '}'}[opener]];
              if (start < 0) { start = at; first = {kind: t[1], text: opener ?? t[2], to: t[0]}; }
              end = t[0]; prev = t; i = t[0];
            }
            flush();
            return list;
          };
          const fixed = /^(?:var|let|const|function|class|if|for|while|do|switch|try|return|throw|import|export|with)$/;
          const rewrite = (from, to) => {
            const list = split(from, to);
            for (let k = list.length - 1; k >= 0; k--) {
              const {from, to, first} = list[k];
              if (first.kind === 'w' && /^(?:break|continue|debugger)$/.test(first.text)) continue;
              if (first.kind === 'p' && first.text === '{') return first.to === to ? rewrite(from + 1, to - 1) : null;
              if (first.kind === 'w') {
                if (fixed.test(first.text) || /^async\s+function\b/.test(source.slice(from, from + 64))) return null;
                const label = /^[\w$]+\s*:\s*/.exec(source.slice(from, to));
                if (label) return rewrite(from + label[0].length, to);
              }
              return source.slice(0, from) + 'return new ' + box + '((\n' + source.slice(from, to) + '\n))' + source.slice(to);
            }
            return null;
          };
          return rewrite(0, n);
        }
        """#

    private static let rewrite: JSValue? = JSContext().evaluateScript("(" + rewriter + ")")

    /// `source` with its last expression statement returned through `new <box>(…)`, or
    /// `nil` when it ends in something else (a declaration, a loop, an explicit `return`).
    static func returningLast(_ source: String, box: String) -> String? {
        guard let result = rewrite?.call(withArguments: [source, box]), result.isString else { return nil }
        return result.toString()
    }

    /// The function body WebKit runs for one evaluation. Only names carrying `token` are
    /// in scope of the caller's code, so none can shadow a page global it meant to read.
    nonisolated static func evaluation(_ body: String, token: String) -> String {
        """
        class \(token) { constructor(value) { this.value = value; } }
        const \(token)_run = (async function () {
        \(body)
        }).call(globalThis).then(value => [false, value], error => [true, error]);
        return (async (run, box, options) => {
          if (location.origin !== options.origin) return JSON.stringify({moved: true});
          const describe = (v, byValue) => {
            const t = typeof v;
            if (v === undefined) return {type: 'undefined'};
            if (v === null) return {type: 'object', subtype: 'null', value: null};
            if (t === 'boolean' || t === 'string') return {type: t, value: v};
            if (t === 'number') {
              const text = Object.is(v, -0) ? '-0' : String(v);
              return Number.isFinite(v) && text !== '-0' ? {type: t, value: v, description: text} : {type: t, unserializableValue: text, description: text};
            }
            if (t === 'bigint') return {type: t, unserializableValue: v + 'n', description: v + 'n'};
            if (t === 'symbol') return {type: t, description: String(v)};
            if (t === 'function') return {type: t, className: 'Function', description: Function.prototype.toString.call(v)};
            let className = 'Object';
            try { className = v.constructor?.name || Object.prototype.toString.call(v).slice(8, -1); } catch {}
            const subtype = Array.isArray(v) ? 'array' : v instanceof Error ? 'error' : v instanceof Node ? 'node'
              : v instanceof Date ? 'date' : v instanceof RegExp ? 'regexp' : v instanceof Promise ? 'promise'
              : v instanceof Map ? 'map' : v instanceof Set ? 'set' : undefined;
            const result = {type: 'object', className, description: className};
            if (subtype) result.subtype = subtype;
            if (subtype === 'error') result.description = String(v) + (v.stack ? '\\n' + String(v.stack).split('\\n').map(line => '    at ' + line).join('\\n') : '');
            else if (subtype === 'array') result.description = 'Array(' + v.length + ')';
            else if (subtype === 'node') result.description = v.nodeName.toLowerCase() + (v.id ? '#' + v.id : '');
            else if (subtype === 'date' || subtype === 'regexp') result.description = String(v);
            if (byValue) result.value = JSON.parse(JSON.stringify(v) ?? 'null');
            return result;
          };
          const work = (async () => {
            let [thrown, value] = await run;
            if (!thrown && value instanceof box) {
              value = value.value;
              if (options.awaitPromise) try { value = await value; } catch (error) { thrown = true; value = error; }
            }
            return [thrown, value];
          })();
          const [thrown, value] = await (options.timeout > 0 ? Promise.race([work, new Promise(resolve =>
            setTimeout(resolve, options.timeout, [true, new Error('Script execution was terminated')]))]) : work);
          try {
            if (!thrown) return JSON.stringify({result: describe(value, options.returnByValue)});
            const exception = describe(value, false);
            return JSON.stringify({result: exception, exceptionDetails: {exceptionId: 1, text: 'Uncaught', lineNumber: 0, columnNumber: 0, exception}});
          } catch (error) { return JSON.stringify({failed: 'Object reference chain is too long'}); }
        })(\(token)_run, \(token), \(token)_options);
        """
    }

    // MARK: Input

    /// DOM `code` to the Mac virtual key code WebKit derives it back from.
    nonisolated static let keyCodes: [String: UInt16] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9,
        "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17, "Digit1": 18, "Digit2": 19,
        "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
        "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34, "KeyP": 35,
        "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42, "Comma": 43,
        "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51,
        "Escape": 53, "NumpadEnter": 76, "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103,
        "F10": 109, "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120,
        "PageDown": 121, "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126
    ]

    /// What AppKit puts in `characters` for keys that type nothing.
    nonisolated static let functionCharacters: [String: Int] = [
        "Enter": 0x0D, "NumpadEnter": 0x03, "Tab": 0x09, "Backspace": 0x7F, "Escape": 0x1B, "Delete": NSDeleteFunctionKey,
        "ArrowUp": NSUpArrowFunctionKey, "ArrowDown": NSDownArrowFunctionKey, "ArrowLeft": NSLeftArrowFunctionKey,
        "ArrowRight": NSRightArrowFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey,
        "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey, "F1": NSF1FunctionKey, "F2": NSF2FunctionKey,
        "F3": NSF3FunctionKey, "F4": NSF4FunctionKey, "F5": NSF5FunctionKey, "F6": NSF6FunctionKey, "F7": NSF7FunctionKey,
        "F8": NSF8FunctionKey, "F9": NSF9FunctionKey, "F10": NSF10FunctionKey, "F11": NSF11FunctionKey, "F12": NSF12FunctionKey
    ]

    /// Editing commands a ⌘ shortcut may name. A selector from an extension is never
    /// performed unless it is one of these.
    nonisolated static func isEditingCommand(_ name: String) -> Bool {
        ["selectAll", "copy", "cut", "paste", "pasteAsPlainText", "undo", "redo"].contains(name)
            || (["move", "delete", "scroll", "page"].contains { name.hasPrefix($0) } && name.allSatisfy { $0.isASCII && $0.isLetter })
    }

    /// CDP's modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
    nonisolated static func flags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.option) }
        if modifiers & 2 != 0 { flags.insert(.control) }
        if modifiers & 4 != 0 { flags.insert(.command) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }
}

/// The answer to one bridge call: the "tab" `tabs.create` resolves to. It is in no
/// window and no query; its URL is the extension's own, so the extension may read its
/// title, which is the JSON.
@MainActor final class ExtensionBridgeReply: NSObject, WKWebExtensionTab {
    private let location: URL
    fileprivate var json = "null"
    fileprivate var busy = false

    fileprivate init(base: URL) { location = base.appendingPathComponent(String(ExtensionDebuggerAPI.bridgePath.dropFirst())) }

    func url(for context: WKWebExtensionContext) -> URL? { location }

    /// WebKit reads this once, as the call resolves; the object then serves another call,
    /// so WebKit's table of tabs it has seen does not grow by one per command.
    func title(for context: WKWebExtensionContext) -> String? {
        DispatchQueue.main.async { [self] in busy = false }
        return json
    }
}

/// One profile's debugger sessions: which extension drives which tab, the commands they
/// send, and the events they are owed.
@MainActor final class ExtensionDebugger: ObservableObject {
    final class Session {
        let context: WKWebExtensionContext
        private(set) weak var tab: Tab?
        let tabID: Tab.ID
        /// The extension's own id for the tab, echoed in events and `getTargets`.
        let label: Int

        fileprivate init(context: WKWebExtensionContext, tab: Tab, label: Int) {
            self.context = context
            self.tab = tab
            tabID = tab.id
            self.label = label
        }
    }

    @Published private(set) var sessions: [Session] = []
    private let profileID: UUID
    private var replies: [ObjectIdentifier: [ExtensionBridgeReply]] = [:]
    private var logs: [ObjectIdentifier: (next: Int, items: [(sequence: Int, item: [String: Any])])] = [:]
    private var waiters: [ObjectIdentifier: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var eventNumber = 0
    /// How long one WebKit call may take before the command fails instead of hanging.
    var patience: TimeInterval = 30

    init(profileID: UUID) { self.profileID = profileID }

    func session(on tab: Tab.ID) -> Session? { sessions.first { $0.tabID == tab } }

    // MARK: Requests

    func handle(_ request: ExtensionDebuggerAPI.Request, tab shim: ExtTab?, panels: [ExtensionSidePanel],
                for context: WKWebExtensionContext) async throws -> ExtensionBridgeReply {
        let key = ObjectIdentifier(context)
        if request.operation == "contexts" { return reply(contexts(of: context, panels: panels), for: context) }
        guard ExtensionDebuggerAPI.declared(context.webExtension.manifest) else {
            throw ExtensionHost.Failure("This extension has not requested the debugger permission.")
        }
        let label = request.values["tabId"].flatMap(Int.init) ?? -1
        func attached() -> Session? {
            guard let tab = shim?.tab else { return nil }
            return sessions.first { $0.context === context && $0.tab === tab }
        }
        switch request.operation {
        case "targets":
            return reply(sessions.filter { $0.context === context }.map(\.label), for: context)
        case "events":
            let next = logs[key]?.next ?? 0
            guard let after = request.values["after"].flatMap(Int.init) else {
                return reply(["cursor": next, "events": [Any](), "idle": !sessions.contains { $0.context === context }], for: context)
            }
            if after >= next, sessions.contains(where: { $0.context === context }), (waiters[key]?.count ?? 0) < 8 { await wait(key) }
            let log = logs[key]
            return reply(["cursor": log?.next ?? 0, "events": (log?.items ?? []).filter { $0.sequence >= after }.map(\.item),
                          "idle": !sessions.contains { $0.context === context }], for: context)
        case "attach":
            let page = try await page(shim, label: label, for: context)
            guard session(on: page.tab.id) == nil else {
                throw ExtensionHost.Failure("Another debugger is already attached to the tab with id: \(label).")
            }
            let session = Session(context: context, tab: page.tab, label: label)
            sessions.append(session)
            return reply(["cursor": logs[key]?.next ?? 0], for: context)
        case "detach":
            guard let session = attached() else {
                throw ExtensionHost.Failure("Debugger is not attached to the tab with id: \(label).")
            }
            sessions.removeAll { $0 === session }
            return reply([String: Any](), for: context)
        case "sendCommand":
            guard let session = attached() else {
                throw ExtensionHost.Failure("Debugger is not attached to the tab with id: \(label).")
            }
            let page = try await page(shim, label: label, for: context)
            let parameters = (try? JSONSerialization.jsonObject(with: Data((request.values["params"] ?? "{}").utf8))) as? [String: Any] ?? [:]
            let result = try await command(request.values["method"] ?? "", parameters, session: session, page: page,
                                           shim: shim, context: context)
            guard sessions.contains(where: { $0 === session }) else { throw ExtensionHost.Failure("Detached while handling command.") }
            return reply(result, for: context)
        default:
            throw ExtensionHost.Failure("Unknown bridge request.")
        }
    }

    private func reply(_ result: Any, for context: WKWebExtensionContext) -> ExtensionBridgeReply {
        let key = ObjectIdentifier(context)
        let reply = replies[key]?.first { !$0.busy } ?? {
            let reply = ExtensionBridgeReply(base: context.baseURL)
            replies[key, default: []].append(reply)
            return reply
        }()
        let data = try? JSONSerialization.data(withJSONObject: ["result": result], options: [.fragmentsAllowed, .sortedKeys])
        reply.json = data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"result":null}"#
        reply.busy = true
        return reply
    }

    /// What `runtime.getContexts` lists: the background, and each open side panel.
    // ponytail: no popup or options-page contexts, and no window ids (WebKit keeps those
    // to itself). Add them when an extension asks for more than its side panels.
    private func contexts(of context: WKWebExtensionContext, panels: [ExtensionSidePanel]) -> [[String: Any]] {
        let origin = context.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func entry(_ type: String, id: String, url: String?, frame: Int, incognito: Bool) -> [String: Any] {
            var entry: [String: Any] = ["contextType": type, "contextId": id, "documentOrigin": origin, "frameId": frame,
                                        "tabId": -1, "windowId": -1, "incognito": incognito]
            if let url { entry["documentUrl"] = url; entry["documentId"] = id }
            return entry
        }
        return [entry("BACKGROUND", id: "background", url: nil, frame: -1, incognito: false)]
            + panels.filter { $0.context === context }.map {
                entry("SIDE_PANEL", id: String(UInt(bitPattern: ObjectIdentifier($0).hashValue)),
                      url: ($0.web.url ?? $0.page).absoluteString, frame: 0, incognito: $0.store?.isPrivate ?? false)
            }
    }

    // MARK: Events and lifetime

    private func wait(_ key: ObjectIdentifier) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[key, default: [:]][id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                self?.waiters[key]?.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func emit(_ item: [String: Any], to context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        var log = logs[key] ?? (0, [])
        log.items.append((log.next, item))
        log.next += 1
        if log.items.count > 256 { log.items.removeFirst(log.items.count - 256) }
        logs[key] = log
        for waiter in (waiters.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }

    private func end(_ session: Session, reason: String) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        emit(["tabId": session.label, "reason": reason], to: session.context)
    }

    /// The banner's Stop: the user takes the tab back.
    func stop(_ session: Session) { end(session, reason: "canceled_by_user") }

    /// A session lasts as long as its tab is held by one of the profile's windows.
    func sync() {
        guard !sessions.isEmpty else { return }
        let held = Set(TabStore.all.filter { $0.profileID == profileID }.flatMap { $0.everyTab.map(\.id) })
        for session in sessions where session.tab == nil || !held.contains(session.tabID) { end(session, reason: "target_closed") }
    }

    func forget(_ context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        sessions.removeAll { $0.context === context }
        logs[key] = nil
        replies[key] = nil
        for waiter in (waiters.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }

    // MARK: The page

    private struct Page {
        let tab: Tab
        let web: WKWebView
        let url: URL
        let scroll: CGPoint
        /// When the loaded document began: its identity, which a reload changes too.
        let began: Double
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    /// One WebKit call with a completion handler, bounded: a hung page fails the command.
    private func bounded<Value>(_ work: (@escaping (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        // Main actor on both sides: the value never leaves it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Unchecked<Value>, any Error>) in
            var done = false
            let finish: (Result<Value, any Error>) -> Void = { result in
                guard !done else { return }
                done = true
                continuation.resume(with: result.map(Unchecked.init))
            }
            work(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + patience) {
                finish(.failure(ExtensionDebuggerAPI.failure(-32000, "The page did not answer in time.")))
            }
        }.value
    }

    /// The tab's page, if this extension may drive it now: an open tab it can see, showing
    /// a website it has host access to. Checked against the document that is actually
    /// loaded, which is not always the address the tab reports while it navigates.
    // ponytail: checked once per command, before it runs. `Runtime.evaluate` checks the
    // origin again inside the page; input and screenshots do not, so a navigation in the
    // few milliseconds between check and delivery lands on the new page.
    private func page(_ shim: ExtTab?, label: Int, for context: WKWebExtensionContext) async throws -> Page {
        guard let shim, let tab = shim.tab, let web = shim.webView(for: context),
              !tab.isPrivate || context.hasAccessToPrivateData else {
            throw ExtensionHost.Failure("No tab with given id \(label).")
        }
        let probe: [Any] = try await bounded { finish in
            web.evaluateJavaScript("[location.href, scrollX, scrollY, performance.timeOrigin]", in: nil, in: .defaultClient) { result in
                finish(result.flatMap { value in
                    (value as? [Any]).map(Result.success) ?? .failure(ExtensionDebuggerAPI.failure(-32000, "Inspected target navigated or closed"))
                })
            }
        }
        guard probe.count == 4, let url = (probe[0] as? String).flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ExtensionHost.Failure("Cannot attach to this target.")
        }
        switch context.permissionStatus(for: url, in: shim) {
        case .grantedExplicitly, .grantedImplicitly: break
        default:
            throw ExtensionHost.Failure("Cannot access contents of the page. Extension manifest must request permission to access the respective host.")
        }
        return Page(tab: tab, web: web, url: url,
                    scroll: CGPoint(x: (probe[1] as? Double) ?? 0, y: (probe[2] as? Double) ?? 0),
                    began: (probe[3] as? Double) ?? 0)
    }

    // MARK: Commands

    private func command(_ method: String, _ parameters: [String: Any], session: Session, page: Page,
                         shim: ExtTab?, context: WKWebExtensionContext) async throws -> Any {
        let none = [String: Any]()
        switch method {
        case "Runtime.evaluate": return try await evaluate(parameters, page)
        case "Page.captureScreenshot": return try await screenshot(parameters, page)
        case "Input.dispatchMouseEvent": try mouse(parameters, page.web); return none
        case "Input.dispatchKeyEvent": try key(parameters, page.web); return none
        case "Input.insertText":
            guard let text = parameters["text"] as? String else { throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: text") }
            try insert(text, page.web)
            return none
        case "Page.navigate":
            guard let url = (parameters["url"] as? String).flatMap(URL.init(string:)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ExtensionDebuggerAPI.failure(-32000, "Cannot navigate to invalid URL")
            }
            page.tab.navigate(to: url)
            return ["frameId": frameID(session), "loaderId": loaderID(page)]
        case "Page.reload":
            page.tab.reload()
            return none
        case "Page.getFrameTree":
            let origin = page.url.scheme.map { $0 + "://" + (page.url.host ?? "") + (page.url.port.map { ":\($0)" } ?? "") } ?? ""
            return ["frameTree": ["frame": [
                "id": frameID(session), "loaderId": loaderID(page), "url": page.url.absoluteString,
                "domainAndRegistry": page.url.host ?? "", "securityOrigin": origin, "mimeType": "text/html",
                "secureContextType": page.url.scheme == "https" ? "Secure" : "InsecureScheme",
                "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [String]()
            ] as [String: Any]]]
        case "Page.bringToFront":
            try await shim?.activate(for: context)
            return none
        // Accepted so an attach sequence completes. Nothing is switched on: these domains'
        // events (console, network, dialogs, screencast frames) are never sent.
        case "Page.enable", "Page.disable", "Runtime.enable", "Runtime.disable", "Network.enable", "Network.disable",
             "Network.setBypassServiceWorker", "Emulation.setFocusEmulationEnabled", "Page.startScreencast",
             "Page.stopScreencast", "Input.cancelDragging":
            return none
        case "Page.handleJavaScriptDialog":
            throw ExtensionDebuggerAPI.failure(-32602, "No dialog is showing")
        default:
            throw ExtensionDebuggerAPI.failure(-32601, "'\(method)' wasn't found")
        }
    }

    private func frameID(_ session: Session) -> String { "vane-frame-" + session.tabID.uuidString }
    private func loaderID(_ page: Page) -> String { "vane-loader-\(page.began)" }

    private func evaluate(_ parameters: [String: Any], _ page: Page) async throws -> Any {
        guard let expression = parameters["expression"] as? String else {
            throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: expression")
        }
        let token = "__vane" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let port = page.url.port.map { ":\($0)" } ?? ""
        let options: [String: Any] = [
            "origin": (page.url.scheme ?? "") + "://" + (page.url.host ?? "") + port,
            "awaitPromise": parameters["awaitPromise"] as? Bool ?? false,
            "returnByValue": parameters["returnByValue"] as? Bool ?? false,
            "timeout": parameters["timeout"] as? Double ?? 0
        ]
        var syntax: String?
        for body in [ExtensionDebuggerAPI.returningLast(expression, box: token), expression].compactMap({ $0 }) {
            let outcome: Result<Any, any Error> = try await bounded { finish in
                page.web.callAsyncJavaScript(ExtensionDebuggerAPI.evaluation(body, token: token),
                                             arguments: [token + "_options": options], in: nil, in: .page) { finish(.success($0)) }
            }
            switch outcome {
            case .success(let value):
                guard let text = value as? String,
                      let answer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                    throw ExtensionDebuggerAPI.failure(-32000, "The page returned no result.")
                }
                if answer["moved"] != nil { throw ExtensionDebuggerAPI.failure(-32000, "Inspected target navigated or closed") }
                if let failed = answer["failed"] as? String { throw ExtensionDebuggerAPI.failure(-32000, failed) }
                return answer
            case .failure(let error):
                // A body that does not compile ran nothing, so the next form may be tried.
                let error = error as NSError
                let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                guard error.domain == WKErrorDomain, error.code == WKError.javaScriptExceptionOccurred.rawValue,
                      message.hasPrefix("SyntaxError") else {
                    throw ExtensionDebuggerAPI.failure(-32000, "Inspected target navigated or closed")
                }
                syntax = syntax ?? message
            }
        }
        let exception: [String: Any] = ["type": "object", "subtype": "error", "className": "SyntaxError",
                                        "description": syntax ?? "SyntaxError"]
        return ["result": exception, "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0,
                                                           "scriptId": "0", "exception": exception] as [String: Any]]
    }

    private func screenshot(_ parameters: [String: Any], _ page: Page) async throws -> Any {
        let format = parameters["format"] as? String ?? "png"
        guard format == "png" || format == "jpeg" else {
            throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: Vane captures png and jpeg only")
        }
        let configuration = WKSnapshotConfiguration()
        if let clip = parameters["clip"] as? [String: Any] {
            guard let x = clip["x"] as? Double, let y = clip["y"] as? Double, let width = clip["width"] as? Double,
                  let height = clip["height"] as? Double, width > 0, height > 0 else {
                throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: clip")
            }
            // The clip is in document pixels; a snapshot is cut from the view.
            let zoom = page.web.pageZoom
            configuration.rect = CGRect(x: (x - page.scroll.x) * zoom, y: (y - page.scroll.y) * zoom,
                                        width: width * zoom, height: height * zoom)
            configuration.snapshotWidth = NSNumber(value: width * (clip["scale"] as? Double ?? 1))
        }
        let image: NSImage = try await bounded { finish in
            page.web.takeSnapshot(with: configuration) { image, error in
                finish(image.map(Result.success) ?? .failure(error ?? ExtensionDebuggerAPI.failure(-32000, "Unable to capture screenshot")))
            }
        }
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)),
              let data = format == "png" ? bitmap.representation(using: .png, properties: [:])
                : bitmap.representation(using: .jpeg, properties: [.compressionFactor: min(max((parameters["quality"] as? Double ?? 80) / 100, 0), 1)]) else {
            throw ExtensionDebuggerAPI.failure(-32000, "Unable to capture screenshot")
        }
        return ["data": data.base64EncodedString()]
    }

    // Input reaches the page as AppKit events handed straight to its web view: WebKit
    // treats them as the user's, so the page sees trusted events. Nothing is posted to
    // the system and the pointer never moves.
    // ponytail: a view outside a window takes no events, so only a tab that is on screen
    // can be driven. Hosting background tabs in an offscreen window is the upgrade.

    private func window(of web: WKWebView) throws -> NSWindow {
        guard let window = web.window else {
            throw ExtensionDebuggerAPI.failure(-32000, "Vane can only send input to a tab that is on screen.")
        }
        return window
    }

    private func insert(_ text: String, _ web: WKWebView) throws {
        _ = try window(of: web)
        // The web view is its own text input client; AppKit's header does not say so.
        if let client = web as? NSTextInputClient { client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        else { web.insertText(text) }
    }

    private func mouse(_ parameters: [String: Any], _ web: WKWebView) throws {
        guard let type = parameters["type"] as? String, let x = parameters["x"] as? Double, let y = parameters["y"] as? Double else {
            throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: type, x and y are required")
        }
        let window = try window(of: web)
        let zoom = web.pageZoom
        let location = web.convert(NSPoint(x: x * zoom, y: web.isFlipped ? y * zoom : web.bounds.height - y * zoom), to: nil)
        let flags = ExtensionDebuggerAPI.flags(parameters["modifiers"] as? Int ?? 0)
        let button = parameters["button"] as? String ?? "none", held = parameters["buttons"] as? Int ?? 0
        if type == "mouseWheel" {
            // AppKit builds no scroll event by hand. One from Core Graphics has no window,
            // and reports its screen position where WebKit reads a window position.
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(-(parameters["deltaY"] as? Double ?? 0)),
                                      wheel2: Int32(-(parameters["deltaX"] as? Double ?? 0)), wheel3: 0) else {
                throw ExtensionDebuggerAPI.failure(-32000, "Unable to create the scroll event")
            }
            wheel.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
            wheel.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            guard let event = NSEvent(cgEvent: wheel) else { throw ExtensionDebuggerAPI.failure(-32000, "Unable to create the scroll event") }
            web.scrollWheel(with: event)
            return
        }
        let right = button == "right" || (button == "none" && held & 2 != 0)
        guard button != "middle", button != "back", button != "forward" else {
            throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: Vane sends the left and right buttons only")
        }
        let kind: NSEvent.EventType
        switch type {
        case "mousePressed": kind = right ? .rightMouseDown : .leftMouseDown
        case "mouseReleased": kind = right ? .rightMouseUp : .leftMouseUp
        case "mouseMoved": kind = held == 0 ? .mouseMoved : right ? .rightMouseDragged : .leftMouseDragged
        default: throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: type")
        }
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: eventNumber,
                                             clickCount: kind == .mouseMoved ? 0 : parameters["clickCount"] as? Int ?? 1,
                                             pressure: type == "mousePressed" || held != 0 ? 1 : 0) else {
            throw ExtensionDebuggerAPI.failure(-32000, "Unable to create the mouse event")
        }
        switch kind {
        case .leftMouseDown:
            // A click focuses the page, as the user's would.
            if window.firstResponder !== web { window.makeFirstResponder(web) }
            web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .rightMouseDown: web.rightMouseDown(with: event)
        case .rightMouseUp: web.rightMouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        case .rightMouseDragged: web.rightMouseDragged(with: event)
        default: web.mouseMoved(with: event)
        }
    }

    private func key(_ parameters: [String: Any], _ web: WKWebView) throws {
        guard let type = parameters["type"] as? String else { throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: type") }
        let window = try window(of: web)
        let text = parameters["text"] as? String ?? "", name = parameters["key"] as? String ?? ""
        let code = parameters["code"] as? String ?? ""
        if type == "char" {
            if !text.isEmpty { try insert(text, web) }
            return
        }
        guard type == "keyDown" || type == "rawKeyDown" || type == "keyUp" else {
            throw ExtensionDebuggerAPI.failure(-32602, "Invalid parameters: type")
        }
        // A modifier on its own changes flags and types nothing.
        guard !["Shift", "Control", "Alt", "Meta", "CapsLock"].contains(name) else { return }
        guard let keyCode = ExtensionDebuggerAPI.keyCodes[code] ?? ExtensionDebuggerAPI.keyCodes[name] else {
            // No such key on this keyboard: its text still arrives.
            if type != "keyUp", !text.isEmpty { try insert(text, web) }
            return
        }
        let modifiers = parameters["modifiers"] as? Int ?? 0
        var flags = ExtensionDebuggerAPI.flags(modifiers)
        let special = (ExtensionDebuggerAPI.functionCharacters[code] ?? ExtensionDebuggerAPI.functionCharacters[name])
            .flatMap(UnicodeScalar.init).map { String(Character($0)) }
        if let special, special.unicodeScalars.first.map({ $0.value >= 0xF700 }) == true { flags.insert(.function) }
        let characters = special ?? (text.isEmpty ? (name.count == 1 ? name : "") : text)
        let plain = special ?? (parameters["unmodifiedText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? characters.lowercased()
        guard let event = NSEvent.keyEvent(with: type == "keyUp" ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: plain,
                                           isARepeat: false, keyCode: keyCode) else {
            throw ExtensionDebuggerAPI.failure(-32000, "Unable to create the key event")
        }
        if type == "keyUp" { web.keyUp(with: event); return }
        web.keyDown(with: event)
        // AppKit turns ⌘ shortcuts into commands in its menus, which this event never
        // visits; the commands Chrome's caller names stand in for them.
        guard modifiers & 4 != 0 else { return }
        for command in parameters["commands"] as? [String] ?? [] where ExtensionDebuggerAPI.isEditingCommand(command) {
            let selector = NSSelectorFromString(command + ":")
            if web.responds(to: selector) { web.perform(selector, with: nil) }
        }
    }
}

/// Chrome's "is debugging this browser" bar, as a pill over the page: who is driving the
/// tab on screen, and the user's way to take it back.
struct ExtensionDebuggerBanner: View {
    @ObservedObject var debugger: ExtensionDebugger
    let host: ExtensionHost
    /// Read by the caller so a tab switch re-evaluates which session this window shows.
    let onScreen: [Tab.ID]
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let session = debugger.sessions.first { onScreen.contains($0.tabID) }
        ZStack {
            if let session {
                let name = session.context.webExtension.displayName ?? "An extension"
                HStack(spacing: Look.pillGlyphGap) {
                    if let icon = host.icon(session.context, for: nil) {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: Look.rowIcon, height: Look.rowIcon)
                            .accessibilityHidden(true)
                    }
                    Text("\(name) is controlling this tab").font(Look.caption).lineLimit(1)
                    Button("Stop") { debugger.stop(session) }
                        .buttonStyle(.plain).font(Look.caption.weight(.semibold))
                        .padding(.horizontal, Look.pillGlyphGap).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: .capsule)
                        .contentShape(.capsule)
                        .help("Stop \(name) controlling this tab")
                }
                .padding(.leading, Look.rowInset).padding(.trailing, 5).padding(.vertical, 5)
                .background(Look.panelFill, in: .capsule)
                .overlay { Capsule().strokeBorder(Color(nsColor: .separatorColor)) }
                .padding(.bottom, Look.inset)
                .accessibilityElement(children: .contain)
                .id(ObjectIdentifier(session))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.appear, value: session.map(ObjectIdentifier.init))
    }
}
