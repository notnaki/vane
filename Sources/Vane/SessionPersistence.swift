import Foundation

/// Session and sidecar jobs share submission order. Workers never call MainActor, so
/// legacy synchronous transaction boundaries can drain safely; UI autosave uses flush().
final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()
    private let queue = DispatchQueue(label: "Vane.session-persistence", qos: .utility)
    private var failures: [URL: @Sendable () -> Bool] = [:] // confined to queue
    struct Mutation<Value: Sendable>: Sendable {
        let value: Value
        let previousVersion: UInt64
        let version: UInt64
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
            _ = advance(file)
            if operation() { failures.removeValue(forKey: file) } else { failures[file] = operation }
        }
        return true
    }

    func sync<T>(_ operation: () -> T) -> T { queue.sync(execute: operation) }

    func sync(file: URL, _ operation: @escaping @Sendable () -> Bool) -> Bool {
        queue.sync {
            guard !isRetired(file) else { return false }
            _ = advance(file)
            let ok = operation()
            if ok { failures.removeValue(forKey: file) } else { failures[file] = operation }
            return ok
        }
    }

    func perform(file: URL, _ operation: @escaping @Sendable () -> Bool) async -> Bool {
        guard !isRetired(file) else { return false }
        return await perform { [self] in
            guard !isRetired(file) else { return false }
            _ = advance(file)
            return operation()
        }
    }

    /// Returns the exact write identity needed by a rejected transaction's repair.
    func mutate<Value: Sendable>(file: URL, _ operation: @escaping @Sendable () -> Value) async -> Mutation<Value>? {
        await perform { [self] in
            guard !isRetired(file) else { return nil }
            let previous = versions[file, default: 0]
            let version = advance(file)
            return Mutation(value: operation(), previousVersion: previous, version: version)
        }
    }

    /// nil from operation means external bytes superseded this edit. Reverse repairs
    /// restore predecessor identities so several staged edits can unwind in order.
    func repair(file: URL, version: UInt64, previousVersion: UInt64,
                _ operation: @escaping @Sendable () -> Bool?) async -> Bool {
        await perform { [self] in
            guard !isRetired(file), versions[file, default: 0] == version else { return true }
            let restored = operation()
            if restored == true { versions[file] = previousVersion }
            return restored != false
        }
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }

    func flush() async -> Bool {
        await perform { [self] in
            // Retain rejected work until it succeeds or a newer job supersedes it.
            // One retry per durability boundary handles recovered disk access without
            // spinning, and a persistent failure remains visible to backup/quit.
            for (file, retry) in failures {
                if isRetired(file) { failures.removeValue(forKey: file); continue }
                _ = advance(file)
                if retry() { failures.removeValue(forKey: file) }
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
