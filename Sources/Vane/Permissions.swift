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

    private static let prefix = "sitePermission."

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

    /// The whole decision for `WKUIDelegate`. Returns `.grant`/`.deny` only — never
    /// `.prompt`, which would hand the question back to WebKit, which has nowhere to put it.
    static func decide(origin: WKSecurityOrigin, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.host
        // A blank host means a file:// or opaque origin — there is nothing to remember an
        // answer against and nothing to name in the prompt, so refuse rather than mislead.
        guard !host.isEmpty else { return .deny }
        if let known = remembered(host: host, type: type) { return known ? .grant : .deny }

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

        resetAll()
        results.append(("resetAll forgets everything",
                        remembered(host: "not-other.example", type: .camera) == nil))
        return results
    }
}
