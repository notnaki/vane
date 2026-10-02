import Foundation
import Security
import LocalAuthentication

/// Separate generic-password items: never shipped, synced, logged, or stored in preferences.
enum AIKeys {
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
        var q = query(account: account, namespace: namespace)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, account: String, namespace: String?) -> OSStatus {
        let q = query(account: account, namespace: namespace)
        let value = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(q as CFDictionary, value as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var add = q.merging(value) { _, new in new }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }
    static func remove(account: String, namespace: String?) -> OSStatus {
        let status = SecItemDelete(query(account: account, namespace: namespace) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

