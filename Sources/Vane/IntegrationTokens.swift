import Foundation
import Security

/// Native integration grants never share the Internet-password namespace used by web
/// autofill. One generic-password item holds each profile's GitHub login and token envelope.
struct IntegrationTokens: Sendable {
    /// Security's C callbacks are invoked only inside Passwords' serialized service
    /// lane. The immutable wrapper may cross executors; injected stores obey that lane.
    struct Keychain: @unchecked Sendable {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus
        static var system: Self {
            Self(copy: SecItemCopyMatching, add: SecItemAdd, update: SecItemUpdate, delete: SecItemDelete)
        }
    }

    struct Access: Sendable {
        var read: @Sendable (UUID) -> Passwords.CredentialRead = { IntegrationTokens(profileID: $0).read() }
        var delete: @Sendable (String, UUID) -> Bool = { IntegrationTokens(profileID: $1).delete(account: $0) }
    }

    static let legacyOrigin = PasswordOrigin(host: "api.github.com")
    private static let creator: NSNumber = 0x5661_6E65
    private let profileID: UUID
    private let dataDir: String?
    private let keychain: Keychain
    private let lastUsed: [String: Date]

    init(profileID: UUID, dataDir: String? = Store.overrideDirectory,
         keychain: Keychain = .system, lastUsed: [String: Date]? = nil) {
        self.profileID = profileID
        self.dataDir = dataDir
        self.keychain = keychain
        self.lastUsed = lastUsed ?? Passwords.lastUsed(profileID: profileID)
    }

    private static func service(dataDir: String?) -> String {
        "com.vane.github-integration.v1." + (dataDir.map { UserDefaults.suiteName(forDataDir: $0) } ?? "default")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service(dataDir: dataDir),
         kSecAttrAccount as String: profileID.uuidString.lowercased(),
         kSecAttrCreator as String: Self.creator]
    }

    private struct Credential: Codable {
        let account: String
        let password: String
    }

    private func attributes(_ query: [String: Any]) throws -> [[String: Any]] {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var output: CFTypeRef?
        try Passwords.checkServiceCancellation()
        let status = keychain.copy(query as CFDictionary, &output)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
        guard let items = output as? [[String: Any]] else { throw Passwords.Failure(status: errSecDecode) }
        return items
    }

    private func nativeItem() throws -> [String: Any]? {
        try attributes(query).first
    }

    private func reference(_ item: [String: Any]) throws -> Data {
        guard let ref = item[kSecValuePersistentRef as String] as? Data else {
            throw Passwords.Failure(status: errSecDecode)
        }
        return ref
    }

    private func secret(_ item: [String: Any], itemClass: CFString) throws -> Data {
        var output: CFTypeRef?
        try Passwords.checkServiceCancellation()
        let status = keychain.copy([
            kSecClass as String: itemClass, kSecValuePersistentRef as String: try reference(item),
            kSecReturnData as String: true,
        ] as CFDictionary, &output)
        guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
        guard let data = output as? Data else { throw Passwords.Failure(status: errSecDecode) }
        return data
    }

    private func credential(_ item: [String: Any]) throws -> Credential {
        let data = try secret(item, itemClass: kSecClassGenericPassword)
        guard let value = try? JSONDecoder().decode(Credential.self, from: data),
              !value.account.isEmpty, !value.password.isEmpty else { throw Passwords.Failure(status: errSecDecode) }
        return value
    }

    private func legacyItems() throws -> [[String: Any]] {
        let scope = Passwords.namespace(profileID: profileID, dataDir: dataDir)
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: Self.legacyOrigin.host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrCreator as String: Self.creator]
        if let scope { query[kSecAttrSecurityDomain as String] = scope }
        return try attributes(query).filter {
            Passwords.owns(scope: scope, itemDomain: $0[kSecAttrSecurityDomain as String] as? String)
                && PasswordOrigin(attributes: $0) == Self.legacyOrigin
        }
    }

    private func remove(_ item: [String: Any], itemClass: CFString) throws {
        try Passwords.checkServiceCancellation()
        let status = keychain.delete([kSecClass as String: itemClass,
            kSecValuePersistentRef as String: try reference(item)] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Passwords.Failure(status: status) }
    }

    private func removeLegacy() throws {
        for item in try legacyItems() { try remove(item, itemClass: kSecClassInternetPassword) }
    }

    private func cleanupLegacyAfterSave() {
        do { try removeLegacy() }
        catch let error as Passwords.Failure {
            // The durable native value remains authoritative. Retry cleanup on later reads.
            NSLog("[vane] GitHub legacy credential cleanup failed (status %d)", error.status)
        } catch { NSLog("[vane] GitHub legacy credential cleanup failed") }
    }

    func read() -> Passwords.CredentialRead {
        return Passwords.serialized {
            do {
                if let item = try nativeItem() {
                    let value = try credential(item)
                    cleanupLegacyAfterSave()
                    return .found(account: value.account, password: value.password)
                }
                let items = try legacyItems()
                let logins = try items.map { item -> Passwords.Login in
                    guard let account = item[kSecAttrAccount as String] as? String, !account.isEmpty else {
                        throw Passwords.Failure(status: errSecDecode)
                    }
                    return Passwords.Login(origin: Self.legacyOrigin, account: account)
                }
                guard let account = Passwords.rank(logins, used: lastUsed).first?.account,
                      let item = items.first(where: { $0[kSecAttrAccount as String] as? String == account }) else { return .missing }
                let data = try secret(item, itemClass: kSecClassInternetPassword)
                guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                    throw Passwords.Failure(status: errSecDecode)
                }
                // Migration is add-only: another process may already have persisted a newer
                // grant. Never overwrite it with the old Internet password.
                let status = try add(Credential(account: account, password: password))
                if status == errSecDuplicateItem {
                    guard let winner = try nativeItem() else { throw Passwords.Failure(status: status) }
                    let value = try credential(winner)
                    cleanupLegacyAfterSave()
                    return .found(account: value.account, password: value.password)
                }
                guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
                cleanupLegacyAfterSave()
                return .found(account: account, password: password)
            } catch let error as Passwords.Failure { return .unavailable(error.status) }
            catch { return .unavailable(errSecDecode) }
        }
    }

    private func add(_ credential: Credential) throws -> OSStatus {
        var add = query
        add[kSecValueData as String] = try JSONEncoder().encode(credential)
        add[kSecAttrLabel as String] = "GitHub integration (Vane)"
        try Passwords.checkServiceCancellation()
        return keychain.add(add as CFDictionary, nil)
    }

    /// SecItem success establishes durable storage before any legacy item is removed.
    func save(account: String, password: String) -> Bool {
        return Passwords.serialized {
            guard !account.isEmpty, !password.isEmpty else { return false }
            do {
                let value = Credential(account: account, password: password)
                if let item = try nativeItem() {
                    try update(item, value: value)
                } else {
                    let status = try add(value)
                    if status == errSecDuplicateItem, let item = try nativeItem() { try update(item, value: value) }
                    else if status != errSecSuccess { throw Passwords.Failure(status: status) }
                }
                cleanupLegacyAfterSave()
                return true
            } catch { return false }
        }
    }

    private func update(_ item: [String: Any], value: Credential) throws {
        try Passwords.checkServiceCancellation()
        let status = keychain.update([kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: try reference(item)] as CFDictionary,
            [kSecValueData as String: try JSONEncoder().encode(value)] as CFDictionary)
        guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
    }

    func delete(account: String) -> Bool {
        return Passwords.serialized {
            do {
                if let item = try nativeItem(), try credential(item).account != account { return false }
                return deleteAll()
            } catch { return false }
        }
    }

    /// Remove legacy values first: a locked/failed cleanup must leave the authoritative
    /// native value intact, so a later read cannot resurrect an older integration token.
    func deleteAll() -> Bool {
        return Passwords.serialized {
            do {
                try removeLegacy()
                if let item = try nativeItem() { try remove(item, itemClass: kSecClassGenericPassword) }
                return true
            } catch { return false }
        }
    }

    /// The service binds this enumeration to one data directory, across all its profiles.
    static func deleteEverything(dataDir: String? = Store.overrideDirectory, keychain: Keychain = .system) -> Bool {
        return Passwords.serialized {
            let store = Self(profileID: ProfileManager.defaultID, dataDir: dataDir, keychain: keychain, lastUsed: [:])
            var query = store.query
            query.removeValue(forKey: kSecAttrAccount as String)
            do {
                for item in try store.attributes(query) { try store.remove(item, itemClass: kSecClassGenericPassword) }
                return true
            } catch { return false }
        }
    }
}
