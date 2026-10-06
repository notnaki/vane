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

    func forget() {
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
        guard closing == nil else { return }
        closing = SettingsWindow.onClose { [weak self] in self?.forget() }
    }

    func stopWatching() {
        forget()
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
    }
}
