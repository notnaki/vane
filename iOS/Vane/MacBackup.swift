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

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try BackupIO.read(url)
    }

    static func records(_ data: Data, password: String? = nil) throws -> [ICloudItem] {
        let archive = try BackupCodec.unseal(data, password: password)
        // The phone reads only profiles.json and spaces files, by exact name, and writes none.
        try BackupCodec.validate(archive) { _ in true }
        guard archive.damage == nil else { throw BackupError.invalid("It holds the files of a damaged library.") }
        let files = Dictionary(archive.files.map { ($0.name, $0.data) }, uniquingKeysWith: { first, _ in first })
        let prefs = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil) as? [String: Any] ?? [:]
        guard let list = files["profiles.json"], let disk = try JSONSerialization.jsonObject(with: list) as? [String: Any],
              let profiles = disk["profiles"] as? [[String: Any]] else { throw BackupError.invalid("It has no profiles.") }
        var out: [ICloudItem] = []
        for (position, profile) in profiles.enumerated() {
            guard let pid = uuid(profile["id"]), pid != Profile.incognito.id else { continue }
            let suffix = pid == defaultProfile ? "" : "-" + pid.uuidString.lowercased()
            var f = try fields(profile); f["position"] = try enc(position)
            out.append(ICloudItem(category: .profiles, id: pid.uuidString, profileID: pid, parentID: nil, fields: f))

            let spaces = try files["spaces\(suffix).json"].flatMap { try JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            for (index, space) in spaces.enumerated() {
                guard let sid = uuid(space["id"]) else { continue }
                var f = try fields(space)
                for key in ["tabURLs", "pinnedURLs", "pinnedTabURLs", "layout", "profileID", "id"] { f[key] = nil }
                f["position"] = try enc(index)
                out.append(ICloudItem(category: .spaces, id: sid.uuidString, profileID: pid, parentID: nil, fields: f))

                let layout = space["layout"] as? [String: Any]
                // The section's rows: the layout's, else the older per-Space defaults key.
                func shape(_ section: Int) throws -> [[String: Any]] {
                    let pins: [String: Any]?
                    if let layout { pins = layout[section == 1 ? "pins" : "today"] as? [String: Any] }
                    else { pins = try (prefs["\(section == 1 ? "pinShape" : "todayShape").\(sid.uuidString)\(suffix)"] as? Data)
                        .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
                    return pins?["entries"] as? [[String: Any]] ?? []
                }
                for section in [1, 2] {
                    for (order, entry) in try shape(section).enumerated() {
                        guard var folder = row(entry, "folder") as? [String: Any], let fid = uuid(folder["id"]) else { continue }
                        folder["owned"] = nil; folder["dismissed"] = nil
                        var f = try fields(folder)
                        f["spaceID"] = try enc(sid); f["section"] = try enc(section); f["position"] = try enc(order)
                        f["parentFolderID"] = try enc(uuid(entry["parent"]))
                        out.append(ICloudItem(category: .sidebarFolders, id: fid.uuidString, profileID: pid, parentID: sid.uuidString, fields: f))
                    }
                }
                let pins = try shape(1)
                let pages = (layout?["tabs"] as? [[String: Any]])?.filter { $0["kind"] as? Int == 1 }
                for (order, raw) in (space["pinnedTabURLs"] as? [String] ?? []).enumerated() {
                    guard let url = URL(string: raw), web(url) else { continue }
                    let page = pages.flatMap { $0.indices.contains(order) ? $0[order] : nil }
                    let pageID = uuid(page?["id"])?.uuidString
                    let identity = pageID ?? stable("\(pid)|\(sid)|\(url)|\(order)")
                    let parent = pins.first { entry in
                        guard let tab = row(entry, "tab") as? String else { return false }
                        return tab == pageID || tab == url.absoluteString
                    }.flatMap { uuid($0["parent"]) }
                    let f: [String: Data] = ["url": try enc(url), "title": try enc(page?["title"] as? String ?? ""),
                        "customName": try enc(page?["customName"] as? String), "position": try enc(order),
                        "spaceID": try enc(sid), "parentFolderID": try enc(parent)]
                    out.append(ICloudItem(category: .pinnedTabs, id: identity, profileID: pid, parentID: sid.uuidString, fields: f))
                }
            }

            let names = prefs["tidyTitleOverrides\(suffix)"] as? [String: String]
            for (index, raw) in (prefs["pinnedTabs\(suffix)"] as? [String] ?? []).enumerated() where URL(string: raw).map(web) == true {
                out.append(ICloudItem(category: .favourites, id: stable("\(pid)|\(raw)"), profileID: pid, parentID: nil,
                    fields: ["url": try enc(raw), "position": try enc(index), "customName": try enc(names?[raw])]))
            }
        }
        let order = (disk["spaceOrder"] as? [Any] ?? []).compactMap(uuid)
        if !order.isEmpty {
            out.append(ICloudItem(category: .sidebarFolders, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil, fields: ["ids": try enc(order)]))
        }
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
