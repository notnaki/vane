import AppKit
import SwiftUI
import WebKit

/// The Web Bluetooth API (`navigator.bluetooth`) for system WebKit, which has none.
///
/// A page script defines the spec's objects and forwards each call here; BluetoothDevice.swift
/// talks to the radio through CoreBluetooth. The page script is the page's own and is trusted
/// with nothing: every message is checked again on this side. A device is reachable only from
/// a main-frame document in a secure context, for a device the user picked in the chooser
/// for that exact origin and profile, and only through the services that request named.
/// BluetoothBlocklist's services, characteristics and descriptors are never reachable.
/// Opaque origins have no scope and get nothing.
@MainActor enum WebBluetooth {
    typealias Scope = SitePermissions.Scope
    static let messageName = "vaneBluetooth"
    static let gestureName = "vaneBluetoothGesture"
    static let gestureWorld = WKContentWorld.world(name: "vane-bluetooth")
    static let gestureEvent = "vane-bluetooth-request"
    static let gestureScript = DeviceAccess.gestureScript(event: gestureEvent, handler: gestureName)

    /// GATT assigned numbers by their spec names, for `BluetoothUUID` and every call that takes a name.
    private static let names = """
      const names = {
        service: { generic_access: 0x1800, generic_attribute: 0x1801, immediate_alert: 0x1802, link_loss: 0x1803,
          tx_power: 0x1804, current_time: 0x1805, reference_time_update: 0x1806, next_dst_change: 0x1807, glucose: 0x1808,
          health_thermometer: 0x1809, device_information: 0x180a, heart_rate: 0x180d, phone_alert_status: 0x180e,
          battery_service: 0x180f, blood_pressure: 0x1810, alert_notification: 0x1811, human_interface_device: 0x1812,
          scan_parameters: 0x1813, running_speed_and_cadence: 0x1814, automation_io: 0x1815, cycling_speed_and_cadence: 0x1816,
          cycling_power: 0x1818, location_and_navigation: 0x1819, environmental_sensing: 0x181a, body_composition: 0x181b,
          user_data: 0x181c, weight_scale: 0x181d, bond_management: 0x181e, continuous_glucose_monitoring: 0x181f,
          internet_protocol_support: 0x1820, indoor_positioning: 0x1821, pulse_oximeter: 0x1822, http_proxy: 0x1823,
          transport_discovery: 0x1824, object_transfer: 0x1825, fitness_machine: 0x1826, mesh_provisioning: 0x1827,
          mesh_proxy: 0x1828, reconnection_configuration: 0x1829, insulin_delivery: 0x183a, binary_sensor: 0x183b,
          emergency_configuration: 0x183c, physical_activity_monitor: 0x183e, audio_input_control: 0x1843,
          volume_control: 0x1844, volume_offset_control: 0x1845, device_time: 0x1847, media_control: 0x1848,
          generic_media_control: 0x1849, constant_tone_extension: 0x184a, telephone_bearer: 0x184b,
          generic_telephone_bearer: 0x184c, microphone_control: 0x184d },
        characteristic: { 'gap.device_name': 0x2a00, 'gap.appearance': 0x2a01, 'gap.peripheral_privacy_flag': 0x2a02,
          'gap.reconnection_address': 0x2a03, 'gap.peripheral_preferred_connection_parameters': 0x2a04,
          'gatt.service_changed': 0x2a05, alert_level: 0x2a06, tx_power_level: 0x2a07, date_time: 0x2a08, day_of_week: 0x2a09,
          day_date_time: 0x2a0a, exact_time_256: 0x2a0c, dst_offset: 0x2a0d, time_zone: 0x2a0e, local_time_information: 0x2a0f,
          time_with_dst: 0x2a11, time_accuracy: 0x2a12, time_source: 0x2a13, reference_time_information: 0x2a14,
          time_update_control_point: 0x2a16, time_update_state: 0x2a17, glucose_measurement: 0x2a18, battery_level: 0x2a19,
          temperature_measurement: 0x2a1c, temperature_type: 0x2a1d, intermediate_temperature: 0x2a1e,
          measurement_interval: 0x2a21, boot_keyboard_input_report: 0x2a22, system_id: 0x2a23, model_number_string: 0x2a24,
          serial_number_string: 0x2a25, firmware_revision_string: 0x2a26, hardware_revision_string: 0x2a27,
          software_revision_string: 0x2a28, manufacturer_name_string: 0x2a29,
          'ieee_11073-20601_regulatory_certification_data_list': 0x2a2a, current_time: 0x2a2b, scan_refresh: 0x2a31,
          boot_keyboard_output_report: 0x2a32, boot_mouse_input_report: 0x2a33, glucose_measurement_context: 0x2a34,
          blood_pressure_measurement: 0x2a35, intermediate_cuff_pressure: 0x2a36, heart_rate_measurement: 0x2a37,
          body_sensor_location: 0x2a38, heart_rate_control_point: 0x2a39, alert_status: 0x2a3f, ringer_control_point: 0x2a40,
          ringer_setting: 0x2a41, alert_category_id_bit_mask: 0x2a42, alert_category_id: 0x2a43,
          alert_notification_control_point: 0x2a44, unread_alert_status: 0x2a45, new_alert: 0x2a46,
          supported_new_alert_category: 0x2a47, supported_unread_alert_category: 0x2a48, blood_pressure_feature: 0x2a49,
          hid_information: 0x2a4a, report_map: 0x2a4b, hid_control_point: 0x2a4c, report: 0x2a4d, protocol_mode: 0x2a4e,
          scan_interval_window: 0x2a4f, pnp_id: 0x2a50, glucose_feature: 0x2a51, record_access_control_point: 0x2a52,
          rsc_measurement: 0x2a53, rsc_feature: 0x2a54, sc_control_point: 0x2a55, csc_measurement: 0x2a5b,
          csc_feature: 0x2a5c, sensor_location: 0x2a5d, cycling_power_measurement: 0x2a63, cycling_power_vector: 0x2a64,
          cycling_power_feature: 0x2a65, cycling_power_control_point: 0x2a66, location_and_speed: 0x2a67, navigation: 0x2a68,
          position_quality: 0x2a69, ln_feature: 0x2a6a, ln_control_point: 0x2a6b, elevation: 0x2a6c, pressure: 0x2a6d,
          temperature: 0x2a6e, humidity: 0x2a6f, true_wind_speed: 0x2a70, true_wind_direction: 0x2a71,
          weight_measurement: 0x2a9d, weight_scale_feature: 0x2a9e, fitness_machine_feature: 0x2acc, treadmill_data: 0x2acd,
          indoor_bike_data: 0x2ad2, training_status: 0x2ad3, supported_resistance_level_range: 0x2ad6,
          fitness_machine_control_point: 0x2ad9, fitness_machine_status: 0x2ada },
        descriptor: { 'gatt.characteristic_extended_properties': 0x2900, 'gatt.characteristic_user_description': 0x2901,
          'gatt.client_characteristic_configuration': 0x2902, 'gatt.server_characteristic_configuration': 0x2903,
          'gatt.characteristic_presentation_format': 0x2904, 'gatt.characteristic_aggregate_format': 0x2905,
          valid_range: 0x2906, external_report_reference: 0x2907, report_reference: 0x2908, number_of_digitals: 0x2909,
          value_trigger_setting: 0x290a, es_configuration: 0x290b, es_measurement: 0x290c, es_trigger_setting: 0x290d,
          time_trigger_setting: 0x290e } };
    """

    /// Definitions only: no listener, timer or message until the page uses the API.
    static let script = """
    (() => {
      const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(messageName);
      if (!isSecureContext || !handler || 'bluetooth' in Navigator.prototype) return;
      \(DeviceAccess.pagePrelude(unavailable: "'NetworkError', 'Bluetooth is not available.'"))
      \(names)
      const canonicalUUID = alias => (Number(alias) >>> 0).toString(16).padStart(8, '0') + '-0000-1000-8000-00805f9b34fb';
      const uuid = (kind, name) => {
        if (typeof name === 'number') return canonicalUUID(name);
        const text = String(name);
        if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text)) return text;
        if (Object.hasOwn(names[kind], text)) return canonicalUUID(names[kind][text]);
        const what = kind[0].toUpperCase() + kind.slice(1);
        throw new TypeError("Failed to resolve '" + text + "': Invalid " + what + " name: '" + text + "'. It must be a valid UUID " +
          "alias (e.g. 0x1234), UUID (lowercase hex characters e.g. '00001234-0000-1000-8000-00805f9b34fb'), or recognized standard name.");
      };
      class BluetoothUUID {
        constructor() { throw new TypeError('Illegal constructor'); }
        static getService(name) { return uuid('service', name); }
        static getCharacteristic(name) { return uuid('characteristic', name); }
        static getDescriptor(name) { return uuid('descriptor', name); }
        static canonicalUUID(alias) { return canonicalUUID(alias); }
      }
      const list = (value, name, each) => {
        if (value === undefined) return undefined;
        if (!value || typeof value !== 'object' || typeof value[Symbol.iterator] !== 'function') throw new TypeError(name + ' must be a sequence.');
        return Array.from(value, each);
      };
      const filter = f => {
        const out = {};
        if (!f || typeof f !== 'object') return out;
        if (f.services !== undefined) out.services = list(f.services, 'services', s => uuid('service', s));
        if (f.name !== undefined) out.name = String(f.name);
        if (f.namePrefix !== undefined) out.namePrefix = String(f.namePrefix);
        if (f.manufacturerData !== undefined) out.manufacturerData = list(f.manufacturerData, 'manufacturerData', m => {
          const entry = { companyIdentifier: Number(m && m.companyIdentifier) };
          if (m && m.dataPrefix !== undefined) entry.dataPrefix = toBase64.call(view(m.dataPrefix));
          if (m && m.mask !== undefined) entry.mask = toBase64.call(view(m.mask));
          return entry;
        });
        return out;
      };

      let building = false, bluetooth = null, listening = false, used = false, generation = 0;
      const illegal = () => { if (!building) throw new TypeError('Illegal constructor'); };
      const make = (Class, data, store) => {
        building = true;
        let object;
        try { object = new Class(); } finally { building = false; }
        store.set(object, data);
        return object;
      };
      const slots = new WeakMap(), devices = new Map(), attributes = new Map(), parts = new WeakMap();
      const slot = device => { const s = slots.get(device); if (!s) throw new TypeError('Illegal invocation'); return s; };
      const part = object => { const p = parts.get(object); if (!p) throw new TypeError('Illegal invocation'); return p; };
      const attribute = (Class, info, extra) => {
        let object = attributes.get(info.handle);
        if (!object) { object = make(Class, { ...info, ...extra, value: null }, parts); attributes.set(info.handle, object); }
        return object;
      };
      const disconnectedError = what => fail('NetworkError', 'GATT Server is disconnected. Cannot ' + what + '. (Re)connect first with `device.gatt.connect`.');
      const live = (device, what) => {
        const s = slot(device);
        if (!s.connected) throw disconnectedError(what);
        return s;
      };
      const dropped = s => {
        s.connected = false;
        for (const [handle, object] of attributes) if (part(object).device === s.device) attributes.delete(handle);
      };

      class BluetoothCharacteristicProperties {
        constructor() { illegal(); }
      }
      const propertyNames = ['broadcast', 'read', 'writeWithoutResponse', 'write', 'notify', 'indicate', 'authenticatedSignedWrites',
                             undefined, 'reliableWrite', 'writableAuxiliaries'];
      propertyNames.forEach((name, bit) => {
        if (name) Object.defineProperty(BluetoothCharacteristicProperties.prototype, name, { configurable: true, enumerable: true,
          get() { return !!(part(this) & (1 << bit)); } });
      });

      class BluetoothRemoteGATTDescriptor {
        constructor() { illegal(); }
        get characteristic() { return part(this).characteristic; }
        get uuid() { return part(this).uuid; }
        get value() { return part(this).value; }
        async readValue() {
          const p = part(this);
          live(p.device, 'perform GATT operations');
          return p.value = bytes(await call('read', { id: slot(p.device).id, handle: p.handle }));
        }
        async writeValue(value) {
          const p = part(this), data = toBase64.call(view(value));
          live(p.device, 'perform GATT operations');
          await call('write', { id: slot(p.device).id, handle: p.handle, data, mode: 'with' });
          p.value = bytes(data);
        }
      }

      class BluetoothRemoteGATTCharacteristic extends EventTarget {
        constructor() { illegal(); super(); }
        get service() { return part(this).service; }
        get uuid() { return part(this).uuid; }
        get properties() {
          const p = part(this);
          return p.propertyObject || (p.propertyObject = make(BluetoothCharacteristicProperties, p.properties, parts));
        }
        get value() { return part(this).value; }
        async getDescriptor(name) { return (await descriptorsOf(this, uuid('descriptor', name)))[0]; }
        async getDescriptors(name) { return descriptorsOf(this, name === undefined ? undefined : uuid('descriptor', name)); }
        async readValue() {
          const p = part(this);
          live(p.device, 'perform GATT operations');
          const read = await call('read', { id: slot(p.device).id, handle: p.handle });
          p.value = bytes(read.data);
          if (!read.pushed) this.dispatchEvent(new Event('characteristicvaluechanged', { bubbles: true }));
          return p.value;
        }
        async #write(value, mode) {
          const p = part(this), data = toBase64.call(view(value));
          live(p.device, 'perform GATT operations');
          await call('write', { id: slot(p.device).id, handle: p.handle, data, mode });
          p.value = bytes(data);
        }
        writeValue(value) { return this.#write(value, 'either'); }
        writeValueWithResponse(value) { return this.#write(value, 'with'); }
        writeValueWithoutResponse(value) { return this.#write(value, 'without'); }
        async startNotifications() {
          const p = part(this);
          live(p.device, 'perform GATT operations');
          await call('notify', { id: slot(p.device).id, handle: p.handle, on: true });
          return this;
        }
        async stopNotifications() {
          const p = part(this);
          if (slot(p.device).connected) await call('notify', { id: slot(p.device).id, handle: p.handle, on: false });
          return this;
        }
      }
      const descriptorsOf = async (characteristic, wanted) => {
        const p = part(characteristic);
        live(p.device, 'retrieve descriptors');
        const found = await call('descriptors', { id: slot(p.device).id, handle: p.handle, uuid: wanted });
        return found.map(info => attribute(BluetoothRemoteGATTDescriptor, info, { device: p.device, characteristic }));
      };

      class BluetoothRemoteGATTService {
        constructor() { illegal(); }
        get device() { return part(this).device; }
        get uuid() { return part(this).uuid; }
        get isPrimary() { return true; }
        async getCharacteristic(name) { return (await characteristicsOf(this, uuid('characteristic', name)))[0]; }
        async getCharacteristics(name) { return characteristicsOf(this, name === undefined ? undefined : uuid('characteristic', name)); }
      }
      const characteristicsOf = async (service, wanted) => {
        const p = part(service);
        live(p.device, 'retrieve characteristics');
        const found = await call('characteristics', { id: slot(p.device).id, handle: p.handle, uuid: wanted });
        return found.map(info => attribute(BluetoothRemoteGATTCharacteristic, info, { device: p.device, service }));
      };

      class BluetoothRemoteGATTServer {
        constructor() { illegal(); }
        get device() { return part(this); }
        get connected() { return slot(part(this)).connected; }
        async connect() {
          const device = part(this), s = slot(device);
          listen();
          s.attempt = (s.attempt || 0) + 1;
          const mine = s.attempt;
          await call('connect', { id: s.id });
          if (mine !== s.attempt) throw fail('AbortError', 'Connection attempt was aborted by a call to disconnect().');
          s.connected = true;
          return this;
        }
        disconnect() {
          const device = part(this), s = slot(device), was = s.connected;
          s.attempt = (s.attempt || 0) + 1;
          dropped(s);
          call('disconnect', { id: s.id }).catch(() => {});
          if (was) device.dispatchEvent(new Event('gattserverdisconnected', { bubbles: true }));
        }
        async getPrimaryService(name) { return (await servicesOf(part(this), uuid('service', name)))[0]; }
        async getPrimaryServices(name) { return servicesOf(part(this), name === undefined ? undefined : uuid('service', name)); }
      }
      const servicesOf = async (device, wanted) => {
        const s = live(device, 'retrieve services');
        const found = await call('services', { id: s.id, uuid: wanted });
        return found.map(info => attribute(BluetoothRemoteGATTService, info, { device }));
      };

      class BluetoothDevice extends EventTarget {
        constructor() { illegal(); super(); }
        get id() { return slot(this).id; }
        get name() { return slot(this).name; }
        get gatt() { return slot(this).gatt; }
        get watchingAdvertisements() { return false; }
        async watchAdvertisements() { throw fail('NotSupportedError', 'watchAdvertisements() is not supported.'); }
        async forget() {
          const s = slot(this);
          if (s.connected) this.gatt.disconnect();
          await call('forget', { id: s.id });
        }
      }

      const adopt = info => {
        let device = devices.get(info.id);
        if (!device) {
          building = true;
          try { device = new BluetoothDevice(); } finally { building = false; }
          const s = { id: info.id, connected: false, device };
          slots.set(device, s);
          s.gatt = make(BluetoothRemoteGATTServer, device, parts);
          devices.set(info.id, device);
        }
        slots.get(device).name = info.name;
        return device;
      };
      // One held request, answered when a device drops, a notification arrives, or the
      // radio comes or goes. Started on first use.
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
              if (event.type === 'availability') {
                const changed = new Event('availabilitychanged');
                Object.defineProperty(changed, 'value', { value: event.value, enumerable: true });
                bluetooth.dispatchEvent(changed);
                continue;
              }
              if (event.type === 'value') {
                const object = attributes.get(event.handle);
                if (!object) continue;
                part(object).value = bytes(event.data);
                object.dispatchEvent(new Event('characteristicvaluechanged', { bubbles: true }));
                continue;
              }
              const device = devices.get(event.id), s = device && slots.get(device);
              if (!s || !s.connected) continue;
              dropped(s);
              device.dispatchEvent(new Event('gattserverdisconnected', { bubbles: true }));
            }
          }
        } catch (e) {}
        if (mine === generation) listening = false;
      };
      // Back from the back/forward cache: this side's document ended when the page left,
      // so every connection dropped and every attribute went stale.
      addEventListener('pageshow', e => {
        if (!e.persisted) return;
        for (const device of devices.values()) dropped(slots.get(device));
        generation++;
        listening = false;
        if (used) listen();
      });

      class Bluetooth extends EventTarget {
        constructor() { illegal(); super(); }
        addEventListener(...args) { listen(); return super.addEventListener(...args); }
        async getAvailability() { return !!(await call('availability')); }
        async getDevices() {
          listen();
          return (await call('devices')).map(adopt);
        }
        async requestDevice(options) {
          if (options === undefined) options = {};
          if (!options || typeof options !== 'object') throw new TypeError('requestDevice needs options.');
          const sent = {};
          if (options.filters !== undefined) sent.filters = list(options.filters, 'filters', filter);
          if (options.exclusionFilters !== undefined) sent.exclusionFilters = list(options.exclusionFilters, 'exclusionFilters', filter);
          if (options.optionalServices !== undefined) sent.optionalServices = list(options.optionalServices, 'optionalServices', s => uuid('service', s));
          if (options.optionalManufacturerData !== undefined) sent.optionalManufacturerData = list(options.optionalManufacturerData, 'optionalManufacturerData', Number);
          if (options.acceptAllDevices) sent.acceptAllDevices = true;
          if (!activation.isActive) throw fail('SecurityError', 'Must be handling a user gesture to show a permission request.');
          dispatchEvent(new Event('\(gestureEvent)'));
          listen();
          const info = await call('request', sent);
          if (!info) throw fail('NotFoundError', 'User cancelled the requestDevice() chooser.');
          return adopt(info);
        }
      }

      handlerAttribute(Bluetooth, 'availabilitychanged');
      handlerAttribute(BluetoothDevice, 'gattserverdisconnected');
      handlerAttribute(BluetoothRemoteGATTCharacteristic, 'characteristicvaluechanged');
      expose([[Bluetooth, 'Bluetooth'], [BluetoothDevice, 'BluetoothDevice'], [BluetoothUUID, 'BluetoothUUID'],
              [BluetoothRemoteGATTServer, 'BluetoothRemoteGATTServer'], [BluetoothRemoteGATTService, 'BluetoothRemoteGATTService'],
              [BluetoothRemoteGATTCharacteristic, 'BluetoothRemoteGATTCharacteristic'],
              [BluetoothRemoteGATTDescriptor, 'BluetoothRemoteGATTDescriptor'],
              [BluetoothCharacteristicProperties, 'BluetoothCharacteristicProperties']]);
      Object.defineProperty(Navigator.prototype, 'bluetooth', { configurable: true, enumerable: true,
        get() {
          if (!bluetooth) {
            building = true;
            try { bluetooth = new Bluetooth(); } finally { building = false; }
          }
          return bluetooth;
        } });
    })();
    """

    /// Main frame only, as for the other device APIs.
    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: gestureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: gestureWorld))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    static func attach(_ tab: Tab, to web: WKWebView) {
        web.configuration.userContentController.addScriptMessageHandler(Bridge(tab), contentWorld: .page, name: messageName)
    }

    static func detach(from web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        web.configuration.userContentController.removeScriptMessageHandler(forName: gestureName, contentWorld: gestureWorld)
    }

    @MainActor private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            do throws(BluetoothError) { return (["value": try await WebBluetooth.handle(message, tab: tab) ?? NSNull()], nil) }
            catch { return (["error": [error.name, error.message]], nil) }
        }
    }

    // MARK: - The radio

    #if DEBUG
    /// Fixtures stand in for the radio. Set before the first use.
    static var backendForTesting: (any BluetoothBackend)?
    #endif
    private static var realBackend: CoreBluetoothBackend?

    /// No CBCentralManager exists until a page is granted a device or asks to pick one.
    static var backend: any BluetoothBackend {
        let backend: any BluetoothBackend
        #if DEBUG
        if let backendForTesting { backend = backendForTesting } else { backend = realBackend ?? { realBackend = CoreBluetoothBackend(); return realBackend! }() }
        #else
        backend = realBackend ?? { realBackend = CoreBluetoothBackend(); return realBackend! }()
        #endif
        if backend.onEvent == nil { backend.onEvent = { received($0) } }
        return backend
    }

    /// What the radio has heard since the chooser opened.
    @MainActor final class Scan: ObservableObject {
        static let shared = Scan()
        @Published fileprivate(set) var found: [BluetoothAdvertisement] = []

        fileprivate func heard(_ ad: BluetoothAdvertisement) {
            guard let index = found.firstIndex(where: { $0.id == ad.id }) else { return found.append(ad) }
            var merged = found[index]
            // Scan responses carry the name; advertisements may not. Keep what was heard.
            if let name = ad.name, !name.isEmpty { merged.name = name }
            merged.services = Array(Set(merged.services).union(ad.services)).sorted()
            merged.manufacturer.merge(ad.manufacturer) { $1 }
            if merged != found[index] { found[index] = merged }
        }
        #if DEBUG
        func reset() { found = [] }
        #endif
    }

    // MARK: - Filters

    struct ManufacturerFilter: Equatable, Sendable {
        var company: Int
        var prefix = Data()
        var mask: Data?

        func matches(_ data: Data?) -> Bool {
            guard let data = data.map(Array.init), data.count >= prefix.count else { return false }
            let mask = self.mask.map(Array.init) ?? Array(repeating: 0xff, count: prefix.count)
            return zip(zip(data, prefix), mask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }

    struct Filter: Equatable, Sendable {
        var services: [String]?
        var name: String?
        var namePrefix: String?
        var manufacturer: [ManufacturerFilter]?

        func matches(_ ad: BluetoothAdvertisement) -> Bool {
            if let services, !Set(services).isSubset(of: ad.services) { return false }
            if let name, ad.name != name { return false }
            if let namePrefix, !(ad.name ?? "").hasPrefix(namePrefix) { return false }
            if let manufacturer, !manufacturer.allSatisfy({ $0.matches(ad.manufacturer[$0.company]) }) { return false }
            return true
        }

        static func parse(_ body: Any?, name list: String) throws(BluetoothError) -> [Filter] {
            guard let entries = body as? [[String: Any]] else { throw .type("'\(list)' must be a sequence of filters.") }
            var out: [Filter] = []
            for entry in entries {
                var filter = Filter()
                if let value = entry["services"] {
                    guard let services = (value as? [Any])?.compactMap(BluetoothUUID.canonical),
                          services.count == (value as? [Any])?.count else { throw .type("Invalid service UUID.") }
                    if services.isEmpty { throw .type("'services', if present, must contain at least one service.") }
                    if services.contains(where: { BluetoothBlocklist.services[$0] == .all }) {
                        throw .security("requestDevice() called with a filter containing a blocklisted UUID. https://goo.gl/4NeimX")
                    }
                    filter.services = services
                }
                if let value = entry["name"] {
                    guard let name = value as? String, name.utf8.count <= 248 else { throw .type("A device name can't be longer than 248 bytes.") }
                    filter.name = name
                }
                if let value = entry["namePrefix"] {
                    guard let prefix = value as? String, prefix.utf8.count <= 248 else { throw .type("A device name can't be longer than 248 bytes.") }
                    if prefix.isEmpty { throw .type("'namePrefix', if present, must be non-empty.") }
                    filter.namePrefix = prefix
                }
                if let value = entry["manufacturerData"] {
                    guard let items = value as? [[String: Any]] else { throw .type("Invalid manufacturer data filter.") }
                    if items.isEmpty { throw .type("'manufacturerData', if present, must be non-empty.") }
                    filter.manufacturer = try items.map { item throws(BluetoothError) -> ManufacturerFilter in
                        guard let number = item["companyIdentifier"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              let company = Int(exactly: number.doubleValue), (0...0xFFFF).contains(company) else {
                            throw .type("Invalid companyIdentifier.")
                        }
                        let prefix = (item["dataPrefix"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                        let mask = (item["mask"] as? String).flatMap { Data(base64Encoded: $0) }
                        if let mask, mask.count != prefix.count { throw .type("'mask' size must be equal to 'dataPrefix' size.") }
                        if BluetoothBlocklist.blocksManufacturer(company: company, prefix: prefix, mask: mask) {
                            throw .security("requestDevice() called with a filter containing a blocklisted manufacturer data.")
                        }
                        return ManufacturerFilter(company: company, prefix: prefix, mask: mask)
                    }
                }
                if filter == Filter() { throw .type("A filter must restrict the devices in some way.") }
                out.append(filter)
            }
            if out.isEmpty { throw .type("'\(list)' member must be non-empty to \(list == "filters" ? "find" : "exclude") any devices.") }
            return out
        }
    }

    /// What `requestDevice` asked for, checked.
    struct Request: Equatable, Sendable {
        var filters: [Filter] = []
        var excluding: [Filter] = []
        var acceptAll = false
        /// Every service the grant will cover: the filters' and `optionalServices`, less the blocklist's.
        var services: [String] = []

        func matches(_ ad: BluetoothAdvertisement) -> Bool {
            (acceptAll || filters.contains { $0.matches(ad) }) && !excluding.contains { $0.matches(ad) }
        }

        static func parse(_ body: [String: Any]) throws(BluetoothError) -> Request {
            var request = Request()
            request.acceptAll = body["acceptAllDevices"] as? Bool == true
            let filters = body["filters"]
            if request.acceptAll == (filters != nil) {
                throw .type("Either 'filters' should be present or 'acceptAllDevices' should be true, but not both.")
            }
            if let filters { request.filters = try Filter.parse(filters, name: "filters") }
            if let excluding = body["exclusionFilters"] {
                if request.acceptAll { throw .type("'exclusionFilters' cannot be used with 'acceptAllDevices'.") }
                request.excluding = try Filter.parse(excluding, name: "exclusionFilters")
            }
            var optional: [String] = []
            if let value = body["optionalServices"] {
                guard let list = value as? [Any] else { throw .type("Invalid optionalServices.") }
                optional = list.compactMap(BluetoothUUID.canonical)
                if optional.count != list.count { throw .type("Invalid service UUID.") }
            }
            let named = request.filters.flatMap { $0.services ?? [] } + optional
            // A blocklisted optional service is dropped rather than refused, as in Chromium.
            request.services = Array(Set(named)).filter { BluetoothBlocklist.services[$0] != .all }.sorted()
            return request
        }
    }

    // MARK: - What is remembered

    struct Grant: Codable, Equatable, Sendable {
        /// The page's `device.id`: random, so two origins never see the same one.
        let id: String
        var peripheral: UUID
        var name: String
        var services: [String]
    }

    private static let store = DeviceGrants<Grant>(prefix: "bluetoothDevice.v1.")

    static func grants(scope: Scope?) -> [Grant] { store.grants(scope: scope) }
    static func all(profileID: UUID) -> [(scope: Scope, grant: Grant)] { store.all(profileID: profileID) }
    static func forgetPrivate(tabID: UUID) { store.forgetPrivate(tabID: tabID) }

    /// The chooser's answer. Picking a device again adds the services this request named.
    @discardableResult static func grant(_ ad: BluetoothAdvertisement, services: [String], scope: Scope) -> Grant {
        var all = grants(scope: scope)
        let grant: Grant
        if let index = all.firstIndex(where: { $0.peripheral == ad.id }) {
            all[index].name = ad.label
            all[index].services = Array(Set(all[index].services).union(services)).sorted()
            grant = all[index]
        } else {
            var id = Data(count: 16)
            id.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            grant = Grant(id: id.base64EncodedString(), peripheral: ad.id, name: ad.label, services: services)
            all.append(grant)
        }
        store.save(all, scope: scope)
        return grant
    }

    /// Takes the grant back and drops the connection wherever this origin has it.
    static func forget(scope: Scope?, id: String) {
        guard let scope else { return }
        store.save(grants(scope: scope).filter { $0.id != id }, scope: scope)
        for session in sessions.values where session.scope == scope { revoke(session) }
        SiteChanges.shared.bump()
    }

    static func forgetAll(profileID: UUID? = nil) {
        store.forgetAll(profileID: profileID)
        for session in sessions.values where (profileID == nil || session.scope.profileID == profileID) && session.scope.privateTabID == nil {
            revoke(session)
        }
    }

    /// Drops every connection this document no longer has a grant for.
    private static func revoke(_ session: Session) {
        let kept = Set(grants(scope: session.scope).map(\.peripheral))
        for peripheral in session.connected.union(session.connecting) where !kept.contains(peripheral) {
            release(peripheral, from: session)
            session.push(["type": "disconnected", "id": session.ids[peripheral] ?? ""])
        }
    }

    // MARK: - One document's devices

    @MainActor final class Session {
        /// Values a page has not collected. Past this the oldest go.
        static let maxEvents = 1024

        let scope: Scope
        var connected: Set<UUID> = []
        var connecting: Set<UUID> = []
        /// The page's `device.id` for each peripheral it has been shown.
        var ids: [UUID: String] = [:]
        struct Handle { let peripheral: UUID; let attribute: BluetoothAttribute; let kind: Kind }
        enum Kind { case service, characteristic, descriptor }
        /// The page's name for each attribute it has been given; the radio's own handle never crosses.
        var handles: [String: Handle] = [:]
        var notifying: Set<UInt64> = []
        var events: [[String: Any]] = []
        var waiter: CheckedContinuation<Bool, Never>?
        var gesture: ContinuousClock.Instant?
        var chooser: SitePermissionPrompt?
        weak var chooserWindow: NSWindow?
        init(scope: Scope) { self.scope = scope }

        func handle(_ attribute: BluetoothAttribute, of peripheral: UUID, kind: Kind) -> String {
            if let known = handles.first(where: { $0.value.peripheral == peripheral && $0.value.attribute.instance == attribute.instance })?.key {
                return known
            }
            let handle = UUID().uuidString
            handles[handle] = Handle(peripheral: peripheral, attribute: attribute, kind: kind)
            return handle
        }

        func forgetAttributes(of peripheral: UUID) {
            for (key, value) in handles where value.peripheral == peripheral {
                handles.removeValue(forKey: key)
                notifying.remove(value.attribute.instance)
            }
        }

        func push(_ event: [String: Any]) {
            if events.count >= Self.maxEvents { events.removeFirst() }
            events.append(event)
            guard let waiter else { return }
            self.waiter = nil
            waiter.resume(returning: true)
        }

        func end() {
            chooser?.finish(.abort)
            waiter?.resume(returning: false)
            waiter = nil
        }
    }
    private static var sessions: [UUID: Session] = [:]
    /// Which documents hold each connection and each subscription: CoreBluetooth has one of
    /// each per peripheral for the whole app.
    private static var holders: [UUID: Set<ObjectIdentifier>] = [:]
    private static var subscribers: [UInt64: Set<ObjectIdentifier>] = [:]

    #if DEBUG
    /// Fixtures answer the chooser themselves, from what the fake radio advertised.
    static var chooserForTesting: (([BluetoothAdvertisement]) -> BluetoothAdvertisement?)?
    #endif

    static func chooser(in window: NSWindow) -> SitePermissionPrompt? {
        sessions.values.first { $0.chooser != nil && $0.chooserWindow === window }?.chooser
    }

    static func hasConnection(tabID: UUID) -> Bool {
        sessions[tabID].map { !$0.connected.isEmpty || !$0.connecting.isEmpty } ?? false
    }

    static func endDocument(tabID: UUID, navigationStarted: Bool = false) {
        guard let session = sessions[tabID] else { return }
        if navigationStarted { session.chooser?.finish(.abort); return }
        sessions.removeValue(forKey: tabID)
        for peripheral in session.connected.union(session.connecting) { release(peripheral, from: session) }
        session.end()
    }

    static func gesture(_ message: WKScriptMessage, tab: Tab) {
        guard let scope = DeviceAccess.scope(of: message, tab: tab) else { return }
        session(tab: tab, scope: scope).gesture = .now
    }

    private static func session(tab: Tab, scope: Scope) -> Session {
        if let session = sessions[tab.id], session.scope == scope { return session }
        endDocument(tabID: tab.id)
        let session = Session(scope: scope)
        sessions[tab.id] = session
        return session
    }

    /// This document lets go of the connection, its subscriptions and its attributes; the
    /// radio drops the connection once no document holds it.
    private static func release(_ peripheral: UUID, from session: Session) {
        let me = ObjectIdentifier(session)
        for instance in session.notifying where session.handles.values.contains(where: { $0.peripheral == peripheral && $0.attribute.instance == instance }) {
            subscribers[instance]?.remove(me)
            if subscribers[instance]?.isEmpty == true {
                subscribers[instance] = nil
                Task { _ = await backend.notify(peripheral, instance, false) }
            }
        }
        session.forgetAttributes(of: peripheral)
        session.connected.remove(peripheral)
        session.connecting.remove(peripheral)
        holders[peripheral]?.remove(me)
        if holders[peripheral]?.isEmpty == true {
            holders[peripheral] = nil
            backend.disconnect(peripheral)
        }
    }

    private static func received(_ event: BluetoothEvent) {
        switch event {
        case .found(let ad):
            Scan.shared.heard(ad)
        case .disconnected(let peripheral):
            holders[peripheral] = nil
            for session in sessions.values where session.connected.contains(peripheral) || session.connecting.contains(peripheral) {
                session.forgetAttributes(of: peripheral)
                session.connected.remove(peripheral)
                session.connecting.remove(peripheral)
                session.push(["type": "disconnected", "id": session.ids[peripheral] ?? ""])
            }
            subscribers = subscribers.filter { instance, _ in
                sessions.values.contains { $0.notifying.contains(instance) }
            }
        case .value(let peripheral, let instance, let data):
            for session in sessions.values where session.notifying.contains(instance) {
                guard let handle = session.handles.first(where: { $0.value.peripheral == peripheral && $0.value.attribute.instance == instance })?.key
                else { continue }
                session.push(["type": "value", "handle": handle, "data": data.base64EncodedString()])
            }
        case .availability(let value):
            for session in sessions.values { session.push(["type": "availability", "value": value]) }
        }
    }

    private static func info(_ grant: Grant, session: Session) -> [String: Any] {
        session.ids[grant.peripheral] = grant.id
        return ["id": grant.id, "name": grant.name]
    }

    /// One call from the page. The reply is the call's result; a throw is its rejection.
    private static func handle(_ message: WKScriptMessage, tab: Tab?) async throws(BluetoothError) -> Any? {
        guard let tab, !tab.tornDown, let web = tab.existingWeb, message.webView === web,
              let body = message.body as? [String: Any], let op = body["op"] as? String,
              let scope = DeviceAccess.scope(of: message, tab: tab) else { throw .security("Bluetooth is not available to this page.") }
        let session = session(tab: tab, scope: scope)
        let tabID = tab.id
        var current: Bool { sessions[tabID] === session }

        switch op {
        case "availability":
            return backend.available
        case "devices":
            return grants(scope: scope).map { info($0, session: session) }
        case "events":
            session.waiter?.resume(returning: false)
            session.waiter = nil
            if session.events.isEmpty {
                guard await withCheckedContinuation({ session.waiter = $0 }) else { return nil }
            }
            defer { session.events = [] }
            return session.events
        case "request":
            let request = try Request.parse(body)
            guard let gesture = session.gesture, ContinuousClock.now - gesture < .seconds(2) else {
                throw .security("Must be handling a user gesture to show a permission request.")
            }
            session.gesture = nil
            guard session.chooser == nil else { throw .state("A device chooser is already open.") }
            guard let picked = await choose(session: session, tab: tab, web: web, request: request), current else { return nil }
            let grant = grant(picked, services: request.services, scope: scope)
            SiteChanges.shared.bump()
            return info(grant, session: session)
        default: break
        }

        guard let id = body["id"] as? String, let grant = grants(scope: scope).first(where: { $0.id == id }) else {
            throw .security("The device is not allowed for this origin, or it has been forgotten.")
        }
        let peripheral = grant.peripheral
        session.ids[peripheral] = grant.id
        let me = ObjectIdentifier(session)
        func connected(_ what: String) throws(BluetoothError) {
            guard session.connected.contains(peripheral) else {
                throw .network("GATT Server is disconnected. Cannot \(what). (Re)connect first with `device.gatt.connect`.")
            }
        }
        func attribute(_ kind: Session.Kind) throws(BluetoothError) -> Session.Handle {
            guard let handle = body["handle"] as? String, let found = session.handles[handle], found.kind == kind,
                  found.peripheral == peripheral else {
                throw .state("GATT \(kind == .service ? "Service" : kind == .characteristic ? "Characteristic" : "Descriptor") no longer exists.")
            }
            return found
        }
        /// A characteristic or descriptor: the things with a value.
        func value() throws(BluetoothError) -> Session.Handle {
            guard let handle = body["handle"] as? String, let found = session.handles[handle], found.kind != .service,
                  found.peripheral == peripheral else { throw .state("GATT Characteristic no longer exists.") }
            return found
        }
        let wanted: String?? = body["uuid"].map { BluetoothUUID.canonical($0) }
        if case .some(.none) = wanted { throw .type("Invalid UUID.") }
        let uuid = wanted.flatMap { $0 }

        switch op {
        case "forget":
            forget(scope: scope, id: grant.id)
        case "connect":
            if session.connected.contains(peripheral) { return nil }
            session.connecting.insert(peripheral)
            holders[peripheral, default: []].insert(me)
            let ok = await backend.connect(peripheral)
            guard current, session.connecting.contains(peripheral) else {
                throw BluetoothError(name: "AbortError", message: "Connection attempt was aborted by a call to disconnect().")
            }
            session.connecting.remove(peripheral)
            guard ok, grants(scope: scope).contains(where: { $0.id == grant.id }) else {
                release(peripheral, from: session)
                throw .network("Bluetooth Device is no longer in range.")
            }
            session.connected.insert(peripheral)
        case "disconnect":
            release(peripheral, from: session)
        case "services":
            try connected("retrieve services")
            if let uuid {
                if BluetoothBlocklist.services[uuid] == .all { throw .security("getPrimaryService(s) called with blocklisted UUID. https://goo.gl/4NeimX") }
                if !grant.services.contains(uuid) {
                    throw .security("Origin is not allowed to access the service. Tip: Add the service UUID to 'optionalServices' in requestDevice() options. https://goo.gl/HxfxSQ")
                }
            }
            guard let found = await backend.services(peripheral), current, session.connected.contains(peripheral) else {
                throw .network("GATT Server is disconnected. Cannot retrieve services. (Re)connect first with `device.gatt.connect`.")
            }
            let shown = found.filter { grant.services.contains($0.uuid) && BluetoothBlocklist.services[$0.uuid] != .all && (uuid == nil || $0.uuid == uuid) }
            if shown.isEmpty { throw .notFound(uuid.map { "No Services matching UUID \($0) found in Device." } ?? "No Services found in device.") }
            return shown.map { ["handle": session.handle($0, of: peripheral, kind: .service), "uuid": $0.uuid] }
        case "characteristics":
            try connected("retrieve characteristics")
            let service = try attribute(.service)
            if let uuid, BluetoothBlocklist.characteristics[uuid] == .all { throw .security("getCharacteristic(s) called with blocklisted UUID. https://goo.gl/4NeimX") }
            guard let found = await backend.characteristics(peripheral, service: service.attribute.instance), current else {
                throw .network("GATT operation failed for unknown reason.")
            }
            let shown = found.filter { BluetoothBlocklist.characteristics[$0.uuid] != .all && (uuid == nil || $0.uuid == uuid) }
            if shown.isEmpty {
                throw .notFound(uuid.map { "No Characteristics matching UUID \($0) found in Service with UUID \(service.attribute.uuid)." }
                                ?? "No Characteristics found in service.")
            }
            return shown.map { ["handle": session.handle($0, of: peripheral, kind: .characteristic), "uuid": $0.uuid, "properties": Int($0.properties)] }
        case "descriptors":
            try connected("retrieve descriptors")
            let characteristic = try attribute(.characteristic)
            if let uuid, BluetoothBlocklist.descriptors[uuid] == .all { throw .security("getDescriptor(s) called with blocklisted UUID. https://goo.gl/4NeimX") }
            guard let found = await backend.descriptors(peripheral, characteristic: characteristic.attribute.instance), current else {
                throw .network("GATT operation failed for unknown reason.")
            }
            let shown = found.filter { BluetoothBlocklist.descriptors[$0.uuid] != .all && (uuid == nil || $0.uuid == uuid) }
            if shown.isEmpty {
                throw .notFound(uuid.map { "No Descriptors matching UUID \($0) found in Characteristic with UUID \(characteristic.attribute.uuid)." }
                                ?? "No Descriptors found in Characteristic.")
            }
            return shown.map { ["handle": session.handle($0, of: peripheral, kind: .descriptor), "uuid": $0.uuid] }
        case "read":
            try connected("perform GATT operations")
            let target = try value()
            let rule = target.kind == .descriptor ? BluetoothBlocklist.descriptors[target.attribute.uuid] : BluetoothBlocklist.characteristics[target.attribute.uuid]
            if BluetoothBlocklist.blocks(rule, write: false) { throw .security("readValue() called on blocklisted object marked exclude-reads. https://goo.gl/4NeimX") }
            if target.kind == .characteristic, target.attribute.properties & 0x02 == 0 { throw .notSupported("GATT operation not permitted.") }
            guard let value = await backend.read(peripheral, target.attribute.instance), current else {
                throw .network("GATT operation failed for unknown reason.")
            }
            guard target.kind == .characteristic else { return value.base64EncodedString() }
            // A document subscribed to it gets the read's value as a notification already.
            return ["data": value.base64EncodedString(), "pushed": session.notifying.contains(target.attribute.instance)]
        case "write":
            try connected("perform GATT operations")
            let target = try value()
            guard let text = body["data"] as? String, let data = Data(base64Encoded: text) else { throw .type("Invalid value.") }
            if data.count > 512 { throw BluetoothError(name: "InvalidModificationError", message: "Value can't exceed 512 bytes.") }
            let rule = target.kind == .descriptor ? BluetoothBlocklist.descriptors[target.attribute.uuid] : BluetoothBlocklist.characteristics[target.attribute.uuid]
            if BluetoothBlocklist.blocks(rule, write: true) { throw .security("writeValue() called on blocklisted object marked exclude-writes. https://goo.gl/4NeimX") }
            var withResponse = true
            if target.kind == .characteristic {
                let canWrite = target.attribute.properties & 0x08 != 0, canWriteBlind = target.attribute.properties & 0x04 != 0
                switch body["mode"] as? String {
                case "with": guard canWrite else { throw .notSupported("GATT operation not permitted.") }
                case "without": guard canWriteBlind else { throw .notSupported("GATT operation not permitted.") }; withResponse = false
                default: guard canWrite || canWriteBlind else { throw .notSupported("GATT operation not permitted.") }; withResponse = canWrite
                }
            }
            guard await backend.write(peripheral, target.attribute.instance, data, withResponse: withResponse), current else {
                throw .network("GATT operation failed for unknown reason.")
            }
        case "notify":
            let characteristic = try attribute(.characteristic)
            let instance = characteristic.attribute.instance
            let on = body["on"] as? Bool == true
            if on {
                try connected("perform GATT operations")
                if BluetoothBlocklist.blocks(BluetoothBlocklist.characteristics[characteristic.attribute.uuid], write: false) {
                    throw .security("startNotifications() called on blocklisted object marked exclude-reads. https://goo.gl/4NeimX")
                }
                guard characteristic.attribute.properties & 0x30 != 0 else { throw .notSupported("GATT operation not permitted.") }
                if session.notifying.contains(instance) { return nil }
                var started = !subscribers[instance, default: []].isEmpty
                if !started { started = await backend.notify(peripheral, instance, true) }
                guard started, current, session.connected.contains(peripheral) else {
                    throw .network("GATT operation failed for unknown reason.")
                }
                subscribers[instance, default: []].insert(me)
                session.notifying.insert(instance)
            } else if session.notifying.remove(instance) != nil {
                subscribers[instance]?.remove(me)
                if subscribers[instance]?.isEmpty == true {
                    subscribers[instance] = nil
                    _ = await backend.notify(peripheral, instance, false)
                }
            }
        default: throw .type("Unknown Bluetooth operation.")
        }
        return nil
    }

    // MARK: - The chooser

    /// The radio scans for as long as the chooser is up, and only then.
    private static func choose(session: Session, tab: Tab, web: WKWebView, request: Request) async -> BluetoothAdvertisement? {
        guard session.scope == SitePermissions.scope(for: tab) else { return nil }
        let radio = backend
        Scan.shared.found = []
        radio.startScan()
        var picked: UUID?
        defer { radio.stopScan(keeping: Set(holders.keys).union(picked.map { [$0] } ?? [])) }
        #if DEBUG
        if let chooserForTesting {
            let ad = chooserForTesting(Scan.shared.found.filter(request.matches))
            picked = ad?.id
            return ad
        }
        #endif
        let answered = await DeviceAccess.choose(
            tab: tab, web: web, scope: session.scope, busy: sessions.values.contains { $0.chooser != nil },
            hold: { session.chooser = $0; session.chooserWindow = $1 }) { site, respond in
                AnyView(BluetoothChooser(site: site, request: request) { id in
                    picked = id
                    respond(id != nil)
                })
            }
        guard answered, let picked else { return nil }
        return Scan.shared.found.first { $0.id == picked && request.matches($0) }
    }
}

/// The devices in range that match, as the radio hears them.
struct BluetoothChooser: View {
    let site: String
    let request: WebBluetooth.Request
    let respond: (UUID?) -> Void
    @ObservedObject var scan = WebBluetooth.Scan.shared

    var body: some View {
        DeviceChooserList(symbol: "antenna.radiowaves.left.and.right", title: "\(site) wants to pair with a Bluetooth device",
                          rows: scan.found.filter(request.matches).map { .init(id: $0.id, label: $0.label) },
                          empty: WebBluetooth.backend.available ? "Looking for devices…"
                            : "Bluetooth is off, or Vane isn't allowed to use it. Check System Settings → Privacy & Security → Bluetooth.",
                          accessibility: "Bluetooth device request from \(site)", respond: respond)
    }
}
