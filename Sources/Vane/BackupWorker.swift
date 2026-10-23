import Foundation

/// One executor owns backup disk transactions. Operations do not suspend halfway
/// through their filesystem work, so export, retention and restore cannot interleave.
actor BackupWorker {
    static let shared = BackupWorker()

    func run<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value {
        try operation()
    }
}
