import Foundation
import Darwin

/// Accepted extension code belongs to the profile, independently of the source bookmark.
/// Revision names and identities are UUIDs; no manifest-controlled path is a store path.
struct ExtensionCodeStore: Sendable {
    struct Record: Codable, Sendable {
        var identity: String
        var revision: String
        var sourcePath: String
        var name: String
        var version: String
        var summary: String
        var required: ExtensionAccess
        var optional: ExtensionAccess
        var compatibility: [String]
        var integratedCapabilities: Set<String>? = nil
    }

    struct Stage: Sendable {
        let revision: String
        let url: URL
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = detail }
    }

    static let fileLimit = 64 * 1024 * 1024
    static let totalLimit = 256 * 1024 * 1024
    static let entryLimit = 20_000
    let root: URL

    init(profileID: UUID, directory: URL = Store.directory) {
        root = directory.appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    private var index: URL { root.appendingPathComponent("installations.json") }

    func records() throws -> [String: Record] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [:] }
        try checkDirectory(root)
        let data = try readRegular(index, limit: 4 * 1024 * 1024)
        let records = try JSONDecoder().decode([String: Record].self, from: data)
        try validate(records)
        return records
    }

    private func validate(_ records: [String: Record]) throws {
        guard records.count <= 1000,
              Set(records.values.map { $0.identity.lowercased() }).count == records.count,
              Set(records.values.map { $0.revision.lowercased() }).count == records.count,
              records.values.allSatisfy({ UUID(uuidString: $0.identity) != nil && UUID(uuidString: $0.revision) != nil }) else {
            throw Problem("Saved extension metadata is invalid or exceeds the 1,000 installation limit. Your extension files have been retained.")
        }
    }

    func code(for record: Record) -> URL {
        root.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(record.revision, isDirectory: true)
    }

    /// Called after candidate validation/activation. Atomic index replacement selects the
    /// accepted revision. The previous code remains available until the caller finishes.
    func save(_ records: [String: Record]) throws {
        try validate(records)
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        guard data.count <= 4 * 1024 * 1024 else { throw Problem("There are too many saved extensions to save this change.") }
        // No fallible operation follows the commit point: a reported save failure must
        // never leave the index pointing at a candidate the caller will discard.
        let temporary = root.appendingPathComponent("index-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, index.path) == 0 else {
            throw Problem("The accepted extension could not be saved. Check profile storage permissions and retry; the previous version is retained.")
        }
    }

    /// Preserve unreadable metadata before an explicitly reviewed repair replaces it.
    /// Move the entry itself, without following a symlink or reading unbounded data.
    func retainUnusableIndex() throws {
        try prepare()
        var info = stat()
        if lstat(index.path, &info) != 0 {
            if errno == ENOENT { return }
            throw Problem("Saved extension metadata could not be retained. Check profile storage permissions and retry.")
        }
        let recovery = root.appendingPathComponent("metadata-recovery-" + UUID().uuidString.lowercased())
        guard rename(index.path, recovery.path) == 0 else {
            throw Problem("Saved extension metadata could not be retained. Check profile storage permissions and retry.")
        }
    }

    func stage(_ source: URL) throws -> Stage {
        try prepare()
        let revision = UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        // The bookmark's resolved root is allowed; internal links are never followed.
        let sourceFD = open(source.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            throw Problem("The source folder is missing or unreadable. Reconnect its disk or choose Update from Folder to locate it again.")
        }
        defer { close(sourceFD) }
        var budget = Budget()
        try copyDirectory(sourceFD, to: destination, depth: 0, budget: &budget)
        committed = true
        return Stage(revision: revision, url: destination)
    }

    func discard(_ stage: Stage) { try? FileManager.default.removeItem(at: stage.url) }
    func discard(_ record: Record) {
        guard UUID(uuidString: record.revision) != nil else { return }
        try? FileManager.default.removeItem(at: code(for: record))
    }

    static func removeProfile(_ profileID: UUID, directory: URL = Store.directory) throws {
        let store = Self(profileID: profileID, directory: directory)
        if FileManager.default.fileExists(atPath: store.root.path) {
            try store.checkDirectory(store.root)
            try FileManager.default.removeItem(at: store.root)
        }
    }

    private func prepare() throws {
        let parent = root.deletingLastPathComponent()
        for directory in [parent, root, root.appendingPathComponent("revisions", isDirectory: true)] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                catch { try checkDirectory(directory) }
            }
            try checkDirectory(directory)
        }
    }

    private func checkDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Problem("Vane’s extension storage is unavailable or is a symbolic link. Restore the profile’s Extensions folder and retry.")
        }
    }

    private struct Budget {
        var entries = 0
        var bytes = 0
    }

    /// Walk using directory descriptors and openat(O_NOFOLLOW), rather than reopening
    /// enumerated paths. Replacing a parent with a symlink cannot redirect a later read.
    private func copyDirectory(_ sourceFD: Int32, to destination: URL, depth: Int, budget: inout Budget) throws {
        guard depth <= 64 else { throw Problem("The extension has too many nested folders (maximum 64 levels).") }
        let listingFD = dup(sourceFD)
        guard listingFD >= 0 else { throw Problem("The source folder could not be read. Check its permissions and retry.") }
        guard let listing = fdopendir(listingFD) else {
            close(listingFD)
            throw Problem("The source folder could not be read. Check its permissions and retry.")
        }
        defer { closedir(listing) }
        while true {
            errno = 0
            guard let entry = readdir(listing) else {
                guard errno == 0 else { throw Problem("A source folder became unreadable during import. Retry when its disk is available.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            budget.entries += 1
            guard budget.entries <= Self.entryLimit else { throw Problem("This extension exceeds the 20,000 file and folder limit.") }
            var info = stat()
            guard fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Problem("An extension file disappeared during import. Retry with a complete folder.") }
            let kind = info.st_mode & S_IFMT
            let target = destination.appendingPathComponent(name)
            switch kind {
            case S_IFDIR:
                let child = openat(sourceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Problem("A source folder changed or became unreadable during import. Retry.") }
                defer { close(child) }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try copyDirectory(child, to: target, depth: depth + 1, budget: &budget)
            case S_IFREG:
                let child = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard child >= 0 else { throw Problem("An extension file is unreadable. Check its permissions and retry.") }
                let handle = FileHandle(fileDescriptor: child, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      opened.st_size >= 0, opened.st_size <= Self.fileLimit else {
                    throw Problem("Extension files must be regular files no larger than 64 MB each.")
                }
                let data = try handle.read(upToCount: min(Self.fileLimit, Self.totalLimit - budget.bytes) + 1) ?? Data()
                guard data.count <= Self.fileLimit, data.count <= Self.totalLimit - budget.bytes else {
                    throw Problem("This extension exceeds the 64 MB file or 256 MB total size limit.")
                }
                budget.bytes += data.count
                try data.write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            default:
                throw Problem("The extension contains a symbolic link or special file. Use a folder containing only regular files and folders.")
            }
        }
    }

    private func readRegular(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Problem("Saved extension metadata is unreadable. Restore its file permissions and retry.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw Problem("Saved extension metadata is invalid or too large.") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Problem("Saved extension metadata is too large.") }
        return data
    }
}
