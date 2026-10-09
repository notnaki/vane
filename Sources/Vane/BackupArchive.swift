import Foundation
import CryptoKit
import Darwin

enum BackupError: LocalizedError {
    case invalid(String), futureVersion, tooLarge, storage(String), saveFailed, recoveryFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "This backup cannot be restored: \(detail)"
        case .futureVersion: "This backup needs a newer version of Vane."
        case .tooLarge: "This backup exceeds the 512 MB backup limit. No data was omitted."
        case .storage(let detail): detail
        case .saveFailed: "Current changes could not be saved. Resolve the save failure and try again."
        case .recoveryFailed(let detail): "Vane could not finish recovery. Your originals have been kept. \(detail)"
        }
    }
}

enum BackupReason: String, Codable, Sendable {
    case manual, automatic, beforeRestore
    var title: String {
        switch self { case .manual: "Export"; case .automatic: "Automatic"; case .beforeRestore: "Before restore" }
    }
}

struct BackupArchive: Codable, Sendable {
    struct File: Codable, Sendable, Equatable {
        var name: String
        var data: Data
        var digest: String
        init(name: String, data: Data) {
            self.name = name; self.data = data; digest = BackupCodec.digest(data)
        }
    }
    var format = "Vane.Backup"
    var version = 1
    var id = UUID()
    var created = Date.now
    var appVersion: String
    var reason: BackupReason
    var preferences: Data
    var preferenceDigest: String
    var files: [File]
    /// Raw originals from a damaged library remain available, but cannot be applied as
    /// a healthy library. They are separate from the transaction's exact rollback copy.
    var damage: String?

    init(preferences: Data, files: [File], reason: BackupReason = .manual, damage: String? = nil) {
        self.preferences = preferences; preferenceDigest = BackupCodec.digest(preferences)
        self.files = files; self.reason = reason; self.damage = damage
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
    }
}

enum BackupPaths {
    static func names(for id: UUID) -> Set<String> {
        let suffix = ProfileManager.suffix(id)
        return Set(["spaces\(suffix).json", "session\(suffix).json", "spacestate\(suffix).json",
                    "vane\(suffix).db", "easels-\(id.uuidString).json", "space-templates\(suffix).json"])
    }
    static func isOwned(_ name: String) -> Bool {
        if ReadingQueueFiles.parseOwnedName(name) != nil { return true }
        if name == "profiles.json" { return true }
        if name.hasPrefix("FilterLists/") {
            let part = String(name.dropFirst("FilterLists/".count))
            return part.hasSuffix(".txt") && UUID(uuidString: String(part.dropLast(4))) != nil
                && !part.contains("/") && !part.contains("\\")
        }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        for (prefix, ext) in [("spaces", ".json"), ("session", ".json"), ("spacestate", ".json"), ("vane", ".db"),
                              ("space-templates", ".json")] {
            if name == prefix + ext { return true }
            if name.hasPrefix(prefix + "-"), name.hasSuffix(ext) {
                let value = String(name.dropFirst(prefix.count + 1).dropLast(ext.count))
                if let id = UUID(uuidString: value), value == id.uuidString.lowercased(),
                   id != ProfileManager.defaultID { return true }
            }
        }
        if name.hasPrefix("easels-"), name.hasSuffix(".json") {
            let value = String(name.dropFirst(7).dropLast(5))
            return UUID(uuidString: value).map { value == $0.uuidString } ?? false
        }
        return false
    }
    static func isOriginal(_ name: String) -> Bool {
        if isOwned(name) { return true }
        // Operational fallback generations participate in exact restore rollback,
        // but are never accepted as extra files in a healthy exported backup.
        if name.hasSuffix(".previous") {
            let base = String(name.dropLast(".previous".count))
            if (base.hasPrefix("session") || base.hasPrefix("spacestate")), isOwned(base) { return true }
        }
        for suffix in ["-wal", "-shm"] where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if base.hasSuffix(".db"), isOwned(base) { return true }
        }
        return false
    }
}

enum BackupCodec {
    static let limit = 512 * 1024 * 1024
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func withinLimit(_ sizes: [Int]) -> Bool {
        var remaining = limit
        for size in sizes {
            guard size >= 0, size <= remaining else { return false }
            remaining -= size
        }
        return true
    }
    static func validate(_ archive: BackupArchive) throws {
        guard archive.format == "Vane.Backup", archive.version > 0 else { throw BackupError.invalid("Unknown format.") }
        guard archive.version == 1 else { throw BackupError.futureVersion }
        guard archive.created.timeIntervalSince1970.isFinite, archive.files.count <= 100_000,
              Set(archive.files.map(\.name)).count == archive.files.count,
              archive.files.allSatisfy({ archive.damage != nil && archive.reason == .beforeRestore
                  ? BackupPaths.isOriginal($0.name) : BackupPaths.isOwned($0.name) }),
              archive.preferenceDigest == digest(archive.preferences),
              archive.files.allSatisfy({ $0.digest == digest($0.data) }) else {
            throw BackupError.invalid("Invalid filenames, metadata, or damaged contents.")
        }
        guard withinLimit([archive.preferences.count] + archive.files.map { $0.data.count }) else { throw BackupError.tooLarge }
    }
    static func encode(_ archive: BackupArchive) throws -> Data {
        try validate(archive)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(archive)
        guard data.count <= limit else { throw BackupError.tooLarge }
        return data
    }
    static func decode(_ data: Data) throws -> BackupArchive {
        guard data.count <= limit else { throw BackupError.tooLarge }
        let archive: BackupArchive
        do { archive = try PropertyListDecoder().decode(BackupArchive.self, from: data) }
        catch { throw BackupError.invalid("The backup file could not be read.") }
        try validate(archive)
        return archive
    }
    static func read(_ url: URL) throws -> BackupArchive { try decode(BackupIO.read(url)) }
    static func write(_ archive: BackupArchive, to url: URL,
                      writer: (Data, URL) throws -> Void = BackupIO.write) throws {
        try BackupIO.checkFile(url, mayBeMissing: true)
        try writer(encode(archive), url)
    }
}

/// Private, durable replacement writes. The temp inode starts at 0600; fsync the
/// payload and its directory so a journal never promises bytes that only lived in RAM.
enum BackupIO {
    static func checkFile(_ url: URL, mayBeMissing: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if mayBeMissing && errno == ENOENT { return }
            throw posixError()
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw BackupError.storage("Choose a regular file; symbolic links are not supported.") }
    }
    static func directory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupError.storage("The recovery folder is not a regular directory.") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try syncDirectory(url.deletingLastPathComponent())
        }
    }
    static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw BackupError.storage("The backup source is not a regular file.") }
        guard info.st_size >= 0, info.st_size <= BackupCodec.limit else { throw BackupError.tooLarge }
        let data = try handle.read(upToCount: BackupCodec.limit + 1) ?? Data()
        guard data.count <= BackupCodec.limit else { throw BackupError.tooLarge }
        return data
    }
    static func write(_ data: Data, _ url: URL) throws {
        try checkFile(url, mayBeMissing: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw posixError() }
        try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw posixError() }
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func remove(_ url: URL) throws {
        try checkFile(url)
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }
    static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
