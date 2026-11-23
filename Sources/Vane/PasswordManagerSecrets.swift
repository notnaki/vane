import AppKit
import Combine
import LocalAuthentication

/// The manager's temporary plaintext, separate from its names-only login list. Settings
/// retains its hosting view on close, so these values need an explicit window lifetime.
@MainActor final class PasswordManagerSecrets: ObservableObject {
    @Published var adding = false
    @Published var editing: String?
    @Published var draftAccount = ""
    @Published var draftPassword = ""
    @Published var revealed: [String: String] = [:]
    var secretContext = UUID()
    var forgetting: [String: Task<Void, Never>] = [:]
    private var closing: Any?
    private var workspaceObservers: [Any] = []
    private var editExpires: ContinuousClock.Instant?
    private var editExpiry: Task<Void, Never>?

    func beginEditing(_ id: String, account: String, password: String, lifetime: Duration = .seconds(300)) {
        forget()
        editing = id
        draftAccount = account
        draftPassword = password
        editExpires = .now + lifetime
        editExpiry = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            self?.forget()
        }
    }

    func authorizesEdit(_ id: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard editing == id, let editExpires, now < editExpires else { forget(); return false }
        return true
    }

    func forget() {
        editExpiry?.cancel(); editExpiry = nil
        editExpires = nil
        secretContext = UUID()
        for task in forgetting.values { task.cancel() }
        forgetting.removeAll()
        revealed.removeAll()
        draftAccount = ""
        draftPassword = ""
        editing = nil
        adding = false
    }

    func watchSettingsClose() {
        if closing == nil { closing = SettingsWindow.onClose { [weak self] in self?.forget() } }
        guard workspaceObservers.isEmpty else { return }
        // Not on app switch or key-window loss: copying something from elsewhere mid-edit
        // is normal. Locking the screen or sleeping ends the authorization.
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget() }
            })
        }
    }

    func stopWatching() {
        forget()
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }
}

/// Settings → Passwords as a whole sits behind device-owner authentication when
/// "Require Touch ID to view passwords" is on. One app-wide lock rather than view state:
/// switching to another Settings pane and back is not a reason to ask again, but closing
/// Settings, locking the screen, sleeping, switching profile or five idle minutes are.
/// Reveal, copy and edit still ask on their own — this only hides the list.
///
/// Like a locked folder, the locked pane holds the inline Touch ID control and starts it
/// once per presentation; Settings → Privacy and Security → Locked Folders' "System" method,
/// a Mac without Touch ID, or "Use Password…" take the macOS sheet instead.
@MainActor final class PasswordPaneLock: ObservableObject {
    /// Returns the prompt's context, if any, so locking can take a sheet still on screen down.
    typealias Authenticate = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> LAContext?
    /// Evaluates Touch ID on the pane's embedded context.
    typealias Inline = @MainActor (LAContext, String, @escaping @MainActor (Bool) -> Void) -> LAContext?
    static let requiredKey = "passwordsRequireAuthentication"
    static var required: Bool { UserDefaults.vane.object(forKey: requiredKey) as? Bool ?? true }
    static let shared = PasswordPaneLock(observing: true)

    /// The one profile whose list is open; nil when locked.
    @Published private(set) var unlockedProfile: UUID?
    @Published private(set) var authenticating = false
    @Published private(set) var problem: String?
    /// Whether the attempt on screen is the macOS sheet rather than the inline scan.
    @Published private(set) var usingPassword = false
    /// Attached to the pane's embedded Touch ID view. A used context can reuse its
    /// credential, so it is replaced after every attempt and on every lock.
    @Published private(set) var inlineContext = LAContext()
    let idle: Duration
    private let authenticate: Authenticate
    private let inline: Inline
    var biometricsAvailable: @MainActor () -> Bool = {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    /// Starting on its own needs Settings in front; a test hosts the pane elsewhere.
    var mayPrompt: @MainActor () -> Bool = { SettingsWindow.isKey }
    /// The profile the automatic attempt already ran for since the pane was presented.
    private var automaticProfile: UUID?
    private var request = UUID()
    private var context: LAContext?
    private var lastInteraction = ContinuousClock.now
    private var expiry: Task<Void, Never>?
    /// ponytail: never removed — the app has one lock for its lifetime, and the blocks hold
    /// it weakly, so a test's short-lived lock leaves only inert observers behind.
    private var observers: [Any] = []
    private var closing: Any?
    private var interaction: Any?

    /// `distributed` is injectable so a test never broadcasts a real screen-lock
    /// notification to every app on the Mac (Vane's own locked folders included).
    init(idle: Duration = .seconds(300), observing: Bool = false,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         authenticate: Authenticate? = nil, inline: Inline? = nil) {
        self.idle = idle
        self.authenticate = authenticate ?? { Passwords.authenticate($0, $1) }
        // A stub given for the sheet alone answers the inline scan too.
        if let inline { self.inline = inline }
        else if let authenticate { self.inline = { _, reason, done in authenticate(reason, done) } }
        else { self.inline = { Passwords.authenticateInline($0, $1, $2) } }
        guard observing else { return }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } })
    }

    func isUnlocked(_ profile: UUID) -> Bool { !Self.required || unlockedProfile == profile }

    var usesInline: Bool { Prefs.folderUnlockMethod == .touchID && biometricsAvailable() }

    /// Settings exists only once it has been shown, so the close hook and the interaction
    /// monitor are installed by the pane rather than at init. Both are installed once.
    func watchSettings() {
        if closing == nil { closing = SettingsWindow.onClose { [weak self] in self?.lock() } }
        if interaction == nil {
            interaction = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                if SettingsWindow.holds(event.window) { self?.touch() }
                return event
            }
        }
    }

    /// Once per presentation, and only with Settings in front: a cancel or failure waits
    /// for a tap rather than starting again.
    func beginAutomaticUnlock(_ profile: UUID) {
        guard mayPrompt(), !isUnlocked(profile), !authenticating, automaticProfile != profile else { return }
        automaticProfile = profile
        unlock(profile)
    }

    /// The pane was presented again, so it may start on its own once more.
    func rearm() { automaticProfile = nil }

    /// `password` takes the macOS sheet, retiring an inline scan still waiting.
    func unlock(_ profile: UUID, password: Bool = false) {
        guard !isUnlocked(profile) else { return }
        if password, authenticating, !usingPassword { cancel() }
        guard !authenticating else { return }
        let request = UUID()
        self.request = request
        authenticating = true
        problem = nil
        usingPassword = password || !usesInline
        let reply: @MainActor (Bool) -> Void = { [weak self] ok in
            guard let self, self.request == request else { return }
            self.context = nil
            self.authenticating = false
            self.retireInlineContext()
            guard ok else {
                self.problem = "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."
                return
            }
            self.unlockedProfile = profile
            self.touch()
            self.scheduleExpiry()
        }
        let reason = "view your saved passwords"
        let started = usingPassword ? authenticate(reason, reply) : inline(inlineContext, reason, reply)
        // A stub or an unavailable policy may already have answered.
        if self.request == request, authenticating { context = started }
    }

    /// Takes down the attempt on screen without locking: the pane went away.
    func cancel() {
        request = UUID()
        context?.invalidate(); context = nil
        authenticating = false
        retireInlineContext()
    }

    private func retireInlineContext() {
        inlineContext.invalidate()
        inlineContext = LAContext()
    }

    /// Turning the requirement on while already looking at the list keeps it open: that
    /// person has the list in front of them, and asking now proves nothing new.
    func keepOpen(_ profile: UUID) {
        request = UUID()
        context?.invalidate(); context = nil
        authenticating = false
        unlockedProfile = profile
        touch()
        scheduleExpiry()
    }

    /// Any key, click or scroll in Settings counts; the idle clock restarts from it.
    func touch() { lastInteraction = .now }

    /// Also invalidates an authentication still on screen, so a late success cannot
    /// reopen a pane that was locked while its prompt was up, and its sheet goes away.
    func lock() {
        cancel()
        expiry?.cancel(); expiry = nil
        if unlockedProfile != nil { unlockedProfile = nil }
    }

    /// ponytail: one sleeping task that re-reads the last interaction when it wakes,
    /// rather than a new timer per keystroke.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self.map({ $0.lastInteraction + $0.idle }) else { return }
                if ContinuousClock.now >= deadline { self?.lock(); return }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        }
    }
}

/// Deleting a login hides it at once and offers Undo; the Keychain delete runs when the
/// toast expires, or straight away when the pane goes away or the app quits. Undo is
/// therefore free — nothing was written. A delete that then fails puts the row back and
/// says so: the login is never silently gone, nor silently kept.
@MainActor final class PasswordPendingDeletion: ObservableObject {
    typealias Delete = @MainActor (Passwords.Login, UUID) async throws -> Void
    struct Pending: Identifiable {
        let id = UUID()
        let login: Passwords.Login
        let profileID: UUID
        fileprivate let operation: Passwords.PendingUIOperation
    }
    static let shared = PasswordPendingDeletion()
    static let grace: Duration = .seconds(5)

    @Published private(set) var pending: Pending?
    /// Deletes already in the Keychain lane. Still hidden until they settle.
    @Published private(set) var deleting: Set<String> = []
    /// Deleted, but the pane's list has not reloaded yet, with when each delete finished.
    /// Kept hidden until a list fetched after that instant arrives (or one without it), so
    /// a finished delete never flashes its row back for one stale reload — and a login
    /// saved again later is listed again.
    @Published private(set) var gone: [String: ContinuousClock.Instant] = [:]
    @Published var failure: String?
    /// Counts failed deletes, so quitting can tell whether one failed on its watch.
    private(set) var failures = 0
    let grace: Duration
    private let delete: Delete
    private var timer: Task<Void, Never>?
    private var held = false
    private var closing: Any?

    init(grace: Duration = PasswordPendingDeletion.grace,
         delete: @escaping Delete = { try await Passwords.deleteAsync($0, profileID: $1) }) {
        self.grace = grace
        self.delete = delete
    }

    private static func key(_ login: Passwords.Login, _ profileID: UUID) -> String {
        profileID.uuidString + "\n" + login.id
    }

    func hides(_ login: Passwords.Login, profileID: UUID) -> Bool {
        if let pending, pending.profileID == profileID, pending.login.id == login.id { return true }
        let key = Self.key(login, profileID)
        return deleting.contains(key) || gone[key] != nil
    }

    /// The pane's fresh list, fetched at `fetchedAt`: a delete has settled once a list
    /// fetched after it finished arrives, whether or not that list holds the login again.
    func prune(_ logins: [Passwords.Login], profileID: UUID, fetchedAt: ContinuousClock.Instant) {
        let present = Set(logins.map { Self.key($0, profileID) })
        let prefix = profileID.uuidString + "\n"
        let settled = gone.filter { $0.key.hasPrefix(prefix) && ($0.value < fetchedAt || !present.contains($0.key)) }
        for key in settled.keys { gone[key] = nil }
    }

    /// The intent is admitted now, so quitting waits for it (see `commit`).
    @discardableResult func schedule(_ login: Passwords.Login, profileID: UUID) -> Bool {
        commit()
        guard let operation = Passwords.beginUIOperation() else { return false }
        failure = nil
        pending = Pending(login: login, profileID: profileID, operation: operation)
        held = false
        startTimer()
        return true
    }

    /// While the toast has VoiceOver or keyboard focus it stays; the full grace restarts
    /// when focus leaves.
    func hold(_ on: Bool) {
        guard held != on else { return }
        held = on
        timer?.cancel(); timer = nil
        if !on, pending != nil { startTimer() }
    }

    private func startTimer() {
        timer = Task { [weak self, grace] in
            do { try await Task.sleep(for: grace) } catch { return }
            self?.commit()
        }
    }

    func undo() {
        guard let pending else { return }
        timer?.cancel(); timer = nil
        self.pending = nil
        pending.operation.finish()
    }

    func commit() {
        guard let pending else { return }
        timer?.cancel(); timer = nil
        self.pending = nil
        let key = Self.key(pending.login, pending.profileID)
        deleting.insert(key)
        Task { [delete] in
            defer { pending.operation.finish() }
            do {
                do { try await delete(pending.login, pending.profileID) }
                // Already gone from the Keychain is what was asked for.
                catch let refusal as Passwords.Failure where refusal.status == errSecItemNotFound {}
                gone[key] = .now
            } catch {
                let who = pending.login.account.isEmpty ? "the login" : "\u{201C}\(pending.login.account)\u{201D}"
                failures += 1
                failure = "Vane could not delete \(who) for \(pending.login.host). It is still saved. \(error.localizedDescription)"
                axAnnounce(failure ?? "")
            }
            deleting.remove(key)
        }
    }

    /// Quitting: runs the delete still on its toast and waits for every accepted one.
    /// `failuresAtStart` is read when quitting begins, so a delete that fails during an
    /// earlier quit step stops the quit too.
    func finishForQuit(failuresAtStart: Int) async -> Bool {
        commit()
        do { try await Passwords.flushPendingOperations() } catch { return false }
        return failures == failuresAtStart
    }

    /// Settings keeps its hosting view on close, so the pane's onDisappear never sees it.
    func watchSettingsClose() {
        if closing == nil { closing = SettingsWindow.onClose { [weak self] in self?.commit() } }
    }
}
