import Foundation
import Darwin
import Synchronization

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
        var safari: SafariExtensionSource? = nil
        var store: ChromeWebStore? = nil
        // Approval of error callbacks only; never native-host authorization.
        var nativeMessagingErrorCompatibilityVersion: Int? = nil
    }

    struct Stage: Sendable {
        let revision: String
        let url: URL
        // A stage remains live through validation and consent, across store instances.
        private let lease: StageLease
        fileprivate init(revision: String, url: URL, lease: StageLease) {
            self.revision = revision
            self.url = url
            self.lease = lease
        }
    }

    private static let activeStages = Mutex<[String: Set<String>]>([:])

    fileprivate final class StageLease: Sendable {
        let root: String
        let revision: String
        let lock: AdvisoryLock?
        init(root: String, revision: String, lock: AdvisoryLock?) {
            self.root = root; self.revision = revision; self.lock = lock
        }
        deinit {
            ExtensionCodeStore.activeStages.withLock { active in
                active[root]?.remove(revision)
                if active[root]?.isEmpty == true { active[root] = nil }
            }
        }
    }

    fileprivate final class AdvisoryLock: Sendable {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
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
              records.allSatisfy({ key, record in
                  UUID(uuidString: record.identity) != nil && UUID(uuidString: record.revision) != nil
                      && (record.safari.map { $0.isValid && $0.key == key } ?? !key.hasPrefix("/safari-extension/"))
                      && (record.store.map { $0.isValid && $0.key == key && record.safari == nil } ?? !key.hasPrefix("/chrome-web-store/"))
              }),
              Set(records.values.compactMap { $0.safari?.runtimeID }).count == records.values.filter({ $0.safari != nil }).count else {
            throw Problem("Saved extension metadata is invalid or exceeds the 1,000 installation limit. Your extension files have been retained.")
        }
    }

    func code(for record: Record) -> URL {
        root.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(record.revision, isDirectory: true)
    }

    /// Called after candidate validation/activation. Atomic index replacement selects the
    /// accepted revision. The previous code remains available until the caller finishes.
    func save(_ records: [String: Record]) throws {
        try Self.activeStages.withLock { _ in
            try withStorageLock { _ in try writeRecords(records) }
        }
    }

    private func writeRecords(_ records: [String: Record]) throws {
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
        try Self.activeStages.withLock { _ in
            try withStorageLock { _ in try retainIndex() }
        }
    }

    private func retainIndex() throws {
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

    func stage(_ source: URL, appExtension: Bool = false) throws -> Stage {
        let revision = UUID().uuidString.lowercased()
        let lease = try Self.activeStages.withLock { active in
            try withStorageLock { profile in
                // Establish an empty reference set before the first import, so a crash
                // before acceptance can be recovered. Never infer one for existing data.
                let contents = Set(try directoryNames(profile))
                if contents == ["revisions", ".revisions.lock"],
                   try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("revisions").path).isEmpty {
                    try writeRecords([:])
                }
                // The profile lock covers creation until the revision lease is held.
                // Other processes can only observe a UUID directory after its lease.
                let lock = try advisoryLock(profile, name: Self.leaseName(revision), nonBlocking: false)
                let destination = root.appendingPathComponent("revisions").appendingPathComponent(revision)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                let key = root.resolvingSymlinksInPath().standardizedFileURL.path
                active[key, default: []].insert(revision)
                return StageLease(root: key, revision: revision, lock: lock)
            }
        }
        let destination = root.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(revision, isDirectory: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        // The bookmark's resolved root is allowed; internal links are never followed.
        let sourceFD = open(source.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            throw Problem("The source folder is missing or unreadable. Reconnect its disk or choose Update from Folder to locate it again.")
        }
        defer { close(sourceFD) }
        var budget = Budget()
        let target = appExtension ? destination.appendingPathComponent("extension.appex", isDirectory: true) : destination
        if appExtension { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try copyDirectory(sourceFD, to: target, depth: 0, budget: &budget, bundleRoot: appExtension ? target : nil)
        if appExtension, let entries = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in entries where (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                guard url.resolvingSymlinksInPath().path.hasPrefix(target.path + "/") else { throw Problem("The signed bundle contains a link outside its own files.") }
            }
        }
        committed = true
        return Stage(revision: revision, url: destination, lease: lease)
    }

    /// A current readable index and an unowned revision lease prove code unused.
    /// Recovery metadata may contain other references, so retain its code. Advisory
    /// locks coordinate publication and acceptance with other Vane processes.
    func sweepUnreferencedRevisions() throws {
        try Self.activeStages.withLock { active in
            let base = open(root.deletingLastPathComponent().deletingLastPathComponent().path,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard base >= 0 else { return }
            defer { close(base) }
            let extensions = openat(base, "Extensions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard extensions >= 0 else { return }
            defer { close(extensions) }
            let profile = openat(extensions, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard profile >= 0 else { return }
            defer { close(profile) }
            guard let transaction = try advisoryLock(profile, name: ".revisions.lock", nonBlocking: true) else { return }
            defer { withExtendedLifetime(transaction) {} }
            guard !(try directoryNames(profile)).contains(where: { $0.hasPrefix("metadata-recovery-") }) else { return }
            let revisions = openat(profile, "revisions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard revisions >= 0 else { return }
            defer { close(revisions) }
            for name in try directoryNames(revisions) {
                guard UUID(uuidString: name) != nil,
                      !(active[root.resolvingSymlinksInPath().standardizedFileURL.path] ?? []).contains(name.lowercased()) else { continue }
                var info = stat()
                guard fstatat(revisions, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else { continue }
                // Unleased revisions can belong to an older Vane process that does
                // not participate in this protocol. Their inactivity is unknowable.
                guard let lease = try advisoryLock(profile, name: Self.leaseName(name), nonBlocking: true, create: false) else { continue }
                // A different process may have committed this revision while we waited
                // for its lease. Re-read the index after acquiring it, never a snapshot.
                let metadata = openat(profile, "installations.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard metadata >= 0 else { return }
                let data = try readRegular(metadata, limit: 4 * 1024 * 1024)
                let records = try JSONDecoder().decode([String: Record].self, from: data)
                try validate(records)
                if !records.values.contains(where: { $0.revision.lowercased() == name.lowercased() }) {
                    try removeDirectory(name, parent: revisions)
                    _ = unlinkat(profile, Self.leaseName(name), 0)
                }
                withExtendedLifetime(lease) {}
            }
        }
    }

    private static func leaseName(_ revision: String) -> String { ".revision-" + revision.lowercased() + ".lease" }

    /// A short process-visible transaction protects publication and index commits.
    /// Unsupported advisory locking disables collection; imports can still proceed.
    private func withStorageLock<T>(_ body: (Int32) throws -> T) throws -> T {
        try prepare()
        let profile = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard profile >= 0 else { throw Problem("Extension storage is unavailable.") }
        defer { close(profile) }
        let transaction = try advisoryLock(profile, name: ".revisions.lock", nonBlocking: false)
        defer { withExtendedLifetime(transaction) {} }
        return try body(profile)
    }

    private func advisoryLock(_ parent: Int32, name: String, nonBlocking: Bool, create: Bool = true) throws -> AdvisoryLock? {
        let descriptor = openat(parent, name, O_RDWR | (create ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if nonBlocking { return nil }
            throw Problem("Extension storage could not be locked safely. Check profile storage permissions and retry.")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            if nonBlocking { return nil }
            throw Problem("The extension storage lock is not a regular file.")
        }
        var result: Int32
        repeat { result = flock(descriptor, LOCK_EX | (nonBlocking ? LOCK_NB : 0)) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            close(descriptor)
            if nonBlocking || code == ENOTSUP || code == ENOSYS || code == EINVAL { return nil }
            throw Problem("Extension storage could not be locked safely. Retry when its disk is available.")
        }
        return AdvisoryLock(descriptor)
    }

    private func directoryNames(_ descriptor: Int32) throws -> [String] {
        let listingFD = dup(descriptor)
        guard listingFD >= 0 else { throw Problem("Extension storage could not be read. Existing files are retained.") }
        guard let listing = fdopendir(listingFD) else {
            close(listingFD)
            throw Problem("Extension storage could not be read. Existing files are retained.")
        }
        defer { closedir(listing) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(listing) else {
                guard errno == 0 else { throw Problem("Extension storage could not be read. Existing files are retained.") }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// Anchored descriptors prevent a replaced profile/revisions directory or an
    /// internal symlink from redirecting cleanup into another profile or source.
    private func removeDirectory(_ name: String, parent: Int32, depth: Int = 0) throws {
        guard depth <= 64 else { throw Problem("An unused extension revision has too many nested folders to remove safely.") }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0 else { return }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR { try removeDirectory(child, parent: directory, depth: depth + 1) }
            else if unlinkat(directory, child, 0) != 0 { throw Problem("An unused extension revision could not be removed.") }
        }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else { return }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Problem("An unused extension revision could not be removed.") }
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

    /// Snapshot accepted resources without following replaced parents or links.
    /// The runtime view never writes into an accepted revision or signed bundle.
    func resources(in folder: URL) throws -> [String: Data] {
        let rootFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Problem("The accepted extension resources are unavailable.") }
        defer { close(rootFD) }
        var budget = Budget(), result: [String: Data] = [:]
        func read(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth <= 64 else { throw Problem("The extension has too many nested folders.") }
            for name in try directoryNames(parent) {
                budget.entries += 1
                guard budget.entries <= Self.entryLimit else { throw Problem("The extension exceeds the file and folder limit.") }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Problem("An accepted extension resource disappeared.") }
                let path = prefix + name
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Problem("An accepted resource folder changed or became unreadable.") }
                    defer { close(child) }
                    try read(child, prefix: path + "/", depth: depth + 1)
                case S_IFREG:
                    let child = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw Problem("An accepted extension resource is unreadable.") }
                    let data = try readRegular(child, limit: min(Self.fileLimit, Self.totalLimit - budget.bytes))
                    budget.bytes += data.count
                    result[path] = data
                default:
                    throw Problem("Extension runtime resources must contain only regular files and folders.")
                }
            }
        }
        try read(rootFD, prefix: "", depth: 0)
        return result
    }

    /// Walk using directory descriptors and openat(O_NOFOLLOW), rather than reopening
    /// enumerated paths. Replacing a parent with a symlink cannot redirect a later read.
    private func copyDirectory(_ sourceFD: Int32, to destination: URL, depth: Int, budget: inout Budget, bundleRoot: URL? = nil) throws {
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
                try copyDirectory(child, to: target, depth: depth + 1, budget: &budget, bundleRoot: bundleRoot)
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
                try FileManager.default.setAttributes([.posixPermissions: bundleRoot != nil && opened.st_mode & 0o111 != 0 ? 0o700 : 0o600], ofItemAtPath: target.path)
            case S_IFLNK where bundleRoot != nil:
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(sourceFD, name, &buffer, buffer.count - 1)
                guard count > 0, count < Int(PATH_MAX) else { throw Problem("A signed bundle link is invalid.") }
                let link = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard !link.hasPrefix("/"), target.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path.hasPrefix(bundleRoot!.path + "/") else { throw Problem("A signed bundle link points outside its own files.") }
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            default:
                throw Problem("The extension contains a symbolic link or special file. Use a folder containing only regular files and folders.")
            }
        }
    }

    private func readRegular(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Problem("Saved extension metadata is unreadable. Restore its file permissions and retry.") }
        return try readRegular(descriptor, limit: limit)
    }

    private func readRegular(_ descriptor: Int32, limit: Int) throws -> Data {
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
