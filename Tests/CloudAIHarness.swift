import Foundation
import Security

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        private var responseCode = 200
        func reset(_ code: Int) { lock.withLock { requests = 0; responseCode = code } }
        var count: Int { lock.withLock { requests } }
        func record() -> Int { lock.withLock { requests += 1; return responseCode } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.record()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"text\":\"Connected\"}"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CloudAIHarness {
    static func main() async {
        var results = CloudAI.check()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = CloudAI.Configuration(provider: .groq, baseURL: AIProvider.groq.baseURL, model: AIProvider.groq.defaultModel)
        FixtureProtocol.state.reset(200)
        let reply = try? await CloudAI.complete(config, key: "fixture-only", prompt: "test", tokens: 256, using: session)
        results.append(("transport returns complete model content", reply == #"{"text":"Connected"}"# && FixtureProtocol.state.count == 1))
        FixtureProtocol.state.reset(200)
        _ = try? await CloudAI.complete(config, key: "fixture-only", prompt: "private", tokens: 256, isPrivate: true, using: session)
        results.append(("private mode makes zero transport calls", FixtureProtocol.state.count == 0))
        FixtureProtocol.state.reset(429)
        do {
            _ = try await CloudAI.complete(config, key: "fixture-only", prompt: "test", tokens: 256, using: session)
            results.append(("quota errors are surfaced", false))
        } catch CloudAI.Failure.rateLimited { results.append(("quota errors are surfaced", FixtureProtocol.state.count == 1)) }
        catch { results.append(("quota errors are surfaced", false)) }
        FixtureProtocol.state.reset(401)
        do {
            _ = try await CloudAI.complete(config, key: "fixture-only", prompt: "test", tokens: 256, using: session)
            results.append(("rejected keys are surfaced", false))
        } catch CloudAI.Failure.unauthorized { results.append(("rejected keys are surfaced", true)) }
        catch { results.append(("rejected keys are surfaced", false)) }
        let groqAccount = AIKeys.account(provider: .groq, baseURL: config.baseURL)
        let other = AIKeys.account(provider: .openAI, baseURL: AIProvider.openAI.baseURL)
        results.append(("providers have separate credential accounts", groqAccount != other))
        results.append(("custom endpoints have separate credential accounts",
            AIKeys.account(provider: .custom, baseURL: "https://one.example/v1") != AIKeys.account(provider: .custom, baseURL: "https://two.example/v1")))
        results.append(("equivalent custom URLs retain the same key",
            AIKeys.account(provider: .custom, baseURL: "https://one.example/v1/") == AIKeys.account(provider: .custom, baseURL: "https://one.example/v1")))
        // Keychain integration is opt-in: CI/pure checks never touch the login keychain.
        if CommandLine.arguments.contains("--keychain") {
            let namespace = "fixture-" + UUID().uuidString
            defer { _ = AIKeys.remove(account: groqAccount, namespace: namespace) }
            results.append(("fixture key saves", AIKeys.save("fixture-secret", account: groqAccount, namespace: namespace) == errSecSuccess))
            results.append(("fixture key reads", AIKeys.read(account: groqAccount, namespace: namespace) == "fixture-secret"))
            results.append(("credential namespaces isolate keys", AIKeys.read(account: groqAccount, namespace: namespace + "-other") == nil))
            results.append(("fixture key updates", AIKeys.save("fixture-updated", account: groqAccount, namespace: namespace) == errSecSuccess && AIKeys.read(account: groqAccount, namespace: namespace) == "fixture-updated"))
            results.append(("fixture key removes", AIKeys.remove(account: groqAccount, namespace: namespace) == errSecSuccess && AIKeys.read(account: groqAccount, namespace: namespace) == nil))
        }
        for (name, passed) in results { print("\(passed ? "ok" : "FAIL") \(name)") }
        exit(results.allSatisfy(\.1) ? 0 : 1)
    }
}
