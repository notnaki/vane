import AppKit
import SwiftUI
import WebKit

/// What the device APIs Vane adds to WebKit (Web Serial, WebHID, WebUSB, Web Bluetooth)
/// have in common: who may ask, how a click is proven, where grants live, the chooser
/// bubble, and the one place the rest of the app tells them all that a tab, document or
/// profile ended. Each API's own file holds its page script and its rules.
@MainActor enum DeviceAccess {
    typealias Scope = SitePermissions.Scope

    // MARK: - The app's side

    /// A profile is going, or Reset Permissions (every profile when nil).
    static func forgetAll(profileID: UUID? = nil) {
        WebSerial.forgetAll(profileID: profileID)
        WebHID.forgetAll(profileID: profileID)
        WebUSB.forgetAll(profileID: profileID)
        WebBluetooth.forgetAll(profileID: profileID)
    }

    static func forgetPrivate(tabID: UUID) {
        WebSerial.forgetPrivate(tabID: tabID)
        WebHID.forgetPrivate(tabID: tabID)
        WebUSB.forgetPrivate(tabID: tabID)
        WebBluetooth.forgetPrivate(tabID: tabID)
    }

    static func endDocument(tabID: UUID, navigationStarted: Bool) {
        WebSerial.endDocument(tabID: tabID, navigationStarted: navigationStarted)
        WebHID.endDocument(tabID: tabID, navigationStarted: navigationStarted)
        WebUSB.endDocument(tabID: tabID, navigationStarted: navigationStarted)
        WebBluetooth.endDocument(tabID: tabID, navigationStarted: navigationStarted)
    }

    /// A tab talking to hardware is busy, however long it has been in the background.
    static func inUse(tabID: UUID) -> Bool {
        WebSerial.hasOpenPort(tabID: tabID) || WebHID.hasOpenDevice(tabID: tabID)
            || WebUSB.hasOpenDevice(tabID: tabID) || WebBluetooth.hasConnection(tabID: tabID)
    }

    /// The chooser open in this window, if any.
    static func chooser(in window: NSWindow) -> SitePermissionPrompt? {
        WebSerial.chooser(in: window) ?? WebHID.chooser(in: window) ?? WebUSB.chooser(in: window)
            ?? WebBluetooth.chooser(in: window)
    }

    /// One row of Settings → Site Permissions for a device a site was given.
    struct Listed: Identifiable {
        let id: String
        let origin: String
        let text: String
        let name: String
        let forget: @MainActor () -> Void
    }

    /// The USB and Bluetooth devices this profile's sites were given.
    static func listed(profileID: UUID) -> [Listed] {
        WebUSB.all(profileID: profileID).map { entry in
            Listed(id: "usb." + entry.grant.id, origin: entry.scope.origin, text: "USB device: " + entry.grant.name, name: entry.grant.name) {
                WebUSB.forget(scope: entry.scope, id: entry.grant.id)
            }
        } + WebBluetooth.all(profileID: profileID).map { entry in
            Listed(id: "bluetooth." + entry.grant.id, origin: entry.scope.origin, text: "Bluetooth device: " + entry.grant.name, name: entry.grant.name) {
                WebBluetooth.forget(scope: entry.scope, id: entry.grant.id)
            }
        }
    }

    // MARK: - Who may ask

    /// HTTPS, or HTTP to this Mac itself. Mirrors the page's `isSecureContext`, so not
    /// `DeveloperMode.isLocal`: that one also takes `0.0.0.0`, which is no loopback address and no secure context.
    nonisolated static func isSecure(_ scope: Scope) -> Bool {
        if scope.scheme == "https" { return true }
        let host = scope.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Exactly localhost, as WebKit's isSecureContext has it; `*.localhost` is not one.
        if host == "localhost" { return true }
        // inet_pton, not a resolver: a name is never looked up to decide this.
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return v4.s_addr & 0xff == 127 }    // network order: first octet
        return inet_pton(AF_INET6, host, &v6) == 1 && withUnsafeBytes(of: &v6) { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
    }

    /// The main-frame document that sent this, in a secure context; nil for anything else.
    static func scope(of message: WKScriptMessage, tab: Tab) -> Scope? {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              let scope = Scope(scheme: origin.protocol, host: origin.host, port: origin.port, profileID: tab.profileID,
                                privateTabID: tab.isPrivate ? tab.id : nil), isSecure(scope) else { return nil }
        return scope
    }

    /// Run in a world page code cannot reach, so "the user just clicked" is not the page's to claim.
    static func gestureScript(event: String, handler: String) -> String {
        """
        addEventListener('\(event)', () => {
          if (navigator.userActivation.isActive) webkit.messageHandlers.\(handler).postMessage(1);
        }, true);
        """
    }

    /// What every device page script starts with: the bridge call, errors, `on…` attributes
    /// and BufferSource reading. `unavailable` is the rejection when the bridge itself fails.
    static func pagePrelude(unavailable: String) -> String {
        """
        const post = handler.postMessage.bind(handler);
          const activation = navigator.userActivation;
          const toBase64 = Uint8Array.prototype.toBase64, fromBase64 = Uint8Array.fromBase64;
          const fail = (name, message) => name === 'TypeError' ? new TypeError(message) : new DOMException(message, name);
          const call = async (op, args) => {
            let reply;
            try { reply = await post({ op, ...args }); } catch (e) { throw fail(\(unavailable)); }
            if (reply && reply.error) throw fail(reply.error[0], reply.error[1]);
            return reply ? reply.value : undefined;
          };
          const bytes = text => new DataView(fromBase64.call(Uint8Array, text).buffer);
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
          const view = data => {
            const tag = Object.prototype.toString.call(data);
            if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            if (tag === '[object ArrayBuffer]' || tag === '[object SharedArrayBuffer]') return new Uint8Array(data);
            throw new TypeError('The provided value is not of type BufferSource.');
          };
          const expose = pairs => {
            for (const [target, name] of pairs) {
              Object.defineProperty(target.prototype, Symbol.toStringTag, { value: name, configurable: true });
              Object.defineProperty(window, name, { value: target, writable: true, configurable: true });
            }
          };
        """
    }

    // MARK: - The chooser

    /// The user's answer to a chooser, or false. Only the window showing this page can be
    /// asked, only when nothing else is asking there, and only while the page that asked
    /// stays the page on screen. `hold` is told the bubble (and its window) while it is up.
    static func choose(tab: Tab, web: WKWebView, scope: Scope, busy: Bool, width: CGFloat = 300,
                       hold: (SitePermissionPrompt?, NSWindow?) -> Void,
                       content: @escaping (_ site: String, _ respond: @escaping (Bool) -> Void) -> AnyView) async -> Bool {
        // The bubble names the origin that asked; that has to be the one in the address bar.
        guard scope == SitePermissions.scope(for: tab), !busy,
              let window = web.window, window.isVisible, !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              SitePermissions.activePrompt(in: window) == nil else { return false }
        let site = scope.scheme == "https" ? String(scope.origin.dropFirst("https://".count)) : scope.origin
        let prompt = SitePermissionPrompt(width: width) { respond in
            content(site) { respond($0 ? .OK : .abort) }
        }
        hold(prompt, window)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if tab.existingWeb !== web || web.window !== window || web.isHiddenOrHasHiddenAncestor { prompt.finish(.abort) }
            }
        }
        let response = await prompt.present(in: window, tabID: tab.id)
        monitor.cancel()
        hold(nil, nil)
        return response == .OK
    }
}

/// Grants for one kind of device, per origin and profile. Regular tabs keep theirs in
/// UserDefaults under `prefix` (which backups leave out); private tabs keep theirs in
/// memory until the tab closes. `lasting` says which grants may outlive the device being
/// plugged in: the others stay in memory too, and `drop` ends them.
@MainActor final class DeviceGrants<Grant: Codable & Equatable & Sendable> {
    typealias Scope = SitePermissions.Scope
    private let prefix: String
    private let defaults: UserDefaults
    private let lasting: (Grant) -> Bool
    private var privateGrants: [UUID: [String: [Grant]]] = [:]
    private var memory: [String: [Grant]] = [:]

    init(prefix: String, defaults: UserDefaults = .vane, lasting: @escaping (Grant) -> Bool = { _ in true }) {
        self.prefix = prefix
        self.defaults = defaults
        self.lasting = lasting
    }

    private func key(_ scope: Scope) -> String {
        prefix + scope.profileID.uuidString.lowercased() + "." + Data(scope.origin.utf8).base64EncodedString()
    }

    func grants(scope: Scope?) -> [Grant] {
        guard let scope else { return [] }
        let key = key(scope)
        if let tab = scope.privateTabID { return privateGrants[tab]?[key] ?? [] }
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
        return stored + (memory[key] ?? [])
    }

    func save(_ grants: [Grant], scope: Scope) {
        let key = key(scope)
        if let tab = scope.privateTabID { privateGrants[tab, default: [:]][key] = grants.isEmpty ? nil : grants; return }
        let kept = grants.filter(lasting), held = grants.filter { !lasting($0) }
        memory[key] = held.isEmpty ? nil : held
        if kept.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(try? JSONEncoder().encode(kept), forKey: key) }
    }

    /// Settings' list: every origin of this profile outside private tabs, and what it was given.
    func all(profileID: UUID) -> [(scope: Scope, grant: Grant)] {
        let match = prefix + profileID.uuidString.lowercased() + "."
        let keys = Set(defaults.dictionaryRepresentation().keys).union(memory.keys).filter { $0.hasPrefix(match) }
        return keys.sorted().flatMap { key -> [(scope: Scope, grant: Grant)] in
            guard let data = Data(base64Encoded: String(key.dropFirst(match.count))),
                  let origin = String(data: data, encoding: .utf8),
                  let scope = Scope(url: URL(string: origin), profileID: profileID) else { return [] }
            return grants(scope: scope).map { (scope, $0) }
        }
    }

    /// Every profile when nil. Private tabs keep theirs until they close.
    func forgetAll(profileID: UUID?) {
        let match = prefix + (profileID.map { $0.uuidString.lowercased() + "." } ?? "")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(match) { defaults.removeObject(forKey: key) }
        memory = memory.filter { !$0.key.hasPrefix(match) }
    }

    func forgetPrivate(tabID: UUID) { privateGrants.removeValue(forKey: tabID) }

    /// Ends the in-memory grants `ended` names (private tabs' included). True if any went.
    func drop(where ended: (Grant) -> Bool) -> Bool {
        func keep(_ grants: [Grant]) -> [Grant]? {
            let kept = grants.filter { lasting($0) || !ended($0) }
            return kept.isEmpty ? nil : kept
        }
        let before = (memory, privateGrants)
        memory = memory.compactMapValues(keep)
        privateGrants = privateGrants.compactMapValues { tab in
            let kept = tab.compactMapValues(keep)
            return kept.isEmpty ? nil : kept
        }
        return before.0 != memory || before.1 != privateGrants
    }
}

/// The list a device chooser shows: one row per device, a pick, Cancel and Connect. It
/// follows its rows as they change, because the usual order is to click Connect and then
/// go looking for the cable (or switch the device on).
struct DeviceChooserList<ID: Hashable>: View {
    struct Row { let id: ID; let label: String }
    let symbol: String
    let title: String
    let rows: [Row]
    var empty = "No compatible devices found."
    let accessibility: String
    let respond: (ID?) -> Void
    @State private var selection: ID?

    var body: some View {
        let picked = selection.flatMap { id in rows.contains { $0.id == id } ? id : nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One height whatever is found, so the bubble does not resize under the pointer.
            ZStack {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.id) { row in
                        Button { selection = row.id } label: {
                            Text(row.label).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(.primary.opacity(picked == row.id ? 0.21 : 0.04), in: .rect(cornerRadius: 6))
                                .contentShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked == row.id ? .isSelected : [])
                    }
                }
            }
                if rows.isEmpty {
                    Text(empty).font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 12)
                }
            }
            .frame(height: 120)
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
        .accessibilityLabel(accessibility)
    }
}
