import Foundation
import CryptoKit

enum ICloudCategory: String, Codable, CaseIterable, Sendable {
    case profiles, spaces, favourites, pinnedTabs, sidebarFolders, bookmarks, history
    case openTabs, recentlyClosedTabs, easels, readingQueue, offlineArticles, spaceTemplates, boosts
    case appearance, readerPreferences, search, keyboardShortcuts, portablePreferences, siteSettings
    case contentBlocking, extensions, extensionSyncData, passwords, aiKeys, downloadHistory

    var isSecret: Bool { self == .passwords || self == .aiKeys }
    var defaultEnabled: Bool { !isSecret && self != .history && self != .extensionSyncData }
    var title: String {
        switch self {
        case .profiles: "Profiles"
        case .spaces: "Spaces"
        case .favourites: "Favourites"
        case .pinnedTabs: "Pinned tabs"
        case .sidebarFolders: "Sidebar folders"
        case .bookmarks: "Bookmarks"
        case .history: "Browsing history"
        case .openTabs: "Open tabs"
        case .recentlyClosedTabs: "Recently closed tabs"
        case .easels: "Easels"
        case .readingQueue: "Reading queue"
        case .offlineArticles: "Offline article content"
        case .spaceTemplates: "Space templates"
        case .boosts: "Boosts"
        case .appearance: "Appearance"
        case .readerPreferences: "Reader preferences"
        case .search: "Search and homepage"
        case .keyboardShortcuts: "Keyboard shortcuts"
        case .portablePreferences: "Other preferences"
        case .siteSettings: "Site settings"
        case .contentBlocking: "Content blocking"
        case .extensions: "Extensions"
        case .extensionSyncData: "Extension sync data"
        case .passwords: "Passwords"
        case .aiKeys: "AI API keys"
        case .downloadHistory: "Download history"
        }
    }
}

enum ICloudFailure: LocalizedError, Equatable {
    case unavailable(String), accountChanged, invalid(String), storage(String), unsupportedSchema, limitExceeded
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalid(let message), .storage(let message): message
        case .accountChanged: "Your Apple Account changed. Review which local data to merge before resuming iCloud sync."
        case .unsupportedSchema: "This iCloud data needs a newer version of Vane. Update Vane to continue syncing."
        case .limitExceeded: "This sync contains an item larger than the supported limit. Your local data and pending changes have been kept."
        }
    }
}

struct ICloudItem: Codable, Equatable, Sendable {
    var category: ICloudCategory
    var id: String
    var profileID: UUID?
    var parentID: String?
    var fields: [String: Data]
    var key: String { ICloudIdentity.recordKey(category: category, id: id, profileID: profileID) }

    static func encodedFields<T: Encodable>(_ value: T) throws -> [String: Data] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ICloudFailure.invalid("An iCloud entity must have named fields.")
        }
        return try object.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let object = try fields.mapValues { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
    func validate() throws {
        guard !category.isSecret, profileID != Profile.incognito.id,
              !id.isEmpty, id.utf8.count <= 2048, (parentID?.utf8.count ?? 0) <= 2048,
              fields.count <= 512, fields.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw ICloudFailure.invalid("An iCloud entity has an invalid identity or category.")
        }
        guard fields.values.allSatisfy({ $0.count <= ICloudLimits.assetBytes }),
              fields.values.reduce(0, { $0 + $1.count }) <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
    }
}

enum ICloudLimits {
    static let inlineBytes = 256 * 1024
    static let assetBytes = 32 * 1024 * 1024
    static let cycleBytes = 256 * 1024 * 1024
    static let batchCount = 200
}

enum ICloudIdentity {
    static func recordKey(category: ICloudCategory, id: String, profileID: UUID?) -> String {
        category.rawValue + ":" + (profileID?.uuidString.lowercased() ?? "global") + ":" + id
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func uuid(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct ICloudVersion: Codable, Equatable, Sendable {
    var vector: [String: UInt64]
    var writer: String
    var counter: UInt64
    var isValid: Bool {
        !writer.isEmpty && writer.utf8.count <= 128 && counter > 0 && counter < UInt64.max
            && vector.count <= 1000 && vector[writer] == counter
            && vector.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value > 0 && $0.value < UInt64.max }
    }
    func dominates(_ other: Self) -> Bool { other.vector.allSatisfy { vector[$0.key, default: 0] >= $0.value } }
    static func preferred(_ a: Self, _ b: Self) -> Self {
        if a.dominates(b), !b.dominates(a) { return a }
        if b.dominates(a), !a.dominates(b) { return b }
        return a.counter == b.counter ? (a.writer >= b.writer ? a : b) : (a.counter >= b.counter ? a : b)
    }
}

struct ICloudField: Codable, Equatable, Sendable {
    var value: Data?
    var version: ICloudVersion
}

struct ICloudRecord: Codable, Equatable, Sendable {
    var category: ICloudCategory
    var id: String
    var profileID: UUID?
    var parentID: String?
    var fields: [String: ICloudField]
    var deletion: ICloudVersion?
    var parentVersion: ICloudVersion? = nil
    var birthVersion: ICloudVersion? = nil
    var key: String { ICloudIdentity.recordKey(category: category, id: id, profileID: profileID) }
    var item: ICloudItem {
        ICloudItem(category: category, id: id, profileID: profileID, parentID: parentID, fields: fields.compactMapValues(\.value))
    }
    var vector: [String: UInt64] {
        var result: [String: UInt64] = [:]
        for version in fields.values.map(\.version) + [deletion, parentVersion, birthVersion].compactMap({ $0 }) {
            for (writer, counter) in version.vector { result[writer] = max(result[writer, default: 0], counter) }
        }
        return result
    }
    static func merged(_ lhs: Self, _ rhs: Self) -> Self {
        precondition(lhs.key == rhs.key)
        var result = lhs
        if let birth = rhs.birthVersion {
            result.birthVersion = lhs.birthVersion.map { ICloudVersion.preferred($0, birth) } ?? birth
        }
        // A re-created fixed-key entity must not inherit fields from its deleted
        // incarnation. Its birth includes the observed deletion in its vector.
        func belongsToBirth(_ field: ICloudField) -> Bool {
            result.birthVersion.map { field.version.dominates($0) } ?? true
        }
        result.fields = result.fields.filter { belongsToBirth($0.value) }
        for (key, field) in rhs.fields {
            guard belongsToBirth(field) else { continue }
            if let old = result.fields[key] {
                if old.version == field.version {
                    // Corrupt or duplicated writers must still converge independently
                    // of delivery order; empty Data and a removed field are distinct.
                    if old.value == nil || field.value == nil { result.fields[key] = old.value == nil ? old : field }
                    else { result.fields[key] = old.value!.lexicographicallyPrecedes(field.value!) ? field : old }
                } else { result.fields[key] = ICloudVersion.preferred(old.version, field.version) == field.version ? field : old }
            } else { result.fields[key] = field }
        }
        if let right = rhs.deletion {
            if let left = lhs.deletion {
                // A delete is a causal barrier, not a last-writer value. Retain
                // every observed delete clock so a birth that saw only one
                // cannot clear another concurrent deletion on stale delivery.
                var vector = left.vector
                for (writer, counter) in right.vector { vector[writer] = max(vector[writer, default: 0], counter) }
                let writer = max(left.writer, right.writer)
                result.deletion = ICloudVersion(vector: vector, writer: writer, counter: vector[writer]!)
            } else { result.deletion = right }
        }
        if let birth = result.birthVersion, let deletion = result.deletion,
           birth.dominates(deletion), !deletion.dominates(birth) { result.deletion = nil }
        if let right = rhs.parentVersion {
            let winner = lhs.parentVersion.map { ICloudVersion.preferred($0, right) } ?? right
            if winner == right { result.parentID = rhs.parentID; result.parentVersion = right }
        } else if lhs.parentVersion == nil {
            result.parentID = [lhs.parentID, rhs.parentID].compactMap { $0 }.max()
        }
        return result
    }
    func validate() throws {
        try item.validate()
        guard fields.values.allSatisfy({ $0.version.isValid }), deletion?.isValid ?? true,
              parentVersion?.isValid ?? true, birthVersion?.isValid ?? true else {
            throw ICloudFailure.invalid("An iCloud entity has invalid edit versions.")
        }
    }
}

@MainActor protocol ICloudAdapter {
    var categories: Set<ICloudCategory> { get }
    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem]
    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws
}

struct ICloudExchange: Sendable {
    var received: [ICloudRecord] = []
    var acknowledged: [ICloudRecord] = []
    var state: Data?
    var reset: Set<ICloudCategory> = []
    var epochs: [ICloudCategory: String] = [:]
}

@MainActor protocol ICloudTransport {
    func revoke()
    func account() async throws -> String
    func exchange(pending: [ICloudRecord], enabled: Set<ICloudCategory>, state: Data?,
                  epochs: [ICloudCategory: String], persistState: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudExchange
    func remove(_ categories: Set<ICloudCategory>) async throws
    func rebindAccount() async throws -> String
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence]
    func hasPendingRemovals() async throws -> Bool
    func resumeRemovals() async throws
}

extension ICloudTransport {
    func revoke() {}
    func rebindAccount() async throws -> String { try await account() }
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence] { [] }
    func hasPendingRemovals() async throws -> Bool { false }
    func resumeRemovals() async throws {}
}

struct ICloudDeletionFence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case profile, space }
    var kind: Kind
    var profileID: UUID
    var id: String
    var key: String { kind.rawValue + ":" + profileID.uuidString.lowercased() + ":" + id.lowercased() }
    func validate() throws {
        guard profileID != Profile.incognito.id, let identity = UUID(uuidString: id),
              kind != .profile || identity == profileID else { throw ICloudFailure.invalid("An iCloud deletion fence has an invalid identity.") }
    }
}
