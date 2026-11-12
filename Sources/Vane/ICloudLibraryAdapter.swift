import Foundation
import Combine
import CryptoKit

struct ICloudRemoteTab: Codable, Equatable, Identifiable, Sendable {
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

/// Portable completed-download metadata deliberately has no file URL or grant API.
struct ICloudRemoteDownload: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var deviceID: String
    var deviceName: String
    var profileID: UUID
    var source: URL?
    var name: String
    var size: Int64
    var completed: Date
}

@MainActor final class ICloudLibraryAdapter: ObservableObject, ICloudAdapter {
    let categories: Set<ICloudCategory> = [.profiles, .spaces, .favourites, .pinnedTabs, .sidebarFolders,
        .bookmarks, .history, .openTabs, .recentlyClosedTabs, .spaceTemplates, .downloadHistory]
    @Published private(set) var remoteTabs: [ICloudRemoteTab] = []
    @Published private(set) var remoteRecentlyClosedTabs: [ICloudRemoteTab] = []
    @Published private(set) var remoteDownloads: [ICloudRemoteDownload] = []
    let directory: URL
    let profiles: ProfileManager
    private let defaults: UserDefaults
    private let deviceID: String
    private let deviceName: String
    private let storeProvider: ((UUID) -> Store)?
    private var stores: [UUID: Store] = [:]
    private var spacesCache: [UUID: (revision: Int, spaces: [Space])] = [:]
    private var remoteLoaded = false
    private var accountNamespace: String?
    private var remoteItems: [ICloudItem] = []
    private var deletedProfiles = Set<UUID>()
    private var deletedSpaces = Set<String>()

    init(directory: URL = Store.directory, defaults: UserDefaults = .vane, deviceID: String,
         deviceName: String = Host.current().localizedName ?? "Mac", profiles: ProfileManager? = nil,
         storeProvider: ((UUID) -> Store)? = nil) {
        self.directory = directory; self.defaults = defaults; self.deviceID = deviceID; self.deviceName = deviceName
        self.profiles = profiles ?? (directory.standardizedFileURL == Store.directory.standardizedFileURL
            ? ProfileManager.shared : ProfileManager(directory: directory, sandboxed: true))
        self.storeProvider = storeProvider
    }

    func localStore(for id: UUID) -> Store {
        if let storeProvider { return storeProvider(id) }
        if !profiles.sandboxed { return Store.store(for: id) }
        if let existing = stores[id] { return existing }
        let store = Store(path: ProfileManager.dbURL(for: id, in: directory).path, profileID: id)
        stores[id] = store; return store
    }

    func ensureProfile(_ id: UUID) async throws { try profiles.ensureICloudProfile(id) }

    /// Opaque, committed ancestor identities. Absence becomes a fence only in the
    /// journal after this complete inventory succeeds; it contains no parent payload.
    func ancestorInventory() async throws -> [ICloudDeletionFence] {
        while true {
            try ICloudApplyContext.check()
            try await captureBarrier()
            let profileIDs = profiles.profiles.map(\.id).filter { $0 != Profile.incognito.id }
            let revision = profiles.spacesRevision
            let directory = directory
            let result: Result<[ICloudDeletionFence], Error> = await SessionPersistence.shared.perform {
                Result {
                    var inventory = profileIDs.map { ICloudDeletionFence(kind: .profile, profileID: $0, id: $0.uuidString) }
                    for profileID in profileIDs {
                        let file = ProfileManager.spacesURL(for: profileID, in: directory)
                        let spaces: [Space]
                        do { spaces = try JSONDecoder().decode([Space].self, from: Data(contentsOf: file)) }
                        catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                        guard spaces.allSatisfy({ $0.profileID == profileID }), Set(spaces.map(\.id)).count == spaces.count else { throw CocoaError(.fileReadCorruptFile) }
                        inventory += spaces.map { ICloudDeletionFence(kind: .space, profileID: profileID, id: $0.id.uuidString) }
                    }
                    return inventory
                }
            }
            try ICloudApplyContext.check()
            guard profiles.profiles.map(\.id).filter({ $0 != Profile.incognito.id }) == profileIDs,
                  profiles.spacesRevision == revision else { continue }
            return try result.get()
        }
    }

    /// Other Macs' observations and dependency tombstones never cross Apple Accounts.
    /// Previous files remain quarantined locally and are not admitted to a new account.
    func setAccountNamespace(_ account: String) throws {
        let namespace = stable(account)
        guard accountNamespace != namespace else { return }
        accountNamespace = namespace; remoteLoaded = false
        remoteItems = []; deletedProfiles = []; deletedSpaces = []
        remoteTabs = []; remoteRecentlyClosedTabs = []; remoteDownloads = []
        try loadRemote()
    }

    private func fields<T: Encodable>(_ value: T) throws -> [String: Data] { try ICloudItem.encodedFields(value) }
    private func data<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private func field<T: Decodable>(_ item: ICloudItem, _ key: String, _ type: T.Type) throws -> T {
        guard let bytes = item.fields[key] else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: bytes)
    }
    private func merging<T: Codable>(_ item: ICloudItem, into value: T) throws -> T {
        var object = try fields(value)
        var current = object
        // Routing metadata isn't part of the Codable native value. Its actual value
        // is reconciled by the category owner; leave it unchanged in this generic pass.
        for key in ["position", "spaceID", "section", "parentFolderID"] {
            current[key] = ICloudApplyContext.baseline[item.key]?.fields[key]
        }
        object.merge(ICloudApplyContext.reconcile(item, current: current).fields) { _, remote in remote }
        return try ICloudItem(category: item.category, id: item.id, profileID: item.profileID,
            parentID: item.parentID, fields: object).decode(T.self)
    }
    private func spaceFenceKey(_ profile: UUID, _ id: UUID) -> String {
        ICloudDeletionFence(kind: .space, profileID: profile, id: id.uuidString).key
    }

    func applyAncestorFences(_ fences: [ICloudDeletionFence], enabled: Set<ICloudCategory>) throws {
        try ICloudApplyContext.check()
        try loadRemote()
        let checkpoint = remoteCheckpoint()
        var committed = false
        defer { if !committed { restoreRemote(checkpoint) } }
        for fence in fences { try fence.validate() }
        for fence in fences {
            switch fence.kind {
            case .profile:
                deletedProfiles.insert(fence.profileID)
                remoteItems.removeAll { enabled.contains($0.category) && $0.profileID == fence.profileID }
            case .space:
                guard let sid = UUID(uuidString: fence.id) else { throw CocoaError(.fileReadCorruptFile) }
                deletedSpaces.insert(spaceFenceKey(fence.profileID, sid))
                remoteItems.removeAll { enabled.contains($0.category) && $0.profileID == fence.profileID && $0.parentID.flatMap(UUID.init(uuidString:)) == sid }
            }
        }
        // Only opaque admission fences change here. Selected descendant tombstones
        // flow through their owners; disabled native parent payload stays untouched.
        try ICloudApplyContext.check()
        try saveRemote(); try publishRemote()
        committed = true
    }

    private func stable(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func web(_ url: URL?) -> Bool { url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
    private func read<T: Decodable>(_ type: T.Type, at file: URL, missing: T) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return missing }
    }
    private func shape(_ kind: TabKind, space: Space) throws -> Pins {
        if let layout = space.layout { return kind == .pinned ? layout.pins : layout.today }
        guard let bytes = defaults.data(forKey: TabStore.shapeKey(kind, space: space.id, profileID: space.profileID)) else { return Pins() }
        return try JSONDecoder().decode(Pins.self, from: bytes)
    }
    private func committedSpaces(for profileID: UUID) throws -> [Space] {
        if let cached = spacesCache[profileID], cached.revision == profiles.spacesRevision { return cached.spaces }
        let spaces = try profiles.committedICloudSpaces(for: profileID)
        spacesCache[profileID] = (profiles.spacesRevision, spaces)
        return spaces
    }
    private func saveSpaces(_ spaces: [Space], for profileID: UUID) throws -> Bool {
        try ICloudApplyContext.check()
        guard profiles.saveSpaces(spaces, for: profileID) else { return false }
        spacesCache[profileID] = (profiles.spacesRevision, spaces)
        return true
    }
    private func captureBarrier() async throws {
        if !profiles.sandboxed, !Session.enqueueSave() { throw CocoaError(.fileWriteUnknown) }
        await profiles.waitForTransactions()
        await PendingSessionTransactions.drain()
        guard await SessionPersistence.shared.flush() else { throw CocoaError(.fileWriteUnknown) }
        try profiles.commitICloudProfiles()
    }

    private func ensureLayout(_ original: Space) throws -> Space {
        if original.layout != nil { return original }
        var space = original
        let pinShape = try shape(.pinned, space: space), todayShape = try shape(.today, space: space)
        var layout = SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil).reconciled(with: space)
        let lookup = Dictionary(layout.tabs.map { ($0.savedURL.absoluteString, $0.id.uuidString) }, uniquingKeysWith: { first, _ in first })
        layout.pins = pinShape.mapped { lookup[$0] }; layout.today = todayShape.mapped { lookup[$0] }
        layout.pins.sync(tabs: layout.tabs.filter { $0.kind == .pinned }.map { $0.id.uuidString })
        layout.today.sync(tabs: layout.tabs.filter { $0.kind == .today }.map { $0.id.uuidString })
        try layout.validate(); space.layout = layout
        return space
    }

    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        spacesCache.removeAll()
        try ICloudApplyContext.check()
        try await captureBarrier()
        try ICloudApplyContext.check()
        var out: [ICloudItem] = []
        for (position, profile) in profiles.profiles.enumerated() where profile.id != Profile.incognito.id {
            let pid = profile.id
            let placeholderProfile = try profiles.isICloudPlaceholder(pid, category: "profiles")
            if enabled.contains(.profiles), !placeholderProfile || profile.name != "Synced profile" || profile.colorHex != "#6E7DD2" {
                var f = try fields(profile); f["position"] = try data(position)
                out.append(ICloudItem(category: .profiles, id: pid.uuidString, profileID: pid, parentID: nil, fields: f))
            }
            if !enabled.isDisjoint(with: [.bookmarks, .history]) { out += try await localStore(for: pid).captureICloud(enabled, profile: pid, namespace: accountNamespace ?? "") }
            let needsSpaces: Set<ICloudCategory> = [.spaces, .pinnedTabs, .sidebarFolders]
            if !enabled.isDisjoint(with: needsSpaces) {
                let originals = try committedSpaces(for: pid)
                let spaces = enabled.contains(.pinnedTabs) ? try originals.map(ensureLayout) : originals
                if spaces != originals {
                    guard try saveSpaces(spaces, for: pid) else { throw CocoaError(.fileWriteUnknown) }
                }
                for (index, space) in spaces.enumerated() {
                    let placeholderSpace = try profiles.isICloudPlaceholder(space.id, category: "spaces", profileID: pid)
                    if enabled.contains(.spaces), !placeholderSpace || space.name != "Synced Space" || space.colorHex != nil || space.icon != nil || space.colors != nil {
                        var f = try fields(space)
                        for key in ["tabURLs", "pinnedURLs", "pinnedTabURLs", "layout", "profileID", "id"] { f[key] = nil }
                        f["position"] = try data(index)
                        out.append(ICloudItem(category: .spaces, id: space.id.uuidString, profileID: pid, parentID: nil, fields: f))
                    }
                    for kind in [TabKind.pinned, .today] {
                        let shape = try shape(kind, space: space)
                        if enabled.contains(.sidebarFolders) {
                            for (order, entry) in shape.entries.enumerated() {
                                guard let folder = entry.folder else { continue }
                                if try profiles.isICloudPlaceholder(folder.id, category: "folders", profileID: pid), folder.name == "Synced folder" { continue }
                                var f = try fields(folder)
                                f["spaceID"] = try data(space.id); f["section"] = try data(kind.rawValue); f["position"] = try data(order)
                                f["parentFolderID"] = try data(entry.parent)
                                // Owned live definitions contain URLs and portable filters, never credentials.
                                f["owned"] = nil; f["dismissed"] = nil
                                out.append(ICloudItem(category: .sidebarFolders, id: folder.id.uuidString, profileID: pid, parentID: space.id.uuidString, fields: f))
                            }
                        }
                        if kind == .pinned && enabled.contains(.pinnedTabs) {
                            let pages = space.layout?.tabs.filter { $0.kind == .pinned }
                            for (order, url) in (space.pinnedTabURLs ?? []).enumerated() where web(url) {
                                let page = pages.flatMap { $0.indices.contains(order) ? $0[order] : nil }
                                let identity = page?.id.uuidString ?? stable("\(pid)|\(space.id)|\(url)|\(order)")
                                let parent = shape.entries.first { $0.tab == page?.id.uuidString || $0.tab == url.absoluteString }?.parent
                                let f: [String: Data] = ["url": try data(url), "title": try data(page?.title ?? ""),
                                    "customName": try data(page?.customName), "position": try data(order), "spaceID": try data(space.id), "parentFolderID": try data(parent)]
                                out.append(ICloudItem(category: .pinnedTabs, id: identity, profileID: pid, parentID: space.id.uuidString, fields: f))
                            }
                        }
                    }
                }
            }
            if enabled.contains(.favourites) {
                let urls = defaults.stringArray(forKey: TabStore.defaultsKey(.favourite, pid)) ?? []
                for (index, raw) in urls.enumerated() where web(URL(string: raw)) {
                    out.append(ICloudItem(category: .favourites, id: stable("\(pid)|\(raw)"), profileID: pid, parentID: nil,
                        fields: ["url": try data(raw), "position": try data(index), "customName": try data((defaults.dictionary(forKey: ProfileManager.defaultsKey("tidyTitleOverrides", pid)) as? [String: String])?[raw])]))
                }
            }
            if enabled.contains(.spaceTemplates) {
                for template in try WorkspaceTemplates(manager: profiles).load(profile: pid) {
                    out.append(ICloudItem(category: .spaceTemplates, id: template.id.uuidString, profileID: pid, parentID: nil, fields: try fields(template)))
                }
            }
            if enabled.contains(.openTabs) {
                let file = ProfileManager.sessionURL(for: pid, in: directory)
                if FileManager.default.fileExists(atPath: file.path) {
                    guard let loaded = Session.load(file), !loaded.recoveringFile else { throw CocoaError(.fileReadCorruptFile) }
                    for (window, rows) in loaded.snapshot.windows.enumerated() {
                        for (index, row) in rows.enumerated() where web(URL(string: row.url)) {
                            let tab = ICloudRemoteTab(id: "\(deviceID)|\(pid)|\(row.id ?? stable("\(window)|\(index)|\(row.url)"))", deviceID: deviceID, deviceName: deviceName, profileID: pid,
                                spaceID: loaded.snapshot.spaces.indices.contains(window) ? loaded.snapshot.spaces[window] : nil,
                                url: URL(string: row.url)!, title: row.title ?? "", position: index, at: nil)
                            out.append(ICloudItem(category: .openTabs, id: tab.id, profileID: pid, parentID: tab.spaceID?.uuidString, fields: try fields(tab)))
                        }
                    }
                }
            }
            if enabled.contains(.recentlyClosedTabs), let bytes = defaults.data(forKey: ProfileManager.defaultsKey("archivedTabs", pid)) {
                for (index, row) in try JSONDecoder().decode([Archive.Entry].self, from: bytes).enumerated() where web(URL(string: row.url)) {
                    let tab = ICloudRemoteTab(id: "\(deviceID)|\(pid)|\(stable(row.url))", deviceID: deviceID, deviceName: deviceName, profileID: pid, spaceID: row.space, url: URL(string: row.url)!, title: row.title, position: index, at: row.at)
                    out.append(ICloudItem(category: .recentlyClosedTabs, id: tab.id, profileID: pid, parentID: row.space?.uuidString, fields: try fields(tab)))
                }
            }
            if enabled.contains(.downloadHistory) {
                for row in try Downloads.committedICloudHistory(profileID: pid, directory: directory) where ["done", "missing"].contains(row.state) && row.completed != nil {
                    guard row.source == nil || web(row.source) else { continue }
                    let record = ICloudRemoteDownload(id: "\(deviceID)|\(pid)|\(row.id)", deviceID: deviceID, deviceName: deviceName,
                        profileID: pid, source: row.source, name: URL(fileURLWithPath: row.name).lastPathComponent,
                        size: max(0, row.total), completed: row.completed!)
                    out.append(ICloudItem(category: .downloadHistory, id: record.id, profileID: pid, parentID: nil, fields: try fields(record)))
                }
            }
        }
        // Remote device-owned entries are retained in capture so baseline diffing cannot
        // interpret a device's local list as deletion of another Mac's observations.
        try loadRemote()
        out += remoteItems.filter { enabled.contains($0.category) }
        return out
    }

    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        spacesCache.removeAll()
        try ICloudApplyContext.check()
        try await captureBarrier()
        try ICloudApplyContext.check()
        try loadRemote()
        let checkpoint = remoteCheckpoint()
        var remoteCommitted = false
        defer { if !remoteCommitted { restoreRemote(checkpoint) } }
        // Dependency deletion is authoritative even if a descendant switch is off.
        for item in deleted where enabled.contains(item.category) && item.category == .profiles {
            try ICloudApplyContext.check()
            guard let id = UUID(uuidString: item.id), id != Profile.incognito.id else { throw CocoaError(.fileReadCorruptFile) }
            if profiles.profiles.contains(where: { $0.id == id }) {
                if profiles.profiles.count == 1 {
                    _ = profiles.create(name: "Personal")
                    try profiles.commitICloudProfiles()
                }
                guard await profiles.deleteAsync(id) else { throw CocoaError(.fileWriteUnknown) }
            }
            deletedProfiles.insert(id); remoteItems.removeAll { $0.profileID == id }
        }
        for item in deleted where enabled.contains(item.category) && item.category == .spaces {
            try ICloudApplyContext.check()
            guard let pid = item.profileID, let sid = UUID(uuidString: item.id) else { throw CocoaError(.fileReadCorruptFile) }
            let all = try committedSpaces(for: pid)
            guard try saveSpaces(all.filter { $0.id != sid }, for: pid) else { throw CocoaError(.fileWriteUnknown) }
            deletedSpaces.insert(spaceFenceKey(pid, sid)); remoteItems.removeAll { $0.profileID == pid && $0.parentID.flatMap(UUID.init(uuidString:)) == sid }
        }
        let admitted = items.filter { enabled.contains($0.category) && $0.profileID != Profile.incognito.id }
        let ordered = admitted.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            let left = $0.fields["position"].flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 0
            let right = $1.fields["position"].flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
        for item in ordered {
            try ICloudApplyContext.check()
            guard let pid = item.profileID, !deletedProfiles.contains(pid) else { continue }
            if let parent = item.parentID.flatMap(UUID.init(uuidString:)), deletedSpaces.contains(spaceFenceKey(pid, parent)) { continue }
            if !profiles.profiles.contains(where: { $0.id == pid }),
               ICloudApplyContext.baseline.values.contains(where: { $0.profileID == pid }) { continue }
            try profiles.ensureICloudProfile(pid)
            switch item.category {
            case .profiles:
                guard UUID(uuidString: item.id) == pid else { throw CocoaError(.fileReadCorruptFile) }
                let existing = profiles.profiles.first { $0.id == pid }!
                var current = try fields(existing)
                current["position"] = try data(profiles.profiles.firstIndex { $0.id == pid } ?? 0)
                var patch = ICloudApplyContext.reconcile(item, current: current)
                patch.fields["id"] = try data(pid)
                try profiles.mergeICloudProfile(try merging(patch, into: existing), position: try patch.fields["position"].map { try JSONDecoder().decode(Int.self, from: $0) })
            case .spaces:
                guard let sid = UUID(uuidString: item.id) else { throw CocoaError(.fileReadCorruptFile) }
                var all = try committedSpaces(for: pid)
                let old = all.first { $0.id == sid } ?? Space(id: sid, name: "Synced Space", profileID: pid)
                if !all.contains(where: { $0.id == sid }), ICloudApplyContext.baseline[item.key] != nil { continue }
                var current = try fields(old)
                current["position"] = try data(all.firstIndex { $0.id == sid } ?? all.count)
                var patch = ICloudApplyContext.reconcile(item, current: current)
                for key in ["tabURLs", "pinnedURLs", "pinnedTabURLs", "layout", "id", "profileID"] { patch.fields[key] = nil }
                let updated = try merging(patch, into: old)
                let previous = all.firstIndex { $0.id == sid } ?? all.count
                all.removeAll { $0.id == sid }
                let position = try patch.fields["position"].map { try JSONDecoder().decode(Int.self, from: $0) } ?? previous
                all.insert(updated, at: min(max(0, position), all.count))
                try ICloudApplyContext.check()
        guard try saveSpaces(all, for: pid) else { throw CocoaError(.fileWriteUnknown) }
                try profiles.markICloudPlaceholder(sid, category: "spaces", placeholder: false, profileID: pid)
            case .bookmarks, .history:
                try await localStore(for: pid).applyICloud(item, deleting: false, namespace: accountNamespace ?? "")
            case .favourites:
                try applyFavourite(item, deleting: false)
            case .pinnedTabs, .sidebarFolders:
                try applySpaceChild(item, deleting: false)
            case .spaceTemplates:
                guard let id = UUID(uuidString: item.id) else { throw CocoaError(.fileReadCorruptFile) }
                let library = WorkspaceTemplates(manager: profiles)
                let existing = try library.load(profile: pid).first { $0.id == id }
                if existing == nil, ICloudApplyContext.baseline[item.key] != nil { continue }
                let template: WorkspaceTemplate = try existing.map { try merging(item, into: $0) } ?? item.decode(WorkspaceTemplate.self)
                guard template.profileID == pid, template.id == id else { throw CocoaError(.fileReadCorruptFile) }
                try library.mergeICloudTemplate(template, id: id, profile: pid)
            case .openTabs, .recentlyClosedTabs, .downloadHistory:
                try applyRemote(item)
            default: break
            }
        }
        for item in deleted where enabled.contains(item.category) && item.category != .profiles && item.category != .spaces {
            try ICloudApplyContext.check()
            guard let pid = item.profileID, pid != Profile.incognito.id,
                  profiles.profiles.contains(where: { $0.id == pid }) else { continue }
            switch item.category {
            case .bookmarks, .history: try await localStore(for: pid).applyICloud(item, deleting: true, namespace: accountNamespace ?? "")
            case .favourites: try applyFavourite(item, deleting: true)
            case .pinnedTabs, .sidebarFolders: try applySpaceChild(item, deleting: true)
            case .spaceTemplates:
                guard let id = UUID(uuidString: item.id) else { throw CocoaError(.fileReadCorruptFile) }
                try WorkspaceTemplates(manager: profiles).mergeICloudTemplate(nil, id: id, profile: pid)
            case .openTabs, .recentlyClosedTabs, .downloadHistory:
                remoteItems.removeAll { $0.key == item.key }
            default: break
            }
        }
        try ICloudApplyContext.check()
        try saveRemote(); try publishRemote()
        remoteCommitted = true
        if !profiles.sandboxed { reconcileLiveLibrary(enabled) }
    }

    private func reconcileLiveLibrary(_ enabled: Set<ICloudCategory>) {
        SharedTabs.flush()
        var visited = Set<String>()
        for store in TabStore.all where !store.isPrivate && !store.isLittle {
            let key = "\(store.profileID)|\(store.currentSpaceID?.uuidString ?? "")"
            guard visited.insert(key).inserted else { continue }
            let space = profiles.spaces(for: store.profileID).first { $0.id == store.currentSpaceID }
            let favourites = enabled.contains(.favourites)
                ? (defaults.stringArray(forKey: TabStore.defaultsKey(.favourite, store.profileID)) ?? []).compactMap(URL.init(string:)) : nil
            store.reconcileICloudLibrary(space: space, favourites: favourites,
                pins: enabled.contains(.pinnedTabs), folders: enabled.contains(.sidebarFolders), defaults: defaults)
        }
    }

    private func priority(_ item: ICloudItem) -> Int {
        switch item.category {
        case .profiles: 0
        case .spaces: 1
        case .sidebarFolders: 2
        case .bookmarks: item.id.hasPrefix("folder:") ? 3 : 4
        default: 5
        }
    }

    private func applyFavourite(_ source: ICloudItem, deleting: Bool) throws {
        var item = source
        guard let pid = item.profileID else { throw CocoaError(.fileReadCorruptFile) }
        let key = TabStore.defaultsKey(.favourite, pid)
        var all = defaults.stringArray(forKey: key) ?? []
        let baselineURL = ICloudApplyContext.baseline[item.key]?.fields["url"].flatMap { try? JSONDecoder().decode(String.self, from: $0) }
        let incomingURL = try item.fields["url"].map { try JSONDecoder().decode(String.self, from: $0) }
        let knownURL = all.first { stable("\(pid)|\($0)") == item.id } ?? baselineURL ?? incomingURL
        if !deleting {
            var current: [String: Data] = [:]
            if let knownURL, let position = all.firstIndex(of: knownURL) {
                current = ["url": try data(knownURL), "position": try data(position), "customName": try data((defaults.dictionary(forKey: ProfileManager.defaultsKey("tidyTitleOverrides", pid)) as? [String: String])?[knownURL])]
            }
            if current.isEmpty, ICloudApplyContext.baseline[item.key] != nil { return }
            item.fields = current.merging(ICloudApplyContext.reconcile(item, current: current).fields) { _, incoming in incoming }
        }
        let raw = try field(item, "url", String.self)
        guard web(URL(string: raw)) else { throw CocoaError(.fileReadCorruptFile) }
        all.removeAll { $0 == raw }
        if !deleting {
            let position = try field(item, "position", Int.self)
            all.insert(raw, at: min(max(0, position), all.count))
        }
        try ICloudApplyContext.check()
        defaults.set(all, forKey: key)
        if item.fields["customName"] != nil {
            let customName = try field(item, "customName", String?.self)
            let namesKey = ProfileManager.defaultsKey("tidyTitleOverrides", pid)
            var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
            names[raw] = deleting ? nil : customName
            defaults.set(names, forKey: namesKey)
            if !profiles.sandboxed, let url = URL(string: raw) { TidyTitles.rename(url, in: pid, to: deleting ? nil : customName) }
        }
        guard defaults.stringArray(forKey: key) == all else { throw CocoaError(.fileWriteUnknown) }
    }

    private func applySpaceChild(_ source: ICloudItem, deleting: Bool) throws {
        var item = source
        guard let pid = item.profileID, let sid = item.parentID.flatMap(UUID.init(uuidString:)), (deleting || !deletedSpaces.contains(spaceFenceKey(pid, sid))) else { return }
        var all = try committedSpaces(for: pid)
        if !all.contains(where: { $0.id == sid }), deleting || ICloudApplyContext.baseline[item.key] != nil { return }
        if !all.contains(where: { $0.id == sid }) { try profiles.markICloudPlaceholder(sid, category: "spaces", placeholder: true, profileID: pid) }
        var space = all.first { $0.id == sid } ?? Space(id: sid, name: "Synced Space", profileID: pid)
        let requestedKind: TabKind = item.category == .pinnedTabs ? .pinned : try field(item, "section", TabKind.self)
        guard requestedKind == .pinned || requestedKind == .today else { throw CocoaError(.fileReadCorruptFile) }
        var currentKind = requestedKind
        if item.category == .sidebarFolders, let id = UUID(uuidString: item.id) {
            for candidate in [TabKind.pinned, .today] where try shape(candidate, space: space).folder(id) != nil {
                currentKind = candidate
                break
            }
        }
        if !deleting {
            let currentShape = try shape(currentKind, space: space)
            var current: [String: Data] = [:]
            if item.category == .sidebarFolders, let id = UUID(uuidString: item.id), let folder = currentShape.folder(id) {
                current = try fields(folder)
                current["spaceID"] = try data(sid); current["section"] = try data(currentKind.rawValue)
                current["position"] = try data(currentShape.index(of: id) ?? 0)
                current["parentFolderID"] = try data(currentShape.entries.first { $0.folder?.id == id }?.parent)
            } else if let page = space.layout?.tabs.first(where: { $0.id.uuidString == item.id && $0.kind == .pinned }) {
                current = ["url": try data(page.savedURL), "title": try data(page.title), "customName": try data(page.customName),
                    "position": try data((space.pinnedTabURLs ?? []).firstIndex(of: page.savedURL) ?? 0), "spaceID": try data(sid),
                    "parentFolderID": try data(currentShape.entries.first { $0.tab == item.id || $0.tab == page.savedURL.absoluteString }?.parent)]
            }
            if current.isEmpty, ICloudApplyContext.baseline[item.key] != nil { return }
            item.fields = current.merging(ICloudApplyContext.reconcile(item, current: current).fields) { _, incoming in incoming }
        }
        let kind: TabKind = item.category == .pinnedTabs ? .pinned : deleting ? currentKind : try field(item, "section", TabKind.self)
        guard kind == .pinned || kind == .today else { throw CocoaError(.fileReadCorruptFile) }
        var movedSource: (kind: TabKind, shape: Pins)?
        if !deleting, item.category == .sidebarFolders, currentKind != kind, let id = UUID(uuidString: item.id) {
            // Use the same UUID-preserving subtree transfer as a native folder drag.
            // A single layout snapshot commits both sections and existing local pages.
            space = try ensureLayout(space)
            let from = try shape(currentKind, space: space)
            let movingTabs = Set(from.tabs(in: id))
            guard let transfer = TabStore.moved(folder: id, from: from, to: try shape(kind, space: space),
                at: .init(parent: nil, index: .max)), var layout = space.layout else { throw CocoaError(.fileReadCorruptFile) }
            if currentKind == .pinned { layout.pins = transfer.from; layout.today = transfer.to }
            else { layout.today = transfer.from; layout.pins = transfer.to }
            for index in layout.tabs.indices where movingTabs.contains(layout.tabs[index].id.uuidString) {
                layout.tabs[index].kind = kind
                layout.tabs[index].home = kind == .pinned ? layout.tabs[index].url : nil
            }
            layout.tabs = [TabKind.pinned, .today].flatMap { section in layout.tabs.filter { $0.kind == section } }
            space.tabURLs = layout.tabs.filter { $0.kind == .today }.map(\.savedURL)
            space.pinnedTabURLs = layout.tabs.filter { $0.kind == .pinned }.map(\.savedURL)
            space.layout = layout
            movedSource = (currentKind, transfer.from)
        }
        var shape = try shape(kind, space: space)
        if item.category == .pinnedTabs, space.layout == nil {
            space.layout = SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil).reconciled(with: space)
        }
        if item.category == .sidebarFolders {
            guard let id = UUID(uuidString: item.id) else { throw CocoaError(.fileReadCorruptFile) }
            let old = shape.folder(id)
            let oldPosition = shape.index(of: id) ?? shape.entries.count
            if deleting {
                shape.remove(folder: id)
            } else {
                var subtree = shape.lift(folder: id)
                var folder = try merging(item, into: old ?? Folder(id: id, name: "Synced folder"))
                // Remote changes never grant a local unlock or remove existing protection.
                if old?.requiresAuthentication == true { folder.requiresAuthentication = true }
                folder.id = id; folder.owned = nil; folder.dismissed = nil
                let parent = try item.fields["parentFolderID"].flatMap { try JSONDecoder().decode(UUID?.self, from: $0) }
                var position = try item.fields["position"].map { try JSONDecoder().decode(Int.self, from: $0) } ?? oldPosition
                if let parent, let parentIndex = shape.index(of: parent) {
                    guard parent != id, !shape.ancestors(of: parentIndex).contains(id), shape.depth(of: parentIndex) < Pins.maxDepth else { throw CocoaError(.fileReadCorruptFile) }
                    position = max(position, parentIndex + 1)
                }
                let entry = Pins.Entry(row: .folder(folder), parent: parent.flatMap { shape.folder($0) == nil ? nil : $0 })
                if subtree.isEmpty { subtree = [entry] } else { subtree[0] = entry }
                shape.entries.insert(contentsOf: subtree, at: min(max(0, position), shape.entries.count))
                try profiles.markICloudPlaceholder(id, category: "folders", placeholder: false, profileID: pid)
            }
        } else {
            let url = try field(item, "url", URL.self)
            guard web(url) else { throw CocoaError(.fileReadCorruptFile) }
            var urls = space.pinnedTabURLs ?? []
            let existingPages = space.layout?.tabs.filter { $0.kind == .pinned } ?? []
            let oldIndex = existingPages.firstIndex { $0.id.uuidString == item.id }
            let previousURL = oldIndex.map { existingPages[$0].savedURL }
            if let oldIndex, urls.indices.contains(oldIndex) { urls.remove(at: oldIndex) }
            shape.entries.removeAll { $0.tab == item.id || (previousURL != nil && $0.tab == previousURL?.absoluteString) }
            if !deleting {
                let position = try field(item, "position", Int.self)
                urls.insert(url, at: min(max(0, position), urls.count))
                let parent = try item.fields["parentFolderID"].flatMap { try JSONDecoder().decode(UUID?.self, from: $0) }
                if let parent, shape.folder(parent) == nil {
                    try profiles.markICloudPlaceholder(parent, category: "folders", placeholder: true, profileID: pid)
                    var placeholder = Folder(id: parent, name: "Synced folder"); placeholder.requiresAuthentication = true
                    shape.entries.append(Pins.Entry(row: .folder(placeholder), parent: nil))
                }
                shape.entries.insert(Pins.Entry(row: .tab(UUID(uuidString: item.id) == nil ? url.absoluteString : item.id), parent: parent.flatMap { shape.folder($0) == nil ? nil : $0 }), at: min(max(parent.flatMap { shape.index(of: $0).map { $0 + 1 } } ?? 0, oldIndex ?? position), shape.entries.count))
            }
            space.pinnedTabURLs = urls
        }
        // Layouts hold local Today identities. Reconcile only the pinned subset through
        // the existing local layout owner; device tab navigation is never imported.
        if var layout = space.layout {
            if kind == .pinned {
                if item.category == .pinnedTabs, let id = UUID(uuidString: item.id), let url = try? field(item, "url", URL.self) {
                    layout.tabs.removeAll { $0.id == id }
                    if !deleting {
                        let title = try field(item, "title", String.self)
                        let customName = try item.fields["customName"].flatMap { try JSONDecoder().decode(String?.self, from: $0) }
                        let position = try field(item, "position", Int.self)
                        layout.tabs.insert(.init(id: id, url: url, kind: .pinned, title: title, customName: customName, home: url), at: min(max(0, position), layout.tabs.count))
                    }
                }
                layout = layout.reconciled(with: space)
                let lookup = Dictionary(layout.tabs.map { ($0.savedURL.absoluteString, $0.id.uuidString) }, uniquingKeysWith: { a, _ in a })
                let identities = Set(layout.tabs.map { $0.id.uuidString })
                layout.pins = shape.mapped { identities.contains($0) ? $0 : lookup[$0] }
            } else { layout.today = shape }
            if movedSource != nil { try layout.validate() }
            space.layout = layout
        }
        if let index = all.firstIndex(where: { $0.id == sid }) { all[index] = space }
        else { all.append(space) }
        try ICloudApplyContext.check()
        guard try saveSpaces(all, for: pid) else { throw CocoaError(.fileWriteUnknown) }
        var mirrors = [(kind, shape)]
        if let movedSource { mirrors.append((movedSource.kind, movedSource.shape)) }
        for (section, savedShape) in mirrors {
            let key = TabStore.shapeKey(section, space: sid, profileID: pid)
            let bytes = try data(savedShape)
            try ICloudApplyContext.check()
            defaults.set(bytes, forKey: key)
            guard defaults.data(forKey: key) == bytes else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private struct RemoteDisk: Codable {
        var items: [ICloudItem]
        var deletedProfiles: Set<UUID>
        var deletedSpaces: Set<String>
    }
    private struct RemoteCheckpoint {
        var disk: RemoteDisk
        var loaded: Bool
        var tabs: [ICloudRemoteTab]
        var recentlyClosed: [ICloudRemoteTab]
        var downloads: [ICloudRemoteDownload]
    }
    private func remoteCheckpoint() -> RemoteCheckpoint {
        RemoteCheckpoint(disk: RemoteDisk(items: remoteItems, deletedProfiles: deletedProfiles, deletedSpaces: deletedSpaces),
            loaded: remoteLoaded, tabs: remoteTabs, recentlyClosed: remoteRecentlyClosedTabs, downloads: remoteDownloads)
    }
    private func restoreRemote(_ checkpoint: RemoteCheckpoint) {
        remoteItems = checkpoint.disk.items
        deletedProfiles = checkpoint.disk.deletedProfiles; deletedSpaces = checkpoint.disk.deletedSpaces
        remoteLoaded = checkpoint.loaded
        remoteTabs = checkpoint.tabs; remoteRecentlyClosedTabs = checkpoint.recentlyClosed; remoteDownloads = checkpoint.downloads
    }
    private var remoteFile: URL {
        let suffix = accountNamespace.map { "-" + $0 } ?? ""
        return directory.appendingPathComponent("icloud-device-lists" + suffix + ".json")
    }
    private func loadRemote() throws {
        guard !remoteLoaded else { return }
        let saved = try read(RemoteDisk.self, at: remoteFile, missing: RemoteDisk(items: [], deletedProfiles: [], deletedSpaces: []))
        let checkpoint = remoteCheckpoint()
        remoteItems = saved.items; deletedProfiles = saved.deletedProfiles
        // Legacy UUID-only entries were ambiguous across profile moves. The journal
        // replays its authoritative profile-qualified fences before applying payloads.
        deletedSpaces = saved.deletedSpaces.filter { $0.hasPrefix("space:") }
        do {
            try publishRemote()
            remoteLoaded = true
        } catch {
            restoreRemote(checkpoint)
            throw error
        }
    }
    private func saveRemote() throws {
        try ICloudApplyContext.check()
        _ = try decodedRemoteLists()
        let bytes = try data(RemoteDisk(items: remoteItems, deletedProfiles: deletedProfiles, deletedSpaces: deletedSpaces))
        try ICloudApplyContext.check()
        guard SnapshotPersistence.write(bytes, to: remoteFile) else { throw CocoaError(.fileWriteUnknown) }
    }
    private func applyRemote(_ item: ICloudItem) throws {
        let owner = try field(item, "deviceID", String.self)
        guard owner != deviceID else { return }
        guard let pid = item.profileID, item.id.hasPrefix("\(owner)|\(pid)|") else { throw CocoaError(.fileReadCorruptFile) }
        var incoming = item
        if let previous = remoteItems.first(where: { $0.key == item.key }) {
            incoming.fields = previous.fields.merging(item.fields) { _, new in new }
        }
        if item.category == .downloadHistory {
            let row = try incoming.decode(ICloudRemoteDownload.self)
            guard row.id == item.id, row.profileID == item.profileID, row.size >= 0, row.completed.timeIntervalSinceReferenceDate.isFinite,
                  !row.name.contains("/"), row.source == nil || web(row.source) else { throw CocoaError(.fileReadCorruptFile) }
            incoming.fields = try fields(row)
        } else {
            let row = try incoming.decode(ICloudRemoteTab.self)
            guard row.id == item.id, row.profileID == item.profileID, web(row.url) else { throw CocoaError(.fileReadCorruptFile) }
            if let sid = row.spaceID, !deletedSpaces.contains(spaceFenceKey(row.profileID, sid)) {
                var spaces = try committedSpaces(for: row.profileID)
                if !spaces.contains(where: { $0.id == sid }) {
                    try profiles.markICloudPlaceholder(sid, category: "spaces", placeholder: true, profileID: pid)
                    spaces.append(Space(id: sid, name: "Synced Space", profileID: row.profileID))
                    guard try saveSpaces(spaces, for: row.profileID) else { throw CocoaError(.fileWriteUnknown) }
                }
            }
            incoming.fields = try fields(row)
        }
        remoteItems.removeAll { $0.key == item.key }
        remoteItems.append(incoming)
    }
    private func decodedRemoteLists() throws -> (tabs: [ICloudRemoteTab], recentlyClosed: [ICloudRemoteTab], downloads: [ICloudRemoteDownload]) {
        let tabs = try remoteItems.filter { $0.category == .openTabs }.map { try $0.decode(ICloudRemoteTab.self) }.sorted { ($0.deviceName, $0.position, $0.id) < ($1.deviceName, $1.position, $1.id) }
        let closed = try remoteItems.filter { $0.category == .recentlyClosedTabs }.map { try $0.decode(ICloudRemoteTab.self) }.sorted { ($0.deviceName, $0.position, $0.id) < ($1.deviceName, $1.position, $1.id) }
        let downloads = try remoteItems.filter { $0.category == .downloadHistory }.map { try $0.decode(ICloudRemoteDownload.self) }.sorted { $0.completed > $1.completed }
        return (tabs, closed, downloads)
    }
    private func publishRemote() throws {
        let lists = try decodedRemoteLists()
        remoteTabs = lists.tabs; remoteRecentlyClosedTabs = lists.recentlyClosed; remoteDownloads = lists.downloads
    }

}

private extension TabStore {
    /// Reconcile shared library furniture without loading a page or changing selection.
    /// Existing removed furniture remains a normal local Today tab, preserving live work.
    func reconcileICloudLibrary(space: Space?, favourites: [URL]?, pins updatePins: Bool,
                               folders: Bool, defaults: UserDefaults) {
        let ready = sharingReady
        sharingReady = false
        let previous = tabs
        var updated = tabs
        if let favourites {
            let current = updated.filter { $0.kind == .favourite }
            let replacement = favourites.map { url in
                if let old = current.first(where: { $0.pinnedURL == url }) { return old }
                let tab = makeBlankTab(as: .favourite)
                tab.restore(url: url, home: url, parked: Parked())
                return tab
            }
            let kept = Set(replacement.map(\.id))
            for tab in current where !kept.contains(tab.id) { tab.kind = .today }
            updated = replacement + updated.filter { $0.kind != .favourite }
        }
        if folders, let layout = space?.layout {
            // A folder transfer also reclassifies its existing local pages when
            // pinned-tab records are disabled. Keep the page objects and navigation.
            let kinds = Dictionary(layout.tabs.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
            for tab in updated where tab.kind != .favourite {
                if let kind = kinds[tab.id], kind != tab.kind { tab.kind = kind }
            }
            updated = TabKind.allCases.flatMap { kind in updated.filter { $0.kind == kind } }
        }
        if updatePins, let space, let layout = space.layout {
            let current = updated.filter { $0.kind == .pinned }
            let replacement = layout.tabs.filter { $0.kind == .pinned }.map { page in
                if let old = current.first(where: { $0.id == page.id }) {
                    old.workspaceName = page.customName ?? ""
                    return old
                }
                let tab = makeBlankTab(as: .pinned, id: page.id)
                tab.restore(url: page.url, home: page.savedURL, parked: Parked(title: page.title))
                tab.workspaceName = page.customName ?? ""
                return tab
            }
            let kept = Set(replacement.map(\.id))
            for tab in current where !kept.contains(tab.id) { tab.kind = .today }
            updated = updated.filter { $0.kind == .favourite } + replacement + updated.filter { $0.kind == .today }
        }
        Motion.list {
            tabs = updated
            if let space, folders || updatePins {
                let lookup = Dictionary(tabs.compactMap { tab in tab.pinnedURL.map { ($0.absoluteString, tab.id.uuidString) } }, uniquingKeysWith: { first, _ in first })
                if let layout = space.layout {
                    let liveIDs = Set(tabs.map { $0.id.uuidString })
                    let identities = Dictionary(layout.tabs.map { ($0.id.uuidString, liveIDs.contains($0.id.uuidString) ? $0.id.uuidString : lookup[$0.savedURL.absoluteString]) }, uniquingKeysWith: { first, _ in first })
                    if folders || updatePins { self.pins = layout.pins.mapped { identities[$0] ?? nil } }
                    if folders { todayShape = layout.today.mapped { identities[$0] ?? nil } }
                } else {
                    for kind in [TabKind.pinned, .today] where folders || kind == .pinned {
                        if let bytes = defaults.data(forKey: Self.shapeKey(kind, space: space.id, profileID: profileID)),
                           let shape = try? JSONDecoder().decode(Pins.self, from: bytes) {
                            if kind == .pinned { self.pins = shape.mapped { lookup[$0] } }
                            else { todayShape = shape.mapped { lookup[$0] } }
                        }
                    }
                }
                syncShapes()
            }
        }
        sharingReady = ready
        spacesChanged(); applySpaceAppearance()
        captureLockedFolderBackdrop(); enforceFolderLocks()
        SharedTabs.synchronize(from: self)
        SharedTabs.release(previous.filter { old in !tabs.contains { $0 === old } }, excluding: self)
    }
}
