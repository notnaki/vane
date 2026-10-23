import Foundation

/// Session and sidecar jobs share submission order. Workers never call MainActor, so
/// legacy synchronous transaction boundaries can drain safely; UI autosave uses flush().
final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()
    private let queue = DispatchQueue(label: "Vane.session-persistence", qos: .utility)
    private var failures: [URL: @Sendable () -> Bool] = [:] // confined to queue

    func enqueue(file: URL, _ operation: @escaping @Sendable () -> Bool) {
        queue.async { [self] in
            if operation() { failures.removeValue(forKey: file) } else { failures[file] = operation }
        }
    }

    func sync<T>(_ operation: () -> T) -> T { queue.sync(execute: operation) }

    func sync(file: URL, _ operation: @escaping @Sendable () -> Bool) -> Bool {
        queue.sync {
            let ok = operation()
            if ok { failures.removeValue(forKey: file) } else { failures[file] = operation }
            return ok
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
