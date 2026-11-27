import Foundation

/// The parts of the Mac's `BackupIO` (BackupArchive.swift) that `ICloudRemoval` uses:
/// regular files only, private and fsynced replacement writes.
enum BackupIO {
    static func checkFile(_ url: URL, mayBeMissing: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if mayBeMissing && errno == ENOENT { return }
            throw posixError()
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func directory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    static func read(_ url: URL) throws -> Data {
        try checkFile(url)
        return try Data(contentsOf: url)
    }
    static func write(_ data: Data, _ url: URL) throws {
        try checkFile(url, mayBeMissing: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw posixError() }
        try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw posixError() }
    }
    static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
