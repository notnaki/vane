import Dispatch
import Foundation
import WebKit

/// Owns one genuine SDK action decision while the original navigation is pending.
@MainActor final class PasswordDocumentPendingCalibration {
    private var delivery: (@MainActor () -> Void)?
    private var active = true
    private(set) var received = false
    private let channel: PasswordDocumentPhaseChannel?
    private let started = DispatchTime.now().uptimeNanoseconds
    private var deadline: UInt64 { started + 3_000_000_000 }
    private var held: UInt64?
    private var token: String?
    private weak var web: WKWebView?
    private var failure: String?

    init(channel: PasswordDocumentPhaseChannel?) {
        self.channel = channel
        channel?.record("calibration-start", fields: ["startedMonotonicNs": started, "deadlineMonotonicNs": deadline])
    }

    func bindNavigation(token: String, web: WKWebView) {
        guard self.token == nil else { failure = "Calibration navigation was bound twice"; return }
        self.token = token
        self.web = web
    }

    func hold(_ delivery: @escaping @MainActor () -> Void) {
        guard active else { delivery(); return }
        guard self.delivery == nil, !received else {
            failure = "The genuine action-policy callback arrived twice"
            channel?.record("calibration-duplicate-policy")
            delivery()
            return
        }
        received = true
        self.delivery = delivery
        held = DispatchTime.now().uptimeNanoseconds
        channel?.record("calibration-held", fields: ["path": "password", "token": token ?? "missing"])
    }

    func release() {
        active = false
        guard let delivery else { return }
        self.delivery = nil
        channel?.record("calibration-released", fields: ["path": "password"])
        delivery()
    }

    /// The caller joins this structured child before tearing down its tab/window/loop.
    func releaseAfterSamplingProgress() async -> String? {
        func fail(_ reason: String) -> String {
            channel?.record("calibration-failed", fields: ["reason": reason])
            release()
            return reason
        }
        let admissionDeadline = started + 2_000_000_000
        do {
            while !received, active {
                guard DispatchTime.now().uptimeNanoseconds < admissionDeadline else {
                    return fail("The genuine action-policy callback did not arrive within2s")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard received else { return fail("Pending calibration ended before its action callback") }
            while active {
                // Check before reading a ready condition; a late true result must not bypass this budget.
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    return fail("Live sampler acknowledgment did not arrive within the total3s calibration budget")
                }
                if let failure { return fail(failure) }
                guard let channel, let token, let held, let web else {
                    return fail("Missing scoped sampler acknowledgment context")
                }
                let selector = NSSelectorFromString("_webProcessIdentifier")
                guard web.responds(to: selector) else { return fail("Owned WebContent getter is unavailable") }
                typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
                let pid = unsafeBitCast(web.method(for: selector), to: Getter.self)(web, selector)
                guard let content = NativeFixtureDiagnostics.identity(pid), content.isSystemWebContent else {
                    return fail("Owned WebContent launch is unavailable")
                }
                if let proof = try channel.samplerAcknowledgment(token: token, content: content, held: held, deadline: deadline) {
                    channel.record("calibration-acknowledged", fields: ["proof": proof])
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        return fail("Sampler acknowledgment processing exceeded the total3s calibration budget")
                    }
                    release()
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        return fail("Policy delivery exceeded the total3s calibration budget")
                    }
                    return nil
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return fail("Pending calibration ended before live sampling acknowledgment")
        } catch {
            return fail("Pending calibration acknowledgment failed or was cancelled: \(error)")
        }
    }
}
