import Foundation
import CryptoKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (project.yml); the Mac writes these from Settings → Backups → Export.
    static let vaneBackup = UTType(importedAs: "io.github.notnaki.vane.backup", conformingTo: .data)
}

/// A Mac `.vanebackup` read as the records the Mac's iCloud capture
/// (`ICloudLibraryAdapter.capture`) publishes for the same library: profiles, Spaces and their
/// order, favourites, pinned tabs, and the folders of both sidebar sections. Same identities
/// and field encodings, so importing again replaces rather than duplicates, and the records
/// later sync like any other. The backup's JSON is read as is, because the Mac's model types
/// (`Space`, `Folder`, `Pins`) don't compile here.
enum MacBackup {
    /// `ProfileManager.defaultID`: its files have no suffix.
    static let defaultProfile = UUID(uuidString: "00000000-0000-0000-0000-000056616E65")!
    /// The most a file may be. A Mac backup of Spaces and pins is far smaller; this keeps a
    /// crafted file from being read whole into memory, decrypted and decoded.
    static let limit = 64 * 1024 * 1024
    /// `Pins.maxDepth`: three levels of folder.
    static let maxDepth = 2
    /// Far past any real library, so a crafted backup can't flood the phone or iCloud.
    static let caps: [ICloudCategory: Int] = [.profiles: 100, .spaces: 500, .sidebarFolders: 5_000,
                                              .pinnedTabs: 20_000, .favourites: 20_000]

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Coordinated, so a file in iCloud Drive or another provider is downloaded first.
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown)), failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &failure) { url in
            result = Result {
                try BackupIO.checkFile(url)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: limit + 1) ?? Data()
            }
        }
        if let failure { throw failure }
        return try result.get()
    }

    /// The Mac's file names (`BackupPaths.isOwned`) in outline: that rule needs Mac-only types.
    /// The phone reads only profiles.json and spaces files, by exact name, and writes none.
    static func allowed(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.contains("\\"), !name.contains("\0"), parts.count <= 5,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if parts.count > 1 { return ["ReadingQueue", "FilterLists"].contains(String(parts[0])) }
        return name == "profiles.json" || ["spaces", "session", "spacestate", "vane", "easels-", "space-templates"].contains { name.hasPrefix($0) }
    }

    static func records(_ data: Data, password: String? = nil) throws -> [ICloudItem] {
        guard data.count <= limit else { throw BackupError.storage("This backup is larger than the 64 MB iPhone import reads.") }
        let archive = try BackupCodec.unseal(data, password: password)
        try BackupCodec.validate(archive, allowed: allowed)
        guard archive.damage == nil else { throw BackupError.invalid("It holds the files of a damaged library.") }
        let files = Dictionary(archive.files.map { ($0.name, $0.data) }, uniquingKeysWith: { first, _ in first })
        let prefs = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil) as? [String: Any] ?? [:]
        guard let list = files["profiles.json"], let disk = try JSONSerialization.jsonObject(with: list) as? [String: Any],
              let profiles = disk["profiles"] as? [[String: Any]] else { throw BackupError.invalid("It has no profiles.") }
        var out: [ICloudItem] = [], keys = Set<String>(), counts: [ICloudCategory: Int] = [:]
        /// Keeps a record that is valid, new and under its category's cap.
        func add(_ item: ICloudItem) -> Bool {
            guard (try? item.validate()) != nil, counts[item.category, default: 0] < caps[item.category, default: 0],
                  keys.insert(item.key).inserted else { return false }
            counts[item.category, default: 0] += 1
            out.append(item)
            return true
        }
        for (position, profile) in profiles.enumerated() {
            guard let pid = uuid(profile["id"]), pid != Profile.incognito.id else { continue }
            let suffix = pid == defaultProfile ? "" : "-" + pid.uuidString.lowercased()
            // The Mac's stand-ins for records it hasn't received yet, skipped as its capture skips them.
            if profile["name"] as? String != "Synced profile" || profile["colorHex"] as? String != "#6E7DD2" {
                var f = try fields(profile); f["position"] = try enc(position)
                _ = add(ICloudItem(category: .profiles, id: pid.uuidString, profileID: pid, parentID: nil, fields: f))
            }

            let spaces = try files["spaces\(suffix).json"].flatMap { try JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            for (index, space) in spaces.enumerated() {
                guard let sid = uuid(space["id"]) else { continue }
                if space["name"] as? String != "Synced Space" || space["colorHex"] != nil || space["icon"] != nil || space["colors"] != nil {
                    var f = try fields(space)
                    for key in ["tabURLs", "pinnedURLs", "pinnedTabURLs", "layout", "profileID", "id"] { f[key] = nil }
                    f["position"] = try enc(index)
                    _ = add(ICloudItem(category: .spaces, id: sid.uuidString, profileID: pid, parentID: nil, fields: f))
                }

                let layout = space["layout"] as? [String: Any]
                // The section's rows: the layout's, else the older per-Space defaults key.
                func shape(_ section: Int) throws -> [[String: Any]] {
                    let pins: [String: Any]?
                    if let layout { pins = layout[section == 1 ? "pins" : "today"] as? [String: Any] }
                    else { pins = try (prefs["\(section == 1 ? "pinShape" : "todayShape").\(sid.uuidString)\(suffix)"] as? Data)
                        .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
                    return pins?["entries"] as? [[String: Any]] ?? []
                }
                // Each kept folder's depth, by section. A folder sits in an earlier folder of its
                // own section, at most `maxDepth` deep; any other parent puts it at the top.
                var depths: [Int: [UUID: Int]] = [:]
                for section in [1, 2] {
                    for (order, entry) in try shape(section).enumerated() {
                        guard var folder = row(entry, "folder") as? [String: Any], let fid = uuid(folder["id"]),
                              folder["name"] as? String != "Synced folder", depths[section]?[fid] == nil else { continue }
                        folder["owned"] = nil; folder["dismissed"] = nil
                        var parent = uuid(entry["parent"]), depth = 0
                        if let p = parent, let d = depths[section]?[p], d < maxDepth { depth = d + 1 } else { parent = nil }
                        var f = try fields(folder)
                        f["spaceID"] = try enc(sid); f["section"] = try enc(section); f["position"] = try enc(order)
                        f["parentFolderID"] = try enc(parent)
                        if add(ICloudItem(category: .sidebarFolders, id: fid.uuidString, profileID: pid, parentID: sid.uuidString, fields: f)) {
                            depths[section, default: [:]][fid] = depth
                        }
                    }
                }
                // Which kept Pinned folder each tab row sits in.
                var parents: [String: UUID] = [:]
                for entry in try shape(1) {
                    guard let tab = row(entry, "tab") as? String, parents[tab] == nil,
                          let p = uuid(entry["parent"]), depths[1]?[p] != nil else { continue }
                    parents[tab] = p
                }
                let pages = (layout?["tabs"] as? [[String: Any]])?.filter { $0["kind"] as? Int == 1 }
                for (order, raw) in (space["pinnedTabURLs"] as? [String] ?? []).enumerated() {
                    guard let url = URL(string: raw), web(url) else { continue }
                    let page = pages.flatMap { $0.indices.contains(order) ? $0[order] : nil }
                    let pageID = uuid(page?["id"])?.uuidString
                    let identity = pageID ?? stable("\(pid)|\(sid)|\(url)|\(order)")
                    let parent = pageID.flatMap { parents[$0] } ?? parents[url.absoluteString]
                    let f: [String: Data] = ["url": try enc(url), "title": try enc(page?["title"] as? String ?? ""),
                        "customName": try enc(page?["customName"] as? String), "position": try enc(order),
                        "spaceID": try enc(sid), "parentFolderID": try enc(parent)]
                    _ = add(ICloudItem(category: .pinnedTabs, id: identity, profileID: pid, parentID: sid.uuidString, fields: f))
                }
            }

            let names = prefs["tidyTitleOverrides\(suffix)"] as? [String: String]
            for (index, raw) in (prefs["pinnedTabs\(suffix)"] as? [String] ?? []).enumerated() where URL(string: raw).map(web) == true {
                _ = add(ICloudItem(category: .favourites, id: stable("\(pid)|\(raw)"), profileID: pid, parentID: nil,
                    fields: ["url": try enc(raw), "position": try enc(index), "customName": try enc(names?[raw])]))
            }
        }
        let order = Array((disk["spaceOrder"] as? [Any] ?? []).compactMap(uuid).prefix(caps[.spaces]!))
        let item = ICloudItem(category: .sidebarFolders, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil, fields: ["ids": try enc(order)])
        if !order.isEmpty, (try? item.validate()) != nil { out.append(item) }
        return out
    }

    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func web(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
    private static func enc<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private static func stable(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// `ICloudItem.encodedFields` for a value already in JSON form.
    private static func fields(_ object: [String: Any]) throws -> [String: Data] {
        try object.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }
    /// A `Pins.Entry` row's payload: Swift encodes `case folder(Folder)` as `{"folder": {"_0": …}}`.
    private static func row(_ entry: [String: Any], _ kind: String) -> Any? {
        ((entry["row"] as? [String: Any])?[kind] as? [String: Any])?["_0"]
    }
}
