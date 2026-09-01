import AppKit
import CryptoKit
import Security
import WebKit

/// The one place a bad certificate can be got past, and the HTTP auth prompt that lives in
/// the same delegate method. Without this, `WKNavigationDelegate` never answers a challenge
/// at all: a self-signed host is a dead end with an error page, and a Basic-auth realm is a
/// 401 the user can do nothing about.
///
/// ponytail: NSAlert, not a full-page interstitial the way Safari and Chrome do it. The
/// callback doesn't carry the tab, so there is no window to attach a sheet to and no page
/// to render into without threading one through. Ceiling: it is app-modal, so a background
/// tab hitting a bad certificate steals focus. The upgrade path is passing the Tab in.
@MainActor enum CertificateTrust {

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    private static var defaults: UserDefaults = .standard

    /// `|` is the separator because a hostname cannot contain one — a `.` separator would
    /// make the prefix sweep in `forget(host:)` also eat `example.com.au`.
    private static let prefix = "certException."
    private static func key(host: String, fingerprint: String) -> String {
        prefix + host.lowercased() + "|" + fingerprint
    }

    // MARK: - Remembered exceptions

    /// Keyed on the certificate too, not just the host: an exception for one certificate
    /// must not silently cover whatever certificate shows up tomorrow. Swapping the cert is
    /// exactly what an interception looks like, so it has to ask again.
    static func trusted(host: String, fingerprint: String) -> Bool {
        defaults.bool(forKey: key(host: host, fingerprint: fingerprint))
    }

    /// Only ever called from the branch where the user clicked through both alerts.
    static func remember(host: String, fingerprint: String) {
        defaults.set(true, forKey: key(host: host, fingerprint: fingerprint))
    }

    static func forget(host: String) {
        let stem = prefix + host.lowercased() + "|"
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(stem) {
            defaults.removeObject(forKey: k)
        }
    }

    static func forgetAll() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            defaults.removeObject(forKey: k)
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
    static func handle(challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return serverTrust(challenge)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            return login(challenge)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    private static func serverTrust(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // The overwhelmingly common case: the certificate is fine. Hand it back to the
        // system rather than minting a credential of our own.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (.performDefaultHandling, nil) }

        let host = challenge.protectionSpace.host
        guard let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            // No certificate to pin an exception to, so there is no safe way to offer one.
            return (.cancelAuthenticationChallenge, nil)
        }
        let fp = fingerprint(cert)
        if trusted(host: host, fingerprint: fp) {
            return (.useCredential, URLCredential(trust: trust))
        }

        let status = OSStatus(error.map { CFErrorGetCode($0) } ?? Int(errSecNotTrusted))
        let h = hints(for: cert)
        guard ask(host: host, fault: fault(status: status, hints: h), hints: h, fingerprint: fp) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        remember(host: host, fingerprint: fp)
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Two alerts, deliberately. The first defaults to Go Back and its only other button
    /// asks to see the details — clicking through takes a second, separate decision, and
    /// neither Return nor Escape can reach the button that proceeds.
    private static func ask(host: String, fault: Fault, hints: Hints, fingerprint: String) -> Bool {
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
        guard first.runModal() == .alertSecondButtonReturn else { return false }

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
        return second.runModal() == .alertSecondButtonReturn
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

    /// ponytail: the credential is `.forSession`, never `.permanent`. Writing a password
    /// into the login keychain is a decision with its own UI in every other browser, and
    /// this prompt has no "remember me" box to justify it.
    private static func login(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "“\(space.host)” requires a username and password"
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
        guard alert.runModal() == .alertFirstButtonReturn, !user.stringValue.isEmpty else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: user.stringValue,
                                              password: password.stringValue,
                                              persistence: .forSession))
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
            scratch.removePersistentDomain(forName: suite)
        }

        let a = String(repeating: "a1", count: 32)   // stand-in fingerprints, 64 hex chars
        let b = String(repeating: "b2", count: 32)
        var out: [(String, Bool)] = []

        out.append(("an unvisited host is not trusted", trusted(host: "example.com", fingerprint: a) == false))
        remember(host: "example.com", fingerprint: a)
        out.append(("a remembered exception reads back", trusted(host: "example.com", fingerprint: a)))
        out.append(("host matching is case-insensitive", trusted(host: "EXAMPLE.com", fingerprint: a)))
        // The whole point of pinning the fingerprint: a swapped certificate re-prompts.
        out.append(("a different certificate for the same host is NOT trusted",
                    trusted(host: "example.com", fingerprint: b) == false))
        out.append(("the same certificate on another host is NOT trusted",
                    trusted(host: "evil.example", fingerprint: a) == false))

        remember(host: "other.example", fingerprint: b)
        remember(host: "other.example.au", fingerprint: a)
        remember(host: "sub.other.example", fingerprint: a)
        forget(host: "other.example")
        out.append(("forget(host:) drops that host's exception", trusted(host: "other.example", fingerprint: b) == false))
        out.append(("forget(host:) does not eat a host that merely starts the same way",
                    trusted(host: "other.example.au", fingerprint: a)))
        out.append(("forget(host:) does not eat a subdomain",
                    trusted(host: "sub.other.example", fingerprint: a)))
        out.append(("forget(host:) leaves unrelated hosts alone", trusted(host: "example.com", fingerprint: a)))
        forgetAll()
        out.append(("forgetAll drops everything",
                    trusted(host: "example.com", fingerprint: a) == false
                    && trusted(host: "sub.other.example", fingerprint: a) == false))

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
        return out
    }
}
