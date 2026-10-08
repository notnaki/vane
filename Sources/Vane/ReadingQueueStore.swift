import Foundation
import Combine

struct ReadingQueueDamage: Identifiable { var id: UUID; var message: String }
struct ReadingQueueUsage { var articleCount = 0; var publishedBytes: Int64 = 0; var pendingCleanupBytes: Int64 = 0 }

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
        if let store = stores.removeValue(forKey: key) { store.invalidated = true; store.articles = []; store.damaged = [] }
        try ReadingQueueFiles.checkRoot(directory)
        if ReadingQueueFiles.exists(key) { try ReadingQueueFiles.check(key, directory: true); try FileManager.default.removeItem(at: key) }
    }
    let profileID: UUID
    let directory: URL
    @Published private(set) var articles: [ReadingArticle] = []
    @Published private(set) var damaged: [ReadingQueueDamage] = []
    @Published private(set) var usage = ReadingQueueUsage()
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    private(set) var invalidated = false
    private let checkpoint: (String) throws -> Void
    init(profileID: UUID, directory: URL, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
        guard profileID != Profile.incognito.id else { throw ReadingQueueFailure.privateBrowsing }
        self.profileID = profileID; self.directory = directory; self.checkpoint = checkpoint
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
    func reload() {
        guard !invalidated else { return }
        do {
            try ReadingQueueFiles.checkRoot(directory)
            try ReadingQueueFiles.check(profileURL, directory: true, mayBeMissing: true)
            var fresh: [ReadingArticle] = [], damage: [ReadingQueueDamage] = [], size: Int64 = 0
            if ReadingQueueFiles.exists(profileURL) {
                let entries = try FileManager.default.contentsOfDirectory(at: profileURL, includingPropertiesForKeys: nil)
                guard entries.count <= ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
                for entry in entries {
                    guard let id = ReadingQueueFiles.canonicalUUID(entry.lastPathComponent) else { throw ReadingQueueFailure.invalid("Unexpected reading queue folder.") }
                    do {
                        let files = try ReadingQueueFiles.articleFiles(entry)
                        size += try ReadingQueueFiles.bytes(files)
                        fresh.append(try ReadingQueueFiles.load(entry, profileID: profileID, articleID: id).article)
                    } catch { damage.append(.init(id: id, message: error.localizedDescription)) }
                }
            }
            var residual: Int64 = 0, cleanupError: String?
            if ReadingQueueFiles.exists(staging.deletingLastPathComponent()) {
                try ReadingQueueFiles.check(staging.deletingLastPathComponent(), directory: true)
                if ReadingQueueFiles.exists(staging) {
                    try ReadingQueueFiles.check(staging, directory: true)
                    for item in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                        do { try ReadingQueueFiles.check(item, directory: true); try FileManager.default.removeItem(at: item) }
                        catch {
                            residual += (try? ReadingQueueFiles.bytes(ReadingQueueFiles.articleFiles(item))) ?? 0
                            cleanupError = "Some unfinished files could not be removed. Choose Retry. \(error.localizedDescription)"
                        }
                    }
                }
            }
            Motion.list {
                articles = fresh.sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt }
                damaged = damage.sorted { $0.id.uuidString < $1.id.uuidString }
                usage = .init(articleCount: fresh.count + damage.count, publishedBytes: size, pendingCleanupBytes: residual)
                error = cleanupError; revision &+= 1
            }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func publish(_ candidate: ReadingQueueCandidate) throws -> ReadingArticle {
        guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        guard candidate.article.profileID == profileID else { throw ReadingQueueFailure.invalid("The article belongs to another profile.") }
        if let duplicate = articles.first(where: { $0.sourceURL == candidate.article.sourceURL }) { return duplicate }
        guard error == nil else { throw ReadingQueueFailure.storage(error!) }
        try ReadingArticleCodec.validate(candidate)
        try ready()
        guard try FileManager.default.contentsOfDirectory(atPath: profileURL.path).count < ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
        let target = ReadingQueueFiles.articleURL(profileID: profileID, articleID: candidate.article.id, in: directory)
        guard !ReadingQueueFiles.exists(target) else { throw ReadingQueueFailure.invalid("This article identity already exists.") }
        let stage = staging.appendingPathComponent(UUID().uuidString.lowercased())
        try ReadingQueueFiles.ensureDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try checkpoint("stage")
        let record = try ReadingArticleCodec.encode(candidate.article)
        try record.write(to: stage.appendingPathComponent("article.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("article.json").path)
        if !candidate.images.isEmpty {
            let images = stage.appendingPathComponent("images"); try ReadingQueueFiles.ensureDirectory(images)
            for (name, data) in candidate.images {
                let file = images.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        _ = try ReadingQueueFiles.load(stage, profileID: profileID, articleID: candidate.article.id)
        try checkpoint("publish")
        try FileManager.default.moveItem(at: stage, to: target)
        reload()
        return candidate.article
    }
    func setRead(_ read: Bool, id: UUID) throws {
        guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        guard var article = articles.first(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        let folder = ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory)
        try ReadingQueueFiles.checkRoot(directory); try ReadingQueueFiles.check(profileURL, directory: true)
        _ = try ReadingQueueFiles.load(folder, profileID: profileID, articleID: id)
        article.isRead = read
        let data = try ReadingArticleCodec.encode(article)
        try checkpoint("read-state")
        try data.write(to: folder.appendingPathComponent("article.json"), options: .atomic)
        reload()
    }
    func remove(_ id: UUID) throws {
        guard !invalidated else { throw ReadingQueueFailure.staleCapture }
        guard articles.contains(where: { $0.id == id }) || damaged.contains(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        try ready()
        let folder = ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory)
        try ReadingQueueFiles.check(folder, directory: true)
        try checkpoint("delete")
        let trash = staging.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.moveItem(at: folder, to: trash)
        reload()
    }
    func candidate(_ id: UUID) throws -> ReadingQueueCandidate {
        guard !invalidated, articles.contains(where: { $0.id == id }) else { throw ReadingQueueFailure.missing }
        try ReadingQueueFiles.checkRoot(directory); try ReadingQueueFiles.check(profileURL, directory: true)
        return try ReadingQueueFiles.load(ReadingQueueFiles.articleURL(profileID: profileID, articleID: id, in: directory), profileID: profileID, articleID: id)
    }
    func bytes(for article: ReadingArticle) -> Int64 {
        Int64((try? ReadingArticleCodec.encode(article).count) ?? 0) + article.resources.reduce(0) { $0 + Int64($1.byteCount) }
    }
}
