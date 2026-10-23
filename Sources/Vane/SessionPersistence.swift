import Foundation

/// Session and sidecar jobs share submission order. Workers never call MainActor, so
/// legacy synchronous transaction boundaries can drain safely; UI autosave uses flush().
final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()
    private let queue = DispatchQueue(label: "Vane.session-persistence", qos: .utility)
    struct Retry: Sendable {
        fileprivate let version: UInt64
        fileprivate let operation: @Sendable () -> Bool
    }
    struct Ownership: Sendable {
        let file: URL
        let previousVersion: UInt64
        let version: UInt64
        fileprivate let previousRetry: Retry?
    }
    enum RepairDisposition: Sendable { case unchanged, rolledBack, published, failed }
    private var failures: [URL: Retry] = [:] // confined to queue
    struct Mutation<Value: Sendable>: Sendable {
        let value: Value
        let ownership: Ownership
    }
    private var nextVersion: UInt64 = 0
    private var versions: [URL: UInt64] = [:] // queue-confined write identity
    private func advance(_ file: URL) -> UInt64 {
        nextVersion &+= 1; versions[file] = nextVersion; return nextVersion
    }
    private let retirementLock = NSLock()
    private var retired = Set<URL>() // protected by retirementLock, never waits for IO

    func isRetired(_ file: URL) -> Bool {
        retirementLock.withLock { retired.contains(file.standardizedFileURL) }
    }

    /// Admission closes immediately; the barrier waits for any operation already
    /// executing before deletion is allowed to unlink its files. Rejected retries
    /// cannot recreate the profile after the barrier returns.
    func retire(files: [URL]) async {
        retirementLock.withLock { retired.formUnion(files.map(\.standardizedFileURL)) }
        await perform { [self] in
            for file in files { failures.removeValue(forKey: file) }
        }
    }

    @discardableResult
    func enqueue(file: URL, _ operation: @escaping @Sendable () -> Bool) -> Bool {
        guard !isRetired(file) else { return false }
        queue.async { [self] in
            guard !isRetired(file) else { failures.removeValue(forKey: file); return }
            let version = advance(file)
            if operation() { failures.removeValue(forKey: file) }
            else { failures[file] = Retry(version: version, operation: operation) }
        }
        return true
    }

    func sync<T>(_ operation: () -> T) -> T { queue.sync(execute: operation) }

    func sync(file: URL, requiresPendingWrite: Bool = false, _ operation: @escaping @Sendable () -> Bool) -> Bool {
        queue.sync {
            guard !isRetired(file) else { return false }
            guard !requiresPendingWrite || retryPending(file) else { return false }
            let version = advance(file)
            let ok = operation()
            if ok { failures.removeValue(forKey: file) }
            else { failures[file] = Retry(version: version, operation: operation) }
            return ok
        }
    }

    func perform(file: URL, requiresPendingWrite: Bool = false, _ operation: @escaping @Sendable () -> Bool) async -> Bool {
        guard !isRetired(file) else { return false }
        return await perform { [self] in
            guard !isRetired(file) else { return false }
            guard !requiresPendingWrite || retryPending(file) else { return false }
            let previous = versions[file, default: 0]
            _ = advance(file)
            let succeeded = operation()
            if succeeded { failures.removeValue(forKey: file) }
            else { versions[file] = previous }
            return succeeded
        }
    }

    /// Suspend the predecessor's retry while this mutation owns the file. The receipt
    /// carries that obligation until commit supersedes it or an exact rollback restores it.
    func mutate<Value: Sendable>(file: URL, requiresPendingWrite: Bool = false, ownsResult: @escaping @Sendable (Value) -> Bool = { _ in true },
                                 _ operation: @escaping @Sendable () -> Value) async -> Mutation<Value>? {
        await perform { [self] in
            guard !isRetired(file) else { return nil }
            guard !requiresPendingWrite || retryPending(file) else { return nil }
            let previous = versions[file, default: 0]
            let retry = failures.removeValue(forKey: file)
            let version = advance(file)
            let value = operation()
            let ownership = Ownership(file: file, previousVersion: previous, version: version, previousRetry: retry)
            if !ownsResult(value) { versions[file] = previous; failures[file] = retry }
            return Mutation(value: value, ownership: ownership)
        }
    }

    /// All decisions run in the lane. Exact rollback restores its predecessor's retry;
    /// a merged publication satisfies pending writes from the current decoded table.
    func repair<Value: Sendable>(_ ownership: Ownership,
        _ operation: @escaping @Sendable (Bool) -> (Value, RepairDisposition)) async -> Value? {
        await perform { [self] in
            let file = ownership.file
            guard !isRetired(file) else { return nil }
            let ownsFile = versions[file, default: 0] == ownership.version
            let (value, disposition) = operation(ownsFile)
            switch disposition {
            case .rolledBack:
                if ownsFile {
                    versions[file] = ownership.previousVersion
                    failures[file] = ownership.previousRetry
                }
            case .published:
                _ = advance(file)
                failures.removeValue(forKey: file)
            case .failed:
                if ownsFile, let retry = ownership.previousRetry {
                    failures[file] = Retry(version: ownership.version, operation: retry.operation)
                }
            case .unchanged: break
            }
            return value
        }
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }

    /// Disk-only edits must first publish an accepted predecessor snapshot. This runs
    /// in the same lane turn as the edit, with no gap for another capture to interleave.
    private func retryPending(_ file: URL) -> Bool {
        guard let retry = failures[file] else { return true }
        guard versions[file, default: 0] == retry.version else { failures.removeValue(forKey: file); return true }
        let version = advance(file)
        if retry.operation() { failures.removeValue(forKey: file); return true }
        failures[file] = Retry(version: version, operation: retry.operation)
        return false
    }

    func flush() async -> Bool {
        await perform { [self] in
            // One retry per boundary avoids spinning on persistent storage failure.
            for file in Array(failures.keys) {
                if isRetired(file) { failures.removeValue(forKey: file); continue }
                _ = retryPending(file)
            }
            return failures.isEmpty
        }
    }

}

/// Operations which must finish their target write before releasing source tabs.
/// Quit/restore closes UI admission first, then waits for these accepted intents.
@MainActor enum PendingSessionTransactions {
    private static var count = 0
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    static func begin() { count += 1 }
    static func end() {
        count -= 1
        if count == 0 {
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    static func drain() async {
        guard count > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
