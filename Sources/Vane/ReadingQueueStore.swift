import Foundation
import Combine

struct ReadingQueueDamage: Identifiable, Sendable { var id: UUID; var message: String }
struct ReadingQueueUsage: Sendable { var articleCount = 0; var publishedBytes: Int64 = 0; var pendingCleanupBytes: Int64 = 0 }
private struct ReadingQueueScan: Sendable {
    var articles: [ReadingArticle] = []
    var damaged: [ReadingQueueDamage] = []
    var sizes: [UUID: Int64] = [:]
    var pendingBytes: Int64 = 0
    var cleanupError: String?
}

@MainActor final class ReadingQueueStore: ObservableObject {
    private static var stores: [URL: ReadingQueueStore] = [:]
    static func shared(profileID: UUID, directory: URL) throws -> ReadingQueueStore {
        guard profileID != Profile.incognito.id else { throw ReadingQueueFailure.privateBrowsing }
        let key = ReadingQueueFiles.profileURL(profileID, in: directory).standardizedFileURL
        if let store = stores[key] { return store }
        let store = try ReadingQueueStore(profileID: profileID, directory: directory)
        stores[key] = store; return store
    }
    static func forget(profileID: UUID, directory: URL) throws {
        guard profileID != Profile.incognito.id else { return }
        let key = ReadingQueueFiles.profileURL(profileID, in: directory).standardizedFileURL
        if let store = stores.removeValue(forKey: key) {
            store.invalidated = true; store.loadTask?.cancel(); store.articles = []; store.damaged = []
        }
        SavedReaderWindow.forget(profileID: profileID)
        try ReadingQueueFiles.checkRoot(directory)
        if ReadingQueueFiles.exists(key) { try ReadingQueueFiles.check(key, directory: true); try FileManager.default.removeItem(at: key) }
        let stagingRoot = ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging")
        try ReadingQueueFiles.check(stagingRoot, directory: true, mayBeMissing: true)
        let pending = stagingRoot.appendingPathComponent(profileID.uuidString.lowercased())
        if ReadingQueueFiles.exists(pending) { try ReadingQueueFiles.check(pending, directory: true); try FileManager.default.removeItem(at: pending) }
    }
    let profileID: UUID
    let directory: URL
    @Published private(set) var articles: [ReadingArticle] = []
    @Published private(set) var damaged: [ReadingQueueDamage] = []
    @Published private(set) var usage = ReadingQueueUsage()
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    private(set) var invalidated = false
    private let checkpoint: (String) throws -> Void
    private let scanCheckpoint: @Sendable () throws -> Void
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var sizes: [UUID: Int64] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var needsReload = false
    init(profileID: UUID, directory: URL, checkpoint: @escaping (String) throws -> Void = { _ in },
         scanCheckpoint: @escaping @Sendable () throws -> Void = {}) throws {
        guard profileID != Profile.incognito.id else { throw ReadingQueueFailure.privateBrowsing }
        self.profileID = profileID; self.directory = directory; self.checkpoint = checkpoint; self.scanCheckpoint = scanCheckpoint
        try ReadingQueueFiles.checkRoot(directory)
        try ReadingQueueFiles.check(ReadingQueueFiles.profileURL(profileID, in: directory), directory: true, mayBeMissing: true)
        reload()
    }
    private var profileURL: URL { ReadingQueueFiles.profileURL(profileID, in: directory) }
    private var staging: URL { ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging").appendingPathComponent(profileID.uuidString.lowercased()) }
    private func ready() throws {
        guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        try ReadingQueueFiles.prepareRoot(directory)
        try ReadingQueueFiles.ensureDirectory(profileURL)
        try ReadingQueueFiles.ensureDirectory(staging.deletingLastPathComponent())
        try ReadingQueueFiles.ensureDirectory(staging)
    }
    func waitUntilReady() async {
        while let task = loadTask { await task.value }
    }
    private func acquire(allowError: Bool = false) async throws {
        while true {
            await waitUntilReady()
            try Task.checkCancellation()
            guard !invalidated else { throw ReadingQueueFailure.staleCapture }
            if busy { await withCheckedContinuation { waiters.append($0) }; continue }
            if !allowError, let error { throw ReadingQueueFailure.storage(error) }
            busy = true; return
        }
    }
    private func release() {
        busy = false
        if needsReload { needsReload = false; reload() }
        let pending = waiters; waiters = []; pending.forEach { $0.resume() }
    }
    /// Only scans unpublished staging and immutable snapshots. Inventory mutations wait
    /// for this worker; final publication/removal stays on the main actor with backup.
    func reload() {
        guard !invalidated else { return }
        if busy { needsReload = true; return }
        loadTask?.cancel(); loadID = UUID()
        let asked = loadID, profile = profileID, directory = directory, inspection = scanCheckpoint
        loading = true
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try inspection()
                return try Self.scan(profileID: profile, directory: directory)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, self.loadID == asked else { return }
            defer { self.loading = false; self.loadTask = nil }
            guard !self.invalidated, !Task.isCancelled else { return }
            switch result {
            case .success(let scan):
                Motion.list {
                    self.articles = Self.sorted(scan.articles); self.damaged = scan.damaged.sorted { $0.id.uuidString < $1.id.uuidString }
                    self.sizes = scan.sizes
                    self.usage = .init(articleCount: scan.articles.count + scan.damaged.count,
                        publishedBytes: scan.sizes.values.reduce(0, +), pendingCleanupBytes: scan.pendingBytes)
                    self.error = scan.cleanupError; self.revision &+= 1
                }
            case .failure(let failure): self.error = failure.localizedDescription
            }
        }
    }
    private nonisolated static func scan(profileID: UUID, directory: URL) throws -> ReadingQueueScan {
        try Task.checkCancellation()
        try ReadingQueueFiles.checkRoot(directory)
        let profile = ReadingQueueFiles.profileURL(profileID, in: directory)
        try ReadingQueueFiles.check(profile, directory: true, mayBeMissing: true)
        var result = ReadingQueueScan()
        if ReadingQueueFiles.exists(profile) {
            let entries = try FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)
            guard entries.count <= ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
            for entry in entries {
                try Task.checkCancellation()
                guard let id = ReadingQueueFiles.canonicalUUID(entry.lastPathComponent) else { throw ReadingQueueFailure.invalid("Unexpected reading queue folder.") }
                result.sizes[id] = try ReadingQueueFiles.diskBytes(entry)
                do { result.articles.append(try ReadingQueueFiles.load(entry, profileID: profileID, articleID: id).article) }
                catch { result.damaged.append(.init(id: id, message: error.localizedDescription)) }
            }
        }
        let stagingRoot = ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging")
        if ReadingQueueFiles.exists(stagingRoot) {
            try ReadingQueueFiles.check(stagingRoot, directory: true)
            let staging = stagingRoot.appendingPathComponent(profileID.uuidString.lowercased())
            if ReadingQueueFiles.exists(staging) {
                try ReadingQueueFiles.check(staging, directory: true)
                for item in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    do { try FileManager.default.removeItem(at: item) }
                    catch {
                        result.pendingBytes += (try? ReadingQueueFiles.diskBytes(item)) ?? 0
                        result.cleanupError = "Some unfinished files could not be removed. Choose Retry. \(error.localizedDescription)"
                    }
                }
            }
        }
        return result
    }
    private nonisolated static func sorted(_ articles: [ReadingArticle]) -> [ReadingArticle] {
        articles.sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt }
    }
    @discardableResult func publish(_ candidate: ReadingQueueCandidate, validity: () throws -> Void = {}) async throws -> ReadingArticle {
        try await acquire(); defer { release() }
        try validity()
        guard candidate.article.profileID == profileID else { throw ReadingQueueFailure.invalid("The article belongs to another profile.") }
        if let duplicate = articles.first(where: { $0.sourceURL == candidate.article.sourceURL }) { return duplicate }
        guard articles.count + damaged.count < ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
        try ready()
        let target = ReadingQueueFiles.articleURL(profileID: profileID, articleID: candidate.article.id, in: directory)
        guard !ReadingQueueFiles.exists(target) else { throw ReadingQueueFailure.invalid("This article identity already exists.") }
        let stage = staging.appendingPathComponent(UUID().uuidString.lowercased())
        try ReadingQueueFiles.ensureDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try checkpoint("stage")
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation(); try ReadingArticleCodec.validate(candidate)
            let record = try ReadingArticleCodec.encode(candidate.article)
            try record.write(to: stage.appendingPathComponent("article.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("article.json").path)
            if !candidate.images.isEmpty {
                let images = stage.appendingPathComponent("images"); try ReadingQueueFiles.ensureDirectory(images)
                for (name, data) in candidate.images {
                    try Task.checkCancellation()
                    let file = images.appendingPathComponent(name)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }
            _ = try ReadingQueueFiles.load(stage, profileID: candidate.article.profileID, articleID: candidate.article.id)
            return Int64(record.count + candidate.images.values.reduce(0) { $0 + $1.count })
        }
        let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try validity()
        guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        try ReadingQueueFiles.checkRoot(directory); try ReadingQueueFiles.check(profileURL, directory: true)
        try ReadingQueueFiles.check(stage, directory: true)
        guard try FileManager.default.contentsOfDirectory(atPath: profileURL.path).count < ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
        try checkpoint("publish")
        try FileManager.default.moveItem(at: stage, to: target)
        Motion.list {
            articles = Self.sorted(articles + [candidate.article]); sizes[candidate.article.id] = bytes
            usage.articleCount += 1; usage.publishedBytes += bytes; revision &+= 1
        }
        return candidate.article
    }
    func setRead(_ read: Bool, id: UUID) async throws {
        try await acquire(allowError: true); defer { release() }
        guard articles.contains(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        let folder = ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory), profile = profileID
        let worker = Task.detached(priority: .userInitiated) {
            var candidate = try ReadingQueueFiles.load(folder, profileID: profile, articleID: id)
            candidate.article.isRead = read
            let bytes = try ReadingArticleCodec.encode(candidate.article)
            return (candidate.article, bytes, Int64(bytes.count + candidate.images.values.reduce(0) { $0 + $1.count }))
        }
        let (article, data, bytes) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        try ReadingQueueFiles.checkRoot(directory); try ReadingQueueFiles.check(profileURL, directory: true)
        try ReadingQueueFiles.check(folder, directory: true)
        try ReadingQueueFiles.check(folder.appendingPathComponent("article.json"), directory: false)
        try checkpoint("read-state")
        try data.write(to: folder.appendingPathComponent("article.json"), options: .atomic)
        Motion.list {
            usage.publishedBytes += bytes - (sizes[id] ?? 0); sizes[id] = bytes
            if let index = articles.firstIndex(where: { $0.id == id }) { articles[index] = article }
            revision &+= 1
        }
    }
    func remove(_ id: UUID) async throws {
        try await acquire(allowError: true); defer { release() }
        guard articles.contains(where: { $0.id == id }) || damaged.contains(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        try ready()
        let folder = ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory)
        // Move the owned entry itself, including damaged regular files or links.
        // Root/profile/staging parents are checked; rename and removal do not follow it.
        guard ReadingQueueFiles.exists(folder) else { throw ReadingQueueFailure.missing }
        try checkpoint("delete")
        let trash = staging.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.moveItem(at: folder, to: trash)
        let removedBytes = sizes[id] ?? 0
        SavedReaderWindow.close(articleID: id, profileID: profileID)
        Motion.list {
            articles.removeAll { $0.id == id }; damaged.removeAll { $0.id == id }; sizes[id] = nil
            usage.articleCount -= 1; usage.publishedBytes -= removedBytes
            usage.pendingCleanupBytes += removedBytes; revision &+= 1
        }
        let (failure, remaining) = await Task.detached(priority: .utility) { () -> (String?, Int64) in
            do { try FileManager.default.removeItem(at: trash); return (nil, 0) }
            catch { return (error.localizedDescription, (try? ReadingQueueFiles.diskBytes(trash)) ?? removedBytes) }
        }.value
        guard !invalidated else { return }
        usage.pendingCleanupBytes += remaining - removedBytes
        if let failure { error = "Some removed files could not be cleaned up. Choose Retry. \(failure)" }
    }
    func candidate(_ id: UUID) async throws -> ReadingQueueCandidate {
        try await acquire(allowError: true); defer { release() }
        guard articles.contains(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        try ReadingQueueFiles.checkRoot(directory); try ReadingQueueFiles.check(profileURL, directory: true)
        let folder = ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory), profile = profileID
        let worker = Task.detached(priority: .userInitiated) { try ReadingQueueFiles.load(folder, profileID: profile, articleID: id) }
        let candidate = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        return candidate
    }
    func bytes(for article: ReadingArticle) -> Int64 { sizes[article.id] ?? 0 }
}
