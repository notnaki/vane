import Dispatch
import Foundation

/// Owns one genuine SDK action decision while the original navigation is pending.
@MainActor final class PasswordDocumentPendingCalibration {
    private var delivery: (@MainActor () -> Void)?
    private var active = true
    private(set) var received = false
    private let channel: PasswordDocumentPhaseChannel?

    init(channel: PasswordDocumentPhaseChannel?) { self.channel = channel }

    func hold(_ delivery: @escaping @MainActor () -> Void) {
        guard active else { delivery(); return }
        guard self.delivery == nil, !received else {
            channel?.record("calibration-duplicate-policy")
            delivery()
            return
        }
        received = true
        self.delivery = delivery
        channel?.record("calibration-held", fields: ["path": "password"])
    }

    func release() {
        active = false
        guard let delivery else { return }
        self.delivery = nil
        channel?.record("calibration-released", fields: ["path": "password"])
        delivery()
    }

    /// The caller joins this structured child before tearing down its tab/window/loop.
    func releaseAfterInterval() async -> String? {
        let admissionDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        do {
            while !received, active {
                guard DispatchTime.now().uptimeNanoseconds < admissionDeadline else {
                    release()
                    return "The genuine action-policy callback did not arrive within2s"
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard received else { return "Pending calibration ended before its action callback" }
            let releaseDeadline = DispatchTime.now().uptimeNanoseconds + 1_200_000_000
            while active, DispatchTime.now().uptimeNanoseconds < releaseDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            release()
            return nil
        } catch {
            release()
            return "Pending calibration release was cancelled: \(error)"
        }
    }
}
