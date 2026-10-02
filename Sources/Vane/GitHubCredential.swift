import Darwin
import Foundation

/// One Keychain value holds the rotating pair, so a relaunch cannot combine tokens from
/// different grants. Old raw OAuth tokens and personal access tokens remain readable.
struct GitHubCredential: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String? = nil
    var expiresAt: Date? = nil
    var refreshExpiresAt: Date? = nil
    private static let prefix = "vane-github-oauth-v1:"

    var stored: String {
        // These fields are strings and finite dates, all validated when decoding the wire.
        Self.prefix + String(decoding: try! JSONEncoder().encode(self), as: UTF8.self)
    }

    static func restore(_ value: String) -> Self? {
        guard !value.isEmpty else { return nil }
        guard value.hasPrefix(prefix) else { return Self(accessToken: value) }
        guard let grant = try? JSONDecoder().decode(Self.self, from: Data(value.dropFirst(prefix.count).utf8)),
              !grant.accessToken.isEmpty,
              grant.expiresAt == nil || grant.refreshToken?.isEmpty == false else { return nil }
        return grant
    }

    func needsRenewal(at now: Date) -> Bool {
        expiresAt.map { $0 <= now.addingTimeInterval(60) } ?? false
    }
}

struct GitHubSignedIn: Sendable {
    let login: String
    let credential: GitHubCredential
    var token: String { credential.accessToken }
}

/// The file contains no secrets. flock covers separate processes, while the coordinator's
/// task covers multiple folders in this process. Both re-read Keychain after locking.
final class GitHubRefreshLock {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static func tryAcquire(_ url: URL) throws -> GitHubRefreshLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GitHub.Trouble.offline }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return GitHubRefreshLock(fd) }
        let code = errno
        close(fd)
        guard code == EWOULDBLOCK || code == EAGAIN else { throw GitHub.Trouble.offline }
        return nil
    }

    @MainActor static func acquire(_ url: URL) async throws -> GitHubRefreshLock {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let lock = try tryAcquire(url) { return lock }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw GitHub.Trouble.offline
    }
}

@MainActor final class GitHubTokenRenewal {
    typealias Send = (URLRequest) async -> Result<GitHubCredential, GitHub.Trouble>
    let lockURL: URL
    private let read: () -> Passwords.CredentialRead
    private let write: (String, String) -> Bool
    private let secret: () -> String?
    private let send: Send
    private var inFlight: Task<Result<GitHubSignedIn, GitHub.Trouble>, Never>?
    /// Rotation consumes the previous refresh token. If Keychain is temporarily unwritable,
    /// retain the new pair in memory and retry saving it rather than spending the old pair.
    private var pending: (previous: GitHubSignedIn, next: GitHubSignedIn)?

    init(lockURL: URL, read: @escaping () -> Passwords.CredentialRead,
         write: @escaping (String, String) -> Bool, secret: @escaping () -> String?,
         send: Send? = nil) {
        self.lockURL = lockURL
        self.read = read
        self.write = write
        self.secret = secret
        self.send = send ?? Self.request
    }

    func token(after token: String, force: Bool = false) async -> Result<GitHubSignedIn, GitHub.Trouble> {
        if let inFlight { return await inFlight.value }
        let task = Task { await rotate(after: token, force: force) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func saved() -> GitHubSignedIn? {
        guard case let .found(account, value) = read(),
              let grant = GitHubCredential.restore(value) else { return nil }
        return GitHubSignedIn(login: account, credential: grant)
    }

    private func rotate(after token: String, force: Bool) async -> Result<GitHubSignedIn, GitHub.Trouble> {
        do {
            let lock = try await GitHubRefreshLock.acquire(lockURL)
            defer { withExtendedLifetime(lock) {} }
            guard let current = saved() else { return .failure(.offline) }
            if let waiting = pending {
                if current.login == waiting.previous.login && current.credential == waiting.previous.credential {
                    guard write(waiting.next.login, waiting.next.credential.stored) else { return .failure(.offline) }
                    pending = nil
                    return .success(waiting.next)
                }
                pending = nil // A replacement sign-in wins over the unsaved old rotation.
            }
            let now = Date.now
            let due = current.credential.needsRenewal(at: now)
            // A new token saved by another process satisfies the old request's rejection.
            guard due || (force && current.token == token) else { return .success(current) }
            guard let refresh = current.credential.refreshToken, !refresh.isEmpty else {
                return due ? .failure(.unauthorised) : .success(current)
            }
            guard current.credential.refreshExpiresAt.map({ $0 > now }) ?? true,
                  let secret = secret(),
                  let request = GitHubOAuth.refresh(refreshToken: refresh, secret: secret) else {
                return .failure(.unauthorised)
            }
            let reply = await send(request)
            guard case let .success(grant) = reply else {
                if case let .failure(trouble) = reply { return .failure(trouble) }
                return .failure(.offline)
            }
            // Settings can remove credentials independently of Live Folders. Never revive
            // one removed during the network request or overwrite a replacement sign-in.
            guard let latest = saved() else { return .failure(.offline) }
            guard latest.login == current.login && latest.credential == current.credential else { return .success(latest) }
            let next = GitHubSignedIn(login: current.login, credential: grant)
            guard write(next.login, grant.stored) else {
                pending = (current, next)
                return .failure(.offline)
            }
            NSLog("[vane] GitHub OAuth credential renewed")
            return .success(next)
        } catch { return .failure(.offline) }
    }

    private static func request(_ request: URLRequest) async -> Result<GitHubCredential, GitHub.Trouble> {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.offline) }
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            if let error {
                // GitHub reports OAuth errors with HTTP 200. Only a revoked/expired refresh
                // token requires reconnecting; server and configuration errors retain it.
                return .failure(["bad_refresh_token", "expired_refresh_token", "invalid_grant"].contains(error)
                                ? .unauthorised : .offline)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(GitHub.trouble(status: http.statusCode,
                                               remaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                                               retryAfter: http.value(forHTTPHeaderField: "Retry-After")) ?? .offline)
            }
            guard let grant = GitHubOAuth.grant(data) else { return .failure(.offline) }
            return .success(grant)
        } catch { return .failure(.offline) }
    }
}
