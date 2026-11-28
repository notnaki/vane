import Foundation
import CryptoKit

// The backup format. The iPhone app compiles this file too (iOS/project.yml), to import a
// Mac backup; the Mac-only file names and file IO are in BackupPaths.swift.

enum BackupError: LocalizedError {
    case invalid(String), futureVersion, tooLarge, storage(String), saveFailed, recoveryFailed(String)
    case passwordRequired, emptyPassword, unlockFailed
    var errorDescription: String? {
        switch self {
        case .passwordRequired: "Enter the password used to encrypt this backup."
        case .emptyPassword: "Enter a backup password, or explicitly choose Export Without Password."
        case .unlockFailed: "The backup could not be unlocked. Check the password; the file may also be damaged."
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
    /// `allowed` is the rule for file names; the Mac's is in BackupPaths.swift.
    static func validate(_ archive: BackupArchive, allowed: (String) -> Bool) throws {
        guard archive.format == "Vane.Backup", archive.version > 0 else { throw BackupError.invalid("Unknown format.") }
        guard archive.version == 1 else { throw BackupError.futureVersion }
        guard archive.created.timeIntervalSince1970.isFinite, archive.files.count <= 100_000,
              Set(archive.files.map(\.name)).count == archive.files.count,
              archive.files.allSatisfy({ allowed($0.name) }),
              archive.preferenceDigest == digest(archive.preferences),
              archive.files.allSatisfy({ $0.digest == digest($0.data) }) else {
            throw BackupError.invalid("Invalid filenames, metadata, or damaged contents.")
        }
        guard withinLimit([archive.preferences.count] + archive.files.map { $0.data.count }) else { throw BackupError.tooLarge }
    }
    /// Unlocked and decoded, not yet validated.
    static func unseal(_ data: Data, password: String? = nil) throws -> BackupArchive {
        guard data.count <= limit else { throw BackupError.tooLarge }
        let data = try BackupEncryption.isEncrypted(data) ? BackupEncryption.open(data, password: password) : data
        do { return try PropertyListDecoder().decode(BackupArchive.self, from: data) }
        catch { throw BackupError.invalid("The backup file could not be read.") }
    }
}
