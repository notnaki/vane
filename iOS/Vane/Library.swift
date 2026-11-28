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
    /// The Mac's theme: up to three colours, how strongly they tint the ground (0…1, default
    /// 0.8), film grain (0…1), and "light"/"dark" or nil to follow the system.
    var colors: [String]? = nil, tint: Double? = nil, grain: Double? = nil, appearance: String? = nil
    var isLocal: Bool { profileID == Local.profile }
    var isIncognito: Bool { id == Self.incognito.id }
    /// Incognito, as on the Mac: black, never saved, never synced.
    static let incognito = SpaceRow(id: Profile.incognito.id, profileID: Profile.incognito.id, name: "Incognito",
                                    icon: "eyeglasses", colorHex: "#000000", appearance: "dark")
    var palette: [String] { colors ?? colorHex.map { [$0] } ?? [] }
}
struct LinkRow: Identifiable, Hashable {
    let id: String
    var url: URL, title: String
}
/// A sidebar folder in a Space's Pinned or Today section, with what's filed inside it.
/// Today folders arrive without tabs: on the Mac those are open tabs, not pinned ones.
struct FolderRow: Identifiable, Hashable {
    let id: UUID
    var name: String, locked: Bool, today = false
    var links: [LinkRow], folders: [FolderRow]
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
    /// History is off by default, as on the Mac, because it is the largest category.
    var syncHistory = UserDefaults.standard.bool(forKey: "icloud.history") {
        didSet { UserDefaults.standard.set(syncHistory, forKey: "icloud.history"); onEdit() }
    }
    var categories: Set<ICloudCategory> {
        let base: Set<ICloudCategory> = [.profiles, .spaces, .favourites, .pinnedTabs, .sidebarFolders, .bookmarks, .openTabs]
        return syncHistory ? base.union([.history]) : base
    }
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
        // The Mac's global Space order, when it has one, wins over per-profile positions.
        let global = items.values.first(where: \.isSpaceOrder).flatMap { value($0, "ids", [UUID].self) } ?? []
        let rank = Dictionary(global.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let rows = all(.spaces).compactMap { item -> SpaceRow? in
            guard let pid = item.profileID, let id = UUID(uuidString: item.id) else { return nil }
            return SpaceRow(id: id, profileID: pid, name: value(item, "name", String.self) ?? "Space",
                            icon: value(item, "icon", String.self), colorHex: value(item, "colorHex", String.self),
                            colors: value(item, "colors", [String].self), tint: value(item, "tint", Double.self),
                            grain: value(item, "grain", Double.self), appearance: value(item, "appearance", String.self))
        }.enumerated().sorted { (order[$0.element.profileID] ?? .max, $0.offset) < (order[$1.element.profileID] ?? .max, $1.offset) }.map(\.element)
        return global.isEmpty ? rows : rows.enumerated().sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }.map(\.element)
    }
    func profileName(_ id: UUID) -> String? {
        all(.profiles).first { $0.profileID == id }.flatMap { value($0, "name", String.self) }
    }
    func favourites(profile: UUID) -> [LinkRow] {
        all(.favourites).filter { $0.profileID == profile }.compactMap { item in
            guard let raw = value(item, "url", String.self), let url = URL(string: raw) else { return nil }
            let host = url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            return LinkRow(id: item.key, url: url, title: value(item, "customName", String.self) ?? host ?? raw)
        }
    }
    /// Pinned tabs not inside a folder.
    func pinned(space: UUID) -> [LinkRow] { pinnedRows(space: space, folder: nil) }
    private func pinnedRows(space: UUID, folder: UUID?) -> [LinkRow] {
        all(.pinnedTabs).filter { $0.parentID == space.uuidString && value($0, "parentFolderID", UUID?.self) ?? nil == folder }.compactMap { item in
            guard let url = value(item, "url", URL.self) else { return nil }
            let title = value(item, "customName", String.self) ?? value(item, "title", String.self)
            return LinkRow(id: item.key, url: url, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? url.absoluteString)
        }
    }
    /// The Pinned section's folders, then Today's, nested as on the Mac.
    func folders(space: UUID, parent: UUID? = nil) -> [FolderRow] {
        let rows = all(.sidebarFolders).filter {
            $0.parentID == space.uuidString && (value($0, "parentFolderID", UUID?.self) ?? nil) == parent
        }.compactMap { item -> FolderRow? in
            guard let id = UUID(uuidString: item.id), let section = value(item, "section", Int.self), section == 1 || section == 2 else { return nil }
            return FolderRow(id: id, name: value(item, "name", String.self) ?? "Folder",
                             locked: value(item, "requiresAuthentication", Bool.self) == true, today: section == 2,
                             links: pinnedRows(space: space, folder: id), folders: folders(space: space, parent: id))
        }
        return rows.filter { !$0.today } + rows.filter(\.today)
    }
    /// Bookmarks by folder; unfiled ones first under a nil name.
    func bookmarks(profile: UUID) -> [(folder: String?, links: [LinkRow])] {
        let all = all(.bookmarks).filter { $0.profileID == profile }
        let folders = all.filter { $0.id.hasPrefix("folder:") }
        let pages = all.filter { !$0.id.hasPrefix("folder:") }.compactMap { item -> (String?, LinkRow)? in
            guard let raw = value(item, "url", String.self), let url = URL(string: raw) else { return nil }
            let title = value(item, "title", String.self).flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? raw
            return (value(item, "folderID", String?.self) ?? nil, LinkRow(id: item.key, url: url, title: title))
        }
        let loose = pages.filter { folder in !folders.contains { $0.id == "folder:" + (folder.0 ?? "") } }.map(\.1)
        let filed = folders.map { folder in
            (folder: Optional(value(folder, "name", String.self) ?? "Folder"),
             links: pages.filter { "folder:" + ($0.0 ?? "") == folder.id }.map(\.1))
        }.filter { !$0.links.isEmpty }
        return (loose.isEmpty ? [] : [(nil, loose)]) + filed
    }
    func bookmarked(_ url: URL, profile: UUID) -> String? {
        all(.bookmarks).first { $0.profileID == profile && value($0, "url", String.self) == url.absoluteString }?.key
    }
    /// History synced from other devices, newest first.
    var syncedHistory: [Visit] {
        items.values.filter { $0.category == .history }.compactMap { item in
            guard let raw = value(item, "url", String.self), let url = URL(string: raw), let at = value(item, "at", Double.self) else { return nil }
            return Visit(url: url, title: value(item, "title", String.self) ?? raw, at: Date(timeIntervalSince1970: at))
        }.sorted { $0.at > $1.at }
    }

    /// Other devices' open tabs, by device name.
    var remoteTabs: [(device: String, tabs: [RemoteTab])] {
        let tabs = all(.openTabs).compactMap { try? $0.decode(RemoteTab.self) }.filter { $0.deviceID != deviceID }
        return Dictionary(grouping: tabs, by: \.deviceName).sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.position < $1.position }) }
    }
    var hasSyncedProfiles: Bool { !all(.profiles).isEmpty }
    /// Where this phone's tabs are filed on other devices: the Space's profile, else the first synced one.
    /// The Space with this id, Incognito included.
    func space(_ id: UUID) -> SpaceRow? { id == SpaceRow.incognito.id ? .incognito : spaces.first { $0.id == id } }

    func publishingProfile(for space: UUID) -> UUID? {
        guard space != SpaceRow.incognito.id else { return nil }
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
    /// Bookmark and history fields are written the way the Mac's Store writes them
    /// (JSONSerialization), so the Mac's read-back is byte-identical and sends no echo.
    private func page(_ url: URL, _ title: String) -> [String: Data] {
        let object: [String: Any] = ["url": url.absoluteString, "title": title, "at": Date.now.timeIntervalSince1970, "kind": "page", "folderID": NSNull()]
        return object.mapValues { try! JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }
    func addBookmark(_ url: URL, title: String, profile: UUID) {
        guard bookmarked(url, profile: profile) == nil else { return }
        put(.bookmarks, id: UUID().uuidString, profile: profile, parent: nil, page(url, title))
    }
    /// A visit on this device, published while history sync is on.
    func addVisit(_ url: URL, title: String, profile: UUID) {
        guard syncHistory else { return }
        let item = ICloudItem(category: .history, id: UUID().uuidString, profileID: profile, parentID: nil, fields: page(url, title))
        items[item.key] = item
        save(); onEdit()
    }
    /// Clearing history here clears synced history everywhere it syncs.
    func clearSyncedHistory() {
        items = items.filter { $0.value.category != .history }
        save(); onEdit()
    }
    @discardableResult func addSpace(_ name: String, profile: UUID) -> UUID {
        let id = UUID()
        put(.spaces, id: id.uuidString, profile: profile, parent: nil,
            ["name": enc(name), "position": enc(spaces.filter { $0.profileID == profile }.count)])
        return id
    }
    func renameSpace(_ space: SpaceRow, to name: String) { editSpace(space) { $0["name"] = enc(name) } }

    /// The same fields the Mac's theme editor writes (`Spaces.setThemeColors`): its exact
    /// P3 palette is dropped, so the Mac reads these hex colours as the theme.
    func setTheme(_ space: SpaceRow) {
        let colors = Array(space.palette.prefix(3))
        editSpace(space) { fields in
            fields["colors"] = colors.isEmpty ? nil : enc(colors)
            fields["colorHex"] = colors.first.map(enc)
            fields["themePalette"] = nil; fields["themeHarmony"] = nil
            fields["tint"] = space.tint.map(enc)
            fields["grain"] = space.grain.map(enc)
            fields["appearance"] = space.appearance.map(enc)
            fields["icon"] = space.icon.flatMap { $0.isEmpty ? nil : enc($0) }
            fields["name"] = enc(space.name)
        }
    }
    private func editSpace(_ space: SpaceRow, _ change: (inout [String: Data]) -> Void) {
        guard var item = items[ICloudIdentity.recordKey(category: .spaces, id: space.id.uuidString, profileID: space.profileID)] else { return }
        change(&item.fields)
        items[item.key] = item; save(); onEdit()
    }
    /// A favourite's or pinned tab's own name; nil goes back to the page's.
    func setCustomName(_ key: String, to name: String?) {
        guard var item = items[key] else { return }
        item.fields["customName"] = enc(name.flatMap { $0.isEmpty ? nil : $0 })
        items[key] = item; save(); onEdit()
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

    /// A Mac backup's records (`MacBackup`), merged as an iCloud exchange merges them.
    /// Importing again updates the same records rather than adding copies.
    func importBackup(_ records: [ICloudItem]) async throws {
        try await apply(records, deleted: [], enabled: categories)
        onEdit()
    }

    /// After an Apple Account change or a removal on another device: synced copies go, local ones stay.
    func dropSynced(_ categories: Set<ICloudCategory>) {
        items = items.filter { !categories.contains($0.value.category) || $0.value.profileID == Local.profile }
        save()
    }

    // ponytail: rewrites the whole file on each edit; with history sync on that is every
    // visit. Debounce or move to SQLite if large synced histories make this measurable.
    private func save() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
