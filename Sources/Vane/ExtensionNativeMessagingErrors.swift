import Foundation

/// Chrome's answer when no desktop app is installed: the API exists and every request fails.
/// On by default for extensions that declare `nativeMessaging`, as in Chrome; no desktop app
/// is ever contacted. `nil` (never changed) and `currentVersion` mean on, `disabledVersion` off.
/// Bitwarden on WebKit retries a missing API at once and never yields, so off can hang it.
enum ExtensionNativeMessagingErrors {
    static let currentVersion = 1
    static let disabledVersion = 0
    static let apiNames: Set<String> = ["browser.runtime.sendNativeMessage", "browser.runtime.connectNative"]

    static func unavailable() -> NSError {
        NSError(domain: "VaneNativeMessagingUnavailable", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."])
    }

    static func isApproved(version: Int?, required: ExtensionAccess, optional: ExtensionAccess) -> Bool {
        (version == nil || version == currentVersion) &&
            (required.permissions.contains("nativeMessaging") || optional.permissions.contains("nativeMessaging"))
    }

    static func retainedVersion(from old: ExtensionCodeStore.Record?,
                                for required: ExtensionAccess, optional: ExtensionAccess) -> Int? {
        // Only an explicit choice to turn it off carries over; anything else is the default.
        old?.nativeMessagingErrorCompatibilityVersion == disabledVersion ? disabledVersion : nil
    }
}

@MainActor final class ExtensionNativeMessagingDenial {
    static let perContextLimit = 32
    static let totalLimit = 128
    private var pending: [ObjectIdentifier: [UUID: Task<Void, any Error>]] = [:]
    private let sleep: @Sendable (Duration) async throws -> Void
    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }
    private(set) var requestCount = 0
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }
    func wait(contextID: ObjectIdentifier) async throws {
        try Task.checkCancellation()
        requestCount += 1
        guard (pending[contextID]?.count ?? 0) < Self.perContextLimit, pendingCount < Self.totalLimit else {
            throw ExtensionNativeMessagingErrors.unavailable()
        }
        let id = UUID(), sleep = sleep
        let delay = Task { try await sleep(.milliseconds(100)); try Task.checkCancellation() }
        pending[contextID, default: [:]][id] = delay
        defer {
            pending[contextID]?[id] = nil
            if pending[contextID]?.isEmpty == true { pending[contextID] = nil }
        }
        try await withTaskCancellationHandler {
            try await delay.value
            try Task.checkCancellation()
        } onCancel: { delay.cancel() }
    }
    func cancel(contextID: ObjectIdentifier) {
        let waits = pending.removeValue(forKey: contextID)
        waits?.values.forEach { $0.cancel() }
    }
    func cancelAll() {
        let waits = pending.values.flatMap { $0.values }
        pending.removeAll()
        waits.forEach { $0.cancel() }
    }
}
