import AppKit
import UniformTypeIdentifiers
import WebKit

/// The File System Access pickers (`showOpenFilePicker`, `showSaveFilePicker`,
/// `showDirectoryPicker`) for system WebKit, which ships the handle classes for the origin
/// private file system but no way to reach the user's own files.
///
/// A page script makes handles that are `instanceof` WebKit's own `FileSystemFileHandle`
/// and `FileSystemDirectoryHandle` (their prototypes are WebKit's, and those prototypes'
/// methods are wrapped so they serve both kinds) and forwards each call here.
/// FileSystemAccessDisk.swift does the I/O, off the main thread. The page script is the
/// page's own and is trusted with nothing: every message is checked again on this side.
///
/// Access is only to what the user picked, only from a main-frame document in a secure
/// context, and only for that document: a reload, navigation or closed tab ends it. The
/// page holds an opaque token per pick, never a path. Tokens live in memory for this run of
/// the app, so a handle a page kept in IndexedDB can ask again after a reload
/// (`requestPermission`), as in Chrome; nothing is saved to disk.
@MainActor enum FileSystemAccess {
    typealias Scope = SitePermissions.Scope
    typealias Kind = FileAccessDisk.Kind
    static let messageName = "vaneFileAccess"
    static let gestureName = "vaneFileAccessGesture"
    /// Page code cannot reach this world, so "the user just clicked" is not the page's to claim.
    static let gestureWorld = WKContentWorld.world(name: "vane-file-access")
    static let gestureEvent = "vane-file-access-request"
    /// Bytes per message each way. Base64 makes each about 5.6 MB of text.
    nonisolated static let chunk = 4 * 1024 * 1024
    /// Open `createWritable()` streams per document.
    static let maxWritables = 32

    /// One request per real input event: `isActive` stays true for seconds after a click, so
    /// without `used` one click could chain picker after picker.
    /// A global of the isolated world, which the page can't see; tests reset it as a click would.
    static let gestureUsed = "vaneFileAccessGestureUsed"
    static let gestureScript = """
    var \(gestureUsed) = false;
    for (const type of ['keydown', 'pointerdown', 'touchend']) {    // once per physical click or key
      addEventListener(type, e => { if (e.isTrusted) \(gestureUsed) = false; }, true);
    }
    addEventListener('\(gestureEvent)', () => {
      if (\(gestureUsed) || !navigator.userActivation.isActive) return;
      \(gestureUsed) = true;
      webkit.messageHandlers.\(gestureName).postMessage(1);
    }, true);
    """

    /// Definitions only: nothing runs, listens or posts until the page uses the API.
    static let script = """
    (() => {
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(messageName);
      if (!isSecureContext || !handler || 'showOpenFilePicker' in window || typeof FileSystemHandle !== 'function'
          || typeof FileSystemFileHandle !== 'function' || typeof FileSystemDirectoryHandle !== 'function') return;
      const post = handler.postMessage.bind(handler);
      const activation = navigator.userActivation;
      const toBase64 = Uint8Array.prototype.toBase64, fromBase64 = Uint8Array.fromBase64;
      const define = Object.defineProperty, describe = Object.getOwnPropertyDescriptor, freeze = Object.freeze;
      const tag = value => Object.prototype.toString.call(value);
      const fail = (name, message) => name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
      const call = async (op, args) => {
        let reply;
        try { reply = await post({ op, ...args }); } catch (e) { throw fail('NotAllowedError', 'File access is not available.'); }
        if (reply && reply.error) throw fail(reply.error[0], reply.error[1]);
        return reply ? reply.value : undefined;
      };
      const quiet = promise => promise.catch(() => {});
      const gesture = () => {
        if (!activation.isActive) return false;
        dispatchEvent(new Event('\(gestureEvent)'));
        return true;
      };

      // A handle is WebKit's own prototype with a slot that says which pick it came from.
      // The copy under MARK is enumerable so a structured clone (IndexedDB) keeps it.
      const MARK = '__vaneFileSystemHandle';
      const slots = new WeakMap(), streams = new WeakSet();
      const H = FileSystemHandle.prototype, F = FileSystemFileHandle.prototype, D = FileSystemDirectoryHandle.prototype;
      const make = (root, path, kind, name) => {
        const handle = Object.create(kind === 'file' ? F : D);
        path = freeze([...path]);
        slots.set(handle, { root, path, kind, name });
        define(handle, MARK, { value: freeze({ root, path, kind, name }), enumerable: true });
        return handle;
      };
      const slot = (handle, kind) => {
        const s = slots.get(handle);
        if (!s || (kind && s.kind !== kind)) throw new TypeError('Illegal invocation');
        return s;
      };
      const ref = s => ({ root: s.root, path: s.path });
      // Ours when `this` (or, for comparisons, the argument) is ours; WebKit's otherwise.
      const method = (proto, key, ours, fallback, mine = self => slots.has(self) || streams.has(self)) => {
        const native = proto[key] || fallback;
        define(proto, key, { configurable: true, enumerable: true, writable: true, value: { [key](...args) {
          return mine(this, args) ? ours.apply(this, args) : native.apply(this, args);
        } }[key] });
      };
      for (const key of ['kind', 'name']) {
        const d = describe(H, key);
        define(H, key, { ...d, get() { const s = slots.get(this); return s ? s[key] : d.get.call(this); } });
      }
      const modeOf = d => {
        const mode = d && d.mode !== undefined ? String(d.mode) : 'read';
        if (mode !== 'read' && mode !== 'readwrite') throw new TypeError(`The provided value '${mode}' is not a valid enum value of type FileSystemPermissionMode.`);
        return mode;
      };
      // The origin private file system is always granted, as in Chrome.
      const opfs = async () => 'granted';
      const either = (self, args) => slots.has(self) || slots.has(args[0]);

      method(H, 'isSameEntry', async function (other) {
        const a = slots.get(this), b = slots.get(other);
        if (!a || !b || a.kind !== b.kind) return false;
        return call('same', { a: ref(a), b: ref(b) });
      }, null, either);
      method(H, 'queryPermission', async function (d) {
        return call('query', { h: ref(slot(this)), mode: modeOf(d) });
      }, opfs);
      method(H, 'requestPermission', async function (d) {
        const s = slot(this), mode = modeOf(d);
        const state = await call('query', { h: ref(s), mode });
        if (state !== 'prompt') return state;
        if (!gesture()) throw fail('SecurityError', 'User activation is required to request permissions.');
        return call('request', { h: ref(s), mode });
      }, opfs);

      method(F, 'getFile', async function () {
        const s = slot(this, 'file'), parts = [];
        let info = null, at = 0;
        for (;;) {
          const r = await call('read', { h: ref(s), at, ...(info ? { size: info.size, modified: info.modified } : {}) });
          info = info || r;
          const bytes = fromBase64.call(Uint8Array, r.data);
          parts.push(bytes);
          at += bytes.length;
          if (!bytes.length || at >= info.size) break;
        }
        return new File(parts, s.name, { type: info.type, lastModified: info.modified });
      });
      method(F, 'createWritable', async function (options) {
        const s = slot(this, 'file');
        return writable(await call('open', { h: ref(s), keep: !!(options && options.keepExistingData) }));
      });

      const child = kind => async function (name, options) {
        const s = slot(this, 'directory');
        name = String(name);
        await call('child', { h: ref(s), name, kind, create: !!(options && options.create) });
        return make(s.root, [...s.path, name], kind, name);
      };
      method(D, 'getFileHandle', child('file'));
      method(D, 'getDirectoryHandle', child('directory'));
      method(D, 'removeEntry', async function (name, options) {
        await call('remove', { h: ref(slot(this, 'directory')), name: String(name), recursive: !!(options && options.recursive) });
      });
      method(D, 'resolve', async function (other) {
        const s = slots.get(this), o = slots.get(other);
        return s && o ? call('resolve', { a: ref(s), b: ref(o) }) : null;
      }, null, either);
      async function* iterate(handle, shape) {
        const s = slot(handle, 'directory');
        for (const [name, kind] of await call('list', { h: ref(s) })) {
          if (shape === 'keys') { yield name; continue; }
          const entry = make(s.root, [...s.path, name], kind, name);
          yield shape === 'values' ? entry : [name, entry];
        }
      }
      for (const [key, shape] of [['entries', 'entries'], ['keys', 'keys'], ['values', 'values'], [Symbol.asyncIterator, 'entries']]) {
        method(D, key, function () { return iterate(this, shape); });
      }

      // A real WritableStream with WebKit's FileSystemWritableFileStream prototype, where
      // this WebKit has one.
      let Writable = window.FileSystemWritableFileStream;
      if (typeof Writable !== 'function') {
        Writable = function FileSystemWritableFileStream() { throw new TypeError('Illegal constructor'); };
        Object.setPrototypeOf(Writable, WritableStream);
        Writable.prototype = Object.create(WritableStream.prototype, {
          constructor: { value: Writable, writable: true, configurable: true },
          [Symbol.toStringTag]: { value: 'FileSystemWritableFileStream', configurable: true } });
        define(window, 'FileSystemWritableFileStream', { value: Writable, writable: true, configurable: true });
      }
      const W = Writable.prototype;
      const viaWriter = (stream, chunk) => {
        const writer = stream.getWriter();
        const result = writer.write(chunk);
        writer.releaseLock();
        return result;
      };
      method(W, 'write', async function (data) { return viaWriter(this, data); });
      method(W, 'seek', async function (position) { return viaWriter(this, { type: 'seek', position }); });
      method(W, 'truncate', async function (size) { return viaWriter(this, { type: 'truncate', size }); });

      const CHUNK = \(chunk);
      const isBlob = value => value instanceof Blob || tag(value) === '[object Blob]' || tag(value) === '[object File]';
      const send = async (id, data, position) => {
        const at = position === undefined || position === null ? {} : { position: Number(position) };
        if (isBlob(data)) {
          let offset = 0;
          do {
            const piece = new Uint8Array(await data.slice(offset, offset + CHUNK).arrayBuffer());
            await call('write', { id, data: toBase64.call(piece), ...(offset ? {} : at) });
            offset += CHUNK;
          } while (offset < data.size);
          return;
        }
        let bytes;
        if (typeof data === 'string') bytes = new TextEncoder().encode(data);
        else if (ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        else if (tag(data) === '[object ArrayBuffer]' || tag(data) === '[object SharedArrayBuffer]') bytes = new Uint8Array(data);
        else throw new TypeError('The provided value is not of type (BufferSource or Blob or USVString or WriteParams).');
        let offset = 0;
        do {
          await call('write', { id, data: toBase64.call(bytes.slice(offset, offset + CHUNK)), ...(offset ? {} : at) });
          offset += CHUNK;
        } while (offset < bytes.length);
      };
      const isParams = c => c !== null && typeof c === 'object' && typeof c !== 'string' && !ArrayBuffer.isView(c) && !isBlob(c)
        && tag(c) !== '[object ArrayBuffer]' && tag(c) !== '[object SharedArrayBuffer]';
      const missing = value => value === undefined || value === null;
      const writable = id => {
        const stream = new WritableStream({
          async write(chunk) {
            try {
              if (!isParams(chunk)) return await send(id, chunk);
              if (chunk.type === 'write') {
                if (missing(chunk.data)) throw fail('SyntaxError', 'write requires a non-null data.');
                return await send(id, chunk.data, chunk.position);
              }
              if (chunk.type === 'seek') {
                if (missing(chunk.position)) throw fail('SyntaxError', 'seek requires a position.');
                return await call('seek', { id, position: Number(chunk.position) });
              }
              if (chunk.type === 'truncate') {
                if (missing(chunk.size)) throw fail('SyntaxError', 'truncate requires a size.');
                return await call('truncate', { id, size: Number(chunk.size) });
              }
              throw new TypeError(`The provided value '${chunk.type}' is not a valid enum value of type WriteCommandType.`);
            } catch (error) {
              // An errored stream is finished: the copy goes and the file is left as it was.
              quiet(call('abort', { id }));
              throw error;
            }
          },
          close() { return call('close', { id }); },
          abort() { return quiet(call('abort', { id })); },
        });
        Object.setPrototypeOf(stream, W);
        streams.add(stream);
        return stream;
      };

      const typesOf = list => {
        if (list === undefined) return [];
        if (!list || typeof list[Symbol.iterator] !== 'function') throw new TypeError('types must be a sequence.');
        return Array.from(list, t => {
          const accept = {};
          if (t && t.accept && typeof t.accept === 'object') {
            for (const [mime, ext] of Object.entries(t.accept)) accept[mime] = typeof ext === 'string' ? [ext] : Array.from(ext, String);
          }
          return accept;
        });
      };
      const picker = type => async function (options) {
        options = options && typeof options === 'object' ? options : {};
        const sent = { types: typesOf(options.types), excludeAcceptAllOption: !!options.excludeAcceptAllOption, multiple: !!options.multiple };
        if (options.id !== undefined) sent.id = String(options.id);
        if (!missing(options.suggestedName)) sent.suggestedName = String(options.suggestedName);
        if (type === 'directory') sent.mode = modeOf(options);
        if (options.startIn !== undefined) {
          const s = slots.get(options.startIn);
          if (s) sent.startIn = ref(s);
          else if (typeof options.startIn !== 'object') sent.startIn = String(options.startIn);
        }
        if (!gesture()) throw fail('SecurityError', 'Must be handling a user gesture to show a file picker.');
        const handles = (await call('pick', { type, options: sent })).map(p => make(p.root, [], p.kind, p.name));
        return type === 'open' ? handles : handles[0];
      };
      for (const [name, type] of [['showOpenFilePicker', 'open'], ['showSaveFilePicker', 'save'], ['showDirectoryPicker', 'directory']]) {
        define(window, name, { value: picker(type), writable: true, configurable: true, enumerable: true });
      }

      // A handle read back from IndexedDB is a plain object carrying MARK; make it a handle
      // again. Only a stored value itself (or an array of them, for getAll) is looked at.
      const revived = new WeakMap();
      const revive = value => {
        if (value === null || typeof value !== 'object') return value;
        if (revived.has(value)) return revived.get(value);
        let out = value;
        if (Array.isArray(value)) {
          if (value.some(v => v && typeof v === 'object' && !Array.isArray(v) && v[MARK])) out = value.map(revive);
        } else {
          const m = value[MARK];
          if (m && typeof m === 'object' && !slots.has(value) && typeof m.root === 'string' && Array.isArray(m.path)
              && m.path.every(p => typeof p === 'string') && (m.kind === 'file' || m.kind === 'directory') && typeof m.name === 'string') {
            out = make(m.root, m.path, m.kind, m.name);
          }
        }
        revived.set(value, out);
        return out;
      };
      for (const [proto, key] of [[IDBRequest.prototype, 'result'], [IDBCursorWithValue.prototype, 'value']]) {
        const d = describe(proto, key);
        if (d && d.get) define(proto, key, { ...d, get() { return revive(d.get.call(this)); } });
      }
    })();
    """

    /// Main frame only: `WKFrameInfo` cannot say whether a parent's Permissions Policy let a
    /// child frame have file access, so frames get no pickers rather than a guessed answer.
    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: gestureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: gestureWorld))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    static func attach(_ tab: Tab, to web: WKWebView) {
        let bridge = Bridge(tab), controller = web.configuration.userContentController
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: messageName)
        controller.addScriptMessageHandler(bridge, contentWorld: gestureWorld, name: gestureName)
    }

    static func detach(from web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        web.configuration.userContentController.removeScriptMessageHandler(forName: gestureName, contentWorld: gestureWorld)
    }

    private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            do throws(FileAccessError) { return (["value": try await FileSystemAccess.handle(message, tab: tab) ?? NSNull()], nil) }
            catch { return (["error": [error.name, error.message]], nil) }
        }
    }

    // MARK: - What was picked, and what this document may do with it

    enum Mode: Int, Comparable, Sendable {
        case read = 1, readwrite = 2
        init(_ value: Any?) throws(FileAccessError) {
            switch value as? String {
            case nil, "read"?: self = .read
            case "readwrite"?: self = .readwrite
            default: throw .type("Invalid permission mode.")
            }
        }
        static func < (a: Mode, b: Mode) -> Bool { a.rawValue < b.rawValue }
    }

    struct Root: Sendable {
        let path: String
        let kind: Kind
        let name: String
    }

    /// Per origin and profile (and private tab), for this run of the app only.
    private static var roots: [Scope: [String: Root]] = [:]
    /// The folder each picker `id` last ended up in, as Chrome remembers it.
    private static var lastDirectory: [Scope: [String: URL]] = [:]

    private static func register(_ root: Root, scope: Scope) -> String {
        if let token = roots[scope]?.first(where: { $0.value.path == root.path && $0.value.kind == root.kind })?.key { return token }
        let token = UUID().uuidString
        roots[scope, default: [:]][token] = root
        return token
    }

    static func forgetPrivate(tabID: UUID) {
        roots = roots.filter { $0.key.privateTabID != tabID }
        lastDirectory = lastDirectory.filter { $0.key.privateTabID != tabID }
    }

    /// One document's grants, picker and open writes.
    @MainActor private final class Session {
        let scope: Scope
        var grants: [String: Mode] = [:]
        /// Picks the user answered "Don't Allow" for in this document: asked again, `denied`.
        var denied: Set<String> = []
        var gesture: ContinuousClock.Instant?
        /// A picker or a permission bubble is up.
        var busy = false
        var panel: NSSavePanel?
        var waiting: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var prompt: SitePermissionPrompt?
        weak var window: NSWindow?
        var swaps: [String: (swap: FileAccessDisk.Swap, ref: Ref)] = [:]
        /// A write stream mid-call: the page script waits for each one, so a second is forged.
        var writing: Set<String> = []
        init(scope: Scope) { self.scope = scope }

        func grant(_ token: String, _ mode: Mode) { grants[token] = max(grants[token] ?? mode, mode) }

        func answer(_ response: NSApplication.ModalResponse) {
            waiting?.resume(returning: response)
            waiting = nil
        }

        func dismiss() {
            panel?.cancel(nil)
            answer(.abort)
            prompt?.finish(.abort)
        }

        /// Writes not closed are dropped; the files they were for are untouched.
        func end() {
            dismiss()
            let open = swaps.values.map(\.swap)
            swaps.removeAll()
            grants.removeAll()
            for swap in open { swap.queue.async { FileAccessDisk.discard(swap) } }
        }
    }
    private static var sessions: [UUID: Session] = [:]

    /// A new document, or none. A navigation that has only started takes the picker and the
    /// bubble down but keeps the grants, because it may yet turn into a download.
    static func endDocument(tabID: UUID, navigationStarted: Bool = false) {
        guard let session = sessions[tabID] else { return }
        if navigationStarted { session.dismiss(); return }
        sessions.removeValue(forKey: tabID)
        session.end()
    }

    /// The bubble open in this window, if any, so no other permission question stacks on it.
    static func prompt(in window: NSWindow) -> SitePermissionPrompt? {
        sessions.values.first { $0.prompt != nil && $0.window === window }?.prompt
    }

    #if DEBUG
    /// Fixtures answer the panel and the bubble themselves: nothing is shown.
    static var pickerForTesting: ((PickRequest) -> [URL]?)?
    static var promptForTesting: ((Mode, String) -> NSApplication.ModalResponse)?
    static func hasSession(tabID: UUID) -> Bool { sessions[tabID] != nil }
    #endif

    // MARK: - Who may ask

    /// HTTPS, or HTTP to this Mac itself: the page's own `isSecureContext`.
    nonisolated static func isSecure(_ scope: Scope) -> Bool {
        if scope.scheme == "https" { return true }
        let host = scope.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        var v4 = in_addr()
        return inet_pton(AF_INET, host, &v4) == 1 && v4.s_addr & 0xff == 127    // network order: first octet
    }

    private static func scope(of message: WKScriptMessage, tab: Tab) -> Scope? {
        let origin = message.frameInfo.securityOrigin
        guard let scope = Scope(scheme: origin.protocol, host: origin.host, port: origin.port, profileID: tab.profileID,
                                privateTabID: tab.isPrivate ? tab.id : nil), isSecure(scope) else { return nil }
        return scope
    }

    private static func session(tab: Tab, scope: Scope) -> Session {
        if let session = sessions[tab.id], session.scope == scope { return session }
        endDocument(tabID: tab.id)
        let session = Session(scope: scope)
        sessions[tab.id] = session
        return session
    }

    /// The isolated world saw the request while the page had transient activation. One use.
    private static func takeGesture(_ session: Session) -> Bool {
        defer { session.gesture = nil }
        return session.gesture.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
    }

    struct Ref: Sendable {
        let token: String
        let root: Root
        let path: [String]
        func resolve() throws(FileAccessError) -> String { try FileAccessDisk.resolve(root: root.path, path) }
    }

    private static func ref(_ value: Any?, scope: Scope) throws(FileAccessError) -> Ref {
        guard let body = value as? [String: Any], let token = body["root"] as? String,
              let path = body["path"] as? [String], path.count < 4096 else { throw .type("Invalid handle.") }
        guard path.allSatisfy(FileAccessDisk.isValidName) else { throw .badName }
        guard let root = roots[scope]?[token] else { throw .notFound }
        return Ref(token: token, root: root, path: path)
    }

    private static func require(_ mode: Mode, _ ref: Ref, _ session: Session) throws(FileAccessError) {
        guard let granted = session.grants[ref.token], granted >= mode else { throw .notAllowed() }
    }

    /// A byte offset or size from the page: a whole number a double holds exactly.
    private static func offset(_ value: Any?) throws(FileAccessError) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, let whole = Int64(exactly: number.doubleValue),
              (0...(1 << 53)).contains(whole) else { throw .type("Invalid position or size.") }
        return whole
    }

    /// File work off the main thread; a write stream's work on that stream's own queue.
    nonisolated private static func io<T: Sendable>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                                    _ work: @escaping @Sendable () throws(FileAccessError) -> T)
        async throws(FileAccessError) -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, FileAccessError>, Never>) in
            queue.async { continuation.resume(returning: Result(catching: work)) }
        }
        return try result.get()
    }

    // MARK: - One call from the page

    private static func handle(_ message: WKScriptMessage, tab: Tab?) async throws(FileAccessError) -> Any? {
        let unavailable = FileAccessError.notAllowed("File access is not available to this page.")
        guard let tab, !tab.tornDown, let web = tab.existingWeb, message.webView === web, message.frameInfo.isMainFrame,
              let scope = scope(of: message, tab: tab) else { throw unavailable }
        let session = session(tab: tab, scope: scope)
        if message.name == gestureName { session.gesture = .now; return nil }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { throw unavailable }
        // Work that waits can outlive its document; nothing it produced may be handed on then.
        var current: Bool { sessions[tab.id] === session && tab.existingWeb === web }

        switch op {
        case "pick":
            return try await pick(body, session: session, tab: tab, web: web) { current }
        case "query":
            let mode = try Mode(body["mode"])
            guard let token = (body["h"] as? [String: Any])?["root"] as? String else { return "prompt" }
            if let granted = session.grants[token], granted >= mode { return "granted" }
            return session.denied.contains(token) ? "denied" : "prompt"
        case "request":
            let mode = try Mode(body["mode"]), target = try ref(body["h"], scope: scope)
            if let granted = session.grants[target.token], granted >= mode { return "granted" }
            if session.denied.contains(target.token) { return "denied" }
            guard takeGesture(session) else {
                throw FileAccessError(name: "SecurityError", message: "User activation is required to request permissions.")
            }
            guard !session.busy else { throw .notAllowed("A permission request is already active.") }
            session.busy = true
            defer { session.busy = false }
            let response = await ask(mode, root: target.root, session: session, tab: tab, web: web)
            guard current else { throw .abort }
            switch response {
            case .alertFirstButtonReturn, .alertSecondButtonReturn:
                session.grant(target.token, mode)
                return "granted"
            case .alertThirdButtonReturn:
                session.denied.insert(target.token)
                return "denied"
            default: return "prompt"
            }
        case "open", "write", "seek", "truncate", "close", "abort":
            return try await stream(op, body, session: session, tab: tab)
        case "same", "resolve":
            let a = try ref(body["a"], scope: scope), b = try ref(body["b"], scope: scope)
            if a.token == b.token, a.path == b.path { return op == "same" ? true : [String]() }
            if op == "resolve", a.token == b.token, b.path.starts(with: a.path) { return Array(b.path.dropFirst(a.path.count)) }
            // Real paths from here on, so the answer says nothing about entries the page can't read.
            try require(.read, a, session)
            try require(.read, b, session)
            let relative = try await io { () throws(FileAccessError) -> [String]? in
                guard let parent = try? a.resolve(), let child = try? b.resolve() else { return nil }
                return FileAccessDisk.relative(from: parent, to: child)
            }
            return op == "same" ? relative == [] : relative ?? NSNull()
        default: break
        }

        let target = try ref(body["h"], scope: scope)
        switch op {
        case "child":
            guard let name = body["name"] as? String, let kind = (body["kind"] as? String).flatMap(Kind.init) else { throw .badName }
            let create = body["create"] as? Bool ?? false
            try require(create ? .readwrite : .read, target, session)
            try await io { () throws(FileAccessError) in
                try FileAccessDisk.child(root: target.root.path, target.path, name: name, kind: kind, create: create)
            }
            return nil
        case "list":
            try require(.read, target, session)
            return try await io { () throws(FileAccessError) in
                try FileAccessDisk.list(root: target.root.path, target.path).map { [$0.name, $0.kind.rawValue] }
            }
        case "remove":
            guard let name = body["name"] as? String else { throw .badName }
            let recursive = body["recursive"] as? Bool ?? false
            try require(.readwrite, target, session)
            try await io { () throws(FileAccessError) in
                try FileAccessDisk.remove(root: target.root.path, target.path, name: name, recursive: recursive)
            }
            return nil
        case "read":
            try require(.read, target, session)
            let at = try offset(body["at"]) ?? 0
            let size = try offset(body["size"]), modified = try offset(body["modified"])
            let expect = size.flatMap { size in modified.map { (size: size, modified: $0) } }
            let name = target.root.name, last = target.path.last ?? name
            let piece = try await io { () throws(FileAccessError) in
                let piece = try FileAccessDisk.read(try target.resolve(), at: at, length: chunk, expect: expect)
                return (data: piece.data.base64EncodedString(), size: piece.size, modified: piece.modified)
            }
            guard current else { throw .abort }
            return ["data": piece.data, "size": piece.size, "modified": piece.modified, "type": FileAccessDisk.mimeType(of: last)]
        default:
            throw .type("Unknown file operation.")
        }
    }

    /// `createWritable()` and everything its stream does.
    private static func stream(_ op: String, _ body: [String: Any], session: Session, tab: Tab) async throws(FileAccessError) -> Any? {
        if op == "open" {
            let target = try ref(body["h"], scope: session.scope)
            try require(.readwrite, target, session)
            // Each holds a descriptor and a copy on disk; a page doesn't get to pile them up.
            guard session.swaps.count < maxWritables else {
                throw FileAccessError(name: "QuotaExceededError", message: "Too many files are open for writing.")
            }
            let keep = body["keep"] as? Bool ?? false
            let swap = try await io { () throws(FileAccessError) in
                try FileAccessDisk.openSwap(try target.resolve(), keepExistingData: keep)
            }
            guard sessions[tab.id] === session, session.swaps.count < maxWritables else {
                swap.queue.async { FileAccessDisk.discard(swap) }
                throw .abort
            }
            let id = UUID().uuidString
            session.swaps[id] = (swap, target)
            return id
        }
        let closed = FileAccessError.type("The stream is closed.")
        guard let id = body["id"] as? String, let (swap, target) = session.swaps[id] else { throw closed }
        guard session.writing.insert(id).inserted else { throw FileAccessError(name: "InvalidStateError", message: "A write is already in progress.") }
        defer { session.writing.remove(id) }
        switch op {
        case "write":
            // The page script sends at most `chunk` bytes a message; anything larger did not come from it.
            guard let text = body["data"] as? String, text.utf8.count <= (chunk / 3 + 1) * 4 else { throw .type("Invalid data.") }
            let position = try offset(body["position"])
            try await io(on: swap.queue) { () throws(FileAccessError) in
                guard let data = Data(base64Encoded: text) else { throw .type("Invalid data.") }
                try FileAccessDisk.write(swap, data, at: position)
            }
        case "seek":
            guard let position = try offset(body["position"]) else { throw .type("Invalid position.") }
            try await io(on: swap.queue) { () throws(FileAccessError) in swap.cursor = position }
        case "truncate":
            guard let size = try offset(body["size"]) else { throw .type("Invalid size.") }
            try await io(on: swap.queue) { () throws(FileAccessError) in try FileAccessDisk.truncate(swap, to: size) }
        case "abort":
            session.swaps.removeValue(forKey: id)
            swap.queue.async { FileAccessDisk.discard(swap) }
        default:    // close
            session.swaps.removeValue(forKey: id)
            guard (session.grants[target.token] ?? .read) >= .readwrite else {
                swap.queue.async { FileAccessDisk.discard(swap) }
                throw .notAllowed()
            }
            let page = tab.currentURL, isPrivate = tab.isPrivate
            try await io(on: swap.queue) { () throws(FileAccessError) in
                let written = try FileAccessDisk.commit(swap, root: target.root.path, target.path)
                // What a site wrote is marked as from the web, as Chrome and downloads mark it.
                Downloads.quarantine(URL(fileURLWithPath: written), source: nil, page: page, isPrivate: isPrivate)
            }
        }
        return nil
    }

    // MARK: - Pickers

    /// The options a picker was called with, checked as Chrome checks them.
    struct PickRequest: Sendable {
        enum Kind: String, Sendable { case open, save, directory }
        let kind: Kind
        var multiple = false
        var acceptAll = true
        var contentTypes: [UTType] = []
        var suggestedName: String?
        var id = ""
        var startIn: String?
        var startHandle: String?
        var startPath: [String] = []
        var mode = Mode.read

        static let wellKnown = ["desktop": "Desktop", "documents": "Documents", "downloads": "Downloads",
                                "music": "Music", "pictures": "Pictures", "videos": "Movies"]

        init(type: Any?, options: [String: Any]) throws(FileAccessError) {
            guard let kind = (type as? String).flatMap(Kind.init) else { throw .type("Unknown picker.") }
            self.kind = kind
            multiple = kind == .open && options["multiple"] as? Bool == true
            let types = options["types"] as? [[String: Any]] ?? []
            for accept in types {
                for (mime, extensions) in accept {
                    let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
                    let token = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-*".contains($0)) } }
                    guard parts.count == 2, token(parts[0]), token(parts[1]) else { throw .type("Invalid type: \(mime)") }
                    if parts[1] == "*" {
                        if let wild = ["image": UTType.image, "audio": .audio, "video": .movie, "text": .text][String(parts[0])] {
                            contentTypes.append(wild)
                        }
                    } else if let type = UTType(mimeType: mime), !type.isDynamic {
                        contentTypes.append(type)
                    }
                    for ext in extensions as? [String] ?? [] {
                        guard ext.hasPrefix(".") else { throw .type("Extension '\(ext)' must start with '.'.") }
                        guard ext.count <= 17, !ext.hasSuffix("."),
                              ext.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == ".") })
                        else { throw .type("Extension '\(ext)' contains invalid characters.") }
                        if let type = UTType(filenameExtension: String(ext.dropFirst())) { contentTypes.append(type) }
                    }
                }
            }
            acceptAll = kind == .directory || options["excludeAcceptAllOption"] as? Bool != true
            if !acceptAll && types.isEmpty { throw .type("Need at least one accepted type") }
            if let id = options["id"] as? String {
                guard id.count <= 32 else { throw .type("ID must be 32 characters or less") }
                guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                else { throw .type("ID contains invalid characters") }
                self.id = id
            }
            if kind == .save, let name = options["suggestedName"] as? String {
                let clean = String(name.map { $0 == "/" || $0 == ":" ? "_" : $0 }.filter { !$0.isASCII || !($0.asciiValue! < 0x20) })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                suggestedName = FileAccessDisk.safeSaveName(clean)
            }
            if let start = options["startIn"] as? String {
                guard Self.wellKnown[start] != nil else {
                    throw .type("The provided value '\(start)' is not a valid enum value of type WellKnownDirectory.")
                }
                startIn = start
            } else if let start = options["startIn"] as? [String: Any], let root = start["root"] as? String,
                      let path = start["path"] as? [String] {
                startHandle = root
                startPath = path
            }
            if kind == .directory { mode = try Mode(options["mode"]) }
        }
    }

    private static func site(_ scope: Scope) -> String {
        scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
    }

    /// The window the panel or bubble goes on: the one showing this page, when nothing else
    /// is asking there. It names the origin that asked, so that has to be the one in the address bar.
    private static func usableWindow(_ session: Session, _ tab: Tab, _ web: WKWebView) -> NSWindow? {
        guard session.scope == SitePermissions.scope(for: tab), let window = web.window, window.isVisible,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              SitePermissions.activePrompt(in: window) == nil else { return nil }
        return window
    }

    private static func pick(_ body: [String: Any], session: Session, tab: Tab, web: WKWebView,
                             current: () -> Bool) async throws(FileAccessError) -> Any? {
        let request = try PickRequest(type: body["type"], options: body["options"] as? [String: Any] ?? [:])
        guard takeGesture(session) else {
            throw FileAccessError(name: "SecurityError", message: "Must be handling a user gesture to show a file picker.")
        }
        guard !session.busy else { throw .notAllowed("File picker already active.") }
        session.busy = true
        defer { session.busy = false }
        let scope = session.scope
        var start = lastDirectory[scope]?[request.id]
        if start == nil, let known = request.startIn.flatMap({ PickRequest.wellKnown[$0] }) {
            start = URL(fileURLWithPath: FileAccessDisk.home + "/" + known, isDirectory: true)
        } else if start == nil, let token = request.startHandle,
                  let handle = try? ref(["root": token, "path": request.startPath], scope: scope) {
            start = try? await io { () throws(FileAccessError) in
                let path = try handle.resolve()
                let url = URL(fileURLWithPath: path)
                return FileAccessDisk.kind(path) == .directory ? url : url.deletingLastPathComponent()
            }
        }
        guard let urls = await present(request, directory: start, session: session, tab: tab, web: web),
              !urls.isEmpty, current() else { throw .abort }
        let kind: Kind = request.kind == .directory ? .directory : .file
        let create = request.kind == .save
        let rules = FileAccessDisk.defaultRules
        let paths = try await io { () throws(FileAccessError) in
            var paths: [String] = []
            for url in urls { paths.append(try FileAccessDisk.picked(url.path, kind: kind, create: create, rules: rules)) }
            return paths
        }
        let mode: Mode = request.kind == .save ? .readwrite : request.mode
        let picked = zip(urls, paths).map { Root(path: $1, kind: kind, name: $0.lastPathComponent) }
        if request.kind == .directory, mode == .readwrite {
            let response = await ask(.readwrite, root: picked[0], session: session, tab: tab, web: web)
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { throw .abort }
        }
        guard current() else { throw .abort }
        lastDirectory[scope, default: [:]][request.id] = kind == .directory ? urls[0] : urls[0].deletingLastPathComponent()
        return picked.map { root in
            let token = register(root, scope: scope)
            session.denied.remove(token)    // picking it again is a new answer
            session.grant(token, mode)
            return ["root": token, "kind": kind.rawValue, "name": root.name]
        }
    }

    private static func present(_ request: PickRequest, directory: URL?, session: Session, tab: Tab,
                                web: WKWebView) async -> [URL]? {
        #if DEBUG
        if let pickerForTesting { return pickerForTesting(request) }
        #endif
        guard let window = usableWindow(session, tab, web) else { return nil }
        let site = site(session.scope)
        let panel: NSSavePanel
        if request.kind == .save {
            panel = NSSavePanel()
            panel.nameFieldStringValue = request.suggestedName ?? ""
            if !request.contentTypes.isEmpty {
                panel.allowedContentTypes = request.contentTypes
                panel.allowsOtherFileTypes = request.acceptAll
            }
            panel.message = "Choose where \(site) saves this file. It will be able to change it."
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = request.kind == .open
            open.canChooseDirectories = request.kind == .directory
            open.allowsMultipleSelection = request.multiple
            open.treatsFilePackagesAsDirectories = true
            if request.kind == .open, !request.acceptAll, !request.contentTypes.isEmpty { open.allowedContentTypes = request.contentTypes }
            open.message = request.kind == .open
                ? "Choose \(request.multiple ? "files" : "a file") for \(site) to open."
                : "Choose a folder for \(site). It will be able to see the files inside."
            panel = open
        }
        panel.canCreateDirectories = request.kind != .open
        if let directory { panel.directoryURL = directory }
        let guardian = PanelGuard(save: request.kind == .save)
        panel.delegate = guardian
        session.panel = panel
        let response = await withCheckedContinuation { continuation in
            session.waiting = continuation
            panel.beginSheetModal(for: window) { session.answer($0) }
        }
        session.panel = nil
        withExtendedLifetime(guardian) {}
        guard response == .OK else { return nil }
        return (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] }
    }

    /// The panel itself refuses a blocked location, with Chrome's explanation, and stays open.
    private final class PanelGuard: NSObject, NSOpenSavePanelDelegate {
        let rules = FileAccessDisk.defaultRules
        let save: Bool
        init(save: Bool) { self.save = save }

        func panel(_ sender: Any, validate url: URL) throws {
            let parent = FileAccessDisk.real(url.deletingLastPathComponent().path)
            let real = FileAccessDisk.real(url.path) ?? parent.map { $0 + "/" + url.lastPathComponent } ?? url.path
            // isBlocked also covers a folder that holds a protected one, real path or as given.
            guard FileAccessDisk.isBlocked(url.path, rules: rules) || FileAccessDisk.isBlocked(real, rules: rules)
                    || (save && FileAccessDisk.isWriteBlocked(real, file: true)) else { return }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
                NSLocalizedDescriptionKey: "Can’t open this location because it contains system files.",
                NSLocalizedRecoverySuggestionErrorKey: "Choose a different folder or file.",
            ])
        }
    }

    /// The edit (or, after a reload, view) question, in the permission bubble.
    private static func ask(_ mode: Mode, root: Root, session: Session, tab: Tab,
                            web: WKWebView) async -> NSApplication.ModalResponse {
        #if DEBUG
        if let promptForTesting { return promptForTesting(mode, root.name) }
        #endif
        guard let window = usableWindow(session, tab, web) else { return .abort }
        let scope = session.scope
        let what = root.kind == .directory ? "files in “\(root.name)”" : "“\(root.name)”"
        let prompt = SitePermissionPrompt(
            message: "Allow \(site(scope)) to \(mode == .readwrite ? "edit" : "view") \(what)?",
            information: "\(scope.origin) — Allowed until this tab reloads, navigates or closes. "
                + (mode == .readwrite ? "The site can change and delete what it can see." : "The site can read what it can see."),
            persistentAllowTitle: "", symbol: root.kind == .directory ? "folder.fill" : "doc.fill")
        session.prompt = prompt
        session.window = window
        // The page that asked has to stay the page on screen for as long as the question is.
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if tab.existingWeb !== web || web.window !== window || web.isHiddenOrHasHiddenAncestor { prompt.finish(.abort) }
            }
        }
        let bar = TabStore.all.first { $0.isLittle && $0.window === window }
        bar?.barHeld += 1
        let response = await prompt.present(in: window, tabID: tab.id)
        bar?.barHeld -= 1
        monitor.cancel()
        session.prompt = nil
        return response
    }
}
