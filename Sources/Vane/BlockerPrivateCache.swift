import Darwin
import Foundation
import WebKit

/// Public WebKit stores compile to disk. Private exception variants use a transient
/// directory, separate from the persistent store. An owner lock protects other running
/// Vane processes; released locks let the next launch remove leftovers after a crash.
@MainActor final class BlockerPrivateCache {
    nonisolated static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Vane-private-filter-cache", isDirectory: true) }
    let directory: URL
    let store: WKContentRuleListStore
    private var owner: Int32

    init(root: URL = BlockerPrivateCache.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let global = try Self.lock(root.appendingPathComponent(".lock"), nonblocking: false)
        defer { flock(global, LOCK_UN); Darwin.close(global) }
        try Self.sweepLocked(root: root)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        owner = try Self.lock(directory.appendingPathComponent(".owner"), nonblocking: false)
        guard let store = WKContentRuleListStore(url: directory) else {
            flock(owner, LOCK_UN); Darwin.close(owner)
            try? FileManager.default.removeItem(at: directory)
            throw BlockerFiles.Failure("WebKit’s private filter store is unavailable.")
        }
        self.store = store
    }

    func close(removeFiles: Bool = true) {
        guard owner >= 0 else { return }
        // Remove while still owning the lock; another process cannot sweep a live cache.
        if removeFiles { try? FileManager.default.removeItem(at: directory) }
        flock(owner, LOCK_UN); Darwin.close(owner); owner = -1
    }

    nonisolated static func sweep(root: URL = BlockerPrivateCache.root) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let global = try lock(root.appendingPathComponent(".lock"), nonblocking: false)
        defer { flock(global, LOCK_UN); Darwin.close(global) }
        try sweepLocked(root: root)
    }

    private nonisolated static func sweepLocked(root: URL) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // Creation also holds the global lock, so a missing owner file is an orphan.
            guard let descriptor = try? lock(directory.appendingPathComponent(".owner"), nonblocking: true) else { continue }
            defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            try FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func lock(_ file: URL, nonblocking: Bool) throws -> Int32 {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BlockerFiles.Failure("Couldn’t open the private filter cache lock.") }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            Darwin.close(descriptor)
            throw BlockerFiles.Failure("The private filter cache is in use.")
        }
        return descriptor
    }
}
