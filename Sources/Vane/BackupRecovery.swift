import Foundation
import CryptoKit
import CoreFoundation

struct BackupPoint: Identifiable, Sendable {
    var id: UUID
    var date: Date
    var reason: BackupReason
    var size: Int
    var url: URL
    var diagnostic: String?
}

enum BackupSchedule {
    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= 3600
    }
}

@MainActor struct BackupRecovery {
    let library: BackupLibrary
    private nonisolated let writer: @Sendable (BackupArchive, URL) throws -> Void
    private nonisolated let remover: @Sendable (URL) throws -> Void
    private nonisolated let root: URL
    private nonisolated var pointRoot: URL { root.appendingPathComponent("Points") }
    init(library: BackupLibrary,
         writer: @escaping @Sendable (BackupArchive, URL) throws -> Void = { try BackupCodec.write($0, to: $1) },
         remover: @escaping @Sendable (URL) throws -> Void = BackupIO.remove) {
        self.library = library; self.writer = writer; self.remover = remover
        root = library.directory.appendingPathComponent("Recovery")
    }
    nonisolated func points() throws -> [BackupPoint] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try BackupIO.directory(root)
        guard FileManager.default.fileExists(atPath: pointRoot.path) else { return [] }
        try BackupIO.directory(pointRoot)
        let urls = try FileManager.default.contentsOfDirectory(at: pointRoot, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var points: [BackupPoint] = []
        for url in urls where url.pathExtension == "vanebackup" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            do {
                let archive = try BackupCodec.read(url)
                guard archive.id == id else { throw BackupError.invalid("Recovery point identity does not match its filename.") }
                points.append(.init(id: id, date: archive.created, reason: archive.reason,
                                    size: attributes.fileSize ?? 0, url: url, diagnostic: archive.damage))
            } catch {
                points.append(.init(id: id, date: attributes.contentModificationDate ?? .distantPast,
                                    reason: .automatic, size: attributes.fileSize ?? 0, url: url,
                                    diagnostic: error.localizedDescription))
            }
        }
        return points.sorted {
            $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date
        }
    }
    @discardableResult func save(_ archive: BackupArchive) throws -> BackupPoint {
        try BackupCodec.validate(archive)
        if archive.damage == nil { _ = try library.validate(archive) }
        try writePoint(archive)
        return try finishSave(archive)
    }
    func saveAsync(_ archive: BackupArchive) async throws -> BackupPoint {
        try BackupCodec.validate(archive)
        if archive.damage == nil { _ = try library.validate(archive) }
        return try await Task.detached(priority: .utility) {
            try self.writePoint(archive)
            return try self.finishSave(archive)
        }.value
    }
    private nonisolated func writePoint(_ archive: BackupArchive) throws {
        try BackupIO.directory(root); try BackupIO.directory(pointRoot)
        let url = pointRoot.appendingPathComponent("\(archive.id.uuidString).vanebackup")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw BackupError.storage("This recovery point already exists.") }
        try writer(archive, url)
    }
    private nonisolated func finishSave(_ archive: BackupArchive) throws -> BackupPoint {
        let url = pointRoot.appendingPathComponent("\(archive.id.uuidString).vanebackup")
        let written = try BackupCodec.read(url)
        guard written.id == archive.id, written.files == archive.files,
              written.preferences == archive.preferences, written.damage == archive.damage else {
            throw BackupError.storage("The recovery point could not be verified.")
        }
        try reconcileRetention(keeping: archive.id)
        return BackupPoint(id: archive.id, date: archive.created, reason: archive.reason,
                           size: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                           url: url, diagnostic: archive.damage)
    }
    private nonisolated func reconcileRetention(keeping protectedID: UUID) throws {
        let all = try points()
        var kept = Array(all.prefix(10))
        // A clock adjustment or a UUID tie-break must never prune the point we
        // just promised to create, especially the mandatory before-restore point.
        if !kept.contains(where: { $0.id == protectedID }), let newest = all.first(where: { $0.id == protectedID }) {
            if kept.count == 10 { kept.removeLast() }
            kept.append(newest)
        }
        // Damaged originals are valuable evidence, but must not evict the only
        // usable recovery point. Keep nine recent points plus that healthy point.
        if !kept.contains(where: { $0.diagnostic == nil }), let good = all.first(where: { $0.diagnostic == nil }) {
            if kept.count == 10, let index = kept.lastIndex(where: { $0.id != protectedID }) { kept.remove(at: index) }
            kept.append(good)
        }
        let retained = Set(kept.map(\.id))
        for stale in all where !retained.contains(stale.id) { try remover(stale.url) }
    }
    func automaticPointIfChanged(_ archive: BackupArchive) throws -> BackupPoint? {
        _ = try library.validate(archive)
        let digest = try Self.contentDigest(archive)
        // A corrupt latest point does not hide the last healthy one or stop recovery.
        if let latest = try points().first(where: { $0.diagnostic == nil }),
           digest == (try Self.contentDigest(BackupCodec.read(latest.url))) {
            try reconcileRetention(keeping: latest.id)
            return nil
        }
        return try save(archive)
    }
    func automaticPointIfChangedAsync(_ archive: BackupArchive) async throws -> BackupPoint? {
        _ = try library.validate(archive)
        let changed = try await Task.detached(priority: .utility) {
            let digest = try Self.contentDigest(archive)
            if let latest = try self.points().first(where: { $0.diagnostic == nil }) {
                if digest == (try Self.contentDigest(BackupCodec.read(latest.url))) {
                    try self.reconcileRetention(keeping: latest.id)
                    return false
                }
            }
            return true
        }.value
        return changed ? try await saveAsync(archive) : nil
    }
    nonisolated static func contentDigest(_ archive: BackupArchive) throws -> String {
        var hash = SHA256()
        let prefs = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil)
        try hashValue(prefs, into: &hash)
        for file in archive.files.sorted(by: { $0.name < $1.name }) {
            try hashValue(file.name, into: &hash)
            if file.name.hasSuffix(".db") { try hashValue(BackupSQLite.contentDigest(file.data), into: &hash) }
            else if file.name.hasSuffix(".json") {
                let object = try JSONSerialization.jsonObject(with: file.data, options: [.fragmentsAllowed])
                try hashValue(object, into: &hash)
            } else { try hashValue(file.data, into: &hash) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func hashValue(_ value: Any, into hash: inout SHA256) throws {
        switch value {
        case let value as Data:
            hash.update(data: Data("data:\(value.count):".utf8)); hash.update(data: value)
        case let value as Date: hash.update(data: Data("date:\(value.timeIntervalSince1970.bitPattern);".utf8))
        case let value as String:
            let data = Data(value.utf8); hash.update(data: Data("string:\(data.count):".utf8)); hash.update(data: data)
        case let values as [String: Any]:
            hash.update(data: Data("dictionary:\(values.count):".utf8))
            for key in values.keys.sorted() { try hashValue(key, into: &hash); try hashValue(values[key]!, into: &hash) }
        case let values as [Any]:
            hash.update(data: Data("array:\(values.count):".utf8))
            for value in values { try hashValue(value, into: &hash) }
        case let value as NSNumber:
            let type = CFGetTypeID(value) == CFBooleanGetTypeID() ? "bool" : "number"
            hash.update(data: Data("\(type):\(value.stringValue);".utf8))
        case is NSNull: hash.update(data: Data("null;".utf8))
        default: throw BackupError.invalid("Unsupported setting value.")
        }
    }
}
