import Foundation

/// Immutable evidence of a previously confirmed removal. Keeping both epochs
/// makes an ambiguous CAS/deletion result recoverable without choosing a new zone.
struct ICloudRemovalReceipt: Codable, Equatable, Sendable {
    var id = UUID()
    var account: String
    var category: ICloudCategory
    var oldEpoch: String
    var newEpoch: String
    var key: String { account + ":" + category.rawValue }

    func validate() throws {
        guard account.utf8.count == 64, account.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !category.isSecret, let old = UUID(uuidString: oldEpoch),
              let new = UUID(uuidString: newEpoch), old != new else {
            throw ICloudFailure.invalid("The pending iCloud removal receipt is invalid. Removal remains paused.")
        }
    }
}

/// Disk is the authority, including after a write that throws during its final
/// directory fsync. Inspection neither creates a directory nor contacts CloudKit.
actor ICloudRemovalJournal {
    private struct Envelope: Codable { var schema = 1; var receipts: [ICloudRemovalReceipt] }
    private let file: URL
    private let writer: @Sendable (Data, URL) throws -> Void
    private static let maximumBytes = 1024 * 1024
    private static let maximumReceipts = 1024

    init(directory: URL, writer: @escaping @Sendable (Data, URL) throws -> Void = { try BackupIO.write($0, $1) }) {
        file = directory.appendingPathComponent("icloud-removals.json")
        self.writer = writer
    }
    func receipts() throws -> [ICloudRemovalReceipt] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            try BackupIO.checkFile(file)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes + 1
            guard size <= Self.maximumBytes else { throw ICloudFailure.limitExceeded }
            let data = try BackupIO.read(file)
            guard data.count <= Self.maximumBytes else { throw ICloudFailure.limitExceeded }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schema == 1 else { throw ICloudFailure.unsupportedSchema }
            try validate(envelope.receipts)
            return envelope.receipts
        } catch let error as ICloudFailure { throw error }
        catch { throw ICloudFailure.storage("Vane could not read its pending iCloud removals. Removal remains paused.") }
    }
    func append(_ additions: [ICloudRemovalReceipt]) throws {
        try save(receipts() + additions)
    }
    func complete(_ receipt: ICloudRemovalReceipt) throws {
        let existing = try receipts()
        // Do not let an unrelated completion remove another account's request.
        try save(existing.filter { $0.id != receipt.id || $0 != receipt })
    }
    private func validate(_ receipts: [ICloudRemovalReceipt]) throws {
        guard receipts.count <= Self.maximumReceipts,
              Set(receipts.map(\.id)).count == receipts.count,
              Set(receipts.map(\.key)).count == receipts.count else { throw ICloudFailure.limitExceeded }
        for receipt in receipts { try receipt.validate() }
    }
    private func save(_ receipts: [ICloudRemovalReceipt]) throws {
        try validate(receipts)
        let data = try JSONEncoder().encode(Envelope(receipts: receipts))
        guard data.count <= Self.maximumBytes else { throw ICloudFailure.limitExceeded }
        do {
            try BackupIO.directory(file.deletingLastPathComponent())
            // Existing BackupIO fsyncs the private temp inode, renames atomically,
            // then fsyncs its directory. No epoch CAS precedes this completion.
            try writer(data, file)
        } catch { throw ICloudFailure.storage("Vane could not checkpoint its pending iCloud removal. Retry removal before enabling sync.") }
    }
}

@MainActor protocol ICloudRemovalService: AnyObject {
    func account() async throws -> String
    func controls(_ categories: Set<ICloudCategory>) async throws -> [ICloudCategory: String]
    func prepareRemoval() async throws
    func advanceRemoval(_ receipt: ICloudRemovalReceipt) async throws
    func deleteRemoval(_ receipt: ICloudRemovalReceipt) async throws
}
extension ICloudRemovalService {
    func prepareRemoval() async throws {}
}

/// Shared by the real CloudKit backend and injected service tests. Any failure
/// leaves its immutable receipt on disk until the old zone's deletion is verified.
@MainActor final class ICloudRemovalCoordinator {
    private let journal: ICloudRemovalJournal
    private var busy = false
    init(journal: ICloudRemovalJournal) { self.journal = journal }

    func hasPending() async throws -> Bool { !(try await journal.receipts()).isEmpty }

    func request(_ categories: Set<ICloudCategory>, using service: any ICloudRemovalService,
                 admitted: @MainActor () throws -> Void = {}) async throws {
        guard !busy else { throw ICloudFailure.unavailable("An iCloud removal is already running.") }
        busy = true; defer { busy = false }
        try admitted()
        let existing = try await journal.receipts()
        try admitted()
        let identity = try await service.account()
        try admitted()
        guard existing.allSatisfy({ $0.account == identity }) else { throw ICloudFailure.accountChanged }
        let missing = categories.filter { !$0.isSecret }.subtracting(existing.map(\.category))
        if !missing.isEmpty {
            let epochs = try await service.controls(missing)
            try admitted()
            try await requireAccount(identity, service: service, admitted: admitted)
            let receipts = try missing.sorted(by: { $0.rawValue < $1.rawValue }).map { category in
                guard let epoch = epochs[category] else { throw ICloudFailure.invalid("The iCloud namespace could not be read. Removal remains pending.") }
                let receipt = ICloudRemovalReceipt(account: identity, category: category, oldEpoch: epoch, newEpoch: UUID().uuidString)
                try receipt.validate()
                return receipt
            }
            try await journal.append(receipts)
            try admitted()
        }
        // Include earlier confirmed requests even outside the new selection;
        // success must not conceal an outstanding cleanup from a previous attempt.
        try await finish(using: service, admitted: admitted)
    }
    func resume(using service: any ICloudRemovalService, admitted: @MainActor () throws -> Void = {}) async throws {
        guard !busy else { throw ICloudFailure.unavailable("An iCloud removal is already running.") }
        busy = true; defer { busy = false }
        try await finish(using: service, admitted: admitted)
    }
    private func finish(using service: any ICloudRemovalService, admitted: @MainActor () throws -> Void) async throws {
        try admitted()
        let receipts = try await journal.receipts()
        try admitted()
        guard !receipts.isEmpty else { return }
        let identity = try await service.account()
        try admitted()
        guard receipts.allSatisfy({ $0.account == identity }) else { throw ICloudFailure.accountChanged }
        try await service.prepareRemoval()
        try admitted()
        for receipt in receipts {
            try await requireAccount(receipt.account, service: service, admitted: admitted)
            try await service.advanceRemoval(receipt)
            try admitted()
            try await requireAccount(receipt.account, service: service, admitted: admitted)
            try await service.deleteRemoval(receipt)
            try admitted()
            try await requireAccount(receipt.account, service: service, admitted: admitted)
            try await journal.complete(receipt)
            try admitted()
        }
        let remaining = try await journal.receipts()
        try admitted()
        guard remaining.isEmpty else { throw ICloudFailure.storage("Some confirmed iCloud removals are still pending. Retry before enabling sync.") }
    }
    private func requireAccount(_ expected: String, service: any ICloudRemovalService,
                                admitted: @MainActor () throws -> Void) async throws {
        try admitted()
        let actual = try await service.account()
        try admitted()
        guard actual == expected else { throw ICloudFailure.accountChanged }
    }
}
