import Foundation

/// Session generations are published atomically. Damaged or unsupported originals are
/// evidence, never an empty session: preserve them before publishing replacement bytes.
enum RecoverySnapshots {
    static func read(_ file: URL, valid: (Data) -> Bool) -> Data? {
        for candidate in [file, file.appendingPathExtension("previous")] {
            if let data = try? Data(contentsOf: candidate), valid(data) { return data }
        }
        return nil
    }

    @discardableResult
    static func write(_ data: Data, to file: URL, valid: (Data) -> Bool) -> Bool {
        guard valid(data) else { return false }
        do {
            let original: Data?
            do { original = try Data(contentsOf: file) }
            catch CocoaError.fileReadNoSuchFile { original = nil }
            if let original {
                if valid(original) {
                    guard SnapshotPersistence.write(original, to: file.appendingPathExtension("previous")) else { return false }
                } else {
                    // A unique sibling also survives a failure publishing the replacement.
                    let preserved = file.appendingPathExtension("damaged-\(UUID().uuidString)")
                    guard SnapshotPersistence.write(original, to: preserved) else { return false }
                }
            }
            return SnapshotPersistence.write(data, to: file)
        } catch {
            NSLog("Vane: preserving unreadable %@: %@", file.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    /// Explicit profile deletion also removes its local recovery generations. Other
    /// profiles and user-created/exported library backups remain independent.
    static func forget(profileID: UUID, in directory: URL) {
        let fm = FileManager.default
        let names = [ProfileManager.sessionURL(for: profileID, in: directory).lastPathComponent,
                     ProfileManager.spacesURL(for: profileID, in: directory).lastPathComponent,
                     Suspension.SpaceState.url(for: profileID, in: directory).lastPathComponent]
        func removeCopies(in folder: URL) {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for file in files where names.contains(where: { name in
                file.lastPathComponent == name || file.lastPathComponent == name + ".previous"
                    || file.lastPathComponent.hasPrefix(name + ".damaged-")
            }) { try? fm.removeItem(at: file) }
        }
        removeCopies(in: directory)
        let root = directory.appendingPathComponent("Session Recovery", isDirectory: true)
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
            // Never traverse an unexpected symlink while erasing local copies.
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            removeCopies(in: folder)
        }
    }

    /// Runs before profile/session restoration can mutate any saved state. Each unclean
    /// launch gets an independent directory, including the launch after another failed
    /// restore. Failure aborts startup rather than risking the originals.
    static func preserveLaunch(in directory: URL) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            let name = $0.lastPathComponent
            return (name.hasPrefix("session") || name.hasPrefix("spaces") || name.hasPrefix("spacestate")
                    || name == "profiles.json")
                && (name.hasSuffix(".json") || name.hasSuffix(".json.previous"))
                && !name.contains("00000000-0000-0000-0000-000000000001")
        }
        guard !files.isEmpty else { return }
        let archive = directory.appendingPathComponent("Session Recovery", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        for file in files { try fm.copyItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent)) }
    }
}
