import AppKit
import WebKit

/// Camera and microphone answers are scoped to a Web origin and profile. Private tab
/// answers live in memory only and disappear when the tab closes. One-time grants
/// belong to a single tab document and are never written to defaults.
@MainActor enum SitePermissions {
    private static var defaults: UserDefaults = .vane
    private static var privateAnswers: [UUID: [String: Bool]] = [:]
    private static var onceAnswers: [UUID: [String: Bool]] = [:]
    @MainActor private final class Pending {
        let token = UUID()
        let scope: Scope
        let type: WKMediaCaptureType
        let alert: NSAlert
        var closeObserver: NSObjectProtocol?
        weak var window: NSWindow?
        init(scope: Scope, type: WKMediaCaptureType, alert: NSAlert, window: NSWindow) {
            self.scope = scope; self.type = type; self.alert = alert; self.window = window
        }
        func stopObserving() {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
    }
    private static var pending: [UUID: Pending] = [:]
    private static let prefix = "sitePermission.v2."

    struct Scope: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int
        let profileID: UUID
        let privateTabID: UUID?

        init?(scheme: String, host: String, port: Int, profileID: UUID,
              privateTabID: UUID? = nil) {
            let scheme = scheme.lowercased(), host = host.lowercased()
            guard (scheme == "https" || scheme == "http"), !host.isEmpty,
                  (0...65535).contains(port) else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port == 0 ? (scheme == "https" ? 443 : 80) : port
            self.profileID = profileID
            self.privateTabID = privateTabID
        }

        init?(url: URL?, profileID: UUID, privateTabID: UUID? = nil) {
            guard let url, let scheme = url.scheme, let host = url.host else { return nil }
            self.init(scheme: scheme, host: host, port: url.port ?? 0,
                      profileID: profileID, privateTabID: privateTabID)
        }

        var origin: String {
            let hostname = host.contains(":") ? "[\(host)]" : host
            let defaultPort = scheme == "https" ? 443 : 80
            return "\(scheme)://\(hostname)" + (port == defaultPort ? "" : ":\(port)")
        }
    }

    static func scope(for tab: Tab) -> Scope? {
        Scope(url: tab.currentURL, profileID: tab.profileID,
              privateTabID: tab.isPrivate ? tab.id : nil)
    }

    private static func label(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "cameraAndMicrophone"
        @unknown default: "unknown"
        }
    }

    private static func phrase(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .cameraAndMicrophone: "use your camera and microphone"
        @unknown default: "use a device"
        }
    }

    private static func key(scope: Scope, type: WKMediaCaptureType) -> String {
        prefix + scope.profileID.uuidString.lowercased() + "." + label(type) + "."
            + scope.scheme + "." + String(scope.port) + "." + scope.host
    }

    static func remembered(scope: Scope, type: WKMediaCaptureType) -> Bool? {
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { return privateAnswers[tabID]?[name] }
        return defaults.object(forKey: name) as? Bool
    }

    static func remember(scope: Scope, type: WKMediaCaptureType, allow: Bool) {
        cancelPrompts(scope: scope, type: type)
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { privateAnswers[tabID, default: [:]][name] = allow }
        else { defaults.set(allow, forKey: name) }
    }

    private static func forget(scope: Scope, type: WKMediaCaptureType) {
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { privateAnswers[tabID]?.removeValue(forKey: name) }
        else { defaults.removeObject(forKey: name) }
    }

    /// A Block covering a requested device wins even against an older pair Allow.
    static func effective(scope: Scope, type: WKMediaCaptureType, tabID: UUID? = nil) -> Bool? {
        let pair = remembered(scope: scope, type: .cameraAndMicrophone)
        let camera = remembered(scope: scope, type: .camera)
        let microphone = remembered(scope: scope, type: .microphone)
        let once = tabID.flatMap { onceAnswers[$0] } ?? [:]
        let oncePair = once[key(scope: scope, type: .cameraAndMicrophone)]
        let cameraAnswer = camera ?? pair ?? once[key(scope: scope, type: .camera)] ?? oncePair
        let microphoneAnswer = microphone ?? pair ?? once[key(scope: scope, type: .microphone)] ?? oncePair
        switch type {
        case .camera:
            if camera == false || pair == false { return false }
            return cameraAnswer
        case .microphone:
            if microphone == false || pair == false { return false }
            return microphoneAnswer
        case .cameraAndMicrophone:
            if pair == false || camera == false || microphone == false { return false }
            if pair == true { return true }
            return cameraAnswer == true && microphoneAnswer == true ? true : nil
        @unknown default: return nil
        }
    }

    /// Preserve the untouched device's pair answer when the panel changes one device.
    static func set(scope: Scope, type: WKMediaCaptureType, answer: Bool?, tabID: UUID? = nil) {
        cancelPrompts(scope: scope, type: type)
        // Split a combined one-time grant just like a saved combined answer, so changing
        // Camera to Ask does not also discard Microphone's one-time access.
        let owner = tabID ?? scope.privateTabID
        for id in Array(onceAnswers.keys) where owner == nil || id == owner {
            let pairKey = key(scope: scope, type: .cameraAndMicrophone)
            if type != .cameraAndMicrophone, onceAnswers[id]?[pairKey] == true {
                for kind in [WKMediaCaptureType.camera, .microphone] {
                    onceAnswers[id, default: [:]][key(scope: scope, type: kind)] = true
                }
                onceAnswers[id]?.removeValue(forKey: pairKey)
            }
            onceAnswers[id]?.removeValue(forKey: key(scope: scope, type: type))
            if onceAnswers[id]?.isEmpty == true { onceAnswers.removeValue(forKey: id) }
        }
        if let pair = remembered(scope: scope, type: .cameraAndMicrophone) {
            for kind in [WKMediaCaptureType.camera, .microphone]
            where remembered(scope: scope, type: kind) == nil {
                remember(scope: scope, type: kind, allow: pair)
            }
            forget(scope: scope, type: .cameraAndMicrophone)
        }
        if let answer { remember(scope: scope, type: type, allow: answer) }
        else { forget(scope: scope, type: type) }
    }

    static func makePrompt(scope: Scope, type: WKMediaCaptureType) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(scope.origin)” wants to \(phrase(type))"
        alert.informativeText = "Allow Once lasts until this tab navigates or closes. " +
            (scope.privateTabID == nil ? "Always Allow remembers your choice for this site in this profile."
             : "Private permissions are never saved and last only in this private tab.")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: scope.privateTabID == nil ? "Always Allow" : "Allow for This Private Tab")
        alert.addButton(withTitle: "Don’t Allow").keyEquivalent = "\u{1b}"
        return alert
    }

    static func decide(origin: WKSecurityOrigin, type: WKMediaCaptureType,
                       tab: Tab, web: WKWebView) async -> WKPermissionDecision {
        guard let scope = Scope(scheme: origin.protocol, host: origin.host, port: origin.port,
                                profileID: tab.profileID, privateTabID: tab.isPrivate ? tab.id : nil)
        else { return .deny }
        let window = web.window
        return await request(scope: scope, type: type, tabID: tab.id, window: window,
                             isCurrent: { [weak tab, weak web, weak window] in
            guard let tab, let web, let window else { return false }
            return tab.existingWeb === web && web.window === window
                && !web.isHiddenOrHasHiddenAncestor && window.isVisible
        })
    }

    /// The same request path is used by WebKit and popup fixtures. Only the requesting
    /// window is blocked; detached pages, stale documents, and busy windows fail closed.
    static func request(scope: Scope, type: WKMediaCaptureType, tabID: UUID,
                        window: NSWindow?, isCurrent: @escaping @MainActor () -> Bool) async -> WKPermissionDecision {
        guard !Task.isCancelled, isCurrent(), let window,
              scope.privateTabID == nil || scope.privateTabID == tabID else { return .deny }
        switch type {
        case .camera, .microphone, .cameraAndMicrophone: break
        @unknown default: return .deny
        }
        if let known = effective(scope: scope, type: type, tabID: tabID) { return known ? .grant : .deny }
        guard pending[tabID] == nil, window.attachedSheet == nil else { return .deny }
        let alert = makePrompt(scope: scope, type: type)
        let prompt = Pending(scope: scope, type: type, alert: alert, window: window)
        pending[tabID] = prompt
        let token = prompt.token
        prompt.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    if pending[tabID]?.token == token { endDocument(tabID: tabID) }
                }
            }
        let response = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in
                if pending[tabID] === prompt { cancel(tabID: tabID) }
            }
        }
        guard pending[tabID] === prompt else { return .deny }
        pending.removeValue(forKey: tabID)
        prompt.stopObserving()
        guard !Task.isCancelled, isCurrent() else { return .deny }
        switch response {
        case .alertFirstButtonReturn:
            onceAnswers[tabID, default: [:]][key(scope: scope, type: type)] = true
        case .alertSecondButtonReturn:
            remember(scope: scope, type: type, allow: true)
        case .alertThirdButtonReturn:
            remember(scope: scope, type: type, allow: false)
        default: return .deny
        }
        SiteChanges.shared.bump()
        return response == .alertThirdButtonReturn ? .deny : .grant
    }

    private static func cancel(tabID: UUID) {
        guard let prompt = pending.removeValue(forKey: tabID) else { return }
        prompt.stopObserving()
        prompt.window?.endSheet(prompt.alert.window, returnCode: .abort)
    }

    private static func cancelPrompts(scope: Scope, type: WKMediaCaptureType? = nil) {
        for id in Array(pending.keys) {
            guard let prompt = pending[id], prompt.scope == scope else { continue }
            if type == nil || type == prompt.type || type == .cameraAndMicrophone
                || prompt.type == .cameraAndMicrophone { cancel(tabID: id) }
        }
    }

    static func endDocument(tabID: UUID) {
        cancel(tabID: tabID)
        if onceAnswers.removeValue(forKey: tabID) != nil { SiteChanges.shared.bump() }
    }

    static func isAllowedOnce(scope: Scope, type: WKMediaCaptureType, tabID: UUID) -> Bool {
        effective(scope: scope, type: type) == nil && effective(scope: scope, type: type, tabID: tabID) == true
    }

    static func reset(scope: Scope) {
        cancelPrompts(scope: scope)
        for id in Array(onceAnswers.keys) where scope.privateTabID == nil || id == scope.privateTabID {
            for kind in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
                onceAnswers[id]?.removeValue(forKey: key(scope: scope, type: kind))
            }
            if onceAnswers[id]?.isEmpty == true { onceAnswers.removeValue(forKey: id) }
        }
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            forget(scope: scope, type: type)
        }
    }

    static func forgetPrivate(tabID: UUID) {
        endDocument(tabID: tabID)
        privateAnswers.removeValue(forKey: tabID)
    }

    struct Grant: Identifiable, Equatable, Sendable {
        let scope: Scope
        let what: String
        let allowed: Bool
        var id: String { scope.origin + "." + what }
    }

    /// Old host-only keys cannot safely map to one origin or profile, so they are ignored.
    private static func parse(key: String) -> (scope: Scope, what: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let fields = key.dropFirst(prefix.count)
            .split(separator: ".", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, let profileID = UUID(uuidString: String(fields[0])),
              let port = Int(fields[3]),
              let scope = Scope(scheme: String(fields[2]), host: String(fields[4]),
                                port: port, profileID: profileID) else { return nil }
        let what: String
        switch fields[1] {
        case "camera": what = "Camera"
        case "microphone": what = "Microphone"
        case "cameraAndMicrophone": what = "Camera and microphone"
        default: return nil
        }
        return (scope, what)
    }

    static func all(profileID: UUID) -> [Grant] {
        defaults.dictionaryRepresentation().compactMap { name, value in
            guard let parsed = parse(key: name), parsed.scope.profileID == profileID,
                  let allowed = value as? Bool else { return nil }
            return Grant(scope: parsed.scope, what: parsed.what, allowed: allowed)
        }
        .sorted { $0.id < $1.id }
    }

    /// A global reset also removes old host-only keys. Private answers are never persisted.
    static func resetAll(profileID: UUID? = nil) {
        for id in Array(pending.keys) where profileID == nil || pending[id]?.scope.profileID == profileID {
            cancel(tabID: id)
        }
        for id in Array(onceAnswers.keys) {
            onceAnswers[id] = onceAnswers[id]?.filter { profileID != nil && parse(key: $0.key)?.scope.profileID != profileID }
            if onceAnswers[id]?.isEmpty == true { onceAnswers.removeValue(forKey: id) }
        }
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix("sitePermission.") {
            if let profileID, parse(key: name)?.scope.profileID != profileID { continue }
            defaults.removeObject(forKey: name)
        }
        if let profileID {
            for tabID in Array(privateAnswers.keys) {
                privateAnswers[tabID] = privateAnswers[tabID]?.filter {
                    parse(key: $0.key)?.scope.profileID != profileID
                }
            }
        } else { privateAnswers.removeAll() }
    }

    // MARK: - check
    static func check() -> [(String, Bool)] {
        let suite = "vane.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults, oldPrivate = privateAnswers, oldOnce = onceAnswers
        defaults = scratch
        privateAnswers = [:]
        defer {
            defaults = real
            privateAnswers = oldPrivate
            onceAnswers = oldOnce
            UserDefaults.dropScratchSuite(suite)
        }
        let profile = UUID(), otherProfile = UUID(), privateTab = UUID()
        let secure = Scope(url: URL(string: "https://scoped.example/"), profileID: profile)!
        let insecure = Scope(url: URL(string: "http://scoped.example/"), profileID: profile)!
        let alternatePort = Scope(url: URL(string: "https://scoped.example:8443/"), profileID: profile)!
        let other = Scope(url: URL(string: "https://scoped.example/"), profileID: otherProfile)!
        let privateScope = Scope(url: URL(string: "https://scoped.example/"),
                                 profileID: profile, privateTabID: privateTab)!
        var results: [(String, Bool)] = []
        results.append(("an undecided origin is Ask", effective(scope: secure, type: .camera) == nil))
        remember(scope: secure, type: .camera, allow: true)
        results.append(("an Allow round-trips", remembered(scope: secure, type: .camera) == true))
        results.append(("host matching ignores case",
                        remembered(scope: Scope(url: URL(string: "https://SCOPED.example/"),
                                                profileID: profile)!, type: .camera) == true))
        results.append(("a grant stays on its URL scheme",
                        remembered(scope: insecure, type: .camera) == nil))
        results.append(("a grant stays on its URL port",
                        remembered(scope: alternatePort, type: .camera) == nil))
        results.append(("a grant stays in its profile",
                        remembered(scope: other, type: .camera) == nil))
        results.append(("an ordinary grant is not reused in a private tab",
                        remembered(scope: privateScope, type: .camera) == nil))
        remember(scope: privateScope, type: .microphone, allow: true)
        results.append(("a private grant stays in memory and in its tab",
                        remembered(scope: privateScope, type: .microphone) == true
                        && remembered(scope: secure, type: .microphone) == nil
                        && remembered(scope: Scope(url: URL(string: "https://scoped.example/"),
                                                   profileID: profile, privateTabID: UUID())!,
                                      type: .microphone) == nil
                        && !all(profileID: profile).contains { $0.what == "Microphone" }))
        forgetPrivate(tabID: privateTab)
        results.append(("closing a private tab forgets its grants",
                        remembered(scope: privateScope, type: .microphone) == nil))
        results.append(("default and explicit HTTPS ports are the same origin",
                        Scope(url: URL(string: "https://scoped.example:443"), profileID: profile) == secure))
        results.append(("opaque and file origins cannot be remembered",
                        Scope(url: URL(string: "file:///tmp/x"), profileID: profile) == nil))
        scratch.set(true, forKey: "sitePermission.camera.legacy.example")
        let legacy = Scope(url: URL(string: "https://legacy.example"), profileID: profile)!
        results.append(("legacy host-only Allows do not authorize an origin",
                        effective(scope: legacy, type: .camera) == nil))

        reset(scope: secure)
        remember(scope: secure, type: .cameraAndMicrophone, allow: true)
        results.append(("a pair Allow covers either device alone",
                        effective(scope: secure, type: .camera) == true
                        && effective(scope: secure, type: .microphone) == true))
        remember(scope: secure, type: .cameraAndMicrophone, allow: false)
        results.append(("a pair Block refuses either device alone",
                        effective(scope: secure, type: .camera) == false
                        && effective(scope: secure, type: .microphone) == false))
        reset(scope: secure)
        remember(scope: secure, type: .camera, allow: true)
        remember(scope: secure, type: .cameraAndMicrophone, allow: true)
        remember(scope: secure, type: .microphone, allow: false)
        results.append(("a microphone Block beats an explicit pair Allow",
                        effective(scope: secure, type: .cameraAndMicrophone) == false))
        remember(scope: secure, type: .microphone, allow: true)
        remember(scope: secure, type: .camera, allow: false)
        results.append(("a camera Block beats an explicit pair Allow",
                        effective(scope: secure, type: .cameraAndMicrophone) == false))
        reset(scope: secure)
        set(scope: secure, type: .camera, answer: true)
        set(scope: secure, type: .microphone, answer: true)
        results.append(("two single Allows grant the pair",
                        effective(scope: secure, type: .cameraAndMicrophone) == true))
        set(scope: secure, type: .camera, answer: false)
        results.append(("a single Block refuses the pair",
                        effective(scope: secure, type: .cameraAndMicrophone) == false))
        set(scope: secure, type: .camera, answer: nil)
        results.append(("Ask leaves a partially answered pair unanswered",
                        effective(scope: secure, type: .cameraAndMicrophone) == nil))
        remember(scope: secure, type: .cameraAndMicrophone, allow: true)
        set(scope: secure, type: .camera, answer: false)
        results.append(("panel Block splits and replaces a pair Allow",
                        remembered(scope: secure, type: .cameraAndMicrophone) == nil
                        && effective(scope: secure, type: .camera) == false
                        && effective(scope: secure, type: .microphone) == true))
        let listed = all(profileID: profile)
        results.append(("Privacy lists only this profile and the full origin",
                        listed.contains { $0.scope.origin == "https://scoped.example" && !$0.allowed }
                        && all(profileID: otherProfile).isEmpty))
        results.append(("Privacy grants have stable order and device labels",
                        listed.map(\.id) == listed.map(\.id).sorted()
                        && listed.contains { $0.what == "Microphone" }))
        results.append(("malformed permission keys are ignored",
                        parse(key: "sitePermission.v2.no-uuid.camera.https.443.example.com") == nil
                        && parse(key: "sitePermission.v2.\(profile).location.https.443.example.com") == nil))
        remember(scope: alternatePort, type: .camera, allow: true)
        reset(scope: secure)
        results.append(("reset leaves other origins alone",
                        remembered(scope: alternatePort, type: .camera) == true))
        remember(scope: other, type: .camera, allow: true)
        resetAll(profileID: profile)
        results.append(("profile reset leaves other profiles alone",
                        remembered(scope: other, type: .camera) == true
                        && all(profileID: profile).isEmpty))
        resetAll()
        results.append(("global reset removes current and legacy grants",
                        all(profileID: otherProfile).isEmpty
                        && scratch.object(forKey: "sitePermission.camera.legacy.example") == nil))
        return results
    }
}
