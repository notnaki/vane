import Foundation
import CryptoKit
import Security

enum ChatGPTFailure: Error, LocalizedError, Equatable {
    case invalidCallback, invalidIdentity, denied, planDisabled, signInRequired, storage, invalidReply, timedOut
    case api(status: Int, code: String?, requestID: String?)
    var errorDescription: String? {
        switch self {
        case .invalidCallback: return "ChatGPT sign-in could not be verified. Try signing in again."
        case .invalidIdentity: return "ChatGPT returned an identity that could not be verified. Try signing in again."
        case .denied: return "ChatGPT sign-in was cancelled or declined."
        case .planDisabled: return "Signed in. ChatGPT plan usage is not enabled; reconnect to authorize it or choose an API-key connection."
        case .signInRequired: return "Sign in to this ChatGPT account again."
        case .storage: return "Could not save the ChatGPT credentials in Keychain."
        case .invalidReply: return "ChatGPT returned an incomplete or invalid response."
        case .timedOut: return "ChatGPT sign-in timed out. Try again."
        case let .api(status, code, requestID):
            let detail: String
            switch code {
            case "subscription_sharing_usage_limit_exceeded": detail = "This app's ChatGPT usage limit was reached. Review ChatGPT Settings → Usage."
            case "subscription_sharing_user_not_eligible": detail = "ChatGPT plan usage is unavailable for this account or workspace."
            case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": detail = "ChatGPT usage is temporarily unavailable. Try later."
            case "subscription_sharing_unsupported_capability": detail = "This ChatGPT model does not support the requested operation."
            default: detail = "ChatGPT could not complete the request (HTTP \(status)). Try later or reconnect."
            }
            return detail + (code.map { " Code: \($0)." } ?? "") + (requestID.map { " Request: \($0)." } ?? "")
        }
    }
    var terminalRefresh: Bool {
        guard case .api(_, let code, _) = self else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "")
    }
    var rateLimited: Bool {
        if case .api(let status, let code, _) = self { return status == 429 || code == "subscription_sharing_usage_limit_exceeded" }
        return false
    }
}

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTFailure.invalidCallback }
        return base64URL(Data(bytes))
    }
    struct Pending: Sendable {
        let redirectURI: String
        let hostID: String
        let registration: ChatGPTRegistration?
        let idTokenHint: String?
        let state: String
        let nonce: String
        let verifier: String
        init(redirectURI: String, hostID: String, registration: ChatGPTRegistration? = nil, idTokenHint: String? = nil) throws {
            guard let uri = URLComponents(string: redirectURI), uri.scheme == "http", uri.host == "127.0.0.1", uri.port != nil,
                  uri.path == "/auth/callback", uri.query == nil, uri.fragment == nil, uri.user == nil, uri.password == nil else { throw ChatGPTFailure.invalidCallback }
            self.redirectURI = redirectURI; self.hostID = hostID; self.registration = registration; self.idTokenHint = idTokenHint
            state = try random(); nonce = try random(); verifier = try random()
        }
        var authorizationURL: URL {
            var parts = URLComponents(string: issuer + "/api/accounts/authorize")!
            var fields = ["client_id": registration?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                          "response_type": "code", "redirect_uri": redirectURI, "scope": scopes, "resource": resource,
                          "state": state, "nonce": nonce, "code_challenge_method": "S256",
                          "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
            if let registration {
                fields["login_hint"] = registration.email
                fields["id_token_hint"] = idTokenHint
                // Explicit reconnect is also the path to re-enable a previously declined plan grant.
                fields["prompt"] = "consent"
            } else { fields["agent_name_hint"] = "Vane" }
            parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return parts.url!
        }
        struct Callback: Sendable { let code: String; let clientID: String }
        func callback(_ url: URL) throws -> Callback {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let expected = URLComponents(string: redirectURI),
                  parts.scheme == expected.scheme, parts.host == expected.host, parts.port == expected.port,
                  parts.path == expected.path, parts.fragment == nil, parts.user == nil, parts.password == nil else { throw ChatGPTFailure.invalidCallback }
            var values: [String: String] = [:]
            for item in parts.queryItems ?? [] {
                guard values[item.name] == nil, let value = item.value else { throw ChatGPTFailure.invalidCallback }
                values[item.name] = value
            }
            guard values["state"] == state else { throw ChatGPTFailure.invalidCallback }
            if values["error"] != nil { throw ChatGPTFailure.denied }
            guard let code = values["code"], !code.isEmpty else { throw ChatGPTFailure.invalidCallback }
            let clientID = values["client_id"] ?? registration?.clientID
            guard let clientID, !clientID.isEmpty, clientID != "dynamic_agent_client",
                  registration == nil || clientID == registration?.clientID else { throw ChatGPTFailure.invalidCallback }
            return Callback(code: code, clientID: clientID)
        }
        func exchange(_ callback: Callback) -> URLRequest {
            tokenRequest(fields: ["grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code,
                                  "code_verifier": verifier, "redirect_uri": redirectURI, "resource": resource])
        }
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func tokenRequest(fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: issuer + "/api/accounts/oauth/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        return request
    }
    struct Credentials: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String
        var scopes: [String]
        var expiresAt: Date
        var earliestRefreshAt: Date?
        var permitsPlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
        var needsRefresh: Bool { expiresAt <= Date.now.addingTimeInterval(60) }
        var stored: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
        static func restore(_ value: String?) -> Self? { value.flatMap { try? JSONDecoder().decode(Self.self, from: Data($0.utf8)) } }
    }
    static func grant(_ data: Data, previous: Credentials? = nil, now: Date = .now) throws -> Credentials {
        struct Grant: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let token_type: String
            let expires_in: Double
            let scope: String?
            let earliest_refresh_at: Double?
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: data), safeToken(grant.access_token),
              grant.token_type.lowercased() == "bearer", grant.expires_in.isFinite, grant.expires_in > 0, grant.expires_in <= 86400,
              let idToken = grant.id_token ?? previous?.idToken, !idToken.isEmpty,
              let scope = grant.scope ?? previous.map({ $0.scopes.joined(separator: " ") }) else { throw ChatGPTFailure.invalidReply }
        // Rotating refresh replies must supply the complete replacement, never reuse the consumed refresh token.
        if previous != nil && grant.refresh_token == nil { throw ChatGPTFailure.invalidReply }
        if let refresh = grant.refresh_token, !safeToken(refresh) { throw ChatGPTFailure.invalidReply }
        return Credentials(accessToken: grant.access_token, refreshToken: grant.refresh_token, idToken: idToken,
                           scopes: scope.split(separator: " ").map(String.init), expiresAt: now.addingTimeInterval(grant.expires_in),
                           earliestRefreshAt: grant.earliest_refresh_at.map { Date(timeIntervalSince1970: $0) })
    }
    static func safeToken(_ token: String) -> Bool { !token.isEmpty && token.utf8.count <= 65536 && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 } }

    struct Discovery: Decodable, Sendable {
        let issuer: String
        let jwks_uri: String
        let revocation_endpoint: String
        func trustedURL(_ value: String) throws -> URL {
            guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "auth.openai.com",
                  parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
                  parts.fragment == nil, parts.query == nil, let url = parts.url else { throw ChatGPTFailure.invalidIdentity }
            return url
        }
        func validate() throws {
            guard issuer == ChatGPTOAuth.issuer else { throw ChatGPTFailure.invalidIdentity }
            _ = try trustedURL(jwks_uri); _ = try trustedURL(revocation_endpoint)
        }
    }
    struct JWK: Codable, Sendable {
        var kty: String
        var kid: String
        var n: String
        var e: String
        var alg: String?
        var use: String?
    }
    struct JWKS: Codable, Sendable { var keys: [JWK] }

    static func validateIDToken(_ token: String, clientID: String, nonce: String?, expectedSubject: String? = nil,
                                jwks: JWKS, now: Date = .now) throws -> ChatGPTRegistration {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count <= 65536, segments.count == 3,
              let headerData = decodeBase64URL(segments[0]), let payload = decodeBase64URL(segments[1]), let signature = decodeBase64URL(segments[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              header["crit"] == nil, let kid = header["kid"] as? String,
              let jwk = jwks.keys.first(where: { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let modulus = decodeBase64URL(jwk.n), modulus.count >= 256, modulus.count <= 1024,
              let exponent = decodeBase64URL(jwk.e), exponent.count <= 8,
              let key = SecKeyCreateWithData(rsaKey(modulus: modulus, exponent: exponent) as CFData,
                    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((segments[0] + "." + segments[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == issuer, let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30,
              nonce == nil || claims["nonce"] as? String == nonce,
              expectedSubject == nil || subject == expectedSubject else { throw ChatGPTFailure.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID else { throw ChatGPTFailure.invalidIdentity }
        return ChatGPTRegistration(clientID: clientID, subject: subject, email: claims["email"] as? String)
    }
    private static func rsaKey(modulus: Data, exponent: Data) -> Data {
        func wrap(_ tag: UInt8, _ data: Data) -> Data {
            let count = data.count
            let length: [UInt8] = count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
            return Data([tag] + length) + data
        }
        func integer(_ data: Data) -> Data { wrap(0x02, (data.first.map { $0 & 0x80 != 0 } ?? false) ? Data([0]) + data : data) }
        return wrap(0x30, integer(modulus) + integer(exponent))
    }
}
