import Foundation
import Darwin

@MainActor final class BackupDirectoryLock {
    let directory: URL
    private let descriptor: Int32
    init(_ directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let file = directory.appendingPathComponent(".backup-owner")
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackupIO.posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw BackupError.storage("Another Vane instance is using this data folder. Quit that instance before restoring.")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}

@MainActor final class BackupRestore {
    enum Result: Equatable { case none, restored, rolledBack }
    private enum Phase: String, Codable { case prepared, applying, committed }
    private struct Journal: Codable {
        var version = 1
        var phase: Phase
        var incomingDigest: String
        var originalsDigest: String?
    }
    private struct Originals: Codable {
        var preferences: Data
        var files: [BackupArchive.File]
    }
    private static var instanceLock: BackupDirectoryLock?
    let library: BackupLibrary
    private let checkpoint: (String) throws -> Void
    private let stageCheckpoint: () throws -> Void
    var recoveryRoot: URL { library.directory.appendingPathComponent("Recovery") }
    private var pending: URL { recoveryRoot.appendingPathComponent("Pending") }

    init(library: BackupLibrary, checkpoint: @escaping (String) throws -> Void = { _ in },
         stageCheckpoint: @escaping () throws -> Void = {}) {
        self.library = library; self.checkpoint = checkpoint; self.stageCheckpoint = stageCheckpoint
    }
    static func claimInstance(_ directory: URL) throws {
        if instanceLock?.directory == directory.standardizedFileURL { return }
        instanceLock = try BackupDirectoryLock(directory)
    }
    private func ownership() throws -> BackupDirectoryLock? {
        if Self.instanceLock?.directory == library.directory.standardizedFileURL { return nil }
        return try BackupDirectoryLock(library.directory)
    }
    func prepare(_ incoming: BackupArchive) throws {
        let lock = try ownership(); defer { withExtendedLifetime(lock) {} }
        _ = try library.validate(incoming)
        try BackupIO.directory(recoveryRoot)
        guard !FileManager.default.fileExists(atPath: pending.path) else {
            throw BackupError.storage("A restore is already pending. Restart Vane to finish it first.")
        }
        // Publish Pending only after both its contents and journal are complete. A
        // killed preparation can leave a disposable staging folder, never a bogus
        // pending transaction that blocks an otherwise healthy launch.
        let staging = recoveryRoot.appendingPathComponent("Staging-\(UUID().uuidString)")
        try BackupIO.directory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let original = try library.capture(reason: .beforeRestore, allowDamaged: true)
        try BackupRecovery(library: library).save(original)
        let encoded = try BackupCodec.encode(incoming)
        try BackupIO.write(encoded, staging.appendingPathComponent("incoming.vanebackup"))
        try BackupIO.write(plist(Journal(phase: .prepared, incomingDigest: BackupCodec.digest(encoded))),
                           staging.appendingPathComponent("journal.plist"))
        try stageCheckpoint()
        try FileManager.default.moveItem(at: staging, to: pending)
        try BackupIO.syncDirectory(recoveryRoot)
    }
    func cancelPending() throws {
        let lock = try ownership(); defer { withExtendedLifetime(lock) {} }
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        try BackupIO.directory(recoveryRoot); try BackupIO.directory(pending)
        let journal = try readJournal()
        guard journal.phase == .prepared else { throw BackupError.recoveryFailed("The restore has begun and needs launch recovery.") }
        try cleanPending()
    }
    func recoverAtLaunch() throws -> Result {
        let lock = try ownership(); defer { withExtendedLifetime(lock) {} }
        guard FileManager.default.fileExists(atPath: pending.path) else { return .none }
        try BackupIO.directory(recoveryRoot); try BackupIO.directory(pending)
        var journal = try readJournal()
        switch journal.phase {
        case .prepared:
            let incomingData = try BackupIO.read(pending.appendingPathComponent("incoming.vanebackup"))
            guard BackupCodec.digest(incomingData) == journal.incomingDigest else { throw BackupError.recoveryFailed("The staged backup is damaged.") }
            let incoming = try BackupCodec.decode(incomingData)
            _ = try library.validate(incoming)
            let originals = try preserveOriginals()
            let data = try plist(originals)
            guard data.count <= BackupCodec.limit else { throw BackupError.tooLarge }
            try BackupIO.write(data, pending.appendingPathComponent("originals.plist"))
            journal.originalsDigest = BackupCodec.digest(data)
            journal.phase = .applying
            try writeJournal(journal)
            try checkpoint("applying")
            try install(incoming.files, preferences: incoming.preferences, exactPreferences: false)
            journal.phase = .committed
            try writeJournal(journal)
            try checkpoint("committed")
            try cleanPending()
            return .restored
        case .applying:
            do {
                let data = try BackupIO.read(pending.appendingPathComponent("originals.plist"))
                guard BackupCodec.digest(data) == journal.originalsDigest else { throw BackupError.recoveryFailed("The original snapshot is damaged.") }
                let original = try PropertyListDecoder().decode(Originals.self, from: data)
                guard Set(original.files.map(\.name)).count == original.files.count,
                      original.files.allSatisfy({ BackupPaths.isOriginal($0.name) && BackupCodec.digest($0.data) == $0.digest }),
                      BackupCodec.withinLimit([original.preferences.count] + original.files.map { $0.data.count }) else {
                    throw BackupError.recoveryFailed("Invalid original snapshot.")
                }
                try install(original.files, preferences: original.preferences, exactPreferences: true)
                try cleanPending()
                return .rolledBack
            } catch {
                throw BackupError.recoveryFailed(error.localizedDescription)
            }
        case .committed:
            // Commit is the durable point of no return. Cleanup can be retried without
            // ever replacing a successfully restored library with its old bytes.
            try cleanPending()
            return .restored
        }
    }
    private func preserveOriginals() throws -> Originals {
        var files: [BackupArchive.File] = [], remaining = BackupCodec.limit
        for name in try library.ownedNames(includeJournals: true) {
            let data = try BackupIO.read(library.directory.appendingPathComponent(name))
            guard data.count <= remaining else { throw BackupError.tooLarge }
            remaining -= data.count
            files.append(.init(name: name, data: data))
        }
        let prefs = try library.currentPreferences(includeLocal: true)
        guard prefs.count <= remaining else { throw BackupError.tooLarge }
        return Originals(preferences: prefs, files: files)
    }
    private func install(_ files: [BackupArchive.File], preferences: Data, exactPreferences: Bool) throws {
        let names = Set(files.map(\.name))
        for name in try library.ownedNames(includeJournals: true) where !names.contains(name) {
            try BackupIO.remove(library.directory.appendingPathComponent(name))
            try checkpoint("removed:\(name)")
        }
        if files.contains(where: { $0.name.hasPrefix("FilterLists/") }) {
            try BackupIO.directory(library.directory.appendingPathComponent("FilterLists"))
        }
        for file in files {
            if ReadingQueueFiles.parseOwnedName(file.name) != nil { try ReadingQueueFiles.prepareOwnedParents(file.name, in: library.directory) }
            try BackupIO.write(file.data, library.directory.appendingPathComponent(file.name))
            try checkpoint("installed:\(file.name)")
        }
        try ReadingQueueFiles.removeEmptyDirectories(in: library.directory)
        try library.applyPreferences(preferences, includeLocal: exactPreferences)
        try checkpoint("preferences")
    }
    private func readJournal() throws -> Journal {
        let data = try BackupIO.read(pending.appendingPathComponent("journal.plist"))
        let journal: Journal
        do { journal = try PropertyListDecoder().decode(Journal.self, from: data) }
        catch { throw BackupError.recoveryFailed("The restore journal is unreadable.") }
        guard journal.version == 1, journal.incomingDigest.count == 64,
              journal.phase == .prepared || journal.originalsDigest?.count == 64 else {
            throw BackupError.recoveryFailed("The restore journal is invalid.")
        }
        return journal
    }
    private func writeJournal(_ journal: Journal) throws {
        try BackupIO.write(plist(journal), pending.appendingPathComponent("journal.plist"))
    }
    private func plist<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }
    private func cleanPending() throws {
        // Rename first and fsync: a crash during recursive cleanup must not leave an
        // applying journal that points to originals cleanup already removed.
        let garbage = recoveryRoot.appendingPathComponent("Finished-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: pending, to: garbage)
        try BackupIO.syncDirectory(recoveryRoot)
        try FileManager.default.removeItem(at: garbage)
        try BackupIO.syncDirectory(recoveryRoot)
    }
}

extension UserDefaults {
    nonisolated static var vaneDomain: String {
        if let directory = Store.overrideDirectory { return suiteName(forDataDir: directory) }
        return Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }
}
