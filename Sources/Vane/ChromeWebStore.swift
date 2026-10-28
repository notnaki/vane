import Foundation
import Synchronization

struct ChromeWebStore: Codable, Equatable, Sendable {
    let id: String
    var checkedAt: Date? = nil
    var key: String { "/chrome-web-store/" + id }
    var isValid: Bool { Self.validID(id) }
    var listingURL: URL { URL(string: "https://chromewebstore.google.com/detail/" + id)! }

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    init(input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.validID(text) { id = text; return }
        guard let url = URL(string: text), Self.isStoreURL(url) else {
            throw Failure(detail: "Paste a Chrome Web Store extension link or its 32-letter extension ID.")
        }
        let parts = url.path.components(separatedBy: "/")
        guard (parts.count == 3 || parts.count == 4), parts[1] == "detail",
              let candidate = parts.last, Self.validID(candidate), !parts.dropFirst().contains("") else {
            throw Failure(detail: "Open an extension’s detail page in the Chrome Web Store and copy its link.")
        }
        id = candidate
    }

    static func validID(_ id: String) -> Bool { id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) } }
    static func isStoreURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "chromewebstore.google.com"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    var downloadURL: URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "150.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")]
        return components.url!
    }

    static func trustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["clients2.google.com", "clients2.googleusercontent.com"].contains(url.host ?? "")
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func version(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count) else { return nil }
            let values = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(part), number <= 65_535 else { return nil }
                return number
            }
            guard values.count == parts.count else { return nil }
            return values + Array(repeating: 0, count: 4 - values.count)
        }
        guard let candidate = version(candidate), let current = version(current) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }

    /// Caller owns the private workspace and removes it on every outcome.
    func prepare(in workspace: URL) async throws -> URL {
        guard isValid else { throw Failure(detail: "The saved store extension ID is invalid.") }
        let cancellation = Mutex<(cancelled: Bool, download: UpdateDownload?)>((false, nil))
        let package = workspace.appendingPathComponent("extension.crx")
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                do {
                    let download = try UpdateDownload.start(url: downloadURL, destination: package,
                        maxBytes: Int64(ChromeExtensionPackage.maximumBytes), trusted: Self.trustedDownload) {
                            continuation.resume(with: $0)
                        }
                    cancellation.withLock { state in
                        state.download = download
                        if state.cancelled { download.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            cancellation.withLock { state in state.cancelled = true; state.download?.cancel() }
        }
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            let zip = try ChromeExtensionPackage.verifiedZIP(Data(contentsOf: package, options: .mappedIfSafe), id: id)
            let archive = workspace.appendingPathComponent("extension.zip")
            try zip.write(to: archive, options: .withoutOverwriting)
            var limits = UpdateArchive.Limits()
            limits.compressedBytes = Int64(ChromeExtensionPackage.maximumBytes)
            limits.fileBytes = Int64(ExtensionCodeStore.fileLimit)
            limits.totalBytes = Int64(ExtensionCodeStore.totalLimit)
            limits.entries = ExtensionCodeStore.entryLimit
            let folder = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try UpdateArchive.extract(zip: archive, to: folder, limits: limits)
            return folder
        }.value
    }
}
