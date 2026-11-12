import Foundation
import Security
import LocalAuthentication

/// Local generic-password originals. Optional iCloud Keychain sync uses a separate mirror.
enum AIKeys {
    private static let lane = NSRecursiveLock()
    static func account(provider: AIProvider, baseURL: String) -> String {
        provider == .custom ? provider.rawValue + ":" + (CloudAI.endpoint(baseURL)?.absoluteString ?? baseURL)
                            : provider.rawValue
    }
    private static func query(account: String, namespace: String?) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.notnaki.vane.ai" + (namespace.map { "." + $0 } ?? ""),
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    static func read(account: String, namespace: String?) -> String? {
        try? lane.withLock { try readChecked(account: account, namespace: namespace) }
    }
    private static func readChecked(account: String, namespace: String?) throws -> String? {
        var q = query(account: account, namespace: namespace)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw Passwords.Failure(status: errSecDecode) }
        return text
    }
    static func save(_ key: String, account: String, namespace: String?) -> OSStatus {
        do { return try saveChecked(key, account: account, namespace: namespace, admission: {}) }
        catch { return errSecUserCanceled }
    }
    private static func saveChecked(_ key: String, account: String, namespace: String?, admission: () throws -> Void) throws -> OSStatus {
        try lane.withLock {
            let q = query(account: account, namespace: namespace)
            let value = [kSecValueData as String: Data(key.utf8)]
            try admission()
            let updated = SecItemUpdate(q as CFDictionary, value as CFDictionary)
            guard updated == errSecItemNotFound else {
                if updated == errSecSuccess { NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil) }
                return updated
            }
            var add = q.merging(value) { _, new in new }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try admission()
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess { NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil) }
            return status
        }
    }
    static func remove(account: String, namespace: String?) -> OSStatus {
        lane.withLock {
            let status = SecItemDelete(query(account: account, namespace: namespace) as CFDictionary)
            if status == errSecSuccess { NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil) }
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    }

    static func iCloudSnapshot(namespace: String?, accounts: Set<String>, admission: () throws -> Void = {}) throws -> [ICloudSecrets.Identity: Data] {
        try lane.withLock {
            try iCloudSnapshot(accounts: accounts, admission: admission) { try readChecked(account: $0, namespace: namespace) }
        }
    }

    /// Enumerate only registered API accounts, never the shared service containing
    /// device-local ChatGPT credentials. The reader is the native Keychain boundary.
    static func iCloudSnapshot(accounts: Set<String>, admission: () throws -> Void = {},
                               read: (String) throws -> String?) throws -> [ICloudSecrets.Identity: Data] {
        guard accounts.count <= 256 else { throw ICloudSecrets.Failure.invalidData }
        var result: [ICloudSecrets.Identity: Data] = [:]
        for account in accounts.sorted() {
            try admission()
            if let value = try read(account) { result[.aiKey(account: account)] = Data(value.utf8) }
        }
        return result
    }

    static func iCloudApply(account: String, namespace: String?, value: Data?, expected: Data?, admission: () throws -> Void = {}) throws -> Bool {
        try lane.withLock {
            try admission()
            guard try readChecked(account: account, namespace: namespace).map({ Data($0.utf8) }) == expected else { return false }
            if value == expected { return true }
            try admission()
            let status: OSStatus
            if let value {
                guard let text = String(data: value, encoding: .utf8) else { throw Passwords.Failure(status: errSecDecode) }
                status = try saveChecked(text, account: account, namespace: namespace, admission: admission)
            } else { status = remove(account: account, namespace: namespace) }
            guard status == errSecSuccess else { throw Passwords.Failure(status: status) }
            return true
        }
    }
}
