import Foundation
import Darwin

/// A credential-free lock serializes rotating refresh tokens across Vane processes.
final class ChatGPTRefreshLock: Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    static func acquire(_ url: URL) async throws -> ChatGPTRefreshLock {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ChatGPTFailure.storage }
        do {
            for _ in 0..<200 {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return ChatGPTRefreshLock(descriptor) }
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ChatGPTFailure.storage }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ChatGPTFailure.storage
        } catch { close(descriptor); throw error }
    }
}

/// Refresh is shared by all features using this connection. Storage is injected so offline
/// fixtures never touch the user's Keychain. Failed rotating writes are retried in memory.
@MainActor final class ChatGPTSession {
    let registration: ChatGPTRegistration
    private let lockURL: URL
    private let read: () -> ChatGPTOAuth.Credentials?
    private let write: (ChatGPTOAuth.Credentials?) -> Bool
    private let refresh: (ChatGPTOAuth.Credentials) async throws -> ChatGPTOAuth.Credentials
    private var refreshing: Task<ChatGPTOAuth.Credentials, Error>?
    private var unsaved: (previous: ChatGPTOAuth.Credentials, next: ChatGPTOAuth.Credentials)?
    private var generation = 0
    private(set) var signedOut = false
    private let client: URLSession

    init(registration: ChatGPTRegistration, lockURL: URL,
         read: @escaping () -> ChatGPTOAuth.Credentials?, write: @escaping (ChatGPTOAuth.Credentials?) -> Bool,
         using client: URLSession = ChatGPTHTTP.session,
         refresh: ((ChatGPTOAuth.Credentials) async throws -> ChatGPTOAuth.Credentials)? = nil) {
        self.registration = registration; self.lockURL = lockURL; self.read = read; self.write = write; self.client = client
        self.refresh = refresh ?? { previous in
            guard let refreshToken = previous.refreshToken else { throw ChatGPTFailure.signInRequired }
            let request = ChatGPTOAuth.tokenRequest(fields: ["grant_type": "refresh_token", "client_id": registration.clientID,
                                                            "refresh_token": refreshToken, "resource": ChatGPTOAuth.resource])
            // Fetch trusted signing metadata before consuming a rotating token. A
            // temporary metadata outage must never discard a received replacement.
            let keys = try await Self.keys(using: client)
            let data = try await ChatGPTHTTP.data(request, using: client, limit: 128000)
            let next = try ChatGPTOAuth.grant(data, previous: previous)
            if next.idToken != previous.idToken {
                _ = try ChatGPTOAuth.validateIDToken(next.idToken, clientID: registration.clientID, nonce: nil,
                                                     expectedSubject: registration.subject, jwks: keys)
            }
            return next
        }
    }
    static func discovery(using client: URLSession = ChatGPTHTTP.session) async throws -> ChatGPTOAuth.Discovery {
        let data = try await ChatGPTHTTP.data(URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/.well-known/openid-configuration")!), using: client, limit: 64000)
        let discovery = try JSONDecoder().decode(ChatGPTOAuth.Discovery.self, from: data)
        try discovery.validate()
        return discovery
    }
    static func keys(using client: URLSession = ChatGPTHTTP.session) async throws -> ChatGPTOAuth.JWKS {
        let discovery = try await discovery(using: client)
        let data = try await ChatGPTHTTP.data(URLRequest(url: discovery.trustedURL(discovery.jwks_uri)), using: client, limit: 128000)
        return try JSONDecoder().decode(ChatGPTOAuth.JWKS.self, from: data)
    }
    func invalidate() {
        generation += 1; refreshing?.cancel(); refreshing = nil; unsaved = nil
    }
    func credentials() async throws -> ChatGPTOAuth.Credentials {
        guard !signedOut else { throw ChatGPTFailure.signInRequired }
        if let refreshing { return try await refreshing.value }
        guard let current = read() else { throw ChatGPTFailure.signInRequired }
        guard current.permitsPlan else { throw ChatGPTFailure.planDisabled }
        if !current.needsRefresh { return current }
        if let earliest = current.earliestRefreshAt, earliest > .now, current.expiresAt > .now { return current }
        let epoch = generation
        let task = Task { try await self.rotate(generation: epoch) }
        refreshing = task
        defer { if generation == epoch { refreshing = nil } }
        return try await task.value
    }
    private func rotate(generation epoch: Int) async throws -> ChatGPTOAuth.Credentials {
        let lock = try await ChatGPTRefreshLock.acquire(lockURL)
        defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()
        guard generation == epoch, let current = read() else { throw ChatGPTFailure.signInRequired }
        guard current.permitsPlan else { throw ChatGPTFailure.planDisabled }
        if let pending = unsaved {
            unsaved = nil
            if pending.previous == current {
                guard write(pending.next) else { unsaved = pending; throw ChatGPTFailure.storage }
                return pending.next
            }
        }
        if !current.needsRefresh { return current }
        guard current.refreshToken != nil else { throw ChatGPTFailure.signInRequired }
        do {
            let next = try await refresh(current)
            try Task.checkCancellation()
            guard generation == epoch, read() == current else { throw ChatGPTFailure.signInRequired }
            guard write(next) else { unsaved = (current, next); throw ChatGPTFailure.storage }
            guard next.permitsPlan else { throw ChatGPTFailure.planDisabled }
            return next
        } catch let error as ChatGPTFailure {
            if error.terminalRefresh, generation == epoch, read() == current { _ = write(nil) }
            throw error
        }
    }
    /// Clearing locally is explicit even if the service cannot confirm remote revocation.
    func signOut() async throws -> Bool {
        signedOut = true
        let pending = unsaved
        invalidate()
        let lock = try await ChatGPTRefreshLock.acquire(lockURL)
        defer { withExtendedLifetime(lock) {} }
        let current = read()
        let renewable = pending?.previous == current ? pending?.next : current
        var revoked = renewable?.refreshToken == nil
        if let refresh = renewable?.refreshToken {
            do {
                let discovery = try await Self.discovery(using: client)
                var request = URLRequest(url: try discovery.trustedURL(discovery.revocation_endpoint), timeoutInterval: 15)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = ChatGPTOAuth.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": registration.clientID])
                _ = try await ChatGPTHTTP.data(request, using: client, limit: 64000)
                revoked = true
            } catch { revoked = false }
        }
        guard read() == current, write(nil) else { throw ChatGPTFailure.storage }
        return revoked
    }
}
