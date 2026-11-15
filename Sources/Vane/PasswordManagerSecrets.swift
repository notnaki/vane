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
