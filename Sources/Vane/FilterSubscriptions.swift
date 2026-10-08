import AppKit
import Combine
import Foundation

struct FilterSubscription: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var url: URL
    var text = ""
    var etag: String?
    var lastModified: String?
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastError: String?
    var report: BlockerReport?

    func isDue(at now: Date) -> Bool {
        if lastError != nil, let lastAttempt { return now.timeIntervalSince(lastAttempt) >= 3600 }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= 86400
    }
}

/// One atomic document commits metadata and accepted sources together. Local imports
/// deliberately never enter this store and are never fetched by the scheduler.
@MainActor final class FilterSubscriptions: ObservableObject {
    struct Response: Sendable {
        var status: Int
        var text: String = ""
        var etag: String?
        var lastModified: String?
    }
    private struct Document: Codable { var version = 1; var items: [FilterSubscription] }
    nonisolated static var directory: URL { Store.directory.appendingPathComponent("FilterSubscriptions", isDirectory: true) }
    static let shared = FilterSubscriptions(directory: directory, fetch: download,
        validate: { _ in }, transaction: { try await Blocker.commitSubscriptions($0, items: $1) }, changed: { Blocker.refresh() })

    @Published private(set) var items: [FilterSubscription] = []
    @Published private(set) var updating: Set<UUID> = []
    @Published private(set) var storageError: String?
    private let fetch: (FilterSubscription) async throws -> Response
    private let validate: (String) async throws -> Void
    private let persist: ([FilterSubscription]) throws -> Void
    private let changed: () -> Void
    private let transaction: ((String, [FilterSubscription]) async throws -> Void)?
    private let gate = BlockerAsyncGate()
    private var loadFailed = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(directory: URL, fetch: @escaping (FilterSubscription) async throws -> Response,
         validate: @escaping (String) async throws -> Void,
         persist: (([FilterSubscription]) throws -> Void)? = nil,
         transaction: ((String, [FilterSubscription]) async throws -> Void)? = nil, changed: @escaping () -> Void = {}) {
        self.fetch = fetch; self.validate = validate
        self.persist = persist ?? { try Self.write($0, directory: directory) }
        self.changed = changed; self.transaction = transaction
        do { items = try Self.read(directory: directory) }
        catch { loadFailed = true; storageError = error.localizedDescription }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updateDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.updateDue() }
            }
        Task { await updateDue() }
    }

    func add(_ url: URL) async throws {
        await gate.acquire()
        defer { gate.release() }
        guard !loadFailed else { throw BlockerFiles.Failure(storageError ?? "Restore the subscription store first.") }
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
            throw BlockerFiles.Failure("Use an HTTPS filter-list URL without a username, password, or fragment.")
        }
        guard !items.contains(where: { $0.url == url }) else { throw BlockerFiles.Failure("That URL is already subscribed.") }
        let item = FilterSubscription(url: url)
        let candidate = items + [item]
        try persist(candidate)
        items = candidate; storageError = nil
        await updateLocked(item.id)
    }

    func remove(_ id: UUID) async {
        await gate.acquire()
        defer { gate.release() }
        guard !loadFailed else { return }
        do {
            let candidate = items.filter { $0.id != id }
            try await commit(candidate)
            items = candidate; storageError = nil
            changed()
        } catch { storageError = error.localizedDescription }
    }

    func update(_ id: UUID) async {
        await gate.acquire()
        defer { gate.release() }
        await updateLocked(id)
    }

    func updateDue(now: Date = Date(), force: Bool = false) async {
        await gate.acquire()
        defer { gate.release() }
        for id in items.filter({ force || $0.isDue(at: now) }).map(\.id) { await updateLocked(id) }
    }

    private func updateLocked(_ id: UUID) async {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == id }) else { return }
        updating.insert(id)
        defer { updating.remove(id) }
        let accepted = items[index]
        var updated = accepted
        updated.lastAttempt = Date()
        do {
            let response = try await fetch(accepted)
            if response.status == 304 {
                guard !accepted.text.isEmpty else { throw BlockerFiles.Failure("The server returned Not Modified before a working list was saved. Retry the update.") }
            } else {
                let conversion = try await Task.detached(priority: .utility) {
                    let text = try Self.usableText(response)
                    return (text, Blocker.convert(text).report)
                }.value
                updated.text = conversion.0
                updated.report = conversion.1
                updated.etag = response.etag
                updated.lastModified = response.lastModified
            }
            updated.lastSuccess = Date(); updated.lastError = nil
            var candidate = items; candidate[index] = updated
            // Never change in-memory accepted text or validators before the write succeeds.
            if response.status == 304 { try persist(candidate) }
            else { try await commit(candidate) }
            items = candidate; storageError = nil
            changed()
        } catch {
            var failed = accepted
            failed.lastAttempt = updated.lastAttempt
            failed.lastError = error.localizedDescription
            var candidate = items; candidate[index] = failed
            do { try persist(candidate); items = candidate; storageError = nil }
            catch { storageError = error.localizedDescription }
        }
    }

    private func commit(_ candidate: [FilterSubscription]) async throws {
        let text = candidate.map(\.text).joined(separator: "\n")
        if let transaction { try await transaction(text, candidate) }
        else { try await validate(text); try persist(candidate) }
    }

    nonisolated static func usableText(_ response: Response) throws -> String {
        guard response.status == 200 else { throw BlockerFiles.Failure("Filter server returned HTTP \(response.status).") }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard balancedConditionals(text) else { throw BlockerFiles.Failure("Filter list contains unbalanced conditional directives. Previous rules remain active.") }
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw BlockerFiles.Failure("Filter list exceeds the 8 MB limit.") }
        guard !text.isEmpty, !text.lowercased().contains("<html"), !text.lowercased().contains("<!doctype html"),
              !text.contains("\0"), Blocker.convert(text).rules > 0 else {
            throw BlockerFiles.Failure("The response is not a usable UTF-8 filter list. Previous rules remain active.")
        }
        return text
    }

    private nonisolated static func balancedConditionals(_ text: String) -> Bool {
        var depth = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if") { depth += 1 }
            else if line.hasPrefix("!#endif") { depth -= 1; if depth < 0 { return false } }
            else if line.hasPrefix("!#else"), depth == 0 { return false }
        }
        return depth == 0
    }

    nonisolated static func read(directory: URL) throws -> [FilterSubscription] {
        let file = directory.appendingPathComponent("subscriptions.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else { throw BlockerFiles.Failure("Unsupported subscription storage version.") }
            return document.items
        } catch { throw BlockerFiles.Failure("Couldn’t read saved filter subscriptions. Restore subscriptions.json before changing subscriptions.") }
    }

    nonisolated static func write(_ items: [FilterSubscription], directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Document(items: items)).write(to: directory.appendingPathComponent("subscriptions.json"), options: .atomic)
    }

    nonisolated static func request(for item: FilterSubscription) -> URLRequest {
        var request = URLRequest(url: item.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if !item.text.isEmpty {
            if let etag = item.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = item.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        return request
    }

    /// Download to a temporary file to avoid buffering an unbounded response in memory.
    /// Use an ephemeral session: subscriptions don't send the browsing profile's cookies.
    nonisolated static func download(_ item: FilterSubscription) async throws -> Response {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: SecureFilterDownload(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let request = request(for: item)
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.url?.scheme?.lowercased() == "https" else {
            throw BlockerFiles.Failure("Filter server did not return a secure HTTP response.")
        }
        if http.statusCode == 304 { return Response(status: 304) }
        guard http.statusCode == 200 else { throw BlockerFiles.Failure("Filter server returned HTTP \(http.statusCode).") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw BlockerFiles.Failure("Filter list exceeds the 8 MB limit.") }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw BlockerFiles.Failure("Filter list is not UTF-8 text.")
        }
        return Response(status: 200, text: text, etag: http.value(forHTTPHeaderField: "ETag"),
                        lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}

/// Refuse redirects to HTTP or embedded credentials before sending a request there,
/// and bound the temporary download rather than only checking its final file size.
private final class SecureFilterDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 8 * 1024 * 1024 || totalBytesExpectedToWrite > 8 * 1024 * 1024 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
