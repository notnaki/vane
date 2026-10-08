import AppKit
import Combine
import UniformTypeIdentifiers

struct BackupCandidate: Identifiable, Sendable {
    var id: UUID { archive.id }
    var archive: BackupArchive
    var incoming: BackupPreview
    var current: BackupPreview?
    var currentError: String?
}

@MainActor final class BackupController: ObservableObject {
    static let shared = BackupController(library: BackupLibrary(directory: Store.directory,
        defaults: .vane, domain: UserDefaults.vaneDomain), flush: {
            let profiles = ProfileManager.shared.retryProfileSave()
            let session = Session.save()
            return profiles && session && ProfileManager.shared.saveFailures.isEmpty
        }, restart: BackupRestart.run)

    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var recoveryError: String?
    @Published private(set) var points: [BackupPoint] = []
    @Published private(set) var preview: BackupCandidate?
    private let library: BackupLibrary
    private let flush: @MainActor () -> Bool
    private let restart: @MainActor () throws -> Void
    private var timer: Timer?
    private var lastAttempt: Date?
    private var restorePending = false

    init(library: BackupLibrary, flush: @escaping @MainActor () -> Bool, restart: @escaping @MainActor () throws -> Void) {
        self.library = library; self.flush = flush; self.restart = restart
    }
    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.automaticRecovery() }
        }
        Task { await automaticRecovery() }
    }
    func reloadPoints() { Task { await reloadPointsAsync() } }
    private func reloadPointsAsync() async {
        let repository = BackupRecovery(library: library)
        do { points = try await Task.detached(priority: .utility) { try repository.points() }.value }
        catch { recoveryError = error.localizedDescription }
    }
    private func start(_ label: String) -> Bool {
        guard !busy, !restorePending else { return false }
        Motion.list { busy = true; progress = label; error = nil }
        return true
    }
    private func finish() { Motion.list { busy = false; progress = "" } }
    func export(to url: URL) async {
        guard start("Saving backup…") else { return }
        defer { finish() }
        await Task.yield()
        do {
            guard flush() else { throw BackupError.saveFailed }
            let archive = try library.capture(reason: .manual)
            try await Task.detached(priority: .utility) { try BackupCodec.write(archive, to: url) }.value
            Motion.list { status = "Backup saved to \(url.lastPathComponent)." }
        } catch { self.error = error.localizedDescription }
    }
    func previewRestore(from url: URL) async {
        guard start("Checking backup…") else { return }
        defer { finish() }
        do {
            let archive = try await Task.detached(priority: .utility) { try BackupCodec.read(url) }.value
            let incoming = try library.validate(archive)
            var current: BackupPreview?, currentError: String?
            do { current = try library.validate(library.capture(reason: .manual)) }
            catch { currentError = error.localizedDescription }
            Motion.list { preview = BackupCandidate(archive: archive, incoming: incoming, current: current, currentError: currentError) }
        } catch { self.error = error.localizedDescription }
    }
    func cancelPreview() { guard !busy else { return }; Motion.list { preview = nil } }
    func restorePreview() async {
        guard let candidate = preview, start("Preserving a recovery point…") else { return }
        defer { finish() }
        await Task.yield()
        let transaction = BackupRestore(library: library)
        var staged = false
        do {
            if !flush() {
                // A healthy library with unsaved changes must not be silently discarded.
                // Damaged disk originals must still be repairable with a valid backup.
                if (try? library.capture(reason: .manual)) != nil { throw BackupError.saveFailed }
            }
            try transaction.prepare(candidate.archive)
            staged = true
            restorePending = true
            try restart()
            Motion.list { preview = nil; status = "Restore prepared. Vane is restarting." }
        } catch {
            if staged {
                do { try transaction.cancelPending(); restorePending = false }
                catch { self.error = "Restart failed, and the pending restore could not be cancelled: \(error.localizedDescription)"; return }
            }
            self.error = error.localizedDescription
            await reloadPointsAsync()
        }
    }
    func retryRecovery() async { await automaticRecovery(force: true) }
    func automaticRecovery(force: Bool = false, now: Date = .now) async {
        guard !busy, !restorePending, force || BackupSchedule.isDue(lastAttempt: lastAttempt, now: now) else { return }
        busy = true; lastAttempt = now
        defer { finish() }
        await Task.yield()
        do {
            guard flush() else { throw BackupError.saveFailed }
            let archive = try library.capture(reason: .automatic)
            _ = try await BackupRecovery(library: library).automaticPointIfChangedAsync(archive)
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
        await reloadPointsAsync()
    }
    func showExportPanel() {
        guard !busy, !restorePending else { return }
        let panel = NSSavePanel()
        panel.title = "Export Vane Backup"
        panel.nameFieldStringValue = "Vane Backup \(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).vanebackup"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(to: url) }
    }
    func showRestorePanel() {
        guard !busy, !restorePending else { return }
        let panel = NSOpenPanel()
        panel.title = "Preview Vane Backup"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await previewRestore(from: url) }
    }
    func reportLaunch(_ result: BackupRestore.Result) {
        switch result {
        case .restored: status = "Backup restored. Your previous data is in recovery points."
        case .rolledBack: status = "An interrupted restore was rolled back. Your previous data is safe."
        case .none: break
        }
    }
}

/// Launch the exact executable, including isolated test copies, after this process
/// exits. Successful helper creation is required before bypassing termination saves.
@MainActor enum BackupRestart {
    static func run() throws {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BackupError.storage("Vane could not locate its executable. Restart manually to apply the prepared restore.")
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; exec " + quote(executable.path)]
        helper.environment = ProcessInfo.processInfo.environment
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        // Only this restore path uses exit: normal termination would save the old
        // session once more. The helper preserves VANE_DATA_DIR and bundle identity.
        exit(0)
    }
}
