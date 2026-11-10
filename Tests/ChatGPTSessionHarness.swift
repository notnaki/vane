import Foundation

@MainActor private final class Fixture {
    var saved: ChatGPTOAuth.Credentials? = .init(accessToken: "old", refreshToken: "refresh", idToken: "identity", scopes: ["chatgpt.tokens.use.direct"], expiresAt: .distantPast)
    var calls = 0
    var canSave = true
    var failure: ChatGPTFailure?
    var duringRefresh: (() -> Void)?
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-chatgpt-session-\(UUID())")
    func session() -> ChatGPTSession {
        ChatGPTSession(registration: .init(clientID: "oaiapp_fixture", subject: "fixture", email: nil), lockURL: directory.appendingPathComponent("refresh.lock"), read: { [self] in saved }, write: { [self] value in
            if !canSave { return false }; saved = value; return true
        }, refresh: { [self] previous in
            calls += 1
            try await Task.sleep(for: .milliseconds(20))
            duringRefresh?(); duringRefresh = nil
            if let failure { throw failure }
            var next = previous; next.accessToken = "new"; next.refreshToken = "rotated"; next.expiresAt = .distantFuture
            return next
        })
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
private final class SessionProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var failMetadata = true
        private var tokenCalls = 0
        func allowMetadata() { lock.withLock { failMetadata = false } }
        var rotations: Int { lock.withLock { tokenCalls } }
        func reply(path: String) -> (Int, String) {
            lock.withLock {
                if path.contains("openid-configuration") {
                    return failMetadata ? (503, "{}") : (200, #"{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/.well-known/jwks.json","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#)
                }
                if path.hasSuffix("jwks.json") { return (200, #"{"keys":[]}"#) }
                if path.hasSuffix("revoke") { return (200, "") }
                tokenCalls += 1
                return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#)
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.reply(path: request.url!.path)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ChatGPTSessionHarness {
    @MainActor static func main() async {
        var checks: [(String, Bool)] = []
        let fixture = Fixture(); let session = fixture.session()
        async let first = session.credentials()
        async let second = session.credentials()
        let values = try? await [first, second]
        checks.append(("simultaneous requests rotate once and save before returning", fixture.calls == 1 && values?.map(\.accessToken) == ["new", "new"] && fixture.saved?.refreshToken == "rotated"))
        let transient = Fixture(); transient.failure = .api(status: 503, code: nil, requestID: nil)
        _ = try? await transient.session().credentials()
        checks.append(("transient refresh preserves tokens", transient.saved?.refreshToken == "refresh"))
        let terminal = Fixture(); terminal.failure = .api(status: 400, code: "invalid_grant", requestID: nil)
        _ = try? await terminal.session().credentials()
        checks.append(("terminal refresh clears unusable token set", terminal.saved == nil))
        let removed = Fixture(); removed.duringRefresh = { removed.saved = nil }
        let removedResult = try? await removed.session().credentials()
        checks.append(("refresh never resurrects signed-out connection", removedResult == nil && removed.saved == nil))
        let locked = Fixture(); locked.canSave = false; let lockedSession = locked.session()
        let unsaved = try? await lockedSession.credentials()
        locked.canSave = true
        let recovered = try? await lockedSession.credentials()
        checks.append(("Keychain failure never loses rotating token in memory", unsaved == nil && recovered?.refreshToken == "rotated" && locked.calls == 1))
        let identityOnly = Fixture(); identityOnly.saved?.scopes = ["openid"]
        let disabled = try? await identityOnly.session().credentials()
        checks.append(("identity alone cannot authorize plan inference", disabled == nil && identityOnly.calls == 0 && identityOnly.saved != nil))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SessionProtocol.self]
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        let production = Fixture()
        let real = ChatGPTSession(registration: .init(clientID: "oaiapp_fixture", subject: "fixture", email: nil), lockURL: production.directory.appendingPathComponent("production.lock"), read: { production.saved }, write: { production.saved = $0; return true }, using: client)
        let unavailable = try? await real.credentials()
        checks.append(("metadata outage occurs before consuming rotating refresh token", unavailable == nil && SessionProtocol.state.rotations == 0 && production.saved?.refreshToken == "refresh"))
        SessionProtocol.state.allowMetadata()
        let renewed = try? await real.credentials()
        checks.append(("production renewal saves complete rotating pair", renewed?.accessToken == "new-access" && production.saved?.refreshToken == "new-refresh" && SessionProtocol.state.rotations == 1))
        let signingOut = Task { @MainActor in try await real.signOut() }
        while !real.signedOut { await Task.yield() }
        let afterSignOutBegan = try? await real.credentials()
        checks.append(("sign-out blocks credentials before revocation finishes", afterSignOutBegan == nil))
        let revoked = try? await signingOut.value
        checks.append(("confirmed revocation clears local tokens", revoked == true && production.saved == nil))
        for (name, passed) in checks { print("\(passed ? "ok" : "FAIL") \(name)") }
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
}
