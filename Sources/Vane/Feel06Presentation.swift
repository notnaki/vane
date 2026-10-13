import SwiftUI
import Combine

/// View-owned, single-entry memoization. Keeps derived lists out of hover, focus,
/// progress and secret-reveal redraws; the complete input key controls invalidation.
@MainActor final class Feel06PresentationCache<Key: Equatable, Value> {
    private var stored: (key: Key, value: Value)?

    func value(for key: Key, build: () -> Value) -> Value {
        if let stored, stored.key == key { return stored.value }
        let value = build()
        stored = (key, value)
        return value
    }
}

/// Reserve a single status line so starting work doesn't move the controls below it.
struct Feel06ActivityLine: View {
    let busy: Bool
    let text: String

    var body: some View {
        HStack(spacing: Look.inset) {
            if busy { ProgressView().controlSize(.small) }
            Text(busy ? text : " ").font(Look.footnote).lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(busy ? text : "")
        .accessibilityHidden(!busy)
        .help(busy ? text : "")
    }
}

/// Only non-secret login metadata enters this cache. Authentication and plaintext stay
/// in PasswordManagerSecrets; building presentation never queries the Keychain.
@MainActor final class Feel06PasswordPresentation {
    private struct Key: Equatable {
        let logins: [Passwords.Login]
        let query: String
        let sort: PasswordSort
        let used: [String: Date]
    }
    private let cache = Feel06PresentationCache<Key, [(host: String, logins: [Passwords.Login])]>()

    func groups(_ logins: [Passwords.Login], query: String, sort: PasswordSort,
                used: [String: Date]) -> [(host: String, logins: [Passwords.Login])] {
        cache.value(for: Key(logins: logins, query: query, sort: sort, used: used)) {
            PasswordsPane.groups(logins, query: query, sort: sort, used: used)
        }
    }
}

/// Explicitly opening Passwords may read Keychain attributes, but that synchronous
/// system call must not hold up window presentation. It never requests secret data.
@MainActor final class Feel06PasswordMetadata: ObservableObject {
    typealias Fetch = @Sendable (UUID) throws -> [Passwords.Login]
    @Published private(set) var logins: [Passwords.Login] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var profileID: UUID?
    private var request: UUID?
    private var task: Task<Void, Never>?
    private var closing: AnyCancellable?
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { try Passwords.allChecked(profileID: $0) }) {
        self.fetch = fetch
    }

    func load(profileID: UUID) {
        if closing == nil, let observer = SettingsWindow.onClose({ [weak self] in self?.cancel() }) {
            closing = AnyCancellable { NotificationCenter.default.removeObserver(observer) }
        }
        cancel()
        if self.profileID != profileID { logins = [] }
        self.profileID = profileID
        let request = UUID(), fetch = fetch
        self.request = request
        busy = true
        error = nil
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try fetch(profileID) }
            }.value
            guard !Task.isCancelled, let self, self.request == request else { return }
            switch result {
            case .success(let logins): self.logins = logins
            case .failure(let error): self.error = error.localizedDescription
            }
            self.busy = false
            self.task = nil
        }
    }

    func cancel() {
        request = nil
        task?.cancel()
        task = nil
        busy = false
    }

    func stopWatching() {
        cancel()
        closing?.cancel()
        closing = nil
    }

    deinit { task?.cancel() }
}
