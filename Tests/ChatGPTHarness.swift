import Foundation
import CryptoKit
import Security

private final class ChatGPTFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var body = Data()
        private var status = 200
        private var requests = 0
        func reset(_ text: String, status: Int = 200) { lock.withLock { body = Data(text.utf8); self.status = status; requests = 0 } }
        func response() -> (Data, Int) { lock.withLock { requests += 1; return (body, status) } }
        var count: Int { lock.withLock { requests } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status) = Self.state.response()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "x-request-id": "req_fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ChatGPTHarness {
    static func main() async throws {
        var checks: [(String, Bool)] = []
        let pending = try ChatGPTOAuth.Pending(redirectURI: "http://127.0.0.1:54321/auth/callback", hostID: "urn:uuid:fixture")
        let query = URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        checks.append(("new registration uses public dynamic flow", query.contains(URLQueryItem(name: "client_id", value: "dynamic_agent_client")) && query.contains(URLQueryItem(name: "agent_name_hint", value: "Vane"))))
        checks.append(("authorization requests plan permission and PKCE", query.contains(URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")) && query.contains(URLQueryItem(name: "code_challenge_method", value: "S256"))))
        func callback(_ params: String) -> URL { URL(string: pending.redirectURI + "?" + params)! }
        let valid = callback("code=fixture&state=\(pending.state)&client_id=oaiapp_fixture")
        let accepted = try pending.callback(valid)
        checks.append(("issued client ID is used in code exchange", accepted.clientID == "oaiapp_fixture"))
        for (name, url) in [("wrong state", callback("code=x&state=wrong&client_id=oaiapp_fixture")), ("missing issued ID", callback("code=x&state=\(pending.state)")), ("duplicate state", callback("code=x&state=\(pending.state)&state=wrong&client_id=oaiapp_fixture")), ("wrong callback path", URL(string: "http://127.0.0.1:54321/evil?code=x&state=\(pending.state)&client_id=oaiapp_fixture")!)] {
            checks.append(("reject " + name, (try? pending.callback(url)) == nil))
        }
        let registration = ChatGPTRegistration(clientID: "oaiapp_saved", subject: "subject-fixture", email: "same@example.com")
        let returning = try ChatGPTOAuth.Pending(redirectURI: pending.redirectURI, hostID: "urn:uuid:fixture", registration: registration)
        let wrongClient = URL(string: returning.redirectURI + "?code=x&state=\(returning.state)&client_id=oaiapp_other")!
        checks.append(("returning account cannot change registration", (try? returning.callback(wrongClient)) == nil))
        let request = ChatGPTOAuth.tokenRequest(fields: ["client_id": accepted.clientID, "code": "a+ &b"])
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        checks.append(("code exchange encodes secrets in form body only", body.contains("code=a%2B%20%26b") && request.url?.query == nil))

        let config = CloudAI.Configuration(provider: .chatGPT, baseURL: "https://evil.example", model: "fixture-model")
        let inference = ChatGPTResponses.request(config, token: "fixture-token", prompt: "fixture")!
        let payload = try JSONSerialization.jsonObject(with: inference.httpBody!) as! [String: Any]
        checks += [
            ("subscription uses fixed public Responses endpoint", inference.url?.absoluteString == "https://api.openai.com/v1/responses"),
            ("subscription is stateless and streaming", payload["store"] as? Bool == false && payload["stream"] as? Bool == true && payload["input"] is [[String: Any]]),
            ("unsupported generation fields are absent", payload["max_output_tokens"] == nil && payload["temperature"] == nil && payload["messages"] == nil),
            ("private inference is rejected", ChatGPTResponses.request(config, token: "fixture-token", prompt: "private", isPrivate: true) == nil),
            ("subscription token cannot use chat completions", CloudAI.request(config, key: "fixture", prompt: "fixture", tokens: 100) == nil)
        ]
        var stream = ChatGPTResponses.Stream()
        try stream.line("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}")
        try stream.line("")
        checks.append(("deltas do not count as completed answers", stream.result == nil))
        try stream.line("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}")
        try stream.line("")
        checks.append(("completed stream returns text", stream.result == "hello"))
        var failed = ChatGPTResponses.Stream()
        var rejectedFailure = false
        do {
            try failed.line("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}")
            try failed.line("")
        } catch { rejectedFailure = true }
        checks.append(("streamed quota failure is rejected", rejectedFailure && failed.result == nil))
        var incomplete = ChatGPTResponses.Stream()
        checks.append(("incomplete events are rejected", rejects { try incomplete.line("data: {\"type\":\"response.incomplete\"}"); try incomplete.line("") }))
        var oversized = ChatGPTResponses.Stream()
        checks.append(("oversized events are rejected", rejects { try oversized.line("data: " + String(repeating: "x", count: 270_000)) }))
        let catalog = try ChatGPTResponses.models(Data(#"{"models":[{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"first","display_name":"First","visibility":"list"}]}"#.utf8))
        checks.append(("account catalog keeps visible models in server order", catalog.map(\.slug) == ["second", "first"]))
        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.protocolClasses = [ChatGPTFixtureProtocol.self]
        let client = URLSession(configuration: clientConfig)
        defer { client.invalidateAndCancel() }
        let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\r\n\r\n"
        ChatGPTFixtureProtocol.state.reset(sse)
        let transported = try await ChatGPTResponses.complete(config, token: "fixture", prompt: "test", using: client)
        checks.append(("transport consumes real SSE bytes through completion", transported == "hello" && ChatGPTFixtureProtocol.state.count == 1))
        ChatGPTFixtureProtocol.state.reset(sse)
        _ = try? await ChatGPTResponses.complete(config, token: "fixture", prompt: "private", isPrivate: true, using: client)
        checks.append(("private subscription makes zero transport requests", ChatGPTFixtureProtocol.state.count == 0))
        ChatGPTFixtureProtocol.state.reset("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n")
        let interrupted = try? await ChatGPTResponses.complete(config, token: "fixture", prompt: "test", using: client)
        checks.append(("transport rejects an interrupted stream", interrupted == nil))
        ChatGPTFixtureProtocol.state.reset(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#, status: 429)
        do {
            _ = try await ChatGPTResponses.complete(config, token: "fixture", prompt: "test", using: client)
            checks.append(("HTTP errors retain quota code and request ID", false))
        } catch {
            checks.append(("HTTP errors retain quota code and request ID", error as? ChatGPTFailure == .api(status: 429, code: "subscription_sharing_usage_limit_exceeded", requestID: "req_fixture")))
        }
        // A real ephemeral RSA key proves signature validation, not merely JWT decoding.
        let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicBytes = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        var cursor = 0
        func length() -> Int {
            let byte = Int(publicBytes[cursor]); cursor += 1
            if byte < 128 { return byte }
            var value = 0
            for _ in 0..<(byte & 127) { value = value * 256 + Int(publicBytes[cursor]); cursor += 1 }
            return value
        }
        cursor += 1; _ = length()
        func integer() -> Data {
            cursor += 1; let count = length()
            let data = publicBytes.subdata(in: cursor..<(cursor + count)); cursor += count
            return data.first == 0 ? data.dropFirst() : data
        }
        let modulus = integer(), exponent = integer()
        let jwks = ChatGPTOAuth.JWKS(keys: [.init(kty: "RSA", kid: "fixture", n: ChatGPTOAuth.base64URL(modulus), e: ChatGPTOAuth.base64URL(exponent), alg: "RS256", use: "sig")])
        let now = Date(timeIntervalSince1970: 1000)
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "subject-fixture", "aud": "oaiapp_fixture", "exp": 2000, "nonce": pending.nonce, "email": "same@example.com"]
        func jwt(_ changes: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
            let header = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "fixture"]))
            let body = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims.merging(changes) { _, new in new }))
            let content = header + "." + body
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(content.utf8) as CFData, nil)! as Data
            return content + "." + ChatGPTOAuth.base64URL(signature)
        }
        func validate(_ token: String) throws -> ChatGPTRegistration {
            try ChatGPTOAuth.validateIDToken(token, clientID: "oaiapp_fixture", nonce: pending.nonce, expectedSubject: "subject-fixture", jwks: jwks, now: now)
        }
        let verified = try validate(jwt())
        checks.append(("signed ID token binds registration and identity", verified.subject == "subject-fixture" && verified.clientID == "oaiapp_fixture" && verified.email == "same@example.com"))
        for (name, change) in [("issuer", ["iss": "https://evil.example"]), ("audience", ["aud": "oaiapp_other"]), ("nonce", ["nonce": "wrong"]), ("subject", ["sub": "other"]), ("expiry", ["exp": 900]), ("not-before", ["nbf": 3000])] {
            checks.append(("JWT rejects wrong " + name, rejects { _ = try validate(jwt(change)) }))
        }
        checks.append(("JWT rejects algorithm confusion", rejects { _ = try validate(jwt(algorithm: "HS256")) }))
        let original = try jwt().split(separator: ".").map(String.init)
        let tampered = original[0] + "." + ChatGPTOAuth.base64URL(Data("{}".utf8)) + "." + original[2]
        checks.append(("JWT rejects tampered signature", rejects { _ = try validate(tampered) }))
        let initialGrant = try ChatGPTOAuth.grant(Data(#"{"access_token":"access","refresh_token":"refresh","id_token":"id","token_type":"Bearer","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#.utf8), now: now)
        checks.append(("token grant keeps complete credential set", initialGrant.permitsPlan && initialGrant.expiresAt == now.addingTimeInterval(3600)))
        checks.append(("rotation rejects missing replacement refresh token", rejects { _ = try ChatGPTOAuth.grant(Data(#"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#.utf8), previous: initialGrant) }))
        for (name, passed) in checks { print("\(passed ? "ok" : "FAIL") \(name)") }
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
    static func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
}
