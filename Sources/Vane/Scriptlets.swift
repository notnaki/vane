import Foundation

/// uBlock-style scriptlet filters (`example.com##+js(name, args…)`) for the built-in blocker.
///
/// The library below is a clean-room implementation written from uBlock Origin's public
/// descriptions of each scriptlet's behaviour. No uBlock Origin (GPLv3) code is copied;
/// this file is under the repository's MIT license.
///
/// One page-world script per profile carries the library and the hostname table, split into
/// 64 buckets by host. Each bucket and the library sit in function bodies JavaScriptCore only
/// pre-parses (no strings built, no bytecode) until called, and a frame calls only its own
/// host's bucket. A page with no matching scriptlet builds a few KB and runs nothing.
/// ponytail: the source text still reaches every frame. Per-host scripts need match-pattern
/// SPI on `WKUserScript`, which cannot express `name.*` entities and would mean thousands
/// of scripts per tab; revisit if the per-frame pre-parse ever shows in profiles.
enum Scriptlets {
    struct Rule: Equatable {
        var include: [String]
        var exclude: [String]
        /// nil: `#@#+js()`, which disables every scriptlet on those hosts.
        var call: [String]?
        var exception: Bool
    }

    enum Parsed: Equatable {
        case rule(Rule)
        case unsupported(String)
    }

    /// uBlock names and aliases → the library's canonical name.
    nonisolated static let names: [String: String] = [
        "set-constant": "set-constant", "set": "set-constant",
        "abort-on-property-read": "abort-on-property-read", "aopr": "abort-on-property-read",
        "abort-on-property-write": "abort-on-property-write", "aopw": "abort-on-property-write",
        "abort-current-script": "abort-current-script", "acs": "abort-current-script",
        "abort-current-inline-script": "abort-current-script", "acis": "abort-current-script",
        "no-settimeout-if": "no-setTimeout-if", "nostif": "no-setTimeout-if", "settimeout-defuser": "no-setTimeout-if",
        "no-setinterval-if": "no-setInterval-if", "nosiif": "no-setInterval-if", "setinterval-defuser": "no-setInterval-if",
        "prevent-fetch": "prevent-fetch", "no-fetch-if": "prevent-fetch",
        "prevent-xhr": "prevent-xhr", "no-xhr-if": "prevent-xhr",
        "remove-attr": "remove-attr", "ra": "remove-attr",
        "remove-class": "remove-class", "rc": "remove-class",
        "addeventlistener-defuser": "addEventListener-defuser", "aeld": "addEventListener-defuser",
        "prevent-addeventlistener": "addEventListener-defuser",
        "window.open-defuser": "window.open-defuser", "nowoif": "window.open-defuser",
        "prevent-window-open": "window.open-defuser", "no-window-open-if": "window.open-defuser",
        "json-prune": "json-prune",
        "json-prune-fetch-response": "json-prune-fetch-response",
        "json-prune-xhr-response": "json-prune-xhr-response",
    ]

    /// nil when the line is not a scriptlet filter at all.
    nonisolated static func parse(_ line: String) -> Parsed? {
        let exception: Bool
        let marker: Range<String.Index>
        if let found = line.range(of: "#@#+js(") { exception = true; marker = found }
        else if let found = line.range(of: "##+js(") { exception = false; marker = found }
        else { return nil }
        let body = line[marker.upperBound...]
        guard body.hasSuffix(")") else { return .unsupported("Unsupported scriptlet") }
        let args = arguments(String(body.dropLast()))
        var call: [String]?
        if let first = args.first {
            var name = first.lowercased()
            if name.hasSuffix(".js") { name.removeLast(3) }
            // `trusted-*` scriptlets can rewrite responses with arbitrary content; uBlock
            // limits them to its own lists, and a user-added list is not that.
            guard let canonical = names[name] else { return .unsupported("Unsupported scriptlet") }
            call = [canonical] + args.dropFirst()
            // An argument the library would ignore can be one that narrows the filter, so
            // running without it would do more than the list asked. Exceptions match by text.
            if !exception, !understood(canonical, Array(args.dropFirst())) {
                return .unsupported("Unsupported scriptlet arguments")
            }
        } else if !exception {
            return .unsupported("Unsupported scriptlet")
        }
        var include: [String] = [], exclude: [String] = []
        let hosts = line[..<marker.lowerBound]
        if !hosts.isEmpty {
            for part in hosts.split(separator: ",", omittingEmptySubsequences: false) {
                let raw = part.trimmingCharacters(in: .whitespaces)
                let negated = raw.hasPrefix("~")
                let host = String(negated ? raw.dropFirst() : raw[...]).lowercased()
                guard validHost(host) else { return .unsupported("Scriptlet with unsupported hostnames") }
                if negated { exclude.append(host) } else { include.append(host) }
            }
        }
        if exception, include.isEmpty || !exclude.isEmpty {
            return .unsupported("Generic or negated scriptlet exception")
        }
        return .rule(Rule(include: include, exclude: exclude, call: call, exception: exception))
    }

    /// `set-constant` values the library knows, besides small integers.
    nonisolated static let constants: Set<String> = [
        "undefined", "false", "true", "null", "", "emptyStr", "noopFunc", "trueFunc", "falseFunc",
        "throwFunc", "emptyObj", "{}", "emptyArr", "[]", "noopPromiseResolve", "noopPromiseReject",
    ]

    /// Whether the library implements every argument of this call as uBlock means it.
    private nonisolated static func understood(_ name: String, _ a: [String]) -> Bool {
        func at(_ i: Int) -> String { i < a.count ? a[i] : "" }
        /// Trailing `key, value` pairs, each key in `keys`; `values` limits a key's value.
        func pairs(from i: Int, _ keys: Set<String>, _ values: [String: Set<String>] = [:]) -> Bool {
            guard a.count >= i else { return true }
            let rest = Array(a[i...])
            guard rest.count % 2 == 0 else { return false }
            return stride(from: 0, to: rest.count, by: 2).allSatisfy {
                keys.contains(rest[$0]) && values[rest[$0]].map { [v = rest[$0 + 1]] in $0.contains(v) } != false
            }
        }
        let bodies: Set<String> = ["", "emptyObj", "emptyArr", "emptyStr", "true", "false"]
        // `[-]` and `{-}` are uBlock's array-element and recursive-key path forms.
        let plainPaths = { (s: String) in !s.contains("[-]") && !s.contains("{-}") }
        switch name {
        case "set-constant":
            let value = at(1)
            let number = value.wholeMatch(of: /-?\d+/) != nil && abs(Int(value) ?? .max) <= 0x7fff
            return !at(0).isEmpty && (constants.contains(value) || number)
                && pairs(from: 2, ["as"], ["as": ["function", "callback", "resolved", "rejected"]])
        case "abort-on-property-read", "abort-on-property-write": return !at(0).isEmpty && a.count <= 1
        case "abort-current-script": return !at(0).isEmpty && a.count <= 3
        case "no-setTimeout-if", "no-setInterval-if": return a.count <= 2 && at(1).wholeMatch(of: /!?\d*/) != nil
        case "prevent-fetch", "prevent-xhr": return a.count <= 2 && bodies.contains(at(1))
        case "remove-attr", "remove-class":
            return a.count <= 3 && at(2).split(separator: " ").allSatisfy { ["stay", "complete", "interactive", "asap"].contains($0) }
        case "addEventListener-defuser": return pairs(from: 2, ["elements"])
        case "window.open-defuser": return a.count <= 1 || (a.count == 2 && ["0", "1"].contains(at(0)))
        case "json-prune": return a.count <= 2 && plainPaths(at(0)) && plainPaths(at(1))
        case "json-prune-fetch-response", "json-prune-xhr-response":
            return plainPaths(at(0)) && plainPaths(at(1)) && pairs(from: 2, ["propsToMatch"])
        default: return false
        }
    }

    /// Comma-separated, `\,` escapes a comma, and a value wrapped in matching quotes is
    /// unwrapped (so `'a, b'` stays one argument).
    nonisolated static func arguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                if c != "," { current.append("\\") }
                current.append(c); escaped = false
            } else if c == "\\" {
                escaped = true
            } else if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == ",", quote == nil {
                out.append(current); current = ""
            } else {
                if (c == "'" || c == "\"") && current.allSatisfy(\.isWhitespace) { quote = c; current = "" }
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        out.append(current)
        let trimmed = out.map { arg -> String in
            let t = arg.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let f = t.first, f == "'" || f == "\"", t.last == f { return String(t.dropFirst().dropLast()) }
            return t
        }
        return trimmed == [""] ? [] : trimmed
    }

    /// Plain hostnames or `name.*` entities. Regex hostnames are not supported.
    private nonisolated static func validHost(_ host: String) -> Bool {
        let name = host.hasSuffix(".*") ? String(host.dropLast(2)) : host
        guard !name.isEmpty, host.contains(".") else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Host key → (calls to run, calls excepted), as indexes into one list of unique calls,
    /// since many hosts share a call. Key "" is generic. uBlock treats a negated hostname
    /// on a scriptlet filter as an exception there.
    struct Table {
        private var calls: [[String]] = []
        private var index: [[String]: Int] = [:]
        private var apply: [String: [Int]] = [:]
        private var except: [String: [Int]] = [:]
        private(set) var count = 0
        /// Running estimate of `text`'s UTF-8 size.
        private var bytes = 0
        /// Every frame receives the whole table, so it stops growing at about this size.
        nonisolated static let limit = 1_500_000

        /// False, and nothing added, when the rule would take the table past `limit`.
        @discardableResult
        mutating func add(_ rule: Rule) -> Bool {
            let call = rule.call ?? []
            let id = index[call] ?? calls.count
            let keys = rule.exception ? rule.include : (rule.include.isEmpty ? [""] : rule.include) + rule.exclude
            // A row is `\n<key>\t[[ids],[ids]]`; a call is `\n#<id>\t<json>`. Counted as if new.
            var cost = keys.reduce(0) { $0 + $1.utf8.count + 16 }
            if id == calls.count { cost += call.reduce(16) { $0 + $1.utf8.count + 3 } }
            guard bytes + cost <= Self.limit else { return false }
            bytes += cost
            count += 1
            if id == calls.count { calls.append(call); index[call] = id }
            func insert(_ key: String, _ map: inout [String: [Int]]) {
                if map[key]?.contains(id) != true { map[key, default: []].append(id) }
            }
            if rule.exception {
                rule.include.forEach { insert($0, &except) }
                return true
            }
            (rule.include.isEmpty ? [""] : rule.include).forEach { insert($0, &apply) }
            rule.exclude.forEach { insert($0, &except) }
            return true
        }

        /// `buckets` texts joined by U+0001. Each holds `\n<key>\t<json [apply, except]>` for
        /// its hosts, sorted so equal filters give equal text, then `\n#<id>\t<json call>` for
        /// each call whose id falls in it. JSON escapes every control character.
        var text: String {
            guard !apply.isEmpty else { return "" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self) }
            var rows = Array(repeating: "", count: buckets)
            for key in Set(apply.keys).union(except.keys).sorted() {
                rows[bucket(key)] += "\n" + key + "\t" + json([apply[key] ?? [], except[key] ?? []])
            }
            for (id, call) in calls.enumerated() { rows[id % buckets] += "\n#\(id)\t" + json(call) }
            return rows.joined(separator: "\u{1}")
        }
    }

    nonisolated static let buckets = 64

    /// Every key of one host shares its last two labels, so a frame reads one bucket plus
    /// one per entity candidate. FNV-1a, mirrored by `bucket` in the page script.
    nonisolated static func bucket(_ key: String) -> Int {
        let name = key.hasSuffix(".*") ? key : key.split(separator: ".", omittingEmptySubsequences: false).suffix(2).joined(separator: ".")
        var h: UInt32 = 2_166_136_261
        for byte in name.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return Int(h % UInt32(buckets))
    }

    /// The page-world document-start script, or nil when there is nothing to run.
    /// `siteExceptions` are the profile's exact-host blocker exceptions, matched against
    /// the top-level page's host like the content rules' `unless-top-url`.
    nonisolated static func source(table: String, siteExceptions: [String]) -> String? {
        let parts = table.components(separatedBy: "\u{1}")
        guard !table.isEmpty, parts.count == buckets else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) -> String? { (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } }
        guard let x = json(siteExceptions.map { $0.lowercased() }.sorted()) else { return nil }
        // Empty buckets are `0`; the rest are functions so their literals stay unbuilt.
        let functions = try? parts.map { part -> String in
            guard !part.isEmpty else { return "0" }
            guard let literal = json(part) else { throw CocoaError(.coderInvalidValue) }
            return "function () { return " + literal + "; }"
        }
        guard let functions else { return nil }
        return "(() => {\n'use strict';\nconst B = [" + functions.joined(separator: ",\n") + "], X = " + x + ";\n" + library
    }

    private nonisolated static let library = #"""
    let host, top;
    try {
      const a = location.ancestorOrigins;
      host = location.hostname;
      // about:blank and srcdoc frames have no host of their own; they run as their parent.
      if (!host && a && a.length) host = new URL(a[0]).hostname;
      top = host;
      if (a && a.length) top = new URL(a[a.length - 1]).hostname;
    } catch (e) { return; }
    if (!host || X.includes(top)) return;
    const labels = host.split('.'), keys = [''];
    for (let i = 0; i < labels.length; i++) {
      keys.push(labels.slice(i).join('.'));
      // Entities (`example.*`): any run of labels followed by at least one more label.
      // ponytail: no public-suffix list, so `example.*` also matches example.other.com.
      for (let j = i + 1; j < labels.length; j++) keys.push(labels.slice(i, j).join('.') + '.*');
    }
    const bucket = key => {
      const name = key.endsWith('.*') ? key : key.split('.').slice(-2).join('.');
      let h = 2166136261;
      for (let i = 0; i < name.length; i++) h = Math.imul(h ^ name.charCodeAt(i), 16777619) >>> 0;
      return h % B.length;
    };
    const texts = {};
    const line = (b, key) => {
      const T = texts[b] !== undefined ? texts[b] : (texts[b] = B[b] ? B[b]() : '');
      const at = T.indexOf('\n' + key + '\t');
      if (at < 0) return null;
      const start = at + key.length + 2, end = T.indexOf('\n', start);
      return JSON.parse(end < 0 ? T.slice(start) : T.slice(start, end));
    };
    const run = [], skip = new Set();
    for (const key of keys) {
      const found = line(bucket(key), key);
      if (!found) continue;
      run.push(...found[0]);
      for (const id of found[1]) skip.add(id);
    }
    if (!run.length) return;
    const calls = {};
    for (const id of new Set([...run, ...skip])) calls[id] = line(id % B.length, '#' + id);
    for (const id of skip) if (!calls[id].length) return; // `#@#+js()`
    start(run, skip, calls);

    // Only compiled when this frame has something to run.
    function start(run, skip, calls) {
    const W = window, R = Reflect, fnToStr = Function.prototype.toString;
    const parse = JSON.parse, stringify = JSON.stringify, own = Object.prototype.hasOwnProperty;
    const later = W.setTimeout && W.setTimeout.bind(W);
    const listen = W.EventTarget && EventTarget.prototype.addEventListener;
    const magic = Math.random().toString(36).slice(2);
    // Keep the abort scriptlets' errors out of the console and the page's error handlers.
    // Added up front, before any page script, so it sees the error before the page's own
    // capturing listeners do.
    if (listen) R.apply(listen, W, ['error', e => { if (String(e.message).includes(magic)) { e.preventDefault(); e.stopImmediatePropagation(); } }, true]);
    const abort = () => new ReferenceError(magic);

    // Patched functions are Proxies; toString answers for the original so a page
    // comparing `fetch.toString()` against native code sees native code.
    const masks = new WeakMap();
    let masked = false;
    const wrap = (owner, prop, apply) => {
      const orig = owner && owner[prop];
      if (typeof orig !== 'function') return;
      const proxy = new Proxy(orig, { apply });
      masks.set(proxy, masks.get(orig) || orig);
      if (!masked) {
        masked = true;
        const toStr = new Proxy(fnToStr, { apply: (t, self, a) => R.apply(t, masks.get(self) || self, a) });
        masks.set(toStr, fnToStr);
        Function.prototype.toString = toStr;
      }
      owner[prop] = proxy;
    };
    const fnText = fn => {
      try {
        if (typeof fn === 'function') return R.apply(fnToStr, masks.get(fn) || fn, []);
        if (fn && typeof fn.handleEvent === 'function') return R.apply(fnToStr, fn.handleEvent, []);
        return String(fn);
      } catch (e) { return ''; }
    };
    // '' matches everything, `/re/flags` is a regex, a leading `!` negates, else substring.
    const matcher = (raw = '') => {
      let not = false;
      if (raw.startsWith('!')) { not = true; raw = raw.slice(1); }
      const m = /^\/(.+)\/([imsu]*)$/.exec(raw);
      const re = m ? new RegExp(m[1], m[2]) : new RegExp(raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
      return s => re.test(String(s)) !== not;
    };
    const words = s => String(s || '').split(/\s+/).filter(Boolean);
    const pairs = list => { const o = {}; for (let i = 0; i + 1 < list.length; i += 2) o[list[i]] = list[i + 1]; return o; };
    const requestKeys = new Set(['url', 'method', 'body', 'credentials', 'cache', 'mode', 'redirect', 'referrer', 'referrerPolicy', 'integrity', 'headers']);
    // `propsToMatch`: `url:x method:/post/i` or a bare url pattern. null when empty.
    const props = raw => {
      const list = words(raw);
      if (!list.length) return null;
      const o = {};
      for (const part of list) {
        const i = part.indexOf(':');
        if (i > 0 && requestKeys.has(part.slice(0, i))) o[part.slice(0, i)] = matcher(part.slice(i + 1));
        else o.url = matcher(part);
      }
      return o;
    };
    const matches = (want, details) => Object.keys(want).every(k => want[k](details[k] == null ? '' : details[k]));
    const fetchDetails = a => {
      const [res, init] = a, d = {};
      const req = W.Request && res instanceof Request ? res : null;
      d.url = req ? req.url : String(res);
      for (const k of requestKeys) {
        if (k === 'url') continue;
        const v = init && init[k] !== undefined ? init[k] : req ? req[k] : undefined;
        if (v !== undefined) d[k] = typeof v === 'string' ? v : String(v);
      }
      if (!d.method) d.method = 'GET';
      return d;
    };
    const bodyText = name => ({ emptyObj: '{}', emptyArr: '[]', emptyStr: '', true: 'true', false: 'false' })[name] || '';

    // Walk `a.b.[].c` (`[]` and `*` mean every key) and call fn(owner, key) at the end.
    const walk = (o, keys, i, fn) => {
      if (o === null || typeof o !== 'object') return false;
      const k = keys[i], last = i === keys.length - 1;
      if (k === '[]' || k === '*') {
        let hit = false;
        for (const kk of Object.keys(o)) {
          if (last) { fn(o, kk); hit = true; } else if (walk(o[kk], keys, i + 1, fn)) hit = true;
        }
        return hit;
      }
      if (!own.call(o, k)) return false;
      if (last) { fn(o, k); return true; }
      return walk(o[k], keys, i + 1, fn);
    };
    const prune = (obj, prunePaths, needlePaths) => {
      if (obj === null || typeof obj !== 'object') return false;
      if (!needlePaths.every(p => walk(obj, p.split('.'), 0, () => {}))) return false;
      let hit = false;
      for (const p of prunePaths) if (walk(obj, p.split('.'), 0, (o, k) => { delete o[k]; })) hit = true;
      return hit;
    };

    // Trap a dotted property chain; `make(owner, prop)` installs the final property.
    // Missing links are trapped until the page assigns them.
    const trap = (chain, make) => {
      const step = (owner, path) => {
        const dot = path.indexOf('.');
        if (dot < 0) return make(owner, path);
        const prop = path.slice(0, dot), rest = path.slice(dot + 1);
        const v = owner[prop];
        if (v !== null && (typeof v === 'object' || typeof v === 'function')) return step(v, rest);
        if (v !== undefined) return;
        const d = Object.getOwnPropertyDescriptor(owner, prop);
        if (d && !d.configurable) return;
        let value;
        Object.defineProperty(owner, prop, {
          configurable: true, enumerable: !!(d && d.enumerable),
          get() { return value; },
          // A frozen or odd page value must not make the page's own assignment throw.
          set(n) { value = n; try { if (n !== null && (typeof n === 'object' || typeof n === 'function')) step(n, rest); } catch (e) {} },
        });
      };
      if (!chain) throw new Error('no property');
      step(W, chain);
    };
    const replaceable = (owner, prop) => {
      const d = Object.getOwnPropertyDescriptor(owner, prop);
      return !d || d.configurable ? d || {} : null;
    };
    const timer = name => (needle = '', delay = '') => {
      const match = matcher(needle), not = delay.startsWith('!');
      const want = (not ? delay.slice(1) : delay) === '' ? null : Number(not ? delay.slice(1) : delay);
      wrap(W, name, (t, self, a) => {
        if (match(fnText(a[0])) && (want === null || (Number(a[1] || 0) === want) !== not)) a = [function () {}, ...[...a].slice(1)];
        return R.apply(t, self, a);
      });
    };
    const domEdit = (selectorFor, filterFor, edit) => (raw = '', selector = '', behavior = '') => {
      const tokens = raw.split(/\s*\|\s*/).filter(Boolean);
      if (!tokens.length) return;
      const sel = selector || selectorFor(tokens);
      document.querySelector(sel); // A malformed selector throws here, not in every pass.
      let pending = 0;
      const pass = () => { pending = 0; for (const el of document.querySelectorAll(sel)) edit(el, tokens); };
      const observer = new MutationObserver(() => { if (!pending) pending = later(pass, 30); });
      pass();
      observer.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: filterFor(tokens) });
      if (!/\bstay\b/.test(behavior)) R.apply(listen, W, ['load', () => { observer.disconnect(); pass(); }, { once: true }]);
    };

    const S = {
      'set-constant'(chain, raw = '', ...rest) {
        const values = {
          undefined: undefined, false: false, true: true, null: null, '': '', emptyStr: '',
          noopFunc: function () {}, trueFunc: () => true, falseFunc: () => false,
          throwFunc: () => { throw new Error(); }, emptyObj: {}, '{}': {}, emptyArr: [], '[]': [],
          noopPromiseResolve: () => Promise.resolve(), noopPromiseReject: () => Promise.reject(),
        };
        let value;
        if (own.call(values, raw)) value = values[raw];
        else if (/^-?\d+$/.test(raw) && Math.abs(Number(raw)) <= 0x7fff) value = Number(raw);
        else return;
        const as = pairs(rest).as;
        if (as === 'function') { const v = value; value = () => v; }
        else if (as === 'callback') { const v = value; value = () => () => v; }
        else if (as === 'resolved') value = Promise.resolve(value);
        else if (as === 'rejected') { value = Promise.reject(value); value.catch(() => {}); }
        // A page value of a different type means the filter is stale; stop enforcing it.
        let gaveUp = false, pageValue;
        const stale = v => gaveUp || (v !== undefined && v !== null && value !== undefined && value !== null && typeof v !== typeof value);
        trap(chain, (owner, prop) => {
          const d = replaceable(owner, prop);
          if (!d || stale(owner[prop])) return;
          // Not configurable, so a page cannot quietly define the property back.
          Object.defineProperty(owner, prop, {
            configurable: false, enumerable: !!d.enumerable,
            get() { return gaveUp ? pageValue : value; },
            set(v) { if (stale(v)) { gaveUp = true; pageValue = v; } },
          });
        });
      },
      'abort-on-property-read'(chain) {
        trap(chain, (owner, prop) => {
          const d = replaceable(owner, prop);
          if (!d) return;
          Object.defineProperty(owner, prop, { configurable: true, enumerable: !!d.enumerable, get() { throw abort(); }, set() {} });
        });
      },
      'abort-on-property-write'(chain) {
        trap(chain, (owner, prop) => {
          const d = replaceable(owner, prop);
          if (!d) return;
          Object.defineProperty(owner, prop, { configurable: true, enumerable: !!d.enumerable, get() { return undefined; }, set() { throw abort(); } });
        });
      },
      'abort-current-script'(chain, needle = '', context = '') {
        const match = matcher(needle), inContext = matcher(context);
        // The script's own text: inline, or a `data:` URL's payload. An external file's text
        // is not readable here, so a needle never matches one.
        const text = s => {
          const t = s.text;
          if (t.trim() || !s.src.startsWith('data:')) return t;
          const comma = s.src.indexOf(',');
          if (comma < 0) return '';
          const head = s.src.slice(5, comma), body = s.src.slice(comma + 1);
          try { return /;base64$/i.test(head) ? atob(body) : decodeURIComponent(body); } catch (e) { return ''; }
        };
        trap(chain, (owner, prop) => {
          const d = replaceable(owner, prop);
          if (!d) return;
          let value = d.get ? undefined : owner[prop];
          const check = () => {
            const s = document.currentScript;
            if (!(s instanceof HTMLScriptElement)) return;
            if (inContext(s.src || '') && match(text(s))) throw abort();
          };
          Object.defineProperty(owner, prop, {
            configurable: true, enumerable: !!d.enumerable,
            get() { check(); return d.get ? R.apply(d.get, this, []) : value; },
            set(v) { check(); if (d.set) R.apply(d.set, this, [v]); else value = v; },
          });
        });
      },
      'no-setTimeout-if': timer('setTimeout'),
      'no-setInterval-if': timer('setInterval'),
      'prevent-fetch'(raw = '', body = '') {
        const want = props(raw);
        if (!want) return;
        wrap(W, 'fetch', (t, self, a) => {
          const d = fetchDetails(a);
          if (!matches(want, d)) return R.apply(t, self, a);
          const response = new Response(bodyText(body), { status: 200, statusText: 'OK' });
          Object.defineProperty(response, 'url', { value: d.url });
          return Promise.resolve(response);
        });
      },
      'prevent-xhr'(raw = '', body = '') {
        const want = props(raw);
        if (!want) return;
        const P = XMLHttpRequest.prototype, info = new WeakMap();
        wrap(P, 'open', (t, self, a) => { info.set(self, { method: String(a[0]), url: String(a[1]) }); return R.apply(t, self, a); });
        wrap(P, 'send', (t, self, a) => {
          const d = info.get(self);
          if (!d || !matches(want, d)) return R.apply(t, self, a);
          const text = bodyText(body);
          let response = text;
          if (self.responseType === 'json') { try { response = parse(text || 'null'); } catch (e) { response = null; } }
          const set = (k, v) => Object.defineProperty(self, k, { configurable: true, value: v });
          set('readyState', 4); set('status', 200); set('statusText', 'OK');
          set('responseText', text); set('response', response); set('responseURL', d.url);
          later(() => {
            self.dispatchEvent(new Event('readystatechange'));
            self.dispatchEvent(new ProgressEvent('load'));
            self.dispatchEvent(new ProgressEvent('loadend'));
          }, 1);
        });
      },
      'remove-attr': domEdit(t => t.map(a => '[' + CSS.escape(a) + ']').join(','), t => t,
        (el, t) => { for (const a of t) el.removeAttribute(a); }),
      'remove-class': domEdit(t => t.map(c => '.' + CSS.escape(c)).join(','), () => ['class'],
        (el, t) => el.classList.remove(...t)),
      'addEventListener-defuser'(type = '', needle = '', ...rest) {
        const mt = matcher(type), mn = matcher(needle), elements = pairs(rest).elements || '';
        // `elements`: only listeners on these targets (`window`, `document` or a selector).
        const on = self => !elements || (elements === 'window' ? self === W : elements === 'document' ? self === document
          : !!self && typeof self.matches === 'function' && self.matches(elements));
        wrap(EventTarget.prototype, 'addEventListener', (t, self, a) => {
          let hit = false;
          try { hit = mt(a[0]) && mn(fnText(a[1])) && on(self); } catch (e) {}
          if (hit) return undefined;
          return R.apply(t, self, a);
        });
      },
      'window.open-defuser'(pattern = '') {
        // Old `window.open-defuser` took `1`/`0` first; `0` inverted the needle.
        let raw = pattern;
        if (raw === '1' || raw === '0') raw = (raw === '0' ? '!' : '') + (arguments[1] || '');
        const match = matcher(raw);
        wrap(W, 'open', (t, self, a) => match(a[0] == null ? '' : a[0]) ? null : R.apply(t, self, a));
      },
      'json-prune'(rawPrune = '', rawNeedle = '') {
        const pp = words(rawPrune), np = words(rawNeedle);
        if (!pp.length) return;
        wrap(JSON, 'parse', (t, self, a) => { const r = R.apply(t, self, a); prune(r, pp, np); return r; });
        if (W.Response) wrap(Response.prototype, 'json', (t, self, a) => R.apply(t, self, a).then(r => { prune(r, pp, np); return r; }));
      },
      'json-prune-fetch-response'(rawPrune = '', rawNeedle = '', ...rest) {
        const pp = words(rawPrune), np = words(rawNeedle), want = props(pairs(rest).propsToMatch);
        if (!pp.length) return;
        wrap(W, 'fetch', (t, self, a) => {
          const p = R.apply(t, self, a);
          if (want && !matches(want, fetchDetails(a))) return p;
          return p.then(response => response.clone().text().then(text => {
            let obj;
            try { obj = parse(text); } catch (e) { return response; }
            if (!prune(obj, pp, np)) return response;
            const headers = new Headers(response.headers);
            headers.delete('content-length'); headers.delete('content-encoding');
            const fresh = new Response(stringify(obj), { status: response.status, statusText: response.statusText, headers });
            Object.defineProperty(fresh, 'url', { value: response.url });
            Object.defineProperty(fresh, 'type', { value: response.type });
            return fresh;
          }, () => response));
        });
      },
      'json-prune-xhr-response'(rawPrune = '', rawNeedle = '', ...rest) {
        const pp = words(rawPrune), np = words(rawNeedle), want = props(pairs(rest).propsToMatch);
        if (!pp.length) return;
        const P = XMLHttpRequest.prototype;
        const getResponse = Object.getOwnPropertyDescriptor(P, 'response').get;
        const getText = Object.getOwnPropertyDescriptor(P, 'responseText').get;
        wrap(P, 'open', (t, self, a) => {
          const r = R.apply(t, self, a);
          if (want && !matches(want, { method: String(a[0]), url: String(a[1]) })) return r;
          let done = false, text;
          const fix = () => {
            if (done || self.readyState !== 4) return;
            done = true;
            const raw = R.apply(getResponse, self, []);
            if (typeof raw !== 'string') { prune(raw, pp, np); return; } // responseType json: in place.
            try { const obj = parse(raw); if (prune(obj, pp, np)) text = stringify(obj); } catch (e) {}
          };
          Object.defineProperty(self, 'response', { configurable: true, get() { fix(); return text !== undefined ? text : R.apply(getResponse, self, []); } });
          Object.defineProperty(self, 'responseText', { configurable: true, get() { fix(); return text !== undefined ? text : R.apply(getText, self, []); } });
          return r;
        });
      },
    };

    const seen = new Set();
    for (const id of run) {
      const call = calls[id];
      if (skip.has(id) || seen.has(id) || !own.call(S, call[0])) continue;
      seen.add(id);
      try { S[call[0]](...call.slice(1)); } catch (e) {}
    }
    }
    })();
    """#
}
