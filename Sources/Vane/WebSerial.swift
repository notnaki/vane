import AppKit
import SwiftUI
import WebKit

/// The Web Serial API (`navigator.serial`) for system WebKit, which has none.
///
/// A page script defines the spec's objects and forwards each call here; SerialPort.swift
/// does the I/O. The page script is the page's own and is trusted with nothing: every
/// message is checked again on this side. A port is reachable only from a main-frame
/// document in a secure context, for a device the user picked in the chooser for that
/// exact origin and profile. Opaque origins have no scope and get nothing.
@MainActor enum WebSerial {
    typealias Scope = SitePermissions.Scope
    static let messageName = "vaneSerial"
    static let gestureName = "vaneSerialGesture"
    /// Page code cannot reach this world, so "the user just clicked" is not the page's to claim.
    static let gestureWorld = WKContentWorld.world(name: "vane-serial")
    static let gestureEvent = "vane-serial-request"

    static let gestureScript = """
    addEventListener('\(gestureEvent)', () => {
      if (navigator.userActivation.isActive) webkit.messageHandlers.\(gestureName).postMessage(1);
    }, true);
    """

    /// Definitions only: no listener, timer or message until the page uses the API.
    static let script = """
    (() => {
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(messageName);
      if (!isSecureContext || !handler || 'serial' in Navigator.prototype) return;
      const post = handler.postMessage.bind(handler);
      const activation = navigator.userActivation;
      const toBase64 = Uint8Array.prototype.toBase64, fromBase64 = Uint8Array.fromBase64;
      const fail = (name, message) => name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
      const call = async (op, args) => {
        let reply;
        try { reply = await post({ op, ...args }); } catch (e) { throw fail('NetworkError', 'The serial port is not available.'); }
        if (reply && reply.error) throw fail(reply.error[0], reply.error[1]);
        return reply ? reply.value : undefined;
      };
      const quiet = promise => promise.catch(() => {});
      const pick = (source, keys, convert) => {
        const out = {};
        if (source && typeof source === 'object') for (const key of keys) if (source[key] !== undefined) out[key] = convert(source[key], key);
        return out;
      };
      const handlerAttribute = (target, type) => {
        const set = new WeakMap();
        Object.defineProperty(target.prototype, 'on' + type, { configurable: true, enumerable: true,
          get() { return set.get(this) || null; },
          set(value) {
            if (set.has(this)) this.removeEventListener(type, set.get(this));
            set.delete(this);
            if (typeof value === 'function') { set.set(this, value); this.addEventListener(type, value); }
          } });
      };

      let building = false, serial = null, listening = false;
      const slots = new WeakMap(), ports = new Map();
      const slot = port => {
        const s = slots.get(port);
        if (!s) throw new TypeError('Illegal invocation');
        return s;
      };
      const lostError = () => fail('NetworkError', 'The device has been lost.');
      // Both streams are gone and the page must ask for new ones.
      const dropStreams = (s, error) => {
        if (s.readController) try { s.readController.error(error); } catch (e) {}
        if (s.writeController) try { s.writeController.error(error); } catch (e) {}
        s.readable = s.writable = s.readController = s.writeController = null;
      };

      class SerialPort extends EventTarget {
        constructor() {
          if (!building) throw new TypeError('Illegal constructor');
          super();
        }
        get connected() { return slot(this).connected; }
        get readable() {
          const s = slot(this);
          if (s.readable) return s.readable;
          if (s.state !== 'opened' || s.readFatal) return null;
          // Nothing is asked of the device until the page reads: the native side buffers.
          const stream = new ReadableStream({
            start(controller) { s.readController = controller; },
            async pull(controller) {
              let text;
              try { text = await call('read', { id: s.id }); }
              catch (error) {
                if (s.readable === stream) { s.readFatal = true; s.readable = s.readController = null; }
                try { controller.error(error); } catch (e) {}
                return;
              }
              if (text) return controller.enqueue(fromBase64.call(Uint8Array, text));
              // Cancelled, or closed underneath this read.
              if (s.readable === stream) s.readable = s.readController = null;
              try { controller.close(); } catch (e) {}
            },
            async cancel() {
              if (s.readable === stream) s.readable = s.readController = null;
              await quiet(call('cancelRead', { id: s.id }));
            },
          }, { highWaterMark: 0 });
          return s.readable = stream;
        }
        get writable() {
          const s = slot(this);
          if (s.writable) return s.writable;
          if (s.state !== 'opened' || s.writeFatal) return null;
          const gone = () => { if (s.writable === stream) s.writable = s.writeController = null; };
          const stream = new WritableStream({
            start(controller) { s.writeController = controller; },
            async write(chunk) {
              try {
                const tag = Object.prototype.toString.call(chunk);
                let bytes;
                if (ArrayBuffer.isView(chunk)) bytes = new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
                else if (tag === '[object ArrayBuffer]' || tag === '[object SharedArrayBuffer]') bytes = new Uint8Array(chunk);
                else throw new TypeError('The provided value is not of type BufferSource.');
                // One megabyte a message keeps each one small enough to copy cheaply.
                for (let at = 0; at < bytes.length; at += 1048576) {
                  await call('write', { id: s.id, data: toBase64.call(bytes.subarray(at, at + 1048576)) });
                }
              } catch (error) {
                // The stream is errored either way; only a lost device stops a new one being made.
                if (s.writable === stream && !(error instanceof TypeError)) s.writeFatal = true;
                gone();
                throw error;
              }
            },
            async close() { await quiet(call('drain', { id: s.id })); gone(); },
            async abort() { await quiet(call('discard', { id: s.id })); gone(); },
          // Sized by hand: the stock byte-length strategy answers a chunk that is not bytes
          // with a RangeError before `write` can say TypeError.
          }, { highWaterMark: s.bufferSize, size: chunk => (chunk && chunk.byteLength) || 0 });
          return s.writable = stream;
        }
        getInfo() { return { ...slot(this).info }; }
        async open(options) {
          const s = slot(this);
          if (s.state !== 'closed') throw fail('InvalidStateError', 'The port is already open.');
          const sent = pick(options, ['baudRate', 'dataBits', 'stopBits', 'bufferSize'], Number);
          Object.assign(sent, pick(options, ['parity', 'flowControl'], String));
          s.state = 'opening';
          try { await call('open', { id: s.id, options: sent }); }
          catch (error) { if (s.state === 'opening') s.state = 'closed'; throw error; }
          s.bufferSize = sent.bufferSize || 255;
          s.state = 'opened';
        }
        async setSignals(signals) {
          const s = slot(this);
          if (s.state !== 'opened') throw fail('InvalidStateError', 'The port is closed.');
          await call('setSignals', { id: s.id, signals: pick(signals, ['dataTerminalReady', 'requestToSend', 'break'], Boolean) });
        }
        async getSignals() {
          const s = slot(this);
          if (s.state !== 'opened') throw fail('InvalidStateError', 'The port is closed.');
          return call('getSignals', { id: s.id });
        }
        async close() {
          const s = slot(this);
          if (s.state !== 'opened') throw fail('InvalidStateError', 'The port is already closed.');
          if ((s.readable && s.readable.locked) || (s.writable && s.writable.locked)) {
            throw new TypeError('Cannot close a port while its streams are locked.');
          }
          s.state = 'closing';
          const readable = s.readable, writable = s.writable;
          // The device first: that is what ends a write the hardware is holding up.
          await quiet(call('close', { id: s.id }));
          await Promise.all([readable && quiet(readable.cancel()), writable && quiet(writable.abort())]);
          s.readable = s.writable = s.readController = s.writeController = null;
          s.readFatal = s.writeFatal = false;
          if (s.state === 'closing') s.state = 'closed';
        }
        async forget() {
          const s = slot(this);
          if (s.state === 'forgotten') return;
          s.state = 'forgotten';
          ports.delete(s.id);
          dropStreams(s, fail('NetworkError', 'The port has been forgotten.'));
          await call('forget', { id: s.id });
        }
      }

      const adopt = info => {
        let port = ports.get(info.id);
        if (!port) {
          building = true;
          try { port = new SerialPort(); } finally { building = false; }
          slots.set(port, { id: info.id, state: 'closed', bufferSize: 255 });
          ports.set(info.id, port);
        }
        const s = slots.get(port);
        s.connected = true;
        s.info = pick(info, ['usbVendorId', 'usbProductId'], Number);
        return port;
      };
      // The spec bubbles from the port to `navigator.serial`; these are two plain targets.
      const fire = (port, type) => {
        port.dispatchEvent(new Event(type, { bubbles: true }));
        if (!serial) return;
        const event = new Event(type);
        Object.defineProperty(event, 'target', { value: port });
        serial.dispatchEvent(event);
      };
      // One held request, answered when a granted device comes or goes. Started on first use.
      const listen = async () => {
        if (listening) return;
        listening = true;
        try {
          for (;;) {
            const event = await call('events');
            if (!event) break;
            if (event.type === 'connect') fire(adopt(event.port), 'connect');
            const port = event.type === 'disconnect' && ports.get(event.id);
            if (!port) continue;
            const s = slots.get(port);
            s.connected = false;
            if (s.state !== 'forgotten') s.state = 'closed';
            s.readFatal = s.writeFatal = false;
            dropStreams(s, lostError());
            fire(port, 'disconnect');
          }
        } catch (e) {}
        listening = false;
      };

      class Serial extends EventTarget {
        constructor() {
          if (!building) throw new TypeError('Illegal constructor');
          super();
        }
        addEventListener(...args) { listen(); return super.addEventListener(...args); }
        async getPorts() {
          listen();
          return (await call('ports')).map(adopt);
        }
        async requestPort(options) {
          const filters = options && options.filters !== undefined ? options.filters : [];
          if (!Array.isArray(filters)) throw new TypeError('filters must be a sequence.');
          const sent = filters.map(filter => {
            const out = pick(filter, ['usbVendorId', 'usbProductId'], Number);
            if (filter && filter.bluetoothServiceClassId !== undefined) out.bluetoothServiceClassId = String(filter.bluetoothServiceClassId);
            return out;
          });
          if (!activation.isActive) throw fail('SecurityError', 'Must be handling a user gesture to show a permission request.');
          dispatchEvent(new Event('\(gestureEvent)'));
          listen();
          return adopt(await call('request', { filters: sent }));
        }
      }

      for (const [target, name] of [[Serial, 'Serial'], [SerialPort, 'SerialPort']]) {
        handlerAttribute(target, 'connect');
        handlerAttribute(target, 'disconnect');
        Object.defineProperty(target.prototype, Symbol.toStringTag, { value: name, configurable: true });
        Object.defineProperty(window, name, { value: target, writable: true, configurable: true });
      }
      Object.defineProperty(Navigator.prototype, 'serial', { configurable: true, enumerable: true,
        get() {
          if (!serial) {
            building = true;
            try { serial = new Serial(); } finally { building = false; }
          }
          return serial;
        } });
    })();
    """

    /// Main frame only: `WKFrameInfo` cannot say whether a child frame was delegated `serial`
    /// by its parent's Permissions Policy, so frames get no API rather than a guessed one.
    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: gestureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: gestureWorld))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    /// The gesture handler is added by the tab with its others; this is the one that answers.
    static func attach(_ tab: Tab, to web: WKWebView) {
        web.configuration.userContentController.addScriptMessageHandler(Bridge(tab), contentWorld: .page, name: messageName)
    }

    static func detach(from web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        web.configuration.userContentController.removeScriptMessageHandler(forName: gestureName, contentWorld: gestureWorld)
    }

    /// The reply-handler form, not `async`: WebKit calls it on the main thread in the order the
    /// page sent, and each message's task is queued there in that order. The async form starts every
    /// message on its own task off the main thread, so a request could overtake the gesture before it.
    private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor [tab] in
                    do throws(SerialError) { replyHandler(["value": try await WebSerial.handle(message, tab: tab) ?? NSNull()], nil) }
                    catch { replyHandler(["error": [error.name, error.message]], nil) }
                }
            }
        }
    }

    // MARK: - Filters

    /// One `requestPort` filter. A Bluetooth-only filter is valid and matches nothing here.
    struct Filter: Equatable, Sendable {
        var vendorID: Int?
        var productID: Int?

        func matches(_ device: SerialDevice) -> Bool {
            guard let vendorID, device.vendorID == vendorID else { return false }
            return productID == nil || device.productID == productID
        }

        static func parse(_ body: Any?) throws(SerialError) -> [Filter] {
            guard let body, !(body is NSNull) else { return [] }
            guard let list = body as? [[String: Any]] else { throw .type("filters must be a sequence of filters.") }
            var filters: [Filter] = []
            for entry in list {
                func id(_ key: String) throws(SerialError) -> Int? {
                    guard let value = entry[key] else { return nil }
                    guard let number = value as? NSNumber, let id = Int(exactly: number.doubleValue),
                          (0...0xFFFF).contains(id) else { throw .type("\(key) must be a 16-bit number.") }
                    return id
                }
                let vendor = try id("usbVendorId"), product = try id("usbProductId")
                if entry["bluetoothServiceClassId"] != nil {
                    guard vendor == nil, product == nil else {
                        throw .type("A filter cannot specify both bluetoothServiceClassId and usbVendorId or usbProductId.")
                    }
                } else if vendor == nil {
                    throw .type(product == nil ? "A filter must provide a property to filter by."
                                               : "A filter containing a usbProductId must also specify a usbVendorId.")
                }
                filters.append(Filter(vendorID: vendor, productID: product))
            }
            return filters
        }

        /// What the chooser lists: everything, or what any one filter matches.
        static func candidates(_ devices: [SerialDevice], filters: [Filter]) -> [SerialDevice] {
            filters.isEmpty ? devices : devices.filter { device in filters.contains { $0.matches(device) } }
        }
    }

    // MARK: - What is remembered

    /// One device one origin may open. Never the path alone: a different adapter in the same
    /// USB socket gets the same `/dev` name.
    struct Grant: Codable, Equatable, Sendable {
        let id: String
        var path: String
        var vendorID: Int?
        var productID: Int?
        var serialNumber: String?
        var name: String

        /// The same device again. One with a serial number is itself in any socket; one
        /// without is the same model at the same place.
        func matches(_ device: SerialDevice) -> Bool {
            guard vendorID == device.vendorID, productID == device.productID else { return false }
            if let serialNumber, !serialNumber.isEmpty { return serialNumber == device.serialNumber }
            return path == device.path
        }
    }

    private static let defaults: UserDefaults = .vane
    private static let prefix = "serialPort.v1."
    private static var privateGrants: [UUID: [String: [Grant]]] = [:]

    private static func key(scope: Scope) -> String {
        prefix + scope.profileID.uuidString.lowercased() + "." + Data(scope.origin.utf8).base64EncodedString()
    }

    static func grants(scope: Scope?) -> [Grant] {
        guard let scope else { return [] }
        if let tab = scope.privateTabID { return privateGrants[tab]?[key(scope: scope)] ?? [] }
        return defaults.data(forKey: key(scope: scope)).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
    }

    private static func save(_ grants: [Grant], scope: Scope) {
        let key = key(scope: scope)
        if let tab = scope.privateTabID { privateGrants[tab, default: [:]][key] = grants.isEmpty ? nil : grants }
        else if grants.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(try? JSONEncoder().encode(grants), forKey: key) }
    }

    /// The chooser's answer. Picking a device again refreshes its grant rather than adding one.
    @discardableResult static func grant(_ device: SerialDevice, scope: Scope) -> Grant {
        var all = grants(scope: scope)
        let grant: Grant
        if let index = all.firstIndex(where: { $0.matches(device) }) {
            all[index].path = device.path
            all[index].name = device.label
            grant = all[index]
        } else {
            grant = Grant(id: UUID().uuidString, path: device.path, vendorID: device.vendorID, productID: device.productID,
                          serialNumber: device.serialNumber, name: device.label)
            all.append(grant)
        }
        save(all, scope: scope)
        // Pages of this origin that are already open learn of it from `getPorts()`, not a connect event.
        for session in sessions.values where session.scope == scope { session.known.insert(grant.id) }
        return grant
    }

    /// Every saved grant in a profile, for Settings.
    static func all(profileID: UUID) -> [(scope: Scope, grant: Grant)] {
        let match = prefix + profileID.uuidString.lowercased() + "."
        return defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(match) }.sorted().flatMap { key -> [(scope: Scope, grant: Grant)] in
            guard let data = Data(base64Encoded: String(key.dropFirst(match.count))),
                  let origin = String(data: data, encoding: .utf8),
                  let scope = Scope(url: URL(string: origin), profileID: profileID) else { return [] }
            return grants(scope: scope).map { (scope, $0) }
        }
    }

    /// Takes the grant back and closes the port wherever this origin has it open.
    static func forget(scope: Scope?, id: String) {
        guard let scope else { return }
        save(grants(scope: scope).filter { $0.id != id }, scope: scope)
        for session in sessions.values where session.scope == scope {
            session.open.removeValue(forKey: id)?.close(lost: true)
            session.known.remove(id)
        }
    }

    static func forgetPrivate(tabID: UUID) { privateGrants.removeValue(forKey: tabID) }

    /// A profile is going, or Reset Permissions (every profile when nil). Private tabs keep
    /// theirs until they close.
    static func forgetAll(profileID: UUID? = nil) {
        let match = prefix + (profileID.map { $0.uuidString.lowercased() + "." } ?? "")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(match) { defaults.removeObject(forKey: key) }
        for session in sessions.values where (profileID == nil || session.scope.profileID == profileID) && session.scope.privateTabID == nil {
            session.open.values.forEach { $0.close(lost: true) }
            session.open.removeAll()
            session.known.removeAll()
        }
    }

    /// The granted devices that are plugged in, each with the node to open.
    private static func present(scope: Scope) -> [(grant: Grant, device: SerialDevice)] {
        let devices = SerialDevices.shared.devices
        return grants(scope: scope).compactMap { grant in
            devices.first(where: grant.matches).map { (grant, $0) }
        }
    }

    // MARK: - Who may ask

    /// HTTPS, or HTTP to this Mac itself. Mirrors the page's `isSecureContext`, so not
    /// `DeveloperMode.isLocal`: that one also takes `0.0.0.0`, which is no loopback address and no secure context.
    nonisolated static func isSecure(_ scope: Scope) -> Bool { DeviceAccess.isSecure(scope) }

    // MARK: - One document's ports

    @MainActor private final class Session {
        let scope: Scope
        var open: [String: SerialConnection] = [:]
        var opening: Set<String> = []
        /// Granted devices that were present at the last look; a change is an event.
        var known: Set<String>
        var events: [Event] = []
        var waiter: CheckedContinuation<Event?, Never>?
        var gesture: ContinuousClock.Instant?
        var chooser: SitePermissionPrompt?
        weak var chooserWindow: NSWindow?
        init(scope: Scope) {
            self.scope = scope
            known = Set(WebSerial.present(scope: scope).map(\.grant.id))
        }

        func end() {
            chooser?.finish(.abort)
            open.values.forEach { $0.close() }
            open.removeAll()
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }
    private static var sessions: [UUID: Session] = [:]

    /// A granted device arrived, or one the page knew about left.
    private enum Event: Sendable {
        case connect(Grant), disconnect(String)
        @MainActor var body: [String: Any] {
            switch self {
            case .connect(let grant): ["type": "connect", "port": WebSerial.info(grant)]
            case .disconnect(let id): ["type": "disconnect", "id": id]
            }
        }
    }

    #if DEBUG
    /// Fixtures answer the chooser themselves: no popover, and no hardware to pick from.
    static var chooserForTesting: (([SerialDevice]) -> SerialDevice?)?
    #endif

    /// The chooser open in this window, if any: a camera or location question that arrives
    /// meanwhile is turned away, as it would be by any other bubble, rather than stacked on it.
    static func chooser(in window: NSWindow) -> SitePermissionPrompt? {
        sessions.values.first { $0.chooser != nil && $0.chooserWindow === window }?.chooser
    }

    /// A tab in the middle of flashing a board is busy, however long it has been in the background.
    static func hasOpenPort(tabID: UUID) -> Bool {
        sessions[tabID].map { !$0.open.isEmpty || !$0.opening.isEmpty } ?? false
    }

    private static func watch() {
        SerialDevices.shared.onChange = { devicesChanged() }
        SerialDevices.shared.start()
    }

    /// A new document, or none: its ports close and its chooser goes. A navigation that has
    /// only started takes the chooser down but leaves the ports, because it may yet turn into
    /// a download and leave the page that is flashing a board exactly where it was.
    static func endDocument(tabID: UUID, navigationStarted: Bool = false) {
        guard let session = sessions[tabID] else { return }
        if navigationStarted { session.chooser?.finish(.abort); return }
        sessions.removeValue(forKey: tabID)
        session.end()
    }

    /// The isolated world saw the request while the page had transient activation.
    static func gesture(_ message: WKScriptMessage, tab: Tab) {
        guard message.frameInfo.isMainFrame, let scope = scope(of: message, tab: tab) else { return }
        watch()
        session(tab: tab, scope: scope).gesture = .now
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

    private static func info(_ grant: Grant) -> [String: Any] {
        var info: [String: Any] = ["id": grant.id]
        if let vendor = grant.vendorID { info["usbVendorId"] = vendor }
        if let product = grant.productID { info["usbProductId"] = product }
        return info
    }

    private static func devicesChanged() {
        for session in sessions.values {
            let present = present(scope: session.scope)
            let now = Set(present.map(\.grant.id))
            for id in session.known.subtracting(now).sorted() {
                session.open.removeValue(forKey: id)?.close(lost: true)
                session.events.append(.disconnect(id))
            }
            for entry in present where !session.known.contains(entry.grant.id) {
                session.events.append(.connect(entry.grant))
            }
            session.known = now
            if let waiter = session.waiter, !session.events.isEmpty {
                session.waiter = nil
                waiter.resume(returning: session.events.removeFirst())
            }
        }
    }

    /// One call from the page. The reply is the call's result; a throw is its rejection.
    private static func handle(_ message: WKScriptMessage, tab: Tab?) async throws(SerialError) -> Any? {
        let unavailable = SerialError.security("Serial ports are not available to this page.")
        guard let tab, !tab.tornDown, let web = tab.existingWeb, message.webView === web, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let op = body["op"] as? String,
              let scope = scope(of: message, tab: tab) else { throw unavailable }
        watch()
        let session = session(tab: tab, scope: scope)
        // Work that waits can outlive its document; nothing it produced may be handed on then.
        var current: Bool { sessions[tab.id] === session }

        switch op {
        case "ports":
            return present(scope: scope).map { info($0.grant) }
        case "events":
            session.waiter?.resume(returning: nil)
            session.waiter = nil
            if !session.events.isEmpty { return session.events.removeFirst().body }
            return await withCheckedContinuation { session.waiter = $0 }?.body
        case "request":
            let filters = try Filter.parse(body["filters"])
            guard let gesture = session.gesture, ContinuousClock.now - gesture < .seconds(2) else {
                throw .security("Must be handling a user gesture to show a permission request.")
            }
            session.gesture = nil
            guard session.chooser == nil else { throw .state("A serial port chooser is already open.") }
            let notFound = SerialError(name: "NotFoundError", message: "No port selected by the user.")
            guard let device = await choose(session: session, tab: tab, web: web, filters: filters), current,
                  SerialDevices.shared.devices.contains(device) else { throw notFound }
            let grant = grant(device, scope: scope)
            SiteChanges.shared.bump()
            return info(grant)
        default: break
        }

        guard let id = body["id"] as? String else { throw .type("Missing port.") }
        if op == "forget" {
            forget(scope: scope, id: id)
            SiteChanges.shared.bump()
            return nil
        }
        if op == "close" {
            // Not answered until the device is free: `await port.close(); await port.open()` must work.
            await session.open.removeValue(forKey: id)?.closeAndWait()
            return nil
        }
        if op == "open" {
            guard session.open[id] == nil, !session.opening.contains(id) else { throw .state("The port is already open.") }
            let options = try SerialOptions(body["options"])
            guard let device = present(scope: scope).first(where: { $0.grant.id == id })?.device else { throw .lost }
            session.opening.insert(id)
            defer { session.opening.remove(id) }
            let connection = try await SerialConnection.open(path: device.path, options: options)
            // Forgotten, unplugged or navigated away while the driver was opening it.
            guard current, present(scope: scope).contains(where: { $0.grant.id == id }) else {
                connection.close()
                throw .lost
            }
            session.open[id] = connection
            return nil
        }
        // Closed under the page: unplugged, forgotten in Site Controls, or a document restored from history.
        guard let connection = session.open[id] else { throw .network("The port is not open.") }
        switch op {
        case "read":
            return try await connection.read().base64EncodedString()
        case "write":
            // The page script sends a megabyte at a time; anything larger did not come from it.
            guard let text = body["data"] as? String, text.utf8.count <= 2 * 1024 * 1024,
                  let data = Data(base64Encoded: text) else { throw .type("Invalid data.") }
            try await connection.write(data)
        case "cancelRead": connection.cancelRead()
        case "drain": await connection.drain()
        case "discard": connection.discardOutput()
        case "setSignals": try await connection.setSignals(try SerialSignals(body["signals"]))
        case "getSignals": return try await connection.signals()
        default: throw .type("Unknown serial operation.")
        }
        return nil
    }

    // MARK: - The chooser

    /// The user's pick, or nil. Only the window showing this page can be asked, and only
    /// when nothing else is already asking there.
    private static func choose(session: Session, tab: Tab, web: WKWebView, filters: [Filter]) async -> SerialDevice? {
        // The bubble names the origin that asked; that has to be the one in the address bar.
        guard session.scope == SitePermissions.scope(for: tab) else { return nil }
        #if DEBUG
        if let chooserForTesting {
            return chooserForTesting(Filter.candidates(SerialDevices.shared.devices, filters: filters))
        }
        #endif
        guard let window = web.window, window.isVisible, !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              SitePermissions.activePrompt(in: window) == nil, !sessions.values.contains(where: { $0.chooser != nil })
        else { return nil }
        let scope = session.scope
        let site = scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
        var picked: SerialDevice?
        let prompt = SitePermissionPrompt(width: 300) { respond in
            AnyView(SerialChooser(site: site, filters: filters) { device in
                picked = device
                respond(device == nil ? .abort : .OK)
            })
        }
        session.chooser = prompt
        session.chooserWindow = window
        // The page that asked has to stay the page on screen for as long as the question is.
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if tab.existingWeb !== web || web.window !== window || web.isHiddenOrHasHiddenAncestor { prompt.finish(.abort) }
            }
        }
        let response = await prompt.present(in: window, tabID: tab.id)
        monitor.cancel()
        session.chooser = nil
        return response == .OK ? picked : nil
    }
}

/// The list the user picks from. It follows the devices as they are plugged in, because
/// the usual order is to click Connect and then go looking for the cable.
private struct SerialChooser: View {
    let site: String
    let filters: [WebSerial.Filter]
    let respond: (SerialDevice?) -> Void
    @ObservedObject private var devices = SerialDevices.shared

    var body: some View {
        let candidates = WebSerial.Filter.candidates(devices.devices, filters: filters)
        DeviceChooserList(symbol: "cable.connector", title: "\(site) wants to connect to a serial port",
                          rows: candidates.map { .init(id: $0.path, label: $0.label) },
                          accessibility: "Serial port request from \(site)") { path in
            respond(path.flatMap { path in candidates.first { $0.path == path } })
        }
    }
}
