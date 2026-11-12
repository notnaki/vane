import Foundation

/// Portable package identity is independent of a Mac's existing WebKit runtime ID.
enum ICloudExtensionIdentity {
    static func portableID(_ record: ExtensionCodeStore.Record, profile: UUID) -> String {
        if let safari = record.safari {
            return ICloudIdentity.uuid("safari/" + profile.uuidString.lowercased() + safari.key).uuidString.lowercased()
        }
        if let storeID = record.store?.id ?? record.iCloudStoreID {
            return ICloudIdentity.uuid("chrome-store/" + profile.uuidString.lowercased() + storeID).uuidString.lowercased()
        }
        return (record.iCloudIdentity ?? record.identity).lowercased()
    }
}

struct ICloudExtensionNamespace: Codable, Hashable, Sendable {
    var profileID: UUID
    var extensionID: String
    var key: String { profileID.uuidString.lowercased() + "/" + extensionID }
    func validate() throws {
        guard profileID != Profile.incognito.id, UUID(uuidString: extensionID) != nil,
              extensionID == extensionID.lowercased() else {
            throw ICloudFailure.invalid("Extension sync data has an invalid profile or installation identity.")
        }
    }
}

struct ICloudExtensionInstallation: Sendable {
    var namespace: ICloudExtensionNamespace
    var installationID: String
}

/// nil native baseline is deliberately different from an observed empty namespace.
/// Unknown applies remote values over a newly activated extension's initial defaults.
enum ICloudExtensionStorageExpected: Codable, Equatable, Sendable {
    case unknown, absent, value(Data)
}

struct ICloudExtensionStorageMutation: Codable, Equatable, Sendable {
    var key: String
    var value: Data?
    var expected: ICloudExtensionStorageExpected
}

@MainActor protocol ICloudExtensionStorageSession: AnyObject {
    func check() throws
    func read() async throws -> [String: Data]
    func apply(_ mutations: [ICloudExtensionStorageMutation]) async throws -> [String: Data]
    func close()
}

enum ICloudExtensionStorageJSON {
    static let itemBytes = 8192
    static let namespaceBytes = 102400
    static let keyCount = 512

    static func canonical(_ data: Data) throws -> Data {
        guard data.count <= itemBytes else { throw ICloudFailure.limitExceeded }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }
    static func value(_ data: Data, key: String) throws -> Data {
        let data = try canonical(data)
        guard key.utf8.count + data.count <= itemBytes else { throw ICloudFailure.limitExceeded }
        return data
    }
    static func snapshot(_ values: [String: Data]) throws -> [String: Data] {
        guard values.count <= keyCount else { throw ICloudFailure.limitExceeded }
        var bytes = 0, result: [String: Data] = [:]
        for (key, data) in values {
            let canonical = try value(data, key: key)
            bytes += key.utf8.count + canonical.count
            guard bytes <= namespaceBytes else { throw ICloudFailure.limitExceeded }
            result[key] = canonical
        }
        return result
    }
    static func item(namespace: ICloudExtensionNamespace, key: String, value: Data) throws -> ICloudItem {
        try namespace.validate()
        let value = try self.value(value, key: key)
        return ICloudItem(category: .extensionSyncData,
            id: namespace.extensionID + "/" + ICloudIdentity.digest(key), profileID: namespace.profileID, parentID: nil,
            fields: ["extensionID": try JSONEncoder().encode(namespace.extensionID),
                "key": try JSONEncoder().encode(key), "value": value])
    }
    static func decode(_ item: ICloudItem) throws -> (ICloudExtensionNamespace, String, Data) {
        guard item.category == .extensionSyncData, let profile = item.profileID, item.parentID == nil,
              Set(item.fields.keys) == ["extensionID", "key", "value"],
              let extensionData = item.fields["extensionID"], extensionData.count <= 128,
              let keyData = item.fields["key"], keyData.count <= itemBytes * 6,
              let value = item.fields["value"] else {
            throw ICloudFailure.invalid("Extension sync data has invalid named fields.")
        }
        let ns = ICloudExtensionNamespace(profileID: profile, extensionID: try JSONDecoder().decode(String.self, from: extensionData))
        let key = try JSONDecoder().decode(String.self, from: keyData)
        try ns.validate()
        guard item.id == ns.extensionID + "/" + ICloudIdentity.digest(key) else {
            throw ICloudFailure.invalid("Extension sync data does not match its portable key identity.")
        }
        return (ns, key, try self.value(value, key: key))
    }
}
