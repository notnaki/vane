import Foundation
import CryptoKit

/// The two names the shared Mac sync files expect from the app around them.
enum Store {
    static let directory = URL.applicationSupportDirectory.appending(path: "Vane", directoryHint: .isDirectory)
}
struct Profile {
    let id: UUID
    static let incognito = Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
}

/// The library before any Mac is connected. Its items never leave the phone.
enum Local {
    static let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000AB1E")!
    static let space = UUID(uuidString: "00000000-0000-0000-0000-00000000AB1F")!
}

struct SpaceRow: Identifiable, Hashable {
    let id: UUID, profileID: UUID
    var name: String, icon: String?, colorHex: String?
    var isLocal: Bool { profileID == Local.profile }
}
struct LinkRow: Identifiable, Hashable {
    let id: String
    var url: URL, title: String
}
/// Same shape as the Mac's `ICloudRemoteTab`, so open tabs read both ways.
struct RemoteTab: Codable, Equatable, Identifiable {
    var id: String
    var deviceID: String
    var deviceName: String
    var profileID: UUID
    var spaceID: UUID?
    var url: URL
    var title: String
    var position: Int
    var at: Date?
}

/// Every synced record, kept verbatim. Fields this app doesn't show go back to iCloud
/// byte for byte, so the Mac never sees them as deleted. Identities and field encodings
/// match `ICloudLibraryAdapter` on the Mac, which is what lets each side read the other.
@MainActor @Observable final class Library: ICloudAdapter {
    let categories: Set<ICloudCategory> = [.profiles, .spaces, .favourites, .pinnedTabs, .openTabs]
    private(set) var items: [String: ICloudItem] = [:]
    let deviceID: String
    var deviceName = "iPhone"
    /// This device's open tabs, published as its own `openTabs` records.
    var ownTabs: () -> [RemoteTab] = { [] }
    var onEdit: () -> Void = {}
    private let file = Store.directory.appending(path: "library.json")

    init(deviceID: String) {
        self.deviceID = deviceID
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: ICloudItem].self, from: data) { items = saved }
        if spaces.isEmpty { put(.spaces, id: Local.space.uuidString, profile: Local.profile, parent: nil, ["name": enc("Personal"), "position": enc(0)]) }
    }

    // MARK: Reading

    private func value<T: Decodable>(_ item: ICloudItem, _ key: String, _ type: T.Type) -> T? {
        item.fields[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func position(_ item: ICloudItem) -> Int { value(item, "position", Int.self) ?? .max }
    private func all(_ category: ICloudCategory) -> [ICloudItem] {
        items.values.filter { $0.category == category }.sorted { (position($0), $0.id) < (position($1), $1.id) }
    }

    /// Synced profiles in the Mac's order, then this phone's own.
    var spaces: [SpaceRow] {
        let order = Dictionary(all(.profiles).enumerated().compactMap { index, item in item.profileID.map { ($0, index) } }, uniquingKeysWith: min)
        return all(.spaces).compactMap { item -> SpaceRow? in
            guard let pid = item.profileID, let id = UUID(uuidString: item.id) else { return nil }
            return SpaceRow(id: id, profileID: pid, name: value(item, "name", String.self) ?? "Space",
                            icon: value(item, "icon", String.self), colorHex: value(item, "colorHex", String.self))
        }.enumerated().sorted { (order[$0.element.profileID] ?? .max, $0.offset) < (order[$1.element.profileID] ?? .max, $1.offset) }.map(\.element)
    }
    func profileName(_ id: UUID) -> String? {
        all(.profiles).first { $0.profileID == id }.flatMap { value($0, "name", String.self) }
    }
    func favourites(profile: UUID) -> [LinkRow] {
        all(.favourites).filter { $0.profileID == profile }.compactMap { item in
            guard let raw = value(item, "url", String.self), let url = URL(string: raw) else { return nil }
            return LinkRow(id: item.key, url: url, title: value(item, "customName", String.self) ?? url.host() ?? raw)
        }
    }
    func pinned(space: UUID) -> [LinkRow] {
        all(.pinnedTabs).filter { $0.parentID == space.uuidString }.compactMap { item in
            guard let url = value(item, "url", URL.self) else { return nil }
            let title = value(item, "customName", String.self) ?? value(item, "title", String.self)
            return LinkRow(id: item.key, url: url, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? url.absoluteString)
        }
    }
    /// Other devices' open tabs, by device name.
    var remoteTabs: [(device: String, tabs: [RemoteTab])] {
        let tabs = all(.openTabs).compactMap { try? $0.decode(RemoteTab.self) }.filter { $0.deviceID != deviceID }
        return Dictionary(grouping: tabs, by: \.deviceName).sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.position < $1.position }) }
    }
    var hasSyncedProfiles: Bool { !all(.profiles).isEmpty }
    /// Where this phone's tabs are filed on other devices: the Space's profile, else the first synced one.
    func publishingProfile(for space: UUID) -> UUID? {
        if let row = spaces.first(where: { $0.id == space }), !row.isLocal { return row.profileID }
        return all(.profiles).first?.profileID
    }

    // MARK: Editing (same identities and encodings as the Mac)

    private func enc<T: Encodable>(_ value: T) -> Data { try! JSONEncoder().encode(value) }
    private static func stable(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func put(_ category: ICloudCategory, id: String, profile: UUID, parent: String?, _ fields: [String: Data]) {
        let item = ICloudItem(category: category, id: id, profileID: profile, parentID: parent, fields: fields)
        items[item.key] = item
        save(); onEdit()
    }
    func remove(_ key: String) { items[key] = nil; save(); onEdit() }

    func addFavourite(_ url: URL, profile: UUID) {
        let raw = url.absoluteString
        guard !favourites(profile: profile).contains(where: { $0.url == url }) else { return }
        put(.favourites, id: Self.stable("\(profile)|\(raw)"), profile: profile, parent: nil,
            ["url": enc(raw), "position": enc(favourites(profile: profile).count), "customName": enc(String?.none)])
    }
    func addPinned(_ url: URL, title: String, space: SpaceRow) {
        guard !pinned(space: space.id).contains(where: { $0.url == url }) else { return }
        put(.pinnedTabs, id: UUID().uuidString, profile: space.profileID, parent: space.id.uuidString,
            ["url": enc(url), "title": enc(title), "customName": enc(String?.none), "position": enc(pinned(space: space.id).count),
             "spaceID": enc(space.id), "parentFolderID": enc(UUID?.none)])
    }
    @discardableResult func addSpace(_ name: String, profile: UUID) -> UUID {
        let id = UUID()
        put(.spaces, id: id.uuidString, profile: profile, parent: nil,
            ["name": enc(name), "position": enc(spaces.filter { $0.profileID == profile }.count)])
        return id
    }
    func renameSpace(_ space: SpaceRow, to name: String) {
        guard var item = items[ICloudIdentity.recordKey(category: .spaces, id: space.id.uuidString, profileID: space.profileID)] else { return }
        item.fields["name"] = enc(name)
        items[item.key] = item; save(); onEdit()
    }
    /// Deleting a Space takes its pinned tabs with it, here and on every synced device.
    func deleteSpace(_ space: SpaceRow) {
        items = items.filter { $0.value.parentID != space.id.uuidString }
        remove(ICloudIdentity.recordKey(category: .spaces, id: space.id.uuidString, profileID: space.profileID))
    }

    // MARK: ICloudAdapter

    private func isOwnTab(_ item: ICloudItem) -> Bool { item.category == .openTabs && item.id.hasPrefix(deviceID + "|") }

    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        var out = items.values.filter { enabled.contains($0.category) && $0.profileID != Local.profile && !isOwnTab($0) }
        if enabled.contains(.openTabs) {
            out += try ownTabs().map { tab in
                ICloudItem(category: .openTabs, id: tab.id, profileID: tab.profileID, parentID: tab.spaceID?.uuidString, fields: try ICloudItem.encodedFields(tab))
            }
        }
        return out
    }

    func apply(_ incoming: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        for item in deleted where enabled.contains(item.category) { items[item.key] = nil }
        for item in incoming where enabled.contains(item.category) && !isOwnTab(item) && item.profileID != Local.profile {
            let base = ICloudApplyContext.baseline[item.key]
            guard let current = items[item.key] else {
                // Removed here while the exchange was in flight: the next capture sends the deletion.
                if base == nil { items[item.key] = item }
                continue
            }
            // Keep fields edited here since the capture; take everything else from iCloud.
            var merged = item
            if let base, current.fields != base.fields {
                merged.fields = current.fields.merging(ICloudApplyContext.reconcile(item, current: current.fields).fields) { _, new in new }
            }
            items[item.key] = merged
        }
        save()
    }

    /// After an Apple Account change or a removal on another device: synced copies go, local ones stay.
    func dropSynced(_ categories: Set<ICloudCategory>) {
        items = items.filter { !categories.contains($0.value.category) || $0.value.profileID == Local.profile }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
