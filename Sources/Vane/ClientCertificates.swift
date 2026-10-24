import CryptoKit
import Foundation
import Security

/// Client identities are discovered only for a current HTTPS challenge. The session
/// remembers a fingerprint, never a private key or a system-wide identity preference.
enum ClientCertificates {
    struct Scope: Hashable {
        let profileID: UUID
        let host: String
        let port: Int
        let scheme: String

        init?(profileID: UUID, host: String, port: Int, scheme: String?) {
            guard scheme?.lowercased() == "https", !host.isEmpty,
                  port <= 65535 else { return nil }
            self.profileID = profileID
            self.host = host.lowercased()
            self.port = port > 0 ? port : 443
            self.scheme = "https"
        }

        var display: String { port == 443 ? host : "\(host):\(port)" }
    }

    // Identity references cross from the off-main metadata search to the main actor.
    // They are immutable here; only WebKit uses the chosen private key, after consent.
    struct Candidate: @unchecked Sendable {
        let identity: SecIdentity
        let id: String
        let title: String
        let issuerChain: [SecCertificate]

        var credential: URLCredential {
            URLCredential(identity: identity, certificates: issuerChain.isEmpty ? nil : issuerChain,
                          persistence: .forSession)
        }

        init?(identity: SecIdentity, certificates: [SecCertificate] = [], now: Date = .now) {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate, ClientCertificates.eligible(certificate, now: now) else { return nil }
            self.identity = identity
            // Do not guess that a self-issued terminal certificate is a root: a CA
            // key-rollover intermediate can have the same issuer and subject name.
            // Preserve every non-leaf chain certificate, including a possible root.
            issuerChain = certificates.filter { !CFEqual($0, certificate) }
            id = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }.joined()
            let name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Client certificate"
            // Identically named certificates remain distinguishable in the picker.
            title = "\(name) — \(id.prefix(12))"
        }
    }

    /// Security matches an authority anywhere in the chain, including intermediates.
    /// An absent/empty CA list means the server accepts any issuing authority.
    static func query(issuers: [Data]?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecMatchValidOnDate as String: kCFNull as Any,
            kSecMatchPolicy as String: SecPolicyCreateSSL(false, nil)]
        if let issuers, !issuers.isEmpty { query[kSecMatchIssuers as String] = issuers }
        return query
    }

    static func candidates(issuers: [Data]?) async -> [Candidate] {
        await Task.detached(priority: .userInitiated) {
            var result: CFTypeRef?
            guard SecItemCopyMatching(query(issuers: issuers) as CFDictionary, &result) == errSecSuccess,
                  let identities = result as? [SecIdentity] else { return [] }
            var seen = Set<String>()
            return identities.compactMap { Candidate(identity: $0, certificates: chain(for: $0)) }
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    /// The server decides which client CAs it trusts. Check only the leaf's TLS client
    /// purpose and dates, without requiring that this Mac trust the issuing authority.
    /// Anchoring at this leaf makes the policy check independent of issuer discovery.
    private static func eligible(_ certificate: SecCertificate, now: Date) -> Bool {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(false, nil), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, now as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Build with installed issuer certificates only; no AIA download and no private-key use.
    /// Evaluation may fail for an unknown local root even though the server trusts it,
    /// so keep the built chain independently of the local trust verdict.
    private static func chain(for identity: SecIdentity) -> [SecCertificate] {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return [] }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(false, nil), &trust) == errSecSuccess,
              let trust else { return [] }
        SecTrustSetNetworkFetchAllowed(trust, false)
        _ = SecTrustEvaluateWithError(trust, nil)
        return (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }

    @MainActor final class Session {
        private var choices: [Scope: String] = [:]

        func choose(scope: Scope, isPrivate: Bool, previousFailureCount: Int,
                    load: () async -> [Candidate], prompt: ([Candidate]) async -> String?,
                    isCurrent: () -> Bool) async -> Candidate? {
            guard !Task.isCancelled, isCurrent() else { return nil }
            let candidates = await load()
            guard !Task.isCancelled, isCurrent(), !candidates.isEmpty else { return nil }
            if !isPrivate {
                if previousFailureCount == 0, let id = choices[scope],
                   let remembered = candidates.first(where: { $0.id == id }) { return remembered }
                choices[scope] = nil
            }
            // Even one identity needs explicit consent; discovery is never consent.
            guard let id = await prompt(candidates), !Task.isCancelled, isCurrent(),
                  let chosen = candidates.first(where: { $0.id == id }) else { return nil }
            if !isPrivate { choices[scope] = chosen.id }
            return chosen
        }

        func forget(host: String, profileID: UUID) {
            choices = choices.filter { $0.key.profileID != profileID || $0.key.host != host.lowercased() }
        }

        func forget(profileID: UUID) { choices = choices.filter { $0.key.profileID != profileID } }
        func forgetAll() { choices.removeAll() }
    }
}
