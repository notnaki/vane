import AppKit
import SwiftUI
import WebKit

/// The WebUSB API (`navigator.usb`) for system WebKit, which has none.
///
/// A page script defines the spec's objects and forwards each call here; USBDevice.swift
/// does the I/O. The page script is the page's own and is trusted with nothing: every
/// message is checked again on this side, against the device's own descriptors and what
/// this document has claimed. A device is reachable only from a main-frame document in a
/// secure context, for a device the user picked in the chooser for that exact origin and
/// profile, never for a security key, and never through an interface of a class macOS
/// already uses (USBBlocklist). Opaque origins have no scope and get nothing.
@MainActor enum WebUSB {
    typealias Scope = SitePermissions.Scope
    static let messageName = "vaneUSB"
    static let gestureName = "vaneUSBGesture"
    static let gestureWorld = WKContentWorld.world(name: "vane-usb")
    static let gestureEvent = "vane-usb-request"
    static let gestureScript = DeviceAccess.gestureScript(event: gestureEvent, handler: gestureName)

    /// Definitions only: no listener, timer or message until the page uses the API.
    static let script = """
    (() => {
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(messageName);
      if (!isSecureContext || !handler || 'usb' in Navigator.prototype) return;
      \(DeviceAccess.pagePrelude(unavailable: "'NetworkError', 'The device is not available.'"))
      // WebIDL's `[EnforceRange]` integers.
      const ranged = (value, max, what) => {
        const number = Math.trunc(Number(value));
        if (!(number >= 0 && number <= max)) throw new TypeError(what + ' is outside the expected range.');
        return number;
      };
      const octet = (value, what) => ranged(value, 0xff, what);
      const sequence = (value, name) => {
        if (!value || typeof value !== 'object' || typeof value[Symbol.iterator] !== 'function') {
          throw new TypeError(name + ' must be a sequence of filters.');
        }
        return Array.from(value, filter => {
          const out = {};
          if (filter && typeof filter === 'object') {
            for (const key of ['vendorId', 'productId', 'classCode', 'subclassCode', 'protocolCode']) {
              if (filter[key] !== undefined) out[key] = Number(filter[key]);
            }
            if (filter.serialNumber !== undefined) out.serialNumber = String(filter.serialNumber);
          }
          return out;
        });
      };
      const setup = value => {
        if (!value || typeof value !== 'object') throw new TypeError('The setup packet is missing.');
        const requestType = ['standard', 'class', 'vendor'].indexOf(value.requestType);
        const recipient = ['device', 'interface', 'endpoint', 'other'].indexOf(value.recipient);
        if (requestType < 0) throw new TypeError("The provided value is not a valid enum value of type USBRequestType.");
        if (recipient < 0) throw new TypeError("The provided value is not a valid enum value of type USBRecipient.");
        return { requestType, recipient, request: octet(value.request, 'request'),
                 value: ranged(value.value, 0xffff, 'value'), index: ranged(value.index, 0xffff, 'index') };
      };

      let building = false, usb = null, listening = false, used = false, generation = 0;
      const slots = new WeakMap(), devices = new Map(), parts = new WeakMap();
      const slot = device => {
        const s = slots.get(device);
        if (!s) throw new TypeError('Illegal invocation');
        return s;
      };
      const part = object => {
        const p = parts.get(object);
        if (!p) throw new TypeError('Illegal invocation');
        return p;
      };
      const make = (Class, data) => {
        building = true;
        let object;
        try { object = new Class(); } finally { building = false; }
        parts.set(object, data);
        return object;
      };
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
      const configured = device => {
        const s = opened(device);
        if (s.active === null) throw fail('InvalidStateError', 'The device must have a configuration selected.');
        return s;
      };
      const changing = async (s, work) => {
        s.busy = true;
        try { return await work(); } finally { s.busy = false; }
      };
      const interfaceOf = (s, number) => {
        const config = s.configurations.find(c => part(c).value === s.active);
        const found = config && part(config).interfaces.find(i => part(i).number === number);
        if (!found) throw fail('NotFoundError', 'The interface number provided is not supported by the device in its current configuration.');
        return found;
      };
      const reset = s => { s.claimed = new Set(); s.alternates = new Map(); };

      const illegal = () => { if (!building) throw new TypeError('Illegal constructor'); };
      class USBEndpoint { constructor() { illegal(); }
        get endpointNumber() { return part(this).endpointNumber; }
        get direction() { return part(this).direction; }
        get type() { return part(this).type; }
        get packetSize() { return part(this).packetSize; } }
      class USBAlternateInterface { constructor() { illegal(); }
        get alternateSetting() { return part(this).alternateSetting; }
        get interfaceClass() { return part(this).interfaceClass; }
        get interfaceSubclass() { return part(this).interfaceSubclass; }
        get interfaceProtocol() { return part(this).interfaceProtocol; }
        get interfaceName() { return part(this).interfaceName; }
        get endpoints() { return part(this).endpoints; } }
      class USBInterface { constructor() { illegal(); }
        get interfaceNumber() { return part(this).number; }
        get alternate() {
          const p = part(this), s = slots.get(p.device), setting = (s && s.alternates.get(p.number)) || 0;
          return p.alternates.find(a => part(a).alternateSetting === setting) || p.alternates[0] || null;
        }
        get alternates() { return part(this).alternates; }
        get claimed() { const p = part(this), s = slots.get(p.device); return !!s && s.claimed.has(p.number); } }
      class USBConfiguration { constructor() { illegal(); }
        get configurationValue() { return part(this).value; }
        get configurationName() { return part(this).name; }
        get interfaces() { return part(this).interfaces; } }

      const freeze = list => Object.freeze(list);
      const configurations = (device, list) => freeze(list.map(c => make(USBConfiguration, {
        value: c.configurationValue, name: c.configurationName,
        interfaces: freeze(c.interfaces.map(i => make(USBInterface, { device, number: i.interfaceNumber,
          alternates: freeze(i.alternates.map(a => make(USBAlternateInterface, { ...a,
            endpoints: freeze(a.endpoints.map(e => make(USBEndpoint, e))) }))) })))
      })));

      class USBInTransferResult {
        #status; #data;
        constructor(status, data) { this.#status = status; this.#data = data === undefined ? null : data; }
        get status() { return this.#status; }
        get data() { return this.#data; }
      }
      class USBOutTransferResult {
        #status; #bytesWritten;
        constructor(status, bytesWritten = 0) { this.#status = status; this.#bytesWritten = bytesWritten; }
        get status() { return this.#status; }
        get bytesWritten() { return this.#bytesWritten; }
      }
      const inResult = reply => new USBInTransferResult(reply.status, reply.status === 'stall' ? null : bytes(reply.data));
      const outResult = reply => new USBOutTransferResult(reply.status, reply.bytesWritten);
      const notSupported = async () => { throw fail('NotSupportedError', 'Isochronous transfers are not supported.'); };

      class USBDevice {
        constructor() { illegal(); }
        get usbVersionMajor() { return slot(this).info.usbVersion[0]; }
        get usbVersionMinor() { return slot(this).info.usbVersion[1]; }
        get usbVersionSubminor() { return slot(this).info.usbVersion[2]; }
        get deviceClass() { return slot(this).info.deviceClass; }
        get deviceSubclass() { return slot(this).info.deviceSubclass; }
        get deviceProtocol() { return slot(this).info.deviceProtocol; }
        get vendorId() { return slot(this).info.vendorId; }
        get productId() { return slot(this).info.productId; }
        get deviceVersionMajor() { return slot(this).info.deviceVersion[0]; }
        get deviceVersionMinor() { return slot(this).info.deviceVersion[1]; }
        get deviceVersionSubminor() { return slot(this).info.deviceVersion[2]; }
        get manufacturerName() { return slot(this).info.manufacturerName; }
        get productName() { return slot(this).info.productName; }
        get serialNumber() { return slot(this).info.serialNumber; }
        get configuration() {
          const s = slot(this);
          return s.configurations.find(c => part(c).value === s.active) || null;
        }
        get configurations() { return slot(this).configurations; }
        get opened() { return slot(this).opened; }
        async open() {
          const s = slot(this);
          settled(s);
          if (s.opened) return;
          const active = await changing(s, () => call('open', { id: s.id }));
          s.opened = true;
          s.active = active ?? null;
          reset(s);
        }
        async close() {
          const s = slot(this);
          settled(s);
          if (!s.opened) return;
          await changing(s, () => call('close', { id: s.id }));
          s.opened = false;
          reset(s);
        }
        async forget() {
          const s = slot(this);
          settled(s, true);
          await changing(s, () => call('forget', { id: s.id }));
          s.opened = false;
          s.forgotten = true;
          reset(s);
        }
        async selectConfiguration(value) {
          const s = opened(this), configurationValue = octet(value, 'configurationValue');
          if (!s.configurations.some(c => part(c).value === configurationValue)) {
            throw fail('NotFoundError', 'The configuration value provided is not supported by the device.');
          }
          if (s.active === configurationValue) return;
          // Claims are released natively before the switch, so they go here even if it fails.
          try { await changing(s, () => call('configure', { id: s.id, value: configurationValue })); } finally { reset(s); }
          s.active = configurationValue;
        }
        async claimInterface(number) {
          const s = configured(this), interfaceNumber = octet(number, 'interfaceNumber');
          interfaceOf(s, interfaceNumber);
          if (s.claimed.has(interfaceNumber)) return;
          await changing(s, () => call('claim', { id: s.id, interface: interfaceNumber }));
          s.claimed.add(interfaceNumber);
        }
        async releaseInterface(number) {
          const s = configured(this), interfaceNumber = octet(number, 'interfaceNumber');
          interfaceOf(s, interfaceNumber);
          if (!s.claimed.has(interfaceNumber)) return;
          await changing(s, () => call('release', { id: s.id, interface: interfaceNumber }));
          s.claimed.delete(interfaceNumber);
          s.alternates.delete(interfaceNumber);
        }
        async selectAlternateInterface(number, setting) {
          const s = configured(this), interfaceNumber = octet(number, 'interfaceNumber'), alternateSetting = octet(setting, 'alternateSetting');
          const found = interfaceOf(s, interfaceNumber);
          if (!s.claimed.has(interfaceNumber)) throw fail('InvalidStateError', 'The interface must be claimed first.');
          if (!part(found).alternates.some(a => part(a).alternateSetting === alternateSetting)) {
            throw fail('NotFoundError', 'The alternate setting provided is not supported by the device in its current configuration.');
          }
          await changing(s, () => call('alternate', { id: s.id, interface: interfaceNumber, setting: alternateSetting }));
          s.alternates.set(interfaceNumber, alternateSetting);
        }
        async controlTransferIn(packet, length) {
          const s = opened(this);
          return inResult(await call('controlIn', { id: s.id, setup: setup(packet), length: ranged(length, 0xffff, 'length') }));
        }
        async controlTransferOut(packet, data) {
          const s = opened(this), sent = setup(packet);
          return outResult(await call('controlOut', { id: s.id, setup: sent, data: data === undefined ? '' : toBase64.call(view(data)) }));
        }
        async clearHalt(direction, endpointNumber) {
          const s = configured(this);
          if (direction !== 'in' && direction !== 'out') throw new TypeError("The provided value is not a valid enum value of type USBDirection.");
          await call('clearHalt', { id: s.id, direction, endpoint: octet(endpointNumber, 'endpointNumber') });
        }
        async transferIn(endpointNumber, length) {
          const s = configured(this);
          return inResult(await call('transfer', { id: s.id, direction: 'in', endpoint: octet(endpointNumber, 'endpointNumber'),
                                                   length: ranged(length, 0xffffffff, 'length') }));
        }
        async transferOut(endpointNumber, data) {
          const s = configured(this);
          return outResult(await call('transfer', { id: s.id, direction: 'out', endpoint: octet(endpointNumber, 'endpointNumber'),
                                                    data: toBase64.call(view(data)) }));
        }
        isochronousTransferIn() { return notSupported(); }
        isochronousTransferOut() { return notSupported(); }
        async reset() {
          const s = opened(this);
          await changing(s, () => call('reset', { id: s.id }));
        }
      }

      class USBConnectionEvent extends Event {
        #device;
        constructor(type, init) {
          super(type, init);
          if (!init || !slots.has(init.device)) throw new TypeError("Failed to construct 'USBConnectionEvent': member device is not of type USBDevice.");
          this.#device = init.device;
        }
        get device() { return this.#device; }
      }

      const adopt = info => {
        let device = devices.get(info.id);
        if (!device) {
          building = true;
          try { device = new USBDevice(); } finally { building = false; }
          slots.set(device, { id: info.id, opened: false, busy: false, forgotten: false, claimed: new Set(), alternates: new Map() });
          devices.set(info.id, device);
        }
        const s = slots.get(device);
        s.forgotten = false;
        if (!s.opened) s.active = info.configuration;
        s.info = Object.freeze({ ...info, usbVersion: Object.freeze(info.usbVersion), deviceVersion: Object.freeze(info.deviceVersion) });
        s.configurations = s.configurations || configurations(device, info.configurations);
        return device;
      };
      // One held request, answered when a granted device comes or goes. Started on first use.
      const listen = async () => {
        used = true;
        if (listening) return;
        listening = true;
        const mine = generation;
        try {
          for (;;) {
            const events = await call('events');
            if (!events || mine !== generation) break;
            for (const event of events) {
              if (event.type === 'connect') {
                usb.dispatchEvent(new USBConnectionEvent('connect', { device: adopt(event.device) }));
                continue;
              }
              const device = devices.get(event.id), s = device && slots.get(device);
              if (!s) continue;
              // Unplugged, or forgotten from Site Controls: closed either way.
              s.opened = false;
              reset(s);
              if (event.type === 'disconnect') usb.dispatchEvent(new USBConnectionEvent('disconnect', { device }));
            }
          }
        } catch (e) {}
        if (mine === generation) listening = false;
      };
      // Back from the back/forward cache: this side's document ended when the page left,
      // so every device closed and every id went stale. Start over with what is granted now.
      addEventListener('pageshow', e => {
        if (!e.persisted) return;
        for (const device of devices.values()) { const s = slots.get(device); s.opened = false; reset(s); }
        devices.clear();
        generation++;
        listening = false;
        if (used) listen();
      });

      class USB extends EventTarget {
        constructor() { illegal(); super(); }
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
          const info = await call('request', sent);
          if (!info) throw fail('NotFoundError', 'No device selected.');
          return adopt(info);
        }
      }

      handlerAttribute(USB, 'connect');
      handlerAttribute(USB, 'disconnect');
      expose([[USB, 'USB'], [USBDevice, 'USBDevice'], [USBConfiguration, 'USBConfiguration'], [USBInterface, 'USBInterface'],
              [USBAlternateInterface, 'USBAlternateInterface'], [USBEndpoint, 'USBEndpoint'], [USBConnectionEvent, 'USBConnectionEvent'],
              [USBInTransferResult, 'USBInTransferResult'], [USBOutTransferResult, 'USBOutTransferResult']]);
      Object.defineProperty(Navigator.prototype, 'usb', { configurable: true, enumerable: true,
        get() {
          if (!usb) {
            building = true;
            try { usb = new USB(); } finally { building = false; }
          }
          return usb;
        } });
    })();
    """

    /// Main frame only: `WKFrameInfo` cannot say whether a child frame was delegated `usb`
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

    /// Synchronous form, as Web Serial and WebHID: WebKit calls it on the main thread in the
    /// order the page sent its messages, and each task is queued in that order.
    private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor [tab] in
                    do throws(USBError) { replyHandler(["value": try await WebUSB.handle(message, tab: tab) ?? NSNull()], nil) }
                    catch { replyHandler(["error": [error.name, error.message]], nil) }
                }
            }
        }
    }

    // MARK: - Filters

    /// One `requestDevice` filter. A class code matches the device's own class or any
    /// interface alternate's, in any configuration, as in Chromium.
    struct Filter: Equatable, Sendable {
        var vendorID: Int?
        var productID: Int?
        var classCode: Int?
        var subclassCode: Int?
        var protocolCode: Int?
        var serialNumber: String?

        func matches(_ device: USBDeviceInfo) -> Bool {
            if let vendorID, device.vendorID != vendorID { return false }
            if let productID, device.productID != productID { return false }
            if let serialNumber, device.serialNumber != serialNumber { return false }
            guard let classCode else { return true }
            func codes(_ c: UInt8, _ s: UInt8, _ p: UInt8) -> Bool {
                Int(c) == classCode && (subclassCode ?? Int(s)) == Int(s) && (protocolCode ?? Int(p)) == Int(p)
            }
            return codes(device.deviceClass, device.subclass, device.protocol) || device.configurations.contains { config in
                config.interfaces.contains { $0.alternates.contains { codes($0.interfaceClass, $0.subclass, $0.protocol) } }
            }
        }

        static func parse(_ body: Any?, name: String = "filters") throws(USBError) -> [Filter] {
            guard let list = body as? [[String: Any]] else { throw .type("\(name) must be a sequence of filters.") }
            var filters: [Filter] = []
            for entry in list {
                func id(_ key: String, max: Int) throws(USBError) -> Int? {
                    guard let value = entry[key] else { return nil }
                    // A JavaScript `true` is an NSNumber too; it is not an id.
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          let id = Int(exactly: number.doubleValue), (0...max).contains(id) else { throw .type("\(key) is not valid.") }
                    return id
                }
                var serial: String?
                if let value = entry["serialNumber"] {
                    guard let text = value as? String else { throw .type("serialNumber is not valid.") }
                    serial = text
                }
                let filter = Filter(vendorID: try id("vendorId", max: 0xFFFF), productID: try id("productId", max: 0xFFFF),
                                    classCode: try id("classCode", max: 0xFF), subclassCode: try id("subclassCode", max: 0xFF),
                                    protocolCode: try id("protocolCode", max: 0xFF), serialNumber: serial)
                if filter.productID != nil, filter.vendorID == nil { throw .type("A filter containing a productId must also contain a vendorId.") }
                if filter.subclassCode != nil, filter.classCode == nil { throw .type("A filter containing a subclassCode must also contain a classCode.") }
                if filter.protocolCode != nil, filter.subclassCode == nil { throw .type("A filter containing a protocolCode must also contain a subclassCode.") }
                filters.append(filter)
            }
            return filters
        }

        /// What the chooser lists: devices that are not security keys, that any filter
        /// matches (an empty filter matches everything) and no exclusion filter does.
        static func candidates(_ devices: [USBDeviceInfo], filters: [Filter], excluding: [Filter] = []) -> [USBDeviceInfo] {
            devices.filter { device in
                !device.isBlocked && (filters.isEmpty || filters.contains { $0.matches(device) })
                    && !excluding.contains { $0.matches(device) }
            }
        }
    }

    // MARK: - What is remembered

    struct Grant: Codable, Equatable, Sendable {
        let id: String
        var identity: USBDeviceInfo.Identity
        var name: String
    }

    /// A device without a serial number is known only by the port it is in, so its grant
    /// lives in memory and ends when it is unplugged, as in Chromium.
    private static let store = DeviceGrants<Grant>(prefix: "usbDevice.v1.") { !$0.identity.serialNumber.isEmpty }

    static func grants(scope: Scope?) -> [Grant] { store.grants(scope: scope) }
    static func all(profileID: UUID) -> [(scope: Scope, grant: Grant)] { store.all(profileID: profileID) }
    static func forgetPrivate(tabID: UUID) { store.forgetPrivate(tabID: tabID) }

    /// The chooser's answer. Picking a device again refreshes its grant rather than adding one.
    @discardableResult static func grant(_ device: USBDeviceInfo, scope: Scope) -> Grant {
        var all = grants(scope: scope)
        let grant: Grant
        if let index = all.firstIndex(where: { $0.identity == device.identity }) {
            all[index].name = device.label
            grant = all[index]
        } else {
            grant = Grant(id: UUID().uuidString, identity: device.identity, name: device.label)
            all.append(grant)
        }
        store.save(all, scope: scope)
        // Pages of this origin that are already open learn of it from `getDevices()`, not a connect event.
        for session in sessions.values where session.scope == scope { session.known = Set(present(scope: scope).map(\.device.entryID)) }
        return grant
    }

    /// Takes the grant back and closes the device wherever this origin has it open.
    static func forget(scope: Scope?, id: String) {
        guard let scope else { return }
        store.save(grants(scope: scope).filter { $0.id != id }, scope: scope)
        for session in sessions.values where session.scope == scope { session.revoke(keeping: present(scope: scope)) }
        SiteChanges.shared.bump()
    }

    static func forgetAll(profileID: UUID? = nil) {
        store.forgetAll(profileID: profileID)
        for session in sessions.values where (profileID == nil || session.scope.profileID == profileID) && session.scope.privateTabID == nil {
            session.revoke(keeping: [])
        }
    }

    /// Granted devices that are plugged in.
    private static func present(scope: Scope) -> [(grant: Grant, device: USBDeviceInfo)] {
        let grants = grants(scope: scope)
        guard !grants.isEmpty else { return [] }
        return USBDevices.shared.devices.compactMap { device in
            guard !device.isBlocked, let grant = grants.first(where: { $0.identity == device.identity }) else { return nil }
            return (grant, device)
        }
    }

    // MARK: - One document's devices

    private enum Event: Sendable {
        case connect(Grant, USBDeviceInfo), disconnect(UInt64), closed(UInt64)
    }

    /// What this document has done to one open device: the bridge's own record, which the
    /// page's mirror of it is never trusted for.
    private struct Opened {
        let device: USBDeviceInfo
        let transport: any USBTransport
        var configuration: UInt8?
        var claimed: Set<UInt8> = []
        var alternates: [UInt8: UInt8] = [:]

        /// The endpoint in a claimed interface's selected alternate, if this is one.
        func endpoint(_ address: UInt8) -> USBEndpoint? {
            guard let config = device.configuration(configuration) else { return nil }
            for interface in config.interfaces where claimed.contains(interface.number) {
                let setting = alternates[interface.number] ?? 0
                if let found = interface.alternates.first(where: { $0.setting == setting })?.endpoints.first(where: { $0.address == address }) {
                    return found
                }
            }
            return nil
        }
    }

    @MainActor private final class Session {
        let scope: Scope
        var open: [UInt64: Opened] = [:]
        var opening: Set<UInt64> = []
        /// Openings with a configure, claim, release, alternate or reset in flight.
        var changing: Set<ObjectIdentifier> = []
        /// The page's name for each device it has been shown, and the grant that showed it.
        var handles: [String: (entryID: UInt64, grant: String)] = [:]
        var known: Set<UInt64>
        /// Events a page has not collected. Past this the oldest go.
        static let maxEvents = 1024
        private(set) var events: [Event] = []
        var waiter: CheckedContinuation<Bool, Never>?
        var gesture: ContinuousClock.Instant?
        var chooser: SitePermissionPrompt?
        weak var chooserWindow: NSWindow?
        init(scope: Scope) {
            self.scope = scope
            known = Set(WebUSB.present(scope: scope).map(\.device.entryID))
        }

        /// An opaque name: the registry's own id would tell every origin the same thing.
        func handle(_ device: USBDeviceInfo, grant: Grant) -> String {
            if let handle = handles.first(where: { $0.value.entryID == device.entryID })?.key { return handle }
            let handle = UUID().uuidString
            handles[handle] = (device.entryID, grant.id)
            return handle
        }

        func info(_ device: USBDeviceInfo, grant: Grant) -> [String: Any] {
            device.json(id: handle(device, grant: grant), active: open[device.entryID]?.configuration ?? device.activeConfiguration)
        }

        func drain() -> [[String: Any]] {
            func handle(_ entryID: UInt64) -> String? { handles.first { $0.value.entryID == entryID }?.key }
            let out: [[String: Any]] = events.compactMap { event in
                switch event {
                case .connect(let grant, let device): ["type": "connect", "device": info(device, grant: grant)]
                case .disconnect(let entryID): handle(entryID).map { ["type": "disconnect", "id": $0] }
                case .closed(let entryID): handle(entryID).map { ["type": "close", "id": $0] }
                }
            }
            events = []
            return out
        }

        func post(_ event: Event) {
            if events.count >= Self.maxEvents { events.removeFirst() }
            events.append(event)
        }

        func close(_ entryID: UInt64) { open.removeValue(forKey: entryID)?.transport.close() }

        func wake() {
            guard let waiter, !events.isEmpty else { return }
            self.waiter = nil
            waiter.resume(returning: true)
        }

        func revoke(keeping present: [(grant: Grant, device: USBDeviceInfo)]) {
            known = Set(present.map(\.device.entryID))
            for entryID in open.keys.sorted() where !known.contains(entryID) {
                close(entryID)
                post(.closed(entryID))
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
    static var chooserForTesting: (([USBDeviceInfo]) -> USBDeviceInfo?)?
    /// …and stand in for the device.
    static var transportForTesting: ((USBDeviceInfo) -> (any USBTransport)?)?
    #endif

    static func chooser(in window: NSWindow) -> SitePermissionPrompt? {
        sessions.values.first { $0.chooser != nil && $0.chooserWindow === window }?.chooser
    }

    static func hasOpenDevice(tabID: UUID) -> Bool {
        sessions[tabID].map { !$0.open.isEmpty || !$0.opening.isEmpty } ?? false
    }

    static func watch() {
        USBDevices.shared.onChange = { devicesChanged() }
        USBDevices.shared.start()
    }

    /// A new document, or none: its devices close and its chooser goes. A navigation that has
    /// only started takes the chooser down but leaves the devices: it may yet be a download.
    static func endDocument(tabID: UUID, navigationStarted: Bool = false) {
        guard let session = sessions[tabID] else { return }
        if navigationStarted { session.chooser?.finish(.abort); return }
        sessions.removeValue(forKey: tabID)
        session.end()
    }

    /// The isolated world saw the request while the page had transient activation.
    static func gesture(_ message: WKScriptMessage, tab: Tab) {
        guard let scope = DeviceAccess.scope(of: message, tab: tab) else { return }
        watch()
        session(tab: tab, scope: scope).gesture = .now
    }

    private static func session(tab: Tab, scope: Scope) -> Session {
        if let session = sessions[tab.id], session.scope == scope { return session }
        endDocument(tabID: tab.id)
        let session = Session(scope: scope)
        sessions[tab.id] = session
        return session
    }

    private static func devicesChanged() {
        let plugged = Set(USBDevices.shared.devices.map(\.identity))
        if store.drop(where: { !plugged.contains($0.identity) }) { SiteChanges.shared.bump() }
        for session in sessions.values {
            let present = present(scope: session.scope)
            let now = Set(present.map(\.device.entryID))
            for entryID in session.known.subtracting(now).sorted() {
                session.close(entryID)
                session.post(.disconnect(entryID))
            }
            for entry in present where !session.known.contains(entry.device.entryID) {
                session.post(.connect(entry.grant, entry.device))
            }
            session.known = now
            session.wake()
        }
    }

    /// Reads a non-negative integer the page sent, at most `max`.
    private static func number(_ value: Any?, max: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int = Int(exactly: number.doubleValue), (0...max).contains(int) else { return nil }
        return int
    }

    /// The most a page may move in one transfer: messages cross as base64.
    static let maxTransfer = 4 << 20

    /// One call from the page. The reply is the call's result; a throw is its rejection.
    private static func handle(_ message: WKScriptMessage, tab: Tab?) async throws(USBError) -> Any? {
        guard let tab, !tab.tornDown, let web = tab.existingWeb, message.webView === web,
              let body = message.body as? [String: Any], let op = body["op"] as? String,
              let scope = DeviceAccess.scope(of: message, tab: tab) else { throw .security("USB devices are not available to this page.") }
        watch()
        let session = session(tab: tab, scope: scope)
        let tabID = tab.id
        var current: Bool { sessions[tabID] === session }

        switch op {
        case "devices":
            return present(scope: scope).map { session.info($0.device, grant: $0.grant) }
        case "events":
            session.waiter?.resume(returning: false)
            session.waiter = nil
            if session.events.isEmpty {
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
            // Cancelling rejects, as in Chrome: `requestDevice` hands back one device or none.
            guard let identity = await choose(session: session, tab: tab, web: web, filters: filters, excluding: excluding), current,
                  let picked = Filter.candidates(USBDevices.shared.devices, filters: filters, excluding: excluding)
                      .first(where: { $0.identity == identity }) else { return nil }
            let grant = grant(picked, scope: scope)
            SiteChanges.shared.bump()
            return session.info(picked, grant: grant)
        default: break
        }

        guard let handle = body["id"] as? String, let named = session.handles[handle] else { throw .type("Missing device.") }
        let entryID = named.entryID
        func opened() throws(USBError) -> Opened {
            guard let opened = session.open[entryID] else { throw .state("The device must be opened first.") }
            return opened
        }
        func configured() throws(USBError) -> (Opened, USBConfiguration) {
            let opened = try opened()
            guard let config = opened.device.configuration(opened.configuration) else { throw .state("The device must have a configuration selected.") }
            return (opened, config)
        }
        func interface(_ key: String = "interface") throws(USBError) -> (Opened, USBInterface) {
            let (opened, config) = try configured()
            guard let number = number(body[key], max: 0xFF),
                  let found = config.interfaces.first(where: { $0.number == UInt8(number) }) else {
                throw .notFound("The interface number provided is not supported by the device in its current configuration.")
            }
            return (opened, found)
        }
        /// Still this document's, still the same opening of the device, in the same configuration.
        func still(_ before: Opened) -> Bool {
            current && session.open[entryID]?.transport === before.transport && session.open[entryID]?.configuration == before.configuration
        }
        /// One state change at a time per opening, as in Chromium: a claim racing a
        /// `selectConfiguration` could otherwise land on the old configuration's interface.
        func changing(_ opened: Opened) throws(USBError) -> ObjectIdentifier {
            let key = ObjectIdentifier(opened.transport)
            guard !session.changing.contains(key) else { throw .state("An operation that changes the device state is in progress.") }
            session.changing.insert(key)
            return key
        }

        switch op {
        case "forget":
            forget(scope: scope, id: named.grant)
        case "close":
            session.close(entryID)
        case "open":
            if let already = session.open[entryID] { return already.configuration.map { Int($0) } }
            guard !session.opening.contains(entryID) else { return nil }
            guard let device = present(scope: scope).first(where: { $0.device.entryID == entryID })?.device else {
                throw .notFound("The device was disconnected.")
            }
            session.opening.insert(entryID)
            defer { session.opening.remove(entryID) }
            var transport: (any USBTransport)?
            #if DEBUG
            if let transportForTesting { transport = transportForTesting(device) } else { transport = await USBConnection.open(device) }
            #else
            transport = await USBConnection.open(device)
            #endif
            guard let opened = transport else { throw .network("Unable to open the device.") }
            // Forgotten, unplugged or navigated away while macOS was opening it.
            guard current, present(scope: scope).contains(where: { $0.device.entryID == entryID }) else {
                opened.close()
                throw .notFound("The device was disconnected.")
            }
            // The device's own answer at open: macOS or another app may have changed it since it was plugged in.
            session.open[entryID] = Opened(device: device, transport: opened, configuration: opened.configuration)
            return opened.configuration.map { Int($0) }
        case "configure":
            let opened = try opened()
            guard let value = number(body["value"], max: 0xFF), opened.device.configuration(UInt8(value)) != nil else {
                throw .notFound("The configuration value provided is not supported by the device.")
            }
            if opened.configuration == UInt8(value) { return nil }
            let key = try changing(opened)
            defer { session.changing.remove(key) }
            // The spec releases what is claimed before the configuration changes.
            for number in opened.claimed.sorted() {
                session.open[entryID]?.claimed.remove(number)
                session.open[entryID]?.alternates[number] = nil
                _ = await opened.transport.release(number)
            }
            let selected = await opened.transport.selectConfiguration(UInt8(value))
            guard current, session.open[entryID]?.transport === opened.transport else { throw .network("Unable to set device configuration.") }
            guard selected else { throw .network("Unable to set device configuration.") }
            session.open[entryID]?.configuration = UInt8(value)
            session.open[entryID]?.claimed = []
            session.open[entryID]?.alternates = [:]
            USBDevices.shared.configurationChanged(entryID: entryID, to: UInt8(value))
        case "claim":
            let (opened, found) = try interface()
            if opened.claimed.contains(found.number) { return nil }
            if found.isProtected { throw .security("The requested interface implements a protected class.") }
            let key = try changing(opened)
            defer { session.changing.remove(key) }
            guard await opened.transport.claim(found.number), still(opened) else { throw .network("Unable to claim interface.") }
            session.open[entryID]?.claimed.insert(found.number)
        case "release":
            let (opened, found) = try interface()
            guard opened.claimed.contains(found.number) else { return nil }
            let key = try changing(opened)
            defer { session.changing.remove(key) }
            session.open[entryID]?.claimed.remove(found.number)
            session.open[entryID]?.alternates[found.number] = nil
            guard await opened.transport.release(found.number) else { throw .network("Unable to release interface.") }
        case "alternate":
            let (opened, found) = try interface()
            guard opened.claimed.contains(found.number) else { throw .state("The interface must be claimed first.") }
            guard let setting = number(body["setting"], max: 0xFF), found.alternates.contains(where: { $0.setting == UInt8(setting) }) else {
                throw .notFound("The alternate setting provided is not supported by the device in its current configuration.")
            }
            let key = try changing(opened)
            defer { session.changing.remove(key) }
            guard await opened.transport.selectAlternate(found.number, setting: UInt8(setting)), still(opened) else {
                throw .network("Unable to set device interface.")
            }
            session.open[entryID]?.alternates[found.number] = UInt8(setting)
        case "controlIn", "controlOut":
            let opened = try opened()
            let setup = try controlSetup(body["setup"], opened: opened)
            var data: Data?
            var length = 0
            if op == "controlOut" {
                guard let text = body["data"] as? String, let decoded = Data(base64Encoded: text), decoded.count <= 0xFFFF else {
                    throw .type("Invalid data.")
                }
                data = decoded
            } else {
                guard let value = number(body["length"], max: 0xFFFF) else { throw .type("Invalid length.") }
                length = value
            }
            let result = await opened.transport.control(setup, data: data, length: length)
            guard let status = result.status, still(opened) else { throw .network("A transfer error has occurred.") }
            return op == "controlIn" ? ["status": status.rawValue, "data": result.data.prefix(length).base64EncodedString()]
                : ["status": status.rawValue, "bytesWritten": result.written]
        case "transfer":
            let (opened, _) = try configured()
            let isIn = body["direction"] as? String == "in"
            guard let number = number(body["endpoint"], max: 0xFF), (1...15).contains(number),
                  let endpoint = opened.endpoint(UInt8(number) | (isIn ? 0x80 : 0)), endpoint.kind != 1 else {
                throw .notFound("The specified endpoint is not part of a claimed and selected alternate interface.")
            }
            var data: Data?
            var length = 0
            if isIn {
                guard let value = WebUSB.number(body["length"], max: Int(UInt32.max)) else { throw .type("Invalid length.") }
                guard value <= maxTransfer else { throw .type("The transfer length is too large.") }
                length = value
            } else {
                guard let text = body["data"] as? String, text.utf8.count <= maxTransfer / 3 * 4 + 4,
                      let decoded = Data(base64Encoded: text) else { throw .type("The data is too large.") }
                data = decoded
            }
            let result = await opened.transport.transfer(endpoint: endpoint.address, data: data, length: length)
            guard let status = result.status, still(opened) else { throw .network("A transfer error has occurred.") }
            return isIn ? ["status": status.rawValue, "data": result.data.prefix(length).base64EncodedString()]
                : ["status": status.rawValue, "bytesWritten": result.written]
        case "clearHalt":
            let (opened, _) = try configured()
            let isIn = body["direction"] as? String == "in"
            guard let number = number(body["endpoint"], max: 0xFF), (1...15).contains(number),
                  let endpoint = opened.endpoint(UInt8(number) | (isIn ? 0x80 : 0)) else {
                throw .notFound("The specified endpoint is not part of a claimed and selected alternate interface.")
            }
            guard await opened.transport.clearHalt(endpoint: endpoint.address) else { throw .network("Unable to clear endpoint.") }
        case "reset":
            let opened = try opened()
            let key = try changing(opened)
            defer { session.changing.remove(key) }
            guard await opened.transport.reset(), still(opened) else { throw .network("Unable to reset the device.") }
            session.open[entryID]?.claimed = []
            session.open[entryID]?.alternates = [:]
        default: throw .type("Unknown USB operation.")
        }
        return nil
    }

    /// A setup packet a page may send: to the device as a whole, to an interface it has
    /// claimed, or to an endpoint of one. Standard requests that would change the device's
    /// configuration or an interface's setting behind the bridge's back must go through
    /// `selectConfiguration` and `selectAlternateInterface`, which check them.
    private static func controlSetup(_ value: Any?, opened: Opened) throws(USBError) -> USBSetup {
        guard let packet = value as? [String: Any], let type = number(packet["requestType"], max: 2),
              let recipient = number(packet["recipient"], max: 3), let request = number(packet["request"], max: 0xFF),
              let wValue = number(packet["value"], max: 0xFFFF), let index = number(packet["index"], max: 0xFFFF) else {
            throw .type("Invalid setup packet.")
        }
        let setup = USBSetup(requestType: UInt8(type << 5 | recipient), request: UInt8(request),
                             value: UInt16(wValue), index: UInt16(index))
        if type == 0, [0x05, 0x09, 0x0B].contains(request) {    // SET_ADDRESS, SET_CONFIGURATION, SET_INTERFACE
            throw .security("This request is not allowed; use selectConfiguration or selectAlternateInterface.")
        }
        switch recipient {
        case 1:
            guard opened.device.configuration(opened.configuration) != nil else { throw .state("The device must have a configuration selected.") }
            guard opened.claimed.contains(UInt8(index & 0xff)) else { throw .state("The specified interface has not been claimed.") }
        case 2:
            guard opened.device.configuration(opened.configuration) != nil else { throw .state("The device must have a configuration selected.") }
            guard opened.endpoint(UInt8(index & 0x8f)) != nil else { throw .notFound("The specified endpoint has not been claimed.") }
        default:
            break
        }
        return setup
    }

    // MARK: - The chooser

    private static func choose(session: Session, tab: Tab, web: WKWebView, filters: [Filter],
                               excluding: [Filter]) async -> USBDeviceInfo.Identity? {
        guard session.scope == SitePermissions.scope(for: tab) else { return nil }
        #if DEBUG
        if let chooserForTesting {
            return chooserForTesting(Filter.candidates(USBDevices.shared.devices, filters: filters, excluding: excluding))?.identity
        }
        #endif
        var picked: USBDeviceInfo.Identity?
        let answered = await DeviceAccess.choose(
            tab: tab, web: web, scope: session.scope, busy: sessions.values.contains { $0.chooser != nil },
            hold: { session.chooser = $0; session.chooserWindow = $1 }) { site, respond in
                AnyView(USBChooser(site: site, filters: filters, excluding: excluding) { identity in
                    picked = identity
                    respond(identity != nil)
                })
            }
        return answered ? picked : nil
    }
}

/// The list the user picks from, following the devices as they are plugged in.
struct USBChooser: View {
    let site: String
    let filters: [WebUSB.Filter]
    let excluding: [WebUSB.Filter]
    let respond: (USBDeviceInfo.Identity?) -> Void
    @ObservedObject var devices = USBDevices.shared

    var body: some View {
        DeviceChooserList(symbol: "cable.connector.horizontal", title: "\(site) wants to connect to a USB device",
                          rows: WebUSB.Filter.candidates(devices.devices, filters: filters, excluding: excluding)
                              .map { .init(id: $0.identity, label: $0.label) },
                          accessibility: "USB device request from \(site)", respond: respond)
    }
}
