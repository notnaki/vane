import AppKit
import SwiftUI
import WebKit

/// The WebHID API (`navigator.hid`) for system WebKit, which has none.
///
/// A page script defines the spec's objects and forwards each call here; HIDDevice.swift
/// does the I/O. The page script is the page's own and is trusted with nothing: every
/// message is checked again on this side. A device is reachable only from a main-frame
/// document in a secure context, for a device the user picked in the chooser for that
/// exact origin and profile, and never for the reports HIDBlocklist protects. Opaque
/// origins have no scope and get nothing.
@MainActor enum WebHID {
    typealias Scope = SitePermissions.Scope
    static let messageName = "vaneHID"
    static let gestureName = "vaneHIDGesture"
    /// Page code cannot reach this world, so "the user just clicked" is not the page's to claim.
    static let gestureWorld = WKContentWorld.world(name: "vane-hid")
    static let gestureEvent = "vane-hid-request"

    static let gestureScript = """
    addEventListener('\(gestureEvent)', () => {
      if (navigator.userActivation.isActive) webkit.messageHandlers.\(gestureName).postMessage(1);
    }, true);
    """

    /// Definitions only: no listener, timer or message until the page uses the API.
    static let script = """
    (() => {
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(messageName);
      if (!isSecureContext || !handler || 'hid' in Navigator.prototype) return;
      const post = handler.postMessage.bind(handler);
      const activation = navigator.userActivation;
      const toBase64 = Uint8Array.prototype.toBase64, fromBase64 = Uint8Array.fromBase64;
      const fail = (name, message) => name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
      const call = async (op, args) => {
        let reply;
        try { reply = await post({ op, ...args }); } catch (e) { throw fail('NotAllowedError', 'The device is not available.'); }
        if (reply && reply.error) throw fail(reply.error[0], reply.error[1]);
        return reply ? reply.value : undefined;
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
      // WebIDL's `[EnforceRange] octet`.
      const octet = value => {
        const number = Math.trunc(Number(value));
        if (!(number >= 0 && number <= 255)) throw new TypeError('The report ID must be between 0 and 255.');
        return number;
      };
      const view = data => {
        const tag = Object.prototype.toString.call(data);
        if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        if (tag === '[object ArrayBuffer]' || tag === '[object SharedArrayBuffer]') return new Uint8Array(data);
        throw new TypeError('The provided value is not of type BufferSource.');
      };
      const sequence = (value, name) => {
        if (!value || typeof value !== 'object' || typeof value[Symbol.iterator] !== 'function') {
          throw new TypeError(name + ' must be a sequence of filters.');
        }
        return Array.from(value, filter => {
          const out = {};
          if (filter && typeof filter === 'object') {
            if (filter.vendorId !== undefined) out.vendorId = filter.vendorId >>> 0;
            for (const key of ['productId', 'usagePage', 'usage']) if (filter[key] !== undefined) out[key] = filter[key] & 0xffff;
          }
          return out;
        });
      };

      let building = false, hid = null, listening = false;
      const slots = new WeakMap(), devices = new Map();
      const slot = device => {
        const s = slots.get(device);
        if (!s) throw new TypeError('Illegal invocation');
        return s;
      };
      // Open, close and forget take turns, and a forgotten device does nothing more.
      const settled = (s, forgettable) => {
        if (s.busy) throw fail('InvalidStateError', 'An operation that changes the device state is in progress.');
        if (!forgettable && s.forgotten) throw fail('InvalidStateError', 'The device is forgotten.');
      };
      const opened = device => {
        const s = slot(device);
        settled(s);
        if (!s.opened) throw fail('InvalidStateError', 'The device must be opened first.');
        return s;
      };
      const changing = async (s, work) => {
        s.busy = true;
        try { return await work(); } finally { s.busy = false; }
      };

      class HIDDevice extends EventTarget {
        constructor() {
          if (!building) throw new TypeError('Illegal constructor');
          super();
        }
        get opened() { return slot(this).opened; }
        get vendorId() { return slot(this).info.vendorId; }
        get productId() { return slot(this).info.productId; }
        get productName() { return slot(this).info.productName; }
        get collections() { return slot(this).info.collections; }
        async open() {
          const s = slot(this);
          settled(s);
          if (s.opened) throw fail('InvalidStateError', 'The device is already open.');
          await changing(s, () => call('open', { id: s.id }));
          s.opened = true;
        }
        async close() {
          const s = slot(this);
          settled(s);
          await changing(s, () => call('close', { id: s.id }));
          s.opened = false;
        }
        async forget() {
          const s = slot(this);
          settled(s, true);
          await changing(s, () => call('forget', { id: s.id }));
          s.opened = false;
          s.forgotten = true;
        }
        async sendReport(reportId, data) {
          const s = opened(this);
          await call('send', { id: s.id, type: 'output', reportId: octet(reportId), data: toBase64.call(view(data)) });
        }
        async sendFeatureReport(reportId, data) {
          const s = opened(this);
          await call('send', { id: s.id, type: 'feature', reportId: octet(reportId), data: toBase64.call(view(data)) });
        }
        async receiveFeatureReport(reportId) {
          const s = opened(this);
          return new DataView(fromBase64.call(Uint8Array, await call('receive', { id: s.id, reportId: octet(reportId) })).buffer);
        }
      }

      const member = (init, name) => {
        if (!init || !slots.has(init.device)) throw new TypeError("Failed to construct '" + name + "': member device is not of type HIDDevice.");
        return init.device;
      };
      class HIDConnectionEvent extends Event {
        #device;
        constructor(type, init) {
          super(type, init);
          this.#device = member(init, 'HIDConnectionEvent');
        }
        get device() { return this.#device; }
      }
      class HIDInputReportEvent extends Event {
        #device; #reportId; #data;
        constructor(type, init) {
          super(type, init);
          this.#device = member(init, 'HIDInputReportEvent');
          this.#reportId = octet(init.reportId);
          if (!(init.data instanceof DataView)) throw new TypeError("Failed to construct 'HIDInputReportEvent': member data is not of type DataView.");
          this.#data = init.data;
        }
        get device() { return this.#device; }
        get reportId() { return this.#reportId; }
        get data() { return this.#data; }
      }

      const freeze = value => {
        if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
        return value;
      };
      const adopt = info => {
        let device = devices.get(info.id);
        if (!device) {
          building = true;
          try { device = new HIDDevice(); } finally { building = false; }
          slots.set(device, { id: info.id, opened: false, busy: false, forgotten: false });
          devices.set(info.id, device);
        }
        const s = slots.get(device);
        s.forgotten = false;
        s.info = { vendorId: info.vendorId, productId: info.productId, productName: info.productName, collections: freeze(info.collections) };
        return device;
      };
      // One held request, answered when a granted device comes or goes or sends a report.
      // Started on first use.
      const listen = async () => {
        if (listening) return;
        listening = true;
        try {
          for (;;) {
            const events = await call('events');
            if (!events) break;
            for (const event of events) {
              if (event.type === 'connect') {
                hid.dispatchEvent(new HIDConnectionEvent('connect', { device: adopt(event.device) }));
                continue;
              }
              const device = devices.get(event.id), s = device && slots.get(device);
              if (!s) continue;
              if (event.type === 'input') {
                if (s.opened) device.dispatchEvent(new HIDInputReportEvent('inputreport', { device, reportId: event.reportId,
                  data: new DataView(fromBase64.call(Uint8Array, event.data).buffer) }));
                continue;
              }
              // Unplugged, or forgotten from Site Controls: closed either way.
              s.opened = false;
              if (event.type === 'disconnect') hid.dispatchEvent(new HIDConnectionEvent('disconnect', { device }));
            }
          }
        } catch (e) {}
        listening = false;
      };

      class HID extends EventTarget {
        constructor() {
          if (!building) throw new TypeError('Illegal constructor');
          super();
        }
        addEventListener(...args) { listen(); return super.addEventListener(...args); }
        async getDevices() {
          listen();
          return (await call('devices')).map(adopt);
        }
        async requestDevice(options) {
          if (!options || typeof options !== 'object') throw new TypeError('requestDevice needs options with filters.');
          const sent = { filters: sequence(options.filters, 'filters') };
          if (options.exclusionFilters !== undefined) sent.exclusionFilters = sequence(options.exclusionFilters, 'exclusionFilters');
          if (!activation.isActive) throw fail('SecurityError', 'Must be handling a user gesture to show a permission request.');
          dispatchEvent(new Event('\(gestureEvent)'));
          listen();
          return (await call('request', sent)).map(adopt);
        }
      }

      handlerAttribute(HID, 'connect');
      handlerAttribute(HID, 'disconnect');
      handlerAttribute(HIDDevice, 'inputreport');
      for (const [target, name] of [[HID, 'HID'], [HIDDevice, 'HIDDevice'], [HIDConnectionEvent, 'HIDConnectionEvent'],
                                    [HIDInputReportEvent, 'HIDInputReportEvent']]) {
        Object.defineProperty(target.prototype, Symbol.toStringTag, { value: name, configurable: true });
        Object.defineProperty(window, name, { value: target, writable: true, configurable: true });
      }
      Object.defineProperty(Navigator.prototype, 'hid', { configurable: true, enumerable: true,
        get() {
          if (!hid) {
            building = true;
            try { hid = new HID(); } finally { building = false; }
          }
          return hid;
        } });
    })();
    """

    /// Main frame only: `WKFrameInfo` cannot say whether a child frame was delegated `hid`
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

    private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            do throws(HIDError) { return (["value": try await WebHID.handle(message, tab: tab) ?? NSNull()], nil) }
            catch { return (["error": [error.name, error.message]], nil) }
        }
    }

    // MARK: - Filters

    /// One `requestDevice` filter: a vendor (and product), a usage page (and usage), or both.
    struct Filter: Equatable, Sendable {
        var vendorID: Int?
        var productID: Int?
        var usagePage: Int?
        var usage: Int?

        /// The usage is looked for among the interface's top-level collections, protected or not.
        func matches(_ device: HIDDeviceInfo) -> Bool {
            if let vendorID, device.vendorID != vendorID { return false }
            if let productID, device.productID != productID { return false }
            guard let usagePage else { return true }
            return device.descriptor.collections.contains { Int($0.usagePage) == usagePage && (usage == nil || Int($0.usage) == usage) }
        }

        static func parse(_ body: Any?, name: String = "filters") throws(HIDError) -> [Filter] {
            guard let list = body as? [[String: Any]] else { throw .type("\(name) must be a sequence of filters.") }
            var filters: [Filter] = []
            for entry in list {
                func id(_ key: String, max: Int = 0xFFFF) throws(HIDError) -> Int? {
                    guard let value = entry[key] else { return nil }
                    // A JavaScript `true` is an NSNumber too; it is not an id.
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          let id = Int(exactly: number.doubleValue), (0...max).contains(id) else { throw .type("\(key) is not valid.") }
                    return id
                }
                let filter = Filter(vendorID: try id("vendorId", max: Int(UInt32.max)), productID: try id("productId"),
                                    usagePage: try id("usagePage"), usage: try id("usage"))
                if filter == Filter() { throw .type("A filter must provide a property to filter by.") }
                if filter.productID != nil, filter.vendorID == nil { throw .type("A filter containing a productId must also contain a vendorId.") }
                if filter.usage != nil, filter.usagePage == nil { throw .type("A filter containing a usage must also contain a usagePage.") }
                filters.append(filter)
            }
            return filters
        }

        /// What the chooser lists: the interfaces a page may be shown that any one filter
        /// matches (all of them when there are no filters) and no exclusion filter does.
        static func candidates(_ devices: [HIDDeviceInfo], filters: [Filter], excluding: [Filter] = []) -> [HIDDeviceInfo] {
            devices.filter { device in
                device.isExposable && (filters.isEmpty || filters.contains { $0.matches(device) })
                    && !excluding.contains { $0.matches(device) }
            }
        }
    }

    // MARK: - What is remembered

    /// One physical device one origin may open: every interface of it a page may be shown.
    struct Grant: Codable, Equatable, Sendable {
        let id: String
        var identity: HIDDeviceInfo.Identity
        var name: String
    }

    private static let defaults: UserDefaults = .vane
    private static let prefix = "hidDevice.v1."
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
    @discardableResult static func grant(_ device: HIDDeviceInfo, scope: Scope) -> Grant {
        var all = grants(scope: scope)
        let grant: Grant
        if let index = all.firstIndex(where: { $0.identity == device.identity }) {
            all[index].name = device.label
            grant = all[index]
        } else {
            grant = Grant(id: UUID().uuidString, identity: device.identity, name: device.label)
            all.append(grant)
        }
        save(all, scope: scope)
        // Pages of this origin that are already open learn of it from `getDevices()`, not a connect event.
        for session in sessions.values where session.scope == scope { session.known = Set(present(scope: scope).map(\.device.entryID)) }
        return grant
    }

    /// Takes the grant back and closes the device wherever this origin has it open.
    static func forget(scope: Scope?, id: String) {
        guard let scope else { return }
        save(grants(scope: scope).filter { $0.id != id }, scope: scope)
        for session in sessions.values where session.scope == scope { session.revoke(keeping: present(scope: scope)) }
    }

    static func forgetPrivate(tabID: UUID) { privateGrants.removeValue(forKey: tabID) }

    /// A profile is going. Its private tabs keep theirs until they close.
    static func forgetAll(profileID: UUID) {
        let match = prefix + profileID.uuidString.lowercased() + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(match) { defaults.removeObject(forKey: key) }
        for session in sessions.values where session.scope.profileID == profileID && session.scope.privateTabID == nil {
            session.revoke(keeping: [])
        }
    }

    /// The interfaces of granted devices that are plugged in and may be shown to a page.
    private static func present(scope: Scope) -> [(grant: Grant, device: HIDDeviceInfo)] {
        let grants = grants(scope: scope)
        guard !grants.isEmpty else { return [] }
        return HIDDevices.shared.devices.compactMap { device in
            guard device.isExposable, let grant = grants.first(where: { $0.identity == device.identity }) else { return nil }
            return (grant, device)
        }
    }

    // MARK: - Who may ask

    /// HTTPS, or HTTP to this Mac itself. Mirrors the page's `isSecureContext`, so not
    /// `DeveloperMode.isLocal`: that one also takes `0.0.0.0`, which is no loopback address and no secure context.
    nonisolated static func isSecure(_ scope: Scope) -> Bool {
        if scope.scheme == "https" { return true }
        let host = scope.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // inet_pton, not a resolver: a name is never looked up to decide this.
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return v4.s_addr & 0xff == 127 }    // network order: first octet
        return inet_pton(AF_INET6, host, &v6) == 1 && withUnsafeBytes(of: &v6) { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
    }

    // MARK: - One document's devices

    /// A granted device arrived, one the page knew about left or was taken back, or an
    /// open one sent a report.
    private enum Event: Sendable {
        case connect(Grant, HIDDeviceInfo), disconnect(UInt64), closed(UInt64)
    }

    @MainActor private final class Session {
        /// Input reports a page has not collected. Past this the oldest go: a page that
        /// stopped listening must not hold every report a gamepad sends.
        static let maxReports = 1024

        let scope: Scope
        var open: [UInt64: (device: HIDDeviceInfo, transport: any HIDTransport)] = [:]
        var opening: Set<UInt64> = []
        /// The page's name for each interface it has been shown, and the grant that showed it.
        var handles: [String: (entryID: UInt64, grant: String)] = [:]
        /// Granted interfaces that were present at the last look; a change is an event.
        var known: Set<UInt64>
        var events: [Event] = []
        var reports: [(entryID: UInt64, id: UInt8, data: Data)] = []
        var waiter: CheckedContinuation<Bool, Never>?
        var gesture: ContinuousClock.Instant?
        var chooser: SitePermissionPrompt?
        weak var chooserWindow: NSWindow?
        init(scope: Scope) {
            self.scope = scope
            known = Set(WebHID.present(scope: scope).map(\.device.entryID))
        }

        /// An opaque name: the registry's own id would tell every origin the same thing.
        func handle(_ device: HIDDeviceInfo, grant: Grant) -> String {
            if let handle = handles.first(where: { $0.value.entryID == device.entryID })?.key { return handle }
            let handle = UUID().uuidString
            handles[handle] = (device.entryID, grant.id)
            return handle
        }

        func info(_ device: HIDDeviceInfo, grant: Grant) -> [String: Any] {
            ["id": handle(device, grant: grant), "vendorId": device.vendorID, "productId": device.productID,
             "productName": device.product, "collections": device.collections.map(\.json)]
        }

        /// Everything waiting for the page, reports first: a device's last words come before its leaving.
        func drain() -> [[String: Any]] {
            func handle(_ entryID: UInt64) -> String? { handles.first { $0.value.entryID == entryID }?.key }
            var out: [[String: Any]] = reports.compactMap { report in
                handle(report.entryID).map { ["type": "input", "id": $0, "reportId": Int(report.id), "data": report.data.base64EncodedString()] }
            }
            for event in events {
                switch event {
                case .connect(let grant, let device): out.append(["type": "connect", "device": info(device, grant: grant)])
                case .disconnect(let entryID): if let id = handle(entryID) { out.append(["type": "disconnect", "id": id]) }
                case .closed(let entryID): if let id = handle(entryID) { out.append(["type": "close", "id": id]) }
                }
            }
            reports = []; events = []
            return out
        }

        func wake() {
            guard let waiter, !events.isEmpty || !reports.isEmpty else { return }
            self.waiter = nil
            waiter.resume(returning: true)
        }

        /// Closes what is no longer granted and tells the page it is closed.
        func revoke(keeping present: [(grant: Grant, device: HIDDeviceInfo)]) {
            known = Set(present.map(\.device.entryID))
            for entryID in open.keys.sorted() where !known.contains(entryID) {
                open.removeValue(forKey: entryID)?.transport.close()
                events.append(.closed(entryID))
            }
            wake()
        }

        func end() {
            chooser?.finish(.abort)
            open.values.forEach { $0.transport.close() }
            open.removeAll()
            waiter?.resume(returning: false)
            waiter = nil
        }
    }
    private static var sessions: [UUID: Session] = [:]

    #if DEBUG
    /// Fixtures answer the chooser themselves: no popover, and no hardware to pick from.
    static var chooserForTesting: (([HIDDeviceInfo]) -> HIDDeviceInfo?)?
    /// …and stand in for the device.
    static var transportForTesting: ((HIDDeviceInfo, @escaping @Sendable (UInt8, Data) -> Void) -> (any HIDTransport)?)?
    #endif

    /// The chooser open in this window, if any: a camera or location question that arrives
    /// meanwhile is turned away, as it would be by any other bubble, rather than stacked on it.
    static func chooser(in window: NSWindow) -> SitePermissionPrompt? {
        sessions.values.first { $0.chooser != nil && $0.chooserWindow === window }?.chooser
    }

    /// A tab in the middle of configuring a keyboard is busy, however long it has been in the background.
    static func hasOpenDevice(tabID: UUID) -> Bool {
        sessions[tabID].map { !$0.open.isEmpty || !$0.opening.isEmpty } ?? false
    }

    private static func watch() {
        HIDDevices.shared.onChange = { devicesChanged() }
        HIDDevices.shared.start()
    }

    /// A new document, or none: its devices close and its chooser goes. A navigation that has
    /// only started takes the chooser down but leaves the devices, because it may yet turn
    /// into a download and leave the page exactly where it was.
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

    private static func devicesChanged() {
        for session in sessions.values {
            let present = present(scope: session.scope)
            let now = Set(present.map(\.device.entryID))
            for entryID in session.known.subtracting(now).sorted() {
                session.open.removeValue(forKey: entryID)?.transport.close()
                session.events.append(.disconnect(entryID))
            }
            for entry in present where !session.known.contains(entry.device.entryID) {
                session.events.append(.connect(entry.grant, entry.device))
            }
            session.known = now
            session.wake()
        }
    }

    /// One input report, from the device's queue. Dropped unless that document still has
    /// the device open and the report is one a page may see.
    private static func received(tabID: UUID, session: Session, entryID: UInt64, id: UInt8, data: Data) {
        guard sessions[tabID] === session, let device = session.open[entryID]?.device, !device.isProtected(.input, id: id) else { return }
        if session.reports.count >= Session.maxReports { session.reports.removeFirst() }
        session.reports.append((entryID, id, data))
        session.wake()
    }

    /// One call from the page. The reply is the call's result; a throw is its rejection.
    private static func handle(_ message: WKScriptMessage, tab: Tab?) async throws(HIDError) -> Any? {
        guard let tab, !tab.tornDown, let web = tab.existingWeb, message.webView === web, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let op = body["op"] as? String,
              let scope = scope(of: message, tab: tab) else { throw .security("HID devices are not available to this page.") }
        watch()
        let session = session(tab: tab, scope: scope)
        let tabID = tab.id
        // Work that waits can outlive its document; nothing it produced may be handed on then.
        var current: Bool { sessions[tabID] === session }

        switch op {
        case "devices":
            return present(scope: scope).map { session.info($0.device, grant: $0.grant) }
        case "events":
            session.waiter?.resume(returning: false)
            session.waiter = nil
            if session.events.isEmpty, session.reports.isEmpty {
                guard await withCheckedContinuation({ session.waiter = $0 }) else { return nil }
            }
            return session.drain()
        case "request":
            let filters = try Filter.parse(body["filters"])
            var excluding: [Filter] = []
            if let value = body["exclusionFilters"] {
                excluding = try Filter.parse(value, name: "exclusionFilters")
                if excluding.isEmpty { throw .type("'exclusionFilters', if present, must contain at least one filter.") }
            }
            guard let gesture = session.gesture, ContinuousClock.now - gesture < .seconds(2) else {
                throw .security("Must be handling a user gesture to show a permission request.")
            }
            session.gesture = nil
            guard session.chooser == nil else { throw .state("A device chooser is already open.") }
            // Cancelling is not an error here: the page is handed no devices.
            guard let identity = await choose(session: session, tab: tab, web: web, filters: filters, excluding: excluding), current,
                  let picked = Filter.candidates(HIDDevices.shared.devices, filters: filters, excluding: excluding)
                      .first(where: { $0.identity == identity }) else { return [Any]() }
            let grant = grant(picked, scope: scope)
            SiteChanges.shared.bump()
            return Filter.candidates(HIDDevices.shared.devices, filters: filters, excluding: excluding)
                .filter { $0.identity == identity }.map { session.info($0, grant: grant) }
        default: break
        }

        guard let handle = body["id"] as? String, let named = session.handles[handle] else { throw .type("Missing device.") }
        let entryID = named.entryID
        switch op {
        case "forget":
            forget(scope: scope, id: named.grant)
            SiteChanges.shared.bump()
        case "close":
            session.open.removeValue(forKey: entryID)?.transport.close()
        case "open":
            let failed = HIDError.notAllowed("Failed to open the device.")
            guard session.open[entryID] == nil, !session.opening.contains(entryID) else { throw .state("The device is already open.") }
            guard let device = present(scope: scope).first(where: { $0.device.entryID == entryID })?.device else { throw failed }
            session.opening.insert(entryID)
            defer { session.opening.remove(entryID) }
            let input: @Sendable (UInt8, Data) -> Void = { id, data in
                // The main queue keeps the device's order; a Task per report need not.
                // ponytail: one hop per report. A device at 1000 reports a second is fine;
                // batch on the device's queue if one ever is not.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { received(tabID: tabID, session: session, entryID: entryID, id: id, data: data) }
                }
            }
            var transport: (any HIDTransport)?
            #if DEBUG
            if let transportForTesting { transport = transportForTesting(device, input) }
            else { transport = await HIDConnection.open(device, onInput: input) }
            #else
            transport = await HIDConnection.open(device, onInput: input)
            #endif
            guard let opened = transport else { throw failed }
            // Forgotten, unplugged or navigated away while macOS was opening it.
            guard current, present(scope: scope).contains(where: { $0.device.entryID == entryID }) else {
                opened.close()
                throw failed
            }
            session.open[entryID] = (device, opened)
        case "send":
            let failed = HIDError.notAllowed(body["type"] as? String == "feature" ? "Failed to write the feature report." : "Failed to write the report.")
            guard let connection = session.open[entryID] else { throw .state("The device must be opened first.") }
            guard let type = (body["type"] as? String).flatMap(HIDReportType.init), let id = reportID(body["reportId"]),
                  let text = body["data"] as? String, text.utf8.count <= 131072, let data = Data(base64Encoded: text) else {
                throw .type("Invalid report.")
            }
            guard connection.device.maySend(type, id: id, length: data.count),
                  await connection.transport.send(type, id: id, data: data) else { throw failed }
        case "receive":
            guard let connection = session.open[entryID] else { throw .state("The device must be opened first.") }
            guard let id = reportID(body["reportId"]) else { throw .type("Invalid report.") }
            guard connection.device.mayReceiveFeature(id: id),
                  let data = await connection.transport.feature(id: id, length: connection.device.descriptor.maxBytes(.feature) + 1),
                  current else { throw .notAllowed("Failed to receive the feature report.") }
            return data.base64EncodedString()
        default: throw .type("Unknown HID operation.")
        }
        return nil
    }

    private static func reportID(_ value: Any?) -> UInt8? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt8(exactly: number.doubleValue)
    }

    // MARK: - The chooser

    /// The user's pick, or nil. Only the window showing this page can be asked, and only
    /// when nothing else is already asking there.
    private static func choose(session: Session, tab: Tab, web: WKWebView, filters: [Filter],
                               excluding: [Filter]) async -> HIDDeviceInfo.Identity? {
        // The bubble names the origin that asked; that has to be the one in the address bar.
        guard session.scope == SitePermissions.scope(for: tab) else { return nil }
        #if DEBUG
        if let chooserForTesting {
            return chooserForTesting(Filter.candidates(HIDDevices.shared.devices, filters: filters, excluding: excluding))?.identity
        }
        #endif
        guard let window = web.window, window.isVisible, !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              SitePermissions.activePrompt(in: window) == nil, !sessions.values.contains(where: { $0.chooser != nil })
        else { return nil }
        let scope = session.scope
        let site = scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
        var picked: HIDDeviceInfo.Identity?
        let prompt = SitePermissionPrompt(width: 300) { respond in
            AnyView(HIDChooser(site: site, filters: filters, excluding: excluding) { identity in
                picked = identity
                respond(identity == nil ? .abort : .OK)
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

/// The list the user picks from: one row per physical device, however many interfaces it
/// has. It follows the devices as they are plugged in, because the usual order is to
/// click Connect and then go looking for the cable.
private struct HIDChooser: View {
    let site: String
    let filters: [WebHID.Filter]
    let excluding: [WebHID.Filter]
    let respond: (HIDDeviceInfo.Identity?) -> Void
    @ObservedObject private var devices = HIDDevices.shared
    @State private var selection: HIDDeviceInfo.Identity?

    var body: some View {
        // The first interface of each device names its row.
        let candidates = WebHID.Filter.candidates(devices.devices, filters: filters, excluding: excluding)
            .reduce(into: [HIDDeviceInfo]()) { rows, device in
                if !rows.contains(where: { $0.identity == device.identity }) { rows.append(device) }
            }
        let picked = selection.flatMap { identity in candidates.contains { $0.identity == identity } ? identity : nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
                Text("\(site) wants to connect to a HID device")
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One height whatever is plugged in, so the bubble does not resize under the pointer.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(candidates, id: \.identity) { device in
                        Button { selection = device.identity } label: {
                            Text(device.label).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(.primary.opacity(picked == device.identity ? 0.21 : 0.04), in: .rect(cornerRadius: 6))
                                .contentShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked == device.identity ? .isSelected : [])
                    }
                }
            }
            .frame(height: 120)
            .overlay {
                if candidates.isEmpty {
                    Text("No compatible devices found.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { respond(nil) } label: { Text("Cancel") }
                    .buttonStyle(PermissionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                // No default key: a keystroke meant for the page must not be able to grant.
                Button { respond(picked) } label: { Text("Connect") }
                    .buttonStyle(PermissionButtonStyle(emphasized: true))
                    .disabled(picked == nil)
                    .opacity(picked == nil ? 0.5 : 1)
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.primary.opacity(0.8))
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("HID device request from \(site)")
    }
}
