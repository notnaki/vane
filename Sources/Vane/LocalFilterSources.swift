import AppKit
import Combine
import Darwin
import Foundation

/// Portable, owned last-good text only. Bookmarks/path grants never enter preferences
/// (and therefore never enter BackupLibrary's portable preferences or owned files).
struct LocalFilterSource: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var grantID = UUID()
    var text: String
    var enabled = true
    var automaticUpdates = true
    var report: BlockerReport
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastError: String?
}

@MainActor final class LocalFilterSources: ObservableObject {
    nonisolated static let snapshotsKey = "blockerLinkedSnapshots"
    nonisolated static var directory: URL { Store.directory.appendingPathComponent("LocalFilterSources", isDirectory: true) }
    static let shared = LocalFilterSources(defaults: .vane, directory: directory,
        transaction: { try await Blocker.commitLinkedSources($0) }, changed: { Blocker.refresh() })
    private struct Document: Codable { var version = 1; var items: [LocalFilterSource] }
    private struct Grant: Codable { var path: String; var bookmark: Data }
    // UserDefaults is thread-safe; Swift's Foundation overlay does not declare it
    // Sendable. Only its documented concurrent read/set/synchronize API crosses here.
    private struct Preferences: @unchecked Sendable { let defaults: UserDefaults }

    @Published private(set) var items: [LocalFilterSource] = []
    @Published private(set) var updating: Set<UUID> = []
    @Published private(set) var storageError: String?
    private let loading: Task<[LocalFilterSource], Error>
    private var loaded = false
    private var loadFailed = false
    private let directory: URL
    private let readSource: @Sendable (URL) throws -> String
    private let validate: (String) async throws -> Void
    private let persist: ([LocalFilterSource]) async throws -> Void
    private let transaction: (([LocalFilterSource]) async throws -> Void)?
    private let changed: () -> Void
    private let gate = BlockerAsyncGate()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var scheduledRefresh: Task<Void, Never>?

    init(defaults: UserDefaults, directory: URL,
         validate: @escaping (String) async throws -> Void = { _ in },
         readSource: @escaping @Sendable (URL) throws -> String = LocalFilterSources.readRegularText,
         persist: (([LocalFilterSource]) throws -> Void)? = nil,
         transaction: (([LocalFilterSource]) async throws -> Void)? = nil,
         changed: @escaping () -> Void = {}) {
        self.directory = directory; self.readSource = readSource; self.validate = validate; self.transaction = transaction; self.changed = changed
        let preferences = Preferences(defaults: defaults)
        loading = Task.detached(priority: .utility) { try Self.read(defaults: preferences.defaults) }
        if let persist { self.persist = { try persist($0) } }
        else {
            self.persist = { items in
                try await Task.detached(priority: .utility) { try Self.write(items, defaults: preferences.defaults) }.value
            }
        }
    }

    /// Must be called under gate; public load is for startup/settings and tests.
    private func finishLoading() async {
        guard !loaded else { return }
        do { items = try await loading.value }
        catch { storageError = error.localizedDescription; loadFailed = true }
        loaded = true
    }
    func load() async {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
    }

    /// Poll the pathname, not an inode: atomic editor replacement, missing files and
    /// repaired drives all recover. Only one bounded worker batch may be scheduled.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
        scheduleRefresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        scheduledRefresh?.cancel(); scheduledRefresh = nil
    }
    private func scheduleRefresh() {
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            await self?.refreshAll()
            self?.scheduledRefresh = nil
        }
    }

    func link(_ file: URL, replacing id: UUID? = nil) async throws {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
        try requireStorage()
        if let id, !items.contains(where: { $0.id == id }) { throw BlockerFiles.Failure("That linked source was removed.") }
        guard id != nil || items.count < 64 else { throw BlockerFiles.Failure("At most 64 local sources can be linked.") }
        let directory = directory, readSource = readSource
        let grantID = UUID()
        let prepared = try await Task.detached(priority: .utility) {
            let accessed = file.startAccessingSecurityScopedResource()
            defer { if accessed { file.stopAccessingSecurityScopedResource() } }
            let text = try readSource(file)
            let report = try Self.prepare(text)
            let grant = Grant(path: file.path, bookmark: try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
            try Self.writeGrant(grant, id: grantID, directory: directory)
            return (text, report)
        }.value
        var item = id.flatMap { id in items.first { $0.id == id } }
            ?? LocalFilterSource(name: file.lastPathComponent, text: prepared.0, report: prepared.1)
        let oldGrant = id == nil ? nil : item.grantID
        item.name = file.lastPathComponent; item.grantID = grantID
        item.text = prepared.0; item.report = prepared.1
        item.lastAttempt = Date(); item.lastSuccess = Date(); item.lastError = nil
        var candidate = items
        if let index = candidate.firstIndex(where: { $0.id == item.id }) { candidate[index] = item }
        else { candidate.append(item) }
        do { try await commit(candidate); items = candidate; storageError = nil; changed() }
        catch {
            await Self.removeGrant(grantID, directory: directory)
            throw error
        }
        if let oldGrant { await Self.removeGrant(oldGrant, directory: directory) }
    }

    func refreshAll() async {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
        guard !loadFailed else { return }
        for id in items.filter({ $0.enabled && $0.automaticUpdates }).map(\.id) {
            guard !Task.isCancelled else { break }
            await refreshLocked(id)
        }
    }
    func refresh(_ id: UUID) async {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
        await refreshLocked(id)
    }
    private func refreshLocked(_ id: UUID) async {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == id }) else { return }
        updating.insert(id); defer { updating.remove(id) }
        let accepted = items[index], directory = directory, readSource = readSource
        var updated = accepted
        updated.lastAttempt = Date()
        do {
            let result = try await Task.detached(priority: .utility) {
                let text = try Self.readLinked(accepted.grantID, directory: directory, readSource: readSource)
                return (text, try Self.prepare(text))
            }.value
            updated.text = result.0; updated.report = result.1
            updated.lastSuccess = Date(); updated.lastError = nil
            var candidate = items; candidate[index] = updated
            if updated.text == accepted.text { try await persist(candidate) }
            else { try await commit(candidate) }
            items = candidate; storageError = nil
            if updated.text != accepted.text { changed() }
        } catch {
            // Neither accepted text nor its timestamps change before compilation and
            // durable publication succeed. Save error status without losing that text.
            var failed = accepted
            failed.lastAttempt = updated.lastAttempt; failed.lastError = error.localizedDescription
            var candidate = items; candidate[index] = failed
            do { try await persist(candidate); items = candidate; storageError = nil }
            catch { storageError = error.localizedDescription }
        }
    }

    func setAutomaticUpdates(_ id: UUID, enabled: Bool) async {
        await change(id, compiles: false) { $0.automaticUpdates = enabled }
    }
    func setEnabled(_ id: UUID, enabled: Bool) async {
        await change(id) { $0.enabled = enabled }
    }
    private func change(_ id: UUID, compiles: Bool = true, update: (inout LocalFilterSource) -> Void) async {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var candidate = items; update(&candidate[index])
        do {
            if compiles { try await commit(candidate) } else { try await persist(candidate) }
            items = candidate; storageError = nil
            if compiles { changed() }
        } catch { storageError = error.localizedDescription }
    }
    func remove(_ id: UUID) async {
        await gate.acquire(); defer { gate.release() }
        await finishLoading()
        guard !loadFailed, let item = items.first(where: { $0.id == id }) else { return }
        let candidate = items.filter { $0.id != id }
        do {
            try await commit(candidate); items = candidate; storageError = nil; changed()
            await Self.removeGrant(item.grantID, directory: directory)
        } catch { storageError = error.localizedDescription }
    }
    private func requireStorage() throws {
        if loadFailed { throw BlockerFiles.Failure(storageError ?? "Restore saved linked sources before changing them.") }
    }
    private func commit(_ candidate: [LocalFilterSource]) async throws {
        if let transaction { try await transaction(candidate) }
        else {
            let text = await Task.detached(priority: .utility) { candidate.filter(\.enabled).map(\.text).joined(separator: "\n") }.value
            try await validate(text)
            try await persist(candidate)
        }
    }

    nonisolated static func read(defaults: UserDefaults) throws -> [LocalFilterSource] {
        guard let value = defaults.object(forKey: snapshotsKey) else { return [] }
        guard let data = value as? Data else { throw BlockerFiles.Failure("The saved linked filter document is damaged. Restore its settings before changing sources.") }
        guard data.count <= 192 * 1024 * 1024 else { throw BlockerFiles.Failure("Saved linked sources exceed the storage limit.") }
        do {
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1, doc.items.count <= 64,
                  Set(doc.items.map(\.id)).count == doc.items.count,
                  doc.items.allSatisfy({ $0.text.utf8.count <= BlockerFiles.sourceByteLimit }) else {
                throw BlockerFiles.Failure("Invalid linked source document.")
            }
            try admitSnapshots(doc.items)
            return doc.items
        } catch { throw BlockerFiles.Failure("Couldn’t read saved linked filter sources. Restore their settings before changing them.") }
    }
    nonisolated static func write(_ items: [LocalFilterSource], defaults: UserDefaults) throws {
        try admitSnapshots(items)
        let data = try JSONEncoder().encode(Document(items: items))
        let previous = defaults.data(forKey: snapshotsKey)
        defaults.set(data, forKey: snapshotsKey)
        guard defaults.synchronize() else {
            if let previous { defaults.set(previous, forKey: snapshotsKey) }
            else { defaults.removeObject(forKey: snapshotsKey) }
            throw BlockerFiles.Failure("Couldn’t save linked filter sources. Previous rules remain active.")
        }
    }
    private nonisolated static func admitSnapshots(_ items: [LocalFilterSource]) throws {
        guard items.count <= 64, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.text.utf8.count <= BlockerFiles.sourceByteLimit }),
              items.reduce(0, { $0 + $1.text.utf8.count }) <= 64 * 1024 * 1024 else {
            throw BlockerFiles.Failure("Linked snapshots, including disabled sources, exceed the 64 MB storage limit.")
        }
    }
    private nonisolated static func prepare(_ text: String) throws -> BlockerReport {
        _ = try FilterSubscriptions.usableText(.init(status: 200, text: text))
        return try Blocker.convertBoundedSources([text]).report
    }
    private nonisolated static func grantURL(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }
    private nonisolated static func writeGrant(_ grant: Grant, id: UUID, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(grant).write(to: grantURL(id, directory: directory), options: .atomic)
    }
    private nonisolated static func removeGrant(_ id: UUID, directory: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: grantURL(id, directory: directory)) }.value
    }
    private nonisolated static func readLinked(_ id: UUID, directory: URL, readSource: @Sendable (URL) throws -> String) throws -> String {
        let grant: Grant
        do {
            let url = grantURL(id, directory: directory)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 else { throw BlockerFiles.Failure("Invalid file access record.") }
            grant = try JSONDecoder().decode(Grant.self, from: Data(contentsOf: url))
        } catch { throw BlockerFiles.Failure("File access is unavailable. Relink this source to grant access; its last working rules remain active.") }
        var stale = false
        let scoped = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        let accessed = scoped.startAccessingSecurityScopedResource()
        defer { if accessed { scoped.stopAccessingSecurityScopedResource() } }
        // Reopen the exact selected pathname, never follow the old inode to a trashed
        // editor backup. Renew stale bookmarks only while the prior scope is held.
        let file = URL(fileURLWithPath: grant.path)
        let text = try readSource(file)
        if stale {
            let renewed = Grant(path: grant.path, bookmark: try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
            try writeGrant(renewed, id: id, directory: directory)
        }
        return text
    }

    /// Nonblocking open plus fstat prevents a selected path replaced by a pipe/device
    /// from trapping a worker indefinitely. Reads are bounded even if it grows.
    nonisolated static func readRegularText(_ file: URL) throws -> String {
        let fd = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw BlockerFiles.Failure("The linked filter file is unavailable. Restore it or choose Relink.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw BlockerFiles.Failure("Linked filter sources must be regular files, not symbolic links or devices.")
        }
        guard before.st_size <= BlockerFiles.sourceByteLimit else { throw BlockerFiles.Failure("Filter list exceeds the 8 MB limit.") }
        var data = Data()
        while data.count <= BlockerFiles.sourceByteLimit {
            let chunk = try handle.read(upToCount: min(64 * 1024, BlockerFiles.sourceByteLimit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var after = stat()
        guard data.count <= BlockerFiles.sourceByteLimit, fstat(fd, &after) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BlockerFiles.Failure("The filter file changed during reading or exceeded 8 MB. Retry after saving it.")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BlockerFiles.Failure("Filter list is not UTF-8 text.") }
        return text
    }
}
