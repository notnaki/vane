import AppKit
import WebKit

/// Camera, microphone, and location answers are scoped to a Web origin and profile. Private tab
/// answers live in memory only and disappear when the tab closes. One-time grants
/// belong to a single tab document and are never written to defaults.
@MainActor enum SitePermissions {
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case camera, microphone, cameraAndMicrophone, location
        init?(_ media: WKMediaCaptureType) {
            switch media {
            case .camera: self = .camera
            case .microphone: self = .microphone
            case .cameraAndMicrophone: self = .cameraAndMicrophone
            @unknown default: return nil
            }
        }
        var devices: Set<Kind> {
            self == .cameraAndMicrophone ? [.camera, .microphone] : [self]
        }
    }
    nonisolated static var supportsLocation: Bool {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { return true }
        #endif
        return false
    }
    @MainActor private final class CaptureOwner {
        weak var tab: Tab?
        weak var web: WKWebView?
        var permissions: [Scope: Set<Kind>] = [:]
        init(tab: Tab, web: WKWebView) { self.tab = tab; self.web = web }
    }
    private static var captureOwners: [UUID: CaptureOwner] = [:]

    private static func track(scope: Scope, type: Kind, tab: Tab, web: WKWebView) {
        let owner = captureOwners[tab.id] ?? CaptureOwner(tab: tab, web: web)
        owner.permissions[scope, default: []].formUnion(type.devices)
        captureOwners[tab.id] = owner
    }

    /// Capture setters are web-view-wide; stopping one device may also end another
    /// frame's use of that device. Location has no stop API, so revocation reloads the
    /// owning page to destroy existing watches. Never request or alter macOS TCC here.
    private static func revoke(scope: Scope, type: Kind? = nil) {
        for id in Array(captureOwners.keys) {
            guard let owner = captureOwners[id], let held = owner.permissions[scope],
                  let tab = owner.tab, let web = owner.web, tab.existingWeb === web else { continue }
            let devices = type.map { held.intersection($0.devices) } ?? held
            if devices.contains(.camera) { web.setCameraCaptureState(.none, completionHandler: nil) }
            if devices.contains(.microphone) { web.setMicrophoneCaptureState(.none, completionHandler: nil) }
            if devices.contains(.location) {
                // Reload can be cancelled without destroying the old watches. Keep
                // ownership until commit/destruction so a later revocation can retry.
                tab.endPermissionDocument(navigationStarted: true)
                web.reload()
            } else {
                owner.permissions[scope]?.subtract(devices)
            }
        }
    }

    private static var defaults: UserDefaults = .vane
    private static var privateAnswers: [UUID: [String: Bool]] = [:]
    private static var onceAnswers: [UUID: [Scope: Set<Kind>]] = [:]
    @MainActor private final class Pending {
        let token = UUID()
        let scope: Scope
        let type: Kind
        let alert: NSAlert
        var closeObserver: NSObjectProtocol?
        var monitor: Task<Void, Never>?
        weak var window: NSWindow?
        init(scope: Scope, type: Kind, alert: NSAlert, window: NSWindow) {
            self.scope = scope; self.type = type; self.alert = alert; self.window = window
        }
        func stopObserving() {
            monitor?.cancel(); monitor = nil
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

    private static func label(_ type: Kind) -> String { type.rawValue }

    private static func phrase(_ type: Kind) -> String {
        switch type {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .cameraAndMicrophone: "use your camera and microphone"
        case .location: "use your location"
        }
    }

    private static func key(scope: Scope, type: Kind) -> String {
        prefix + scope.profileID.uuidString.lowercased() + "." + label(type) + "."
            + scope.scheme + "." + String(scope.port) + "." + scope.host
    }

    static func remembered(scope: Scope, type: Kind) -> Bool? {
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { return privateAnswers[tabID]?[name] }
        return defaults.object(forKey: name) as? Bool
    }

    static func remember(scope: Scope, type: Kind, allow: Bool) {
        cancelPrompts(scope: scope, type: type)
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { privateAnswers[tabID, default: [:]][name] = allow }
        else { defaults.set(allow, forKey: name) }
        if !allow { revoke(scope: scope, type: type) }
    }

    private static func forget(scope: Scope, type: Kind) {
        let name = key(scope: scope, type: type)
        if let tabID = scope.privateTabID { privateAnswers[tabID]?.removeValue(forKey: name) }
        else { defaults.removeObject(forKey: name) }
    }

    /// A Block covering a requested device wins even against an older pair Allow.
    static func effective(scope: Scope, type: Kind, tabID: UUID? = nil) -> Bool? {
        let pair = remembered(scope: scope, type: .cameraAndMicrophone)
        let camera = remembered(scope: scope, type: .camera)
        let microphone = remembered(scope: scope, type: .microphone)
        let once = tabID.flatMap { onceAnswers[$0]?[scope] } ?? []
        if type == .location {
            return remembered(scope: scope, type: type) ?? (once.contains(type) ? true : nil)
        }
        let oncePair: Bool? = once.contains(.cameraAndMicrophone) ? true : nil
        let cameraAnswer = camera ?? pair ?? (once.contains(.camera) ? true : nil) ?? oncePair
        let microphoneAnswer = microphone ?? pair ?? (once.contains(.microphone) ? true : nil) ?? oncePair
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
        case .location: return nil
        }
    }

    /// Preserve the untouched device's pair answer when the panel changes one device.
    static func set(scope: Scope, type: Kind, answer: Bool?, tabID: UUID? = nil) {
        cancelPrompts(scope: scope, type: type)
        // Split a combined one-time grant just like a saved combined answer, so changing
        // Camera to Ask does not also discard Microphone's one-time access.
        for id in Array(onceAnswers.keys) {
            guard var grants = onceAnswers[id]?[scope] else { continue }
            if type != .location && type != .cameraAndMicrophone, grants.contains(.cameraAndMicrophone) {
                grants.formUnion([.camera, .microphone])
                grants.remove(.cameraAndMicrophone)
            }
            grants.remove(type)
            onceAnswers[id]?[scope] = grants.isEmpty ? nil : grants
            if onceAnswers[id]?.isEmpty == true { onceAnswers.removeValue(forKey: id) }
        }
        if type != .location, let pair = remembered(scope: scope, type: .cameraAndMicrophone) {
            for kind in [Kind.camera, .microphone]
            where remembered(scope: scope, type: kind) == nil {
                remember(scope: scope, type: kind, allow: pair)
            }
            forget(scope: scope, type: .cameraAndMicrophone)
        }
        if let answer { remember(scope: scope, type: type, allow: answer) }
        else { forget(scope: scope, type: type) }
        if answer == nil { revoke(scope: scope, type: type) }
    }

    static func makePrompt(scope: Scope, type: Kind) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(scope.origin)” wants to \(phrase(type))"
        alert.informativeText = "Allow Once lasts until this tab navigates or closes. " +
            (scope.privateTabID == nil ? "Always Allow remembers your choice for this site in this profile."
             : "Private permissions are never saved and last only in this private tab.")
            + " macOS authorization is separate and may still prevent access."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: scope.privateTabID == nil ? "Always Allow" : "Allow for This Private Tab")
        alert.addButton(withTitle: "Don’t Allow").keyEquivalent = "\u{1b}"
        return alert
    }

    /// Capture public lifecycle identity synchronously at the delegate boundary. A
    /// WKFrameInfo exposes no original document ID or exhaustive subframe destruction
    /// notifications, so embedded requests cannot safely enter our saved policy.
    static func handle(origin: WKSecurityOrigin, frame: WKFrameInfo, type: Kind,
                       tab: Tab, web: WKWebView,
                       completion: @escaping @MainActor (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame, let window = web.window, tab.existingWeb === web else { completion(.deny); return }
        let generation = tab.permissionGeneration
        Task { @MainActor in
            completion(await decide(origin: origin, frame: frame, type: type, tab: tab, web: web,
                                    generation: generation, window: window))
        }
    }

    private static func decide(origin: WKSecurityOrigin, frame: WKFrameInfo, type: Kind,
                               tab: Tab, web: WKWebView, generation: UInt, window: NSWindow) async -> WKPermissionDecision {
        guard let document = await SitePermissionDocument.capture(tab: tab, web: web, topOrigin: origin, frame: frame,
                                                                  generation: generation, window: window)
        else { return .deny }
        let scope = document.scope
        return await request(scope: scope, type: type, tabID: tab.id, window: window,
                             isCurrent: { document.ownerIsCurrent }, validate: { await document.isCurrent() },
                             onGrant: { [weak tab, weak web] in
            if let tab, let web { track(scope: scope, type: type, tab: tab, web: web) }
        })
    }

    /// The same request path is used by WebKit and popup fixtures. Only the requesting
    /// window is blocked; detached pages, stale documents, and busy windows fail closed.
    static func request(scope: Scope, type: Kind, tabID: UUID,
                        window: NSWindow?,
                        isCurrent: @escaping @MainActor () -> Bool,
                        validate: @escaping @MainActor () async -> Bool = { true },
                        onGrant: @escaping @MainActor () -> Void = {}) async -> WKPermissionDecision {
        guard !Task.isCancelled, isCurrent(), let window,
              scope.privateTabID == nil || scope.privateTabID == tabID else { return .deny }
        guard type != .location || supportsLocation else { return .deny }
        guard await validate(), !Task.isCancelled, isCurrent() else { return .deny }
        if let known = effective(scope: scope, type: type, tabID: tabID) {
            if known { onGrant() }
            return known ? .grant : .deny
        }
        guard pending[tabID] == nil, window.attachedSheet == nil else { return .deny }
        let alert = makePrompt(scope: scope, type: type)
        let prompt = Pending(scope: scope, type: type, alert: alert, window: window)
        pending[tabID] = prompt
        let token = prompt.token
        prompt.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    if pending[tabID]?.token == token { cancel(tabID: tabID) }
                }
            }
        // Poll only while a sheet is pending. Check the isolated document token and
        // presentation changes such as hiding or window transfer between callbacks.
        prompt.monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, pending[tabID] === prompt else { return }
                let valid = await validate()
                if pending[tabID] === prompt && (!valid || !isCurrent()) { cancel(tabID: tabID); return }
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
        let valid = await validate()
        guard pending[tabID] === prompt else { return .deny }
        pending.removeValue(forKey: tabID)
        prompt.stopObserving()
        guard valid, !Task.isCancelled, isCurrent() else { return .deny }
        switch response {
        case .alertFirstButtonReturn:
            onceAnswers[tabID, default: [:]][scope, default: []].insert(type)
        case .alertSecondButtonReturn:
            remember(scope: scope, type: type, allow: true)
        case .alertThirdButtonReturn:
            remember(scope: scope, type: type, allow: false)
        default: return .deny
        }
        SiteChanges.shared.bump()
        if response != .alertThirdButtonReturn { onGrant() }
        return response == .alertThirdButtonReturn ? .deny : .grant
    }

    private static func cancel(tabID: UUID) {
        guard let prompt = pending.removeValue(forKey: tabID) else { return }
        prompt.stopObserving()
        if let window = prompt.window, window.attachedSheet === prompt.alert.window {
            window.endSheet(prompt.alert.window, returnCode: .abort)
        }
    }

    private static func cancelPrompts(scope: Scope, type: Kind? = nil) {
        for id in Array(pending.keys) {
            guard let prompt = pending[id], prompt.scope == scope else { continue }
            if type == nil || !type!.devices.isDisjoint(with: prompt.type.devices) { cancel(tabID: id) }
        }
    }

    static func endDocument(tabID: UUID, preservingLocation: Bool = false) {
        cancel(tabID: tabID)
        if preservingLocation, let owner = captureOwners[tabID] {
            owner.permissions = owner.permissions.mapValues { $0.intersection([.location]) }.filter { !$0.value.isEmpty }
            if owner.permissions.isEmpty { captureOwners.removeValue(forKey: tabID) }
        } else { captureOwners.removeValue(forKey: tabID) }
        if onceAnswers.removeValue(forKey: tabID) != nil { SiteChanges.shared.bump() }
    }

    static func isAllowedOnce(scope: Scope, type: Kind, tabID: UUID) -> Bool {
        effective(scope: scope, type: type) == nil && effective(scope: scope, type: type, tabID: tabID) == true
    }

    static func reset(scope: Scope) {
        cancelPrompts(scope: scope)
        revoke(scope: scope)
        for id in Array(onceAnswers.keys) {
            onceAnswers[id]?.removeValue(forKey: scope)
            if onceAnswers[id]?.isEmpty == true { onceAnswers.removeValue(forKey: id) }
        }
        for type in Kind.allCases {
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
        case "location": what = "Location"
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
        let scopes = Set(captureOwners.values.flatMap { $0.permissions.keys })
        for scope in scopes where profileID == nil || scope.profileID == profileID { revoke(scope: scope) }
        for id in Array(pending.keys) where profileID == nil || pending[id]?.scope.profileID == profileID {
            cancel(tabID: id)
        }
        for id in Array(onceAnswers.keys) {
            onceAnswers[id] = onceAnswers[id]?.filter { profileID != nil && $0.key.profileID != profileID }
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
        let oldOwners = captureOwners
        defaults = scratch
        privateAnswers = [:]; onceAnswers = [:]; captureOwners = [:]
        defer {
            defaults = real
            privateAnswers = oldPrivate
            onceAnswers = oldOnce
            captureOwners = oldOwners
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
                        && parse(key: "sitePermission.v2.\(profile).unsupported.https.443.example.com") == nil))
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
