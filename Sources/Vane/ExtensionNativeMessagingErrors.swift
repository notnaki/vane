import Foundation

/// Explicit consent for real API error callbacks, with no native transport.
enum ExtensionNativeMessagingErrors {
    static let currentVersion = 1

    static func isApproved(version: Int?, required: ExtensionAccess, optional: ExtensionAccess) -> Bool {
        version == currentVersion &&
            (required.permissions.contains("nativeMessaging") || optional.permissions.contains("nativeMessaging"))
    }

    static func retainedVersion(from old: ExtensionCodeStore.Record?,
                                for required: ExtensionAccess, optional: ExtensionAccess) -> Int? {
        guard let old,
              isApproved(version: old.nativeMessagingErrorCompatibilityVersion, required: old.required, optional: old.optional),
              isApproved(version: currentVersion, required: required, optional: optional) else { return nil }
        return currentVersion
    }
}
