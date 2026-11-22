import AppKit
import Combine

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
@MainActor final class PasswordPaneLock: ObservableObject {
    typealias Authenticate = @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
    static let requiredKey = "passwordsRequireAuthentication"
    static var required: Bool { UserDefaults.vane.object(forKey: requiredKey) as? Bool ?? true }
    static let shared = PasswordPaneLock(observing: true)

    /// The one profile whose list is open; nil when locked.
    @Published private(set) var unlockedProfile: UUID?
    @Published private(set) var authenticating = false
    @Published private(set) var problem: String?
    let idle: Duration
    private let authenticate: Authenticate
    private var request = UUID()
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
         authenticate: @escaping Authenticate = { Passwords.authenticate($0, $1) }) {
        self.idle = idle
        self.authenticate = authenticate
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

    func unlock(_ profile: UUID) {
        guard !isUnlocked(profile) else { return }
        guard !authenticating else { return }
        let request = UUID()
        self.request = request
        authenticating = true
        problem = nil
        authenticate("view your saved passwords") { [weak self] ok in
            guard let self, self.request == request else { return }
            self.authenticating = false
            guard ok else {
                self.problem = "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."
                return
            }
            self.unlockedProfile = profile
            self.touch()
            self.scheduleExpiry()
        }
    }

    /// Turning the requirement on while already looking at the list keeps it open: that
    /// person has the list in front of them, and asking now proves nothing new.
    func keepOpen(_ profile: UUID) {
        request = UUID()
        authenticating = false
        unlockedProfile = profile
        touch()
        scheduleExpiry()
    }

    /// Any key, click or scroll in Settings counts; the idle clock restarts from it.
    func touch() { lastInteraction = .now }

    /// Also invalidates an authentication still on screen, so a late success cannot
    /// reopen a pane that was locked while its prompt was up.
    func lock() {
        request = UUID()
        authenticating = false
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
    /// Deleted, but the pane's list has not reloaded yet. Kept hidden until a list arrives
    /// without them, so a finished delete never flashes its row back for one reload.
    @Published private(set) var gone: Set<String> = []
    @Published var failure: String?
    /// Counts failed deletes, so quitting can tell whether one failed on its watch.
    private(set) var failures = 0
    let grace: Duration
    private let delete: Delete
    private var timer: Task<Void, Never>?
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
        return deleting.contains(key) || gone.contains(key)
    }

    /// The pane's fresh list: anything deleted that it no longer contains has settled.
    func prune(_ logins: [Passwords.Login], profileID: UUID) {
        let present = Set(logins.map { Self.key($0, profileID) })
        let prefix = profileID.uuidString + "\n"
        let settled = gone.filter { $0.hasPrefix(prefix) && !present.contains($0) }
        if !settled.isEmpty { gone.subtract(settled) }
    }

    /// The intent is admitted now, so quitting waits for it (see `commit`).
    @discardableResult func schedule(_ login: Passwords.Login, profileID: UUID) -> Bool {
        commit()
        guard let operation = Passwords.beginUIOperation() else { return false }
        failure = nil
        pending = Pending(login: login, profileID: profileID, operation: operation)
        timer = Task { [weak self, grace] in
            do { try await Task.sleep(for: grace) } catch { return }
            self?.commit()
        }
        return true
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
                try await delete(pending.login, pending.profileID)
                gone.insert(key)
            } catch {
                let who = pending.login.account.isEmpty ? "the login" : "\u{201C}\(pending.login.account)\u{201D}"
                failures += 1
                failure = "Vane could not delete \(who) for \(pending.login.host). It is still saved. \(error.localizedDescription)"
                axAnnounce(failure ?? "")
            }
            deleting.remove(key)
        }
    }

    /// Settings keeps its hosting view on close, so the pane's onDisappear never sees it.
    func watchSettingsClose() {
        if closing == nil { closing = SettingsWindow.onClose { [weak self] in self?.commit() } }
    }
}
