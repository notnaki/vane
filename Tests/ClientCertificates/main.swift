import Foundation
import Security

/// All identities and trust anchors come from the Python fixture, never a keychain.
@MainActor final class FixtureDelegate: NSObject, URLSessionDelegate {
    let candidate: ClientCertificates.Candidate
    let root: SecCertificate
    let omitIntermediates: Bool
    let choices = ClientCertificates.Session()
    var prompts = 0

    init(candidate: ClientCertificates.Candidate, root: SecCertificate, omitIntermediates: Bool) {
        self.candidate = candidate
        self.root = root
        self.omitIntermediates = omitIntermediates
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
        if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           let scope = ClientCertificates.Scope(profileID: UUID(), host: space.host,
                                                port: space.port, scheme: space.protocol) {
            guard let selected = await choices.choose(scope: scope, isPrivate: true, previousFailureCount: 0,
                load: { [self.candidate] }, prompt: { items in self.prompts += 1; return items[0].id },
                isCurrent: { true }) else { return (.cancelAuthenticationChallenge, nil) }
            let credential = omitIntermediates
                ? URLCredential(identity: selected.identity, certificates: nil, persistence: .forSession)
                : selected.credential
            return (.useCredential, credential)
        }
        return (.performDefaultHandling, nil)
    }
}

@main struct Harness {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "fixture", kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: directory.appendingPathComponent("identity.p12")) as CFData,
                                    options as CFDictionary, &imported)
        precondition(status == errSecSuccess)
        let entry = (imported as! [[String: Any]])[0]
        let identity = entry[kSecImportItemIdentity as String] as! SecIdentity
        let chain = entry[kSecImportItemCertChain as String] as! [SecCertificate]
        let root = SecCertificateCreateWithData(nil, try Data(contentsOf: directory.appendingPathComponent("root.der")) as CFData)!
        let rollover = CommandLine.arguments.contains("--rollover")
        let suppliedChain = rollover ? chain.filter { !CFEqual($0, root) } : chain
        let candidate = ClientCertificates.Candidate(identity: identity, certificates: suppliedChain)!
        precondition(!candidate.issuerChain.isEmpty, "The required intermediate must be preserved")
        let delegate = FixtureDelegate(candidate: candidate, root: root,
            omitIntermediates: CommandLine.arguments.contains("--omit-intermediates"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from:
                URL(string: "https://localhost:\(CommandLine.arguments[2])/")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(decoding: data, as: UTF8.self) == "mTLS fixture authenticated",
                  delegate.prompts == 1 else { print("FAIL: client chain not authenticated"); exit(1) }
            print("PASS: generated leaf/intermediate/root client authenticated by root-only TLS server; explicit choice; memory-only import")
        } catch {
            print("FAIL: mTLS request: \(error)")
            exit(1)
        }
    }
}
