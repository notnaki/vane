import AppKit
import CryptoKit
import Security
import WebKit

/// The one place a bad certificate can be got past, and the HTTP auth prompt that lives in
/// the same delegate method. Without this, `WKNavigationDelegate` never answers a challenge
/// at all: a self-signed host is a dead end with an error page, and a Basic-auth realm is a
/// 401 the user can do nothing about.
///
@MainActor enum CertificateTrust {

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    private static var defaults: UserDefaults = .vane

    /// v1 keys contained only a hostname and fingerprint. They are deliberately never read:
    /// treating one as a v2 decision would silently spread it to every profile and port.
    private static let legacyPrefix = "certException."
    private static let prefix = "certException.v2."

    struct Scope: Hashable, Codable, Sendable {
        let profileID: UUID
        let host: String
        let port: Int

        init?(profileID: UUID, host: String, port: Int) {
            let host = host.lowercased()
            guard !host.isEmpty else { return nil }
            self.profileID = profileID
            self.host = host
            self.port = port > 0 ? port : 443
        }

        var display: String { port == 443 ? host : "\(host):\(port)" }
    }

    private final class Memory: NSObject {
        var exceptions: Set<String> = []
        var generation = UUID()
        var prompt: NSAlert?
        weak var window: NSWindow?
    }
    private static let memories = NSMapTable<Tab, Memory>.weakToStrongObjects()

    private static func memory(for tab: Tab) -> Memory {
        if let memory = memories.object(forKey: tab) { return memory }
        let memory = Memory()
        memories.setObject(memory, forKey: tab)
        return memory
    }

    private static func key(scope: Scope, fingerprint: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(scope) else { return "" }
        return prefix + data.base64EncodedString() + "|" + fingerprint
    }

    private static func scope(from key: String) -> Scope? {
        guard key.hasPrefix(prefix),
              let bar = key.lastIndex(of: "|"),
              let data = Data(base64Encoded: String(key[key.index(key.startIndex,
                                                                  offsetBy: prefix.count)..<bar])),
              let scope = try? JSONDecoder().decode(Scope.self, from: data)
        else { return nil }
        return Scope(profileID: scope.profileID, host: scope.host, port: scope.port)
    }

    // MARK: - Remembered exceptions

    /// Keyed on the certificate too, not just the host: an exception for one certificate
    /// must not silently cover whatever certificate shows up tomorrow. Swapping the cert is
    /// exactly what an interception looks like, so it has to ask again.
    static func trusted(scope: Scope, fingerprint: String, privateMemory: Set<String>? = nil) -> Bool {
        let key = key(scope: scope, fingerprint: fingerprint)
        if let privateMemory { return privateMemory.contains(key) }
        return defaults.bool(forKey: key)
    }

    /// Only ever called from the branch where the user clicked through both alerts.
    private static func remember(scope: Scope, fingerprint: String, memory: Memory?) {
        let key = key(scope: scope, fingerprint: fingerprint)
        if let memory { memory.exceptions.insert(key) }
        else { defaults.set(true, forKey: key) }
    }

    static func forget(host: String, profileID: UUID) {
        let host = host.lowercased()
        for key in defaults.dictionaryRepresentation().keys {
            guard let scope = scope(from: key), scope.profileID == profileID,
                  scope.host == host else { continue }
            defaults.removeObject(forKey: key)
        }
        for memory in memories.objectEnumerator()?.allObjects as? [Memory] ?? [] {
            memory.exceptions = Set(memory.exceptions.filter {
                guard let parsed = scope(from: $0) else { return false }
                return parsed.profileID != profileID || parsed.host != host
            })
        }
    }

    static func forget(profile profileID: UUID) {
        for key in defaults.dictionaryRepresentation().keys
            where scope(from: key)?.profileID == profileID { defaults.removeObject(forKey: key) }
        for memory in memories.objectEnumerator()?.allObjects as? [Memory] ?? [] {
            memory.exceptions = Set(memory.exceptions.filter { scope(from: $0)?.profileID != profileID })
        }
    }

    static func forgetAll() {
        for k in defaults.dictionaryRepresentation().keys
            where k.hasPrefix(prefix) || k.hasPrefix(legacyPrefix) {
            defaults.removeObject(forKey: k)
        }
        for memory in memories.objectEnumerator()?.allObjects as? [Memory] ?? [] {
            memory.exceptions.removeAll()
        }
    }

    // MARK: - Why the evaluation failed

    /// What is actually wrong. Kept separate from the alert so the wording can be asserted
    /// offline, and so "something is wrong" is never a reachable answer.
    enum Fault: String, CaseIterable {
        case expired, notYetValid, hostname, revoked, selfSigned, unknownRoot, unknown
    }

    /// What the leaf certificate says about itself. macOS collapses several different
    /// problems into one generic `errSecNotTrusted`, so these are what turn that back into
    /// a real reason.
    struct Hints: Equatable {
        var expired = false
        var notYetValid = false
        var selfSigned = false
        var notAfter: Date?
    }

    static func fault(status: OSStatus, hints: Hints = Hints()) -> Fault {
        // A specific status beats anything we worked out ourselves.
        switch status {
        case errSecCertificateExpired:     return .expired
        case errSecCertificateNotValidYet: return .notYetValid
        case errSecHostNameMismatch:       return .hostname
        case errSecCertificateRevoked:     return .revoked
        default: break
        }
        if hints.expired     { return .expired }
        if hints.notYetValid { return .notYetValid }
        if hints.selfSigned  { return .selfSigned }
        switch status {
        case errSecNotTrusted, errSecCreateChainFailed: return .unknownRoot
        default: return .unknown
        }
    }

    /// Plain language, in the words a person would use. Every case says what is wrong *and*
    /// what the innocent explanation is, because most of these really are just neglect.
    static func detail(_ fault: Fault) -> String {
        switch fault {
        case .expired:
            return "This site’s certificate has expired. Usually that means nobody renewed it — but an expired certificate is also what a replayed old one looks like."
        case .notYetValid:
            return "This site’s certificate isn’t valid yet. It was issued for a date in the future, or this Mac’s clock is wrong."
        case .hostname:
            return "This certificate was issued for a different site. Whoever answered is not the address you typed."
        case .revoked:
            return "This site’s certificate was revoked by the authority that issued it. Certificates get revoked when their private key is known to be stolen."
        case .selfSigned:
            return "This certificate signed itself. Nobody vouches for it, so it proves nothing at all about who is on the other end."
        case .unknownRoot:
            return "This certificate was issued by an authority this Mac doesn’t recognise. That is normal behind a corporate proxy — and it is also exactly what someone intercepting the connection looks like."
        case .unknown:
            return "Vane couldn’t verify this site’s identity, and macOS didn’t say why."
        }
    }

    // MARK: - Reading the certificate

    static func fingerprint(_ cert: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// ponytail: only the leaf is inspected. The chain is where an unknown *intermediate*
    /// would show up, but the leaf's own dates and self-signedness cover the reasons a user
    /// can act on.
    static func hints(for cert: SecCertificate, now: Date = .now) -> Hints {
        var h = Hints()
        let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?
        let issuer  = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?
        h.selfSigned = subject != nil && subject == issuer

        let oids = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, oids, nil) as? [String: Any] else { return h }
        // Each entry is {label, type, value}; the validity dates come back as a
        // CFAbsoluteTime, i.e. seconds since 2001, not since 1970.
        func date(_ oid: CFString) -> Date? {
            guard let entry = values[oid as String] as? [String: Any],
                  let seconds = (entry[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
            else { return nil }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        h.notAfter = date(kSecOIDX509V1ValidityNotAfter)
        if let after = h.notAfter, after < now { h.expired = true }
        if let before = date(kSecOIDX509V1ValidityNotBefore), before > now { h.notYetValid = true }
        return h
    }

    // MARK: - The delegate method

    /// Everything `webView(_:didReceive:)` has to answer. Anything that isn't a server
    /// trust or a login challenge goes back to the system, which is the only honest answer
    /// for a method that also covers client certificates and NTLM.
    static func handle(challenge: URLAuthenticationChallenge, tab: Tab, web: WKWebView) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard tab.web === web else { return (.cancelAuthenticationChallenge, nil) }
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return await serverTrust(challenge, tab: tab, web: web)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            return await login(challenge, tab: tab, web: web)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    private static func serverTrust(_ challenge: URLAuthenticationChallenge, tab: Tab, web: WKWebView) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // The overwhelmingly common case: the certificate is fine. Hand it back to the
        // system rather than minting a credential of our own.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (.performDefaultHandling, nil) }

        let host = challenge.protectionSpace.host
        guard let scope = Scope(profileID: tab.profileID, host: host,
                                port: challenge.protectionSpace.port) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        guard let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            // No certificate to pin an exception to, so there is no safe way to offer one.
            return (.cancelAuthenticationChallenge, nil)
        }
        let fp = fingerprint(cert)
        let memory = memory(for: tab)
        if trusted(scope: scope, fingerprint: fp,
                   privateMemory: tab.isPrivate ? memory.exceptions : nil) {
            return (.useCredential, URLCredential(trust: trust))
        }

        let status = OSStatus(error.map { CFErrorGetCode($0) } ?? Int(errSecNotTrusted))
        let h = hints(for: cert)
        guard await ask(host: scope.display, fault: fault(status: status, hints: h), hints: h,
                        fingerprint: fp, tab: tab, web: web, memory: memory) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        remember(scope: scope, fingerprint: fp, memory: tab.isPrivate ? memory : nil)
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Two alerts, deliberately. The first defaults to Go Back and its only other button
    /// asks to see the details — clicking through takes a second, separate decision, and
    /// neither Return nor Escape can reach the button that proceeds.
    private static func ask(host: String, fault: Fault, hints: Hints, fingerprint: String,
                            tab: Tab, web: WKWebView, memory: Memory) async -> Bool {
        let first = NSAlert()
        first.alertStyle = .critical
        first.messageText = "Vane can’t verify that this is “\(host)”"
        var detailText = detail(fault)
        if fault == .expired, let after = hints.notAfter {
            detailText += "\n\nIt expired on " + after.formatted(date: .abbreviated, time: .omitted) + "."
        }
        first.informativeText = detailText
        first.addButton(withTitle: "Go Back")
        let details = first.addButton(withTitle: "Details…")
        details.keyEquivalent = ""
        guard await present(first, tab: tab, web: web, memory: memory) == .alertSecondButtonReturn
        else { return false }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "Visit “\(host)” anyway?"
        second.informativeText = """
            Everything you type on this site — passwords included — will go over a \
            connection Vane cannot vouch for, and anyone able to produce this certificate \
            can read it.

            Vane will stop asking for this one certificate on this one site. If the site \
            ever presents a different certificate, you will be asked again.

            SHA-256: \(spaced(fingerprint))
            """
        second.addButton(withTitle: "Go Back")
        let proceed = second.addButton(withTitle: "Visit This Site")
        proceed.keyEquivalent = ""
        proceed.hasDestructiveAction = true
        return await present(second, tab: tab, web: web, memory: memory) == .alertSecondButtonReturn
    }

    /// A 64-character hex run is unreadable and unverifiable; grouped bytes can actually be
    /// compared against what the site's operator tells you over the phone.
    static func spaced(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: min(2, hex.count - i))])
        }.joined(separator: " ")
    }

    // MARK: - HTTP Basic / Digest

    /// The credential answers this challenge only. WebKit's profile data store may reuse the
    /// authenticated connection, but Vane never puts the password in process-wide session
    /// credential storage or the login keychain.
    private static func login(_ challenge: URLAuthenticationChallenge, tab: Tab, web: WKWebView) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        let defaultPort = space.protocol?.lowercased() == "http" ? 80 : 443
        let site = space.port > 0 && space.port != defaultPort
            ? "\(space.host):\(space.port)" : space.host
        alert.messageText = "“\(site)” requires a username and password"
        var info = space.realm.map { $0.isEmpty ? "" : "Realm: \($0)\n" } ?? ""
        if space.protocol == "http" {
            info += "This connection is not encrypted, so the password is sent in the clear.\n"
        }
        if challenge.previousFailureCount > 0 { info += "The last attempt was rejected.\n" }
        alert.informativeText = info.trimmingCharacters(in: .newlines)

        let user = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        user.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        password.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 50))
        box.addSubview(user)
        box.addSubview(password)
        alert.accessoryView = box
        alert.window.initialFirstResponder = user

        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert, tab: tab, web: web, memory: memory(for: tab))
                == .alertFirstButtonReturn,
              !user.stringValue.isEmpty else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, loginCredential(user: user.stringValue,
                                                password: password.stringValue))
    }

    private static func loginCredential(user: String, password: String) -> URLCredential {
        URLCredential(user: user, password: password, persistence: .none)
    }

    private static func stillCurrent(generation: UUID, currentGeneration: UUID,
                                     sameWeb: Bool, sameWindow: Bool, visible: Bool) -> Bool {
        generation == currentGeneration && sameWeb && sameWindow && visible
    }

    private static func present(_ alert: NSAlert, tab: Tab, web: WKWebView,
                                memory: Memory) async -> NSApplication.ModalResponse {
        guard memory.prompt == nil, let window = web.window,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return .abort }
        let generation = memory.generation
        memory.prompt = alert
        memory.window = window
        let response = await alert.beginSheetModal(for: window)
        if memory.prompt === alert { memory.prompt = nil; memory.window = nil }
        guard stillCurrent(generation: generation, currentGeneration: memory.generation,
                           sameWeb: tab.web === web, sameWindow: web.window === window,
                           visible: !web.isHiddenOrHasHiddenAncestor) else { return .abort }
        return response
    }

    static func navigationStarted(in tab: Tab) {
        guard let memory = memories.object(forKey: tab) else { return }
        memory.generation = UUID()
        if let prompt = memory.prompt, let window = memory.window {
            window.endSheet(prompt.window, returnCode: .abort)
        }
    }

    // MARK: - check

    /// Runs against a throwaway defaults suite that is deleted afterwards; the user's real
    /// preferences are never read or written, and nothing here opens a socket or an alert.
    static func check() -> [(String, Bool)] {
        let suite = "vane.certcheck.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            UserDefaults.dropScratchSuite(suite)
        }

        let profile = UUID(), otherProfile = UUID()
        let example = Scope(profileID: profile, host: "example.com", port: 443)!
        let otherPort = Scope(profileID: profile, host: "example.com", port: 8443)!
        let otherProfileScope = Scope(profileID: otherProfile, host: "example.com", port: 443)!
        let other = Scope(profileID: profile, host: "other.example", port: 443)!
        let neighbour = Scope(profileID: profile, host: "other.example.au", port: 443)!
        let subdomain = Scope(profileID: profile, host: "sub.other.example", port: 443)!
        let a = String(repeating: "a1", count: 32)   // stand-in fingerprints, 64 hex chars
        let b = String(repeating: "b2", count: 32)
        var out: [(String, Bool)] = []

        out.append(("an unvisited host is not trusted", !trusted(scope: example, fingerprint: a)))
        remember(scope: example, fingerprint: a, memory: nil)
        out.append(("a remembered exception reads back", trusted(scope: example, fingerprint: a)))
        out.append(("host matching is case-insensitive",
                    Scope(profileID: profile, host: "EXAMPLE.com", port: 443) == example))
        // The whole point of pinning the fingerprint: a swapped certificate re-prompts.
        out.append(("a different certificate for the same host is NOT trusted",
                    !trusted(scope: example, fingerprint: b)))
        out.append(("an exception does not cross ports", !trusted(scope: otherPort, fingerprint: a)))
        out.append(("an exception does not cross profiles", !trusted(scope: otherProfileScope, fingerprint: a)))
        scratch.set(true, forKey: legacyPrefix + "example.com|" + a)
        out.append(("a legacy global exception fails closed", !trusted(scope: otherProfileScope, fingerprint: a)))

        let privateMemory = Memory()
        remember(scope: example, fingerprint: b, memory: privateMemory)
        out.append(("a private exception stays out of persistent preferences",
                    trusted(scope: example, fingerprint: b, privateMemory: privateMemory.exceptions)
                    && !trusted(scope: example, fingerprint: b)))
        out.append(("a private exception does not cross tabs",
                    !trusted(scope: example, fingerprint: b, privateMemory: [])))

        remember(scope: other, fingerprint: b, memory: nil)
        remember(scope: Scope(profileID: otherProfile, host: "other.example", port: 443)!,
                 fingerprint: b, memory: nil)
        remember(scope: neighbour, fingerprint: a, memory: nil)
        remember(scope: subdomain, fingerprint: a, memory: nil)
        forget(host: "other.example", profileID: profile)
        out.append(("forget(host:) drops that profile's host exception", !trusted(scope: other, fingerprint: b)))
        out.append(("forget(host:) leaves another profile's decision alone",
                    trusted(scope: Scope(profileID: otherProfile, host: "other.example", port: 443)!,
                            fingerprint: b)))
        out.append(("forget(host:) does not eat a host that merely starts the same way",
                    trusted(scope: neighbour, fingerprint: a)))
        out.append(("forget(host:) does not eat a subdomain",
                    trusted(scope: subdomain, fingerprint: a)))
        out.append(("forget(host:) leaves unrelated hosts alone", trusted(scope: example, fingerprint: a)))
        forget(profile: otherProfile)
        out.append(("deleting a profile drops only that profile's certificate decisions",
                    !trusted(scope: Scope(profileID: otherProfile, host: "other.example", port: 443)!,
                             fingerprint: b)
                    && trusted(scope: example, fingerprint: a)))
        forgetAll()
        out.append(("forgetAll drops everything",
                    !trusted(scope: example, fingerprint: a)
                    && !trusted(scope: subdomain, fingerprint: a)))

        let generation = UUID()
        out.append(("a newer navigation rejects a stale prompt answer",
                    !stillCurrent(generation: generation, currentGeneration: UUID(),
                                  sameWeb: true, sameWindow: true, visible: true)))
        out.append(("a replacement web view rejects a stale prompt answer",
                    !stillCurrent(generation: generation, currentGeneration: generation,
                                  sameWeb: false, sameWindow: true, visible: true)))
        out.append(("a moved or closed window rejects a stale prompt answer",
                    !stillCurrent(generation: generation, currentGeneration: generation,
                                  sameWeb: true, sameWindow: false, visible: true)))
        out.append(("a hidden requesting tab cannot accept a prompt answer",
                    !stillCurrent(generation: generation, currentGeneration: generation,
                                  sameWeb: true, sameWindow: true, visible: false)))
        out.append(("an unchanged visible request can accept its prompt answer",
                    stillCurrent(generation: generation, currentGeneration: generation,
                                 sameWeb: true, sameWindow: true, visible: true)))
        out.append(("HTTP auth credentials are never put in session credential storage",
                    loginCredential(user: "alice", password: "secret").persistence == .none))

        // Reason mapping: every status we claim to handle, and the generic ones that only
        // become specific once the leaf certificate is read.
        let expiredCert = Hints(expired: true)
        let futureCert = Hints(notYetValid: true)
        let selfSigned = Hints(selfSigned: true)
        out.append(("errSecCertificateExpired reads as expired",
                    fault(status: errSecCertificateExpired) == .expired))
        out.append(("errSecCertificateNotValidYet reads as not yet valid",
                    fault(status: errSecCertificateNotValidYet) == .notYetValid))
        out.append(("errSecHostNameMismatch reads as a hostname mismatch",
                    fault(status: errSecHostNameMismatch) == .hostname))
        out.append(("errSecCertificateRevoked reads as revoked",
                    fault(status: errSecCertificateRevoked) == .revoked))
        out.append(("errSecNotTrusted with a clean leaf reads as an unknown root",
                    fault(status: errSecNotTrusted) == .unknownRoot))
        out.append(("errSecCreateChainFailed reads as an unknown root",
                    fault(status: errSecCreateChainFailed) == .unknownRoot))
        out.append(("errSecNotTrusted on a self-signed leaf says self-signed, not unknown root",
                    fault(status: errSecNotTrusted, hints: selfSigned) == .selfSigned))
        out.append(("errSecNotTrusted on an expired leaf says expired",
                    fault(status: errSecNotTrusted, hints: expiredCert) == .expired))
        out.append(("errSecNotTrusted on a not-yet-valid leaf says not yet valid",
                    fault(status: errSecNotTrusted, hints: futureCert) == .notYetValid))
        // A specific status must not be overruled by a hint that also applies.
        out.append(("a hostname mismatch stays a hostname mismatch even on a self-signed leaf",
                    fault(status: errSecHostNameMismatch, hints: selfSigned) == .hostname))
        out.append(("an unrecognised status with nothing to go on admits it doesn’t know",
                    fault(status: -12345) == .unknown))

        out.append(("every fault gets its own wording",
                    Set(Fault.allCases.map(detail)).count == Fault.allCases.count))
        out.append(("no fault falls back to a generic “something is wrong”",
                    Fault.allCases.allSatisfy { detail($0).count > 40 }))
        out.append(("the expired message says expired", detail(.expired).contains("expired")))
        out.append(("the hostname message says it was issued for a different site",
                    detail(.hostname).contains("different site")))
        out.append(("the self-signed message says it signed itself",
                    detail(.selfSigned).contains("signed itself")))
        out.append(("the unknown-root message names interception",
                    detail(.unknownRoot).contains("intercepting")))
        out.append(("the revoked message says revoked", detail(.revoked).contains("revoked")))

        // Fingerprints of two different certificates must not collide, and the displayed
        // form has to be the same bytes the user can read off another tool.
        let der1 = Data([0x30, 0x01, 0x02]), der2 = Data([0x30, 0x01, 0x03])
        let f1 = SHA256.hash(data: der1).map { String(format: "%02x", $0) }.joined()
        let f2 = SHA256.hash(data: der2).map { String(format: "%02x", $0) }.joined()
        out.append(("a fingerprint is 64 hex characters", f1.count == 64))
        out.append(("different certificates fingerprint differently", f1 != f2))
        out.append(("the shown fingerprint is the same bytes, grouped",
                    spaced(f1).replacingOccurrences(of: " ", with: "") == f1
                    && spaced(f1).split(separator: " ").count == 32))
        // The whole file is dead code unless WebKit can find the delegate method. The Swift
        // async spelling of this requirement is `respondTo:`, not `didReceive:` — the wrong
        // name compiles, satisfies nothing, and WebKit then fails every bad certificate and
        // every HTTP login itself. This is the assertion that would have caught it.
        out.append(("Tab answers WebKit's authentication-challenge selector",
                    Tab.instancesRespond(to: NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:"))))
        return out
    }
}
