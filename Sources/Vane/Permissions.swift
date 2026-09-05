import AppKit
import WebKit

/// Per-site camera and microphone permission. WebKit will not hand a page a media stream
/// unless the app answers this; with no WKUIDelegate implementation the default is
/// `.prompt`, which WebKit resolves as "ask nobody, deny".
///
/// ponytail: a UserDefaults bool per (host, kind) and a modal NSAlert. No permission
/// manager UI, no expiry, no per-tab "allow once" — the answer is remembered forever until
/// `reset` is called. Upgrade path: a Site Settings sheet reading the same keys.
@MainActor enum SitePermissions {

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    private static var defaults: UserDefaults = .standard

    /// nonisolated so `parse` can be, and `parse` is nonisolated so the key format can be
    /// asserted anywhere. An immutable string is safe from any thread.
    nonisolated private static let prefix = "sitePermission."

    private static func label(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "cameraAndMicrophone"
        @unknown default: return "unknown"
        }
    }

    private static func phrase(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "use your camera"
        case .microphone: return "use your microphone"
        case .cameraAndMicrophone: return "use your camera and microphone"
        @unknown default: return "use a device"
        }
    }

    /// ponytail: `cameraAndMicrophone` is its own key rather than the intersection of the
    /// two single grants, so a site that asked for both separately still gets asked once
    /// for the pair. Rare enough not to pay for.
    private static func key(host: String, type: WKMediaCaptureType) -> String {
        prefix + label(type) + "." + host.lowercased()
    }

    /// Remembered answer, or nil if this pair has never been decided.
    static func remembered(host: String, type: WKMediaCaptureType) -> Bool? {
        defaults.object(forKey: key(host: host, type: type)) as? Bool
    }

    static func remember(host: String, type: WKMediaCaptureType, allow: Bool) {
        defaults.set(allow, forKey: key(host: host, type: type))
    }

    /// What this site may do with one device, counting the pair grant that covers it. A
    /// site that once said yes to "camera and microphone" *has* said yes to the camera, and
    /// the Site Control Center would be lying if it showed that row as unanswered.
    static func effective(host: String, type: WKMediaCaptureType) -> Bool? {
        remembered(host: host, type: type) ?? remembered(host: host, type: .cameraAndMicrophone)
    }

    /// The Site Control Center's three answers: Allow, Block, or nil for "ask me again".
    ///
    /// The pair grant is split into two single answers on the way through. It is its own
    /// key, so leaving it in place would let a long-forgotten yes-to-both quietly outvote a
    /// Block chosen here the next time the page asked for both at once — and simply
    /// deleting it would silently revoke the *other* device's answer, which the user did
    /// not touch.
    static func set(host: String, type: WKMediaCaptureType, answer: Bool?) {
        guard !host.isEmpty else { return }
        if let pair = remembered(host: host, type: .cameraAndMicrophone) {
            for kind in [WKMediaCaptureType.camera, .microphone]
            where remembered(host: host, type: kind) == nil {
                remember(host: host, type: kind, allow: pair)
            }
            defaults.removeObject(forKey: key(host: host, type: .cameraAndMicrophone))
        }
        if let answer { remember(host: host, type: type, allow: answer) }
        else { defaults.removeObject(forKey: key(host: host, type: type)) }
    }

    /// The whole decision for `WKUIDelegate`. Returns `.grant`/`.deny` only — never
    /// `.prompt`, which would hand the question back to WebKit, which has nowhere to put it.
    static func decide(origin: WKSecurityOrigin, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        // A blank host means a file:// or opaque origin — there is nothing to remember an
        // answer against and nothing to name in the prompt, so refuse rather than mislead.
        guard !host.isEmpty else { return .deny }
        if let known = effective(host: host, type: type) { return known ? .grant : .deny }

        let alert = NSAlert()
        alert.messageText = "Allow “\(host)” to \(phrase(type))?"
        alert.informativeText = "Vane will remember your answer for this site."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        // ponytail: app-modal, not a sheet — the delegate callback doesn't carry the tab,
        // so there is no window to attach to without threading one through.
        let allowed = alert.runModal() == .alertFirstButtonReturn
        remember(host: host, type: type, allow: allowed)
        return allowed ? .grant : .deny
    }

    /// Exact keys rather than a prefix sweep: a suffix match would take `sub.example.com`
    /// down with `example.com`, and permission is per-origin, not per-domain.
    static func reset(host: String) {
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            defaults.removeObject(forKey: key(host: host, type: type))
        }
    }

    /// One remembered answer, for the Privacy pane's summary.
    struct Grant: Identifiable, Equatable, Sendable {
        let host: String
        /// "Camera", "Microphone", "Camera and microphone" — the words, not the enum.
        let what: String
        let allowed: Bool
        var id: String { what + "." + host }
    }

    /// Which key names which grant, or nil when the key is not one of ours. Pure, so the
    /// summary's parsing is provable — and it is parsing, since the answers are stored one
    /// key per (site, device) rather than as a list.
    nonisolated static func parse(key: String) -> (what: String, host: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { return nil }
        let kind = String(rest[..<dot]), host = String(rest[rest.index(after: dot)...])
        guard !host.isEmpty else { return nil }
        switch kind {
        case "camera":              return ("Camera", host)
        case "microphone":          return ("Microphone", host)
        case "cameraAndMicrophone": return ("Camera and microphone", host)
        default:                    return nil
        }
    }

    /// Every site that has been answered, host order, for the Privacy pane.
    static func all() -> [Grant] {
        defaults.dictionaryRepresentation().compactMap { key, value in
            guard let (what, host) = parse(key: key), let allowed = value as? Bool else { return nil }
            return Grant(host: host, what: what, allowed: allowed)
        }
        .sorted { $0.id < $1.id }
    }

    static func resetAll() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            defaults.removeObject(forKey: k)
        }
    }

    // MARK: - check

    /// Runs against a throwaway defaults suite that is deleted afterwards; the user's real
    /// preferences are never read or written.
    static func check() -> [(String, Bool)] {
        let suite = "vane.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }

        var results: [(String, Bool)] = []
        results.append(("an undecided site is not remembered",
                        remembered(host: "example.com", type: .camera) == nil))

        remember(host: "example.com", type: .camera, allow: true)
        results.append(("an allow round-trips",
                        remembered(host: "example.com", type: .camera) == true))
        results.append(("host matching is case-insensitive",
                        remembered(host: "EXAMPLE.com", type: .camera) == true))
        results.append(("camera and microphone are remembered separately",
                        remembered(host: "example.com", type: .microphone) == nil))
        results.append(("the pair is its own permission",
                        remembered(host: "example.com", type: .cameraAndMicrophone) == nil))
        results.append(("one site's answer does not leak to another",
                        remembered(host: "evil.example", type: .camera) == nil))

        remember(host: "example.com", type: .microphone, allow: false)
        results.append(("a deny round-trips as false, not as unset",
                        remembered(host: "example.com", type: .microphone) == false))

        remember(host: "other.example", type: .camera, allow: true)
        reset(host: "example.com")
        results.append(("reset(host:) forgets every kind for that host",
                        remembered(host: "example.com", type: .camera) == nil
                        && remembered(host: "example.com", type: .microphone) == nil))
        results.append(("reset(host:) leaves other hosts alone",
                        remembered(host: "other.example", type: .camera) == true))
        // A prefix/suffix wipe would take neighbouring hosts with it.
        remember(host: "not-other.example", type: .camera, allow: true)
        remember(host: "sub.other.example", type: .camera, allow: true)
        reset(host: "other.example")
        results.append(("reset(host:) does not eat a host that merely ends the same way",
                        remembered(host: "not-other.example", type: .camera) == true))
        results.append(("reset(host:) does not eat a subdomain",
                        remembered(host: "sub.other.example", type: .camera) == true))

        // The Privacy pane reads the answers back out of the keys, so the keys have to
        // parse — and nothing that is not one of ours may ever parse.
        results.append(("a camera key names its site",
                        parse(key: "sitePermission.camera.example.com").map { $0 == ("Camera", "example.com") } == true))
        results.append(("a microphone key names its site",
                        parse(key: "sitePermission.microphone.example.com")?.what == "Microphone"))
        results.append(("the pair reads as the pair",
                        parse(key: "sitePermission.cameraAndMicrophone.example.com")?.what
                            == "Camera and microphone"))
        results.append(("a host with dots survives the parse",
                        parse(key: "sitePermission.camera.sub.example.co.uk")?.host
                            == "sub.example.co.uk"))
        results.append(("somebody else's preference is not a permission",
                        parse(key: "homepage") == nil && parse(key: "httpsOnly") == nil))
        results.append(("a key with no host is not a permission",
                        parse(key: "sitePermission.camera.") == nil))
        results.append(("a key with a kind we do not know is not a permission",
                        parse(key: "sitePermission.location.example.com") == nil))

        remember(host: "listed.example", type: .camera, allow: true)
        remember(host: "denied.example", type: .microphone, allow: false)
        let listed = all()
        results.append(("every answered site is listed",
                        listed.contains { $0.host == "listed.example" }
                        && listed.contains { $0.host == "denied.example" }))
        results.append(("...in a stable order, so the pane does not shuffle",
                        listed.map(\.id) == listed.map(\.id).sorted()))
        results.append(("...with what it was answered about, and what the answer was",
                        listed.contains { $0.host == "denied.example" && $0.what == "Microphone"
                                          && $0.allowed == false }))

        // The Site Control Center's three-way answer, and the pair grant it has to unpick.
        resetAll()
        set(host: "panel.example", type: .camera, answer: true)
        results.append(("Allow from the site panel round-trips",
                        remembered(host: "panel.example", type: .camera) == true))
        set(host: "panel.example", type: .camera, answer: false)
        results.append(("Block overwrites an Allow rather than adding to it",
                        remembered(host: "panel.example", type: .camera) == false))
        set(host: "panel.example", type: .camera, answer: nil)
        results.append(("Ask forgets the answer, so the site is asked again",
                        remembered(host: "panel.example", type: .camera) == nil))
        results.append(("…and only that one, not the whole site",
                        { set(host: "panel.example", type: .microphone, answer: true)
                          set(host: "panel.example", type: .camera, answer: nil)
                          return remembered(host: "panel.example", type: .microphone) == true }()))

        resetAll()
        remember(host: "pair.example", type: .cameraAndMicrophone, allow: true)
        results.append(("a pair grant answers for the camera on its own",
                        effective(host: "pair.example", type: .camera) == true))
        results.append(("…and for the microphone",
                        effective(host: "pair.example", type: .microphone) == true))
        results.append(("…but a single answer beats it",
                        { remember(host: "pair.example", type: .camera, allow: false)
                          return effective(host: "pair.example", type: .camera) == false }()))
        resetAll()
        remember(host: "pair.example", type: .cameraAndMicrophone, allow: true)
        set(host: "pair.example", type: .camera, answer: false)
        results.append(("blocking one device splits the pair instead of leaving it to outvote",
                        remembered(host: "pair.example", type: .cameraAndMicrophone) == nil))
        results.append(("…the blocked device is blocked",
                        effective(host: "pair.example", type: .camera) == false))
        results.append(("…and the untouched one keeps the yes it was given",
                        effective(host: "pair.example", type: .microphone) == true))
        results.append(("a site with no host cannot be answered for",
                        { set(host: "", type: .camera, answer: true); return all().allSatisfy { !$0.host.isEmpty } }()))

        resetAll()
        results.append(("resetAll forgets everything",
                        remembered(host: "not-other.example", type: .camera) == nil))
        results.append(("...and the summary empties with it", all().isEmpty))
        return results
    }
}
