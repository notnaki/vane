import AppKit
import LocalAuthentication

/// Device-owner authentication in front of saved-password autofill. Reveal, copy and edit
/// in Settings already ask the Mac who you are; choosing an account in a page put the same
/// secret into a field that Web Inspector reads straight back.
///
/// One prompt opens a short window shared by every tab, so a sign-in with several steps
/// asks once. Locking the screen, sleeping or switching user ends it.
@MainActor final class PasswordFillGate {
    /// Raises the prompt and returns how to take it off screen again, if it can be.
    typealias Authenticator = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> (@MainActor () -> Void)?

    static let shared = PasswordFillGate()
    static let grace: Duration = .seconds(300)
    /// App-wide rather than per profile: it describes who may sit at this Mac.
    static let requiredKey = "requireAuthToFillPasswords"
    static var isRequired: Bool { UserDefaults.vane.object(forKey: requiredKey) as? Bool ?? true }

    /// The policy and login-password fallback of `Passwords.authenticate`, on a context
    /// this gate can invalidate.
    var authenticate: Authenticator = { reason, done in
        // Nobody can answer a system prompt under XCTest: refuse rather than raise one.
        let context = LAContext()
        guard NSClassFromString("XCTestCase") == nil,
              context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { done(false); return nil }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in done(ok) }
        }
        return { context.invalidate() }
    }
    /// Monotonic, so moving the wall clock back cannot stretch the window.
    var now: () -> ContinuousClock.Instant = { .now }
    private var authorizedUntil: ContinuousClock.Instant?
    /// The one prompt on screen, everyone waiting on its answer, and how to dismiss it.
    private var prompt: UUID?
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var dismissPrompt: (@MainActor () -> Void)?

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        for (center, name) in [(workspace, NSWorkspace.willSleepNotification),
                               (workspace, NSWorkspace.sessionDidResignActiveNotification),
                               (distributed, Notification.Name("com.apple.screenIsLocked"))] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revoke() }
            }
        }
    }

    /// Whether the next password fill raises the system prompt.
    var needsPrompt: Bool {
        guard Self.isRequired else { return false }
        guard let authorizedUntil else { return true }
        return now() >= authorizedUntil
    }

    /// One prompt at a time: a fill that arrives while it is up waits for the same answer
    /// instead of stacking a second dialog. A cancelled fill stops waiting, and the prompt
    /// nobody is waiting for is taken off screen, so it cannot be approved for nothing.
    func authorize(_ reason: String) async -> Bool {
        guard needsPrompt else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiting[id] = continuation
                guard prompt == nil else { return }
                let raised = UUID()
                prompt = raised
                let dismiss = authenticate(reason) { [weak self] allowed in self?.answer(raised, allowed) }
                // A stub answers before returning; there is nothing left to dismiss then.
                if prompt == raised { dismissPrompt = dismiss }
            }
        } onCancel: {
            Task { @MainActor in self.abandon(id) }
        }
    }

    private func answer(_ raised: UUID, _ allowed: Bool) {
        // An invalidated context still reports its failure; that prompt is not ours any more.
        guard prompt == raised else { return }
        prompt = nil
        dismissPrompt = nil
        if allowed { authorizedUntil = now() + Self.grace }
        let answered = waiting
        waiting.removeAll()
        for continuation in answered.values { continuation.resume(returning: allowed) }
    }

    private func abandon(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
        guard waiting.isEmpty else { return }
        prompt = nil
        dismissPrompt?()
        dismissPrompt = nil
    }

    func revoke() { authorizedUntil = nil }

    /// Turning the requirement off is itself what the requirement protects, so it asks first.
    func setRequired(_ required: Bool) {
        guard !required, Self.isRequired else {
            UserDefaults.vane.set(required, forKey: Self.requiredKey)
            return
        }
        _ = authenticate("turn off authentication for filling passwords") { ok in
            if ok { UserDefaults.vane.set(false, forKey: Self.requiredKey) }
        }
    }
}
