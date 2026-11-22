import AppKit

/// Device-owner authentication in front of saved-password autofill. Reveal, copy and edit
/// in Settings already ask the Mac who you are; choosing an account in a page put the same
/// secret into a field that Web Inspector reads straight back.
///
/// One prompt opens a short window shared by every tab, so a sign-in with several steps
/// asks once. Locking the screen, sleeping or switching user ends it.
@MainActor final class PasswordFillGate {
    typealias Authenticator = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void

    static let shared = PasswordFillGate()
    static let grace: Duration = .seconds(300)
    /// App-wide rather than per profile: it describes who may sit at this Mac.
    static let requiredKey = "requireAuthToFillPasswords"
    static var isRequired: Bool { UserDefaults.vane.object(forKey: requiredKey) as? Bool ?? true }

    var authenticate: Authenticator = { reason, done in
        // Nobody can answer a system prompt under XCTest: refuse rather than raise one.
        guard NSClassFromString("XCTestCase") == nil else { done(false); return }
        Passwords.authenticate(reason, done)
    }
    /// Monotonic, so moving the wall clock back cannot stretch the window.
    var now: () -> ContinuousClock.Instant = { .now }
    private var authorizedUntil: ContinuousClock.Instant?

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

    /// ponytail: a fill superseded while its prompt is up leaves the prompt on screen;
    /// answering it only opens the window. Invalidate the LAContext on cancellation if
    /// that proves confusing.
    func authorize(_ reason: String) async -> Bool {
        guard needsPrompt else { return true }
        let allowed = await withCheckedContinuation { continuation in
            authenticate(reason) { continuation.resume(returning: $0) }
        }
        if allowed { authorizedUntil = now() + Self.grace }
        return allowed
    }

    func revoke() { authorizedUntil = nil }

    /// Turning the requirement off is itself what the requirement protects, so it asks first.
    func setRequired(_ required: Bool) {
        guard !required, Self.isRequired else {
            UserDefaults.vane.set(required, forKey: Self.requiredKey)
            return
        }
        authenticate("turn off authentication for filling passwords") { ok in
            if ok { UserDefaults.vane.set(false, forKey: Self.requiredKey) }
        }
    }
}
