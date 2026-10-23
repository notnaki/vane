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

    /// Transfer an exclusively owned directory from the IO worker to WebKit's actor.
    private final class Prepared: @unchecked Sendable {
        let directory: URL
        var owner: Int32
        init(directory: URL, owner: Int32) { self.directory = directory; self.owner = owner }
        deinit {
            if owner >= 0 { flock(owner, LOCK_UN); Darwin.close(owner) }
        }
    }

    static func create(root: URL = BlockerPrivateCache.root) async throws -> BlockerPrivateCache {
        let prepared = try await Task.detached(priority: .utility) { try prepare(root: root) }.value
        return try BlockerPrivateCache(prepared: prepared)
    }

    /// Retained for isolated cache checks; production uses `create` to keep disk IO off UI.
    convenience init(root: URL = BlockerPrivateCache.root) throws {
        try self.init(prepared: Self.prepare(root: root))
    }

    private init(prepared: Prepared) throws {
        directory = prepared.directory
        guard let store = WKContentRuleListStore(url: directory) else {
            throw BlockerFiles.Failure("WebKit’s private filter store is unavailable.")
        }
        self.store = store
        owner = prepared.owner
        prepared.owner = -1
    }

    private nonisolated static func prepare(root: URL) throws -> Prepared {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Busy means recoverable unavailability, never a wait for another Vane copy.
        let global = try lock(root.appendingPathComponent(".lock"), nonblocking: true)
        defer { flock(global, LOCK_UN); Darwin.close(global) }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { return Prepared(directory: directory, owner: try lock(directory.appendingPathComponent(".owner"), nonblocking: true)) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func close(removeFiles: Bool = true) {
        guard owner >= 0 else { return }
        let descriptor = owner
        owner = -1
        if removeFiles {
            let directory = directory
            Task.detached(priority: .utility) {
                // Keep the owner lock until recursive removal finishes.
                try? FileManager.default.removeItem(at: directory)
                flock(descriptor, LOCK_UN); Darwin.close(descriptor)
            }
        } else { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    }

    nonisolated static func sweep(root: URL = BlockerPrivateCache.root) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let global = try lock(root.appendingPathComponent(".lock"), nonblocking: true)
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
