import Foundation

/// Sync admission is separate from ordinary local-edit ownership. A cancelled
/// UI task must still preserve local writes, while a revoked cloud lease cannot
/// start a queued remote mutation after its category/account changes.
final class ICloudAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func revoke() { lock.withLock { valid = false } }
    func check() throws { if !lock.withLock({ valid }) { throw CancellationError() } }
}

enum ICloudApplyContext {
    @TaskLocal static var admission: ICloudAdmission?
    @TaskLocal static var baseline: [String: ICloudItem] = [:]

    static func check() throws { try Task.checkCancellation(); try admission?.check() }

    /// The returned patch omits fields edited locally after the last capture.
    /// Owners call this inside their own serialization boundary, then merge it
    /// into the current native value. Deletion remains an explicit operation.
    static func reconcile(_ incoming: ICloudItem, current: [String: Data]) -> ICloudItem {
        guard let expected = baseline[incoming.key] else { return incoming }
        var patch = incoming
        patch.fields = patch.fields.filter { key, _ in current[key] == expected.fields[key] }
        return patch
    }
}
