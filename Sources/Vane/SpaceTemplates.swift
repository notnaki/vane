import Foundation

/// Address-only sidebar state. No WebKit archives or website data belong here.
struct SpaceLayout: Codable, Equatable {
    struct Page: Codable, Equatable, Identifiable {
        var id: UUID
        var url: URL
        var kind: TabKind
        var title: String
        var customName: String?
        var home: URL? = nil
        var savedURL: URL { kind == .today ? url : home ?? url }
    }
    var tabs: [Page]
    var pins: Pins
    var today: Pins
    var splits: [Split.Saved]
    var selected: UUID?
    var omitted: Int = 0

    var protectedFolders: [Folder] {
        (pins.entries + today.entries).compactMap(\.folder).filter { $0.requiresAuthentication == true }
    }

    func requireAuthentication(_ unlocked: Set<UUID>) throws {
        guard protectedFolders.allSatisfy({ unlocked.contains($0.id) }) else { throw WorkspaceError.authentication }
    }

    func validate(template: Bool = false) throws {
        let ids = Set(tabs.map(\.id))
        guard tabs.count <= 10_000, ids.count == tabs.count, omitted >= 0,
              tabs.allSatisfy({ $0.kind != .favourite && TabAddress.restorable($0.url)
                && TabAddress.restorable($0.savedURL)
                && (!template || (Self.templateURL($0.url) == $0.url && Self.templateURL($0.savedURL) == $0.savedURL)) }),
              selected.map(ids.contains) ?? true else { throw WorkspaceError.damaged }
        var folders = Set<UUID>(), placed = Set<UUID>()
        for (shape, kind) in [(pins, TabKind.pinned), (today, .today)] {
            guard shape.entries.count <= 12_000 else { throw WorkspaceError.damaged }
            var parents: [UUID] = []
            var local = Set<UUID>()
            for entry in shape.entries {
                if let parent = entry.parent {
                    guard local.contains(parent), parents.contains(parent) else { throw WorkspaceError.damaged }
                    parents = Array(parents.prefix(through: parents.firstIndex(of: parent)!))
                } else { parents = [] }
                if let folder = entry.folder {
                    guard folders.insert(folder.id).inserted, parents.count <= Pins.maxDepth,
                          !template || (folder.live == nil && folder.owned == nil && folder.dismissed == nil)
                    else { throw WorkspaceError.damaged }
                    local.insert(folder.id); parents.append(folder.id)
                } else if let tab = entry.tab.flatMap(UUID.init(uuidString:)) {
                    guard placed.insert(tab).inserted, tabs.contains(where: { $0.id == tab && $0.kind == kind })
                    else { throw WorkspaceError.damaged }
                } else { throw WorkspaceError.damaged }
            }
        }
        guard placed == ids else { throw WorkspaceError.damaged }
        var panes = Set<UUID>()
        for split in splits {
            guard let names = split.ids, names.count >= 2, names.count <= Split.maxPanes,
                  names.count == split.urls.count, (0..<names.count).contains(split.active) else { throw WorkspaceError.damaged }
            for (index, name) in names.enumerated() {
                guard let id = UUID(uuidString: name), ids.contains(id), panes.insert(id).inserted,
                      tabs.first(where: { $0.id == id })?.url.absoluteString == split.urls[index]
                else { throw WorkspaceError.damaged }
            }
            if let weights = split.weights {
                guard weights.count == names.count, weights.allSatisfy({ $0.isFinite && $0 > 0 }),
                      abs(weights.reduce(0, +) - 1) < 0.0001 else { throw WorkspaceError.damaged }
            }
        }
    }

    /// URL userinfo and common credential-bearing URL parameters never enter templates.
    static func templateURL(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.user = nil; parts.password = nil
        func sensitive(_ key: String) -> Bool {
            let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
            return ["code", "auth", "authorization", "credential", "credentials", "jwt", "key", "apikey",
                    "password", "passwd", "secret", "signature", "sig", "oobcode", "session", "sessionid", "sid", "ticket"].contains(key)
                || key.contains("token") || key.contains("password") || key.contains("secret")
                || key.hasPrefix("xamz") || key.hasPrefix("xgoog") || key.hasPrefix("oauth")
        }
        if let items = parts.queryItems {
            let kept = items.filter { !sensitive($0.name) }
            parts.queryItems = kept.isEmpty ? nil : kept
        }
        if let fragment = parts.fragment, fragment.contains("=") {
            let kept = fragment.split(separator: "&").filter { item in
                let key = String(item.split(separator: "=", maxSplits: 1).first ?? "")
                return !sensitive(key.removingPercentEncoding ?? key)
            }
            parts.fragment = kept.isEmpty ? nil : kept.joined(separator: "&")
        }
        return parts.url
    }

    func forTemplate(unlocked: Set<UUID>) throws -> SpaceLayout {
        try validate()
        try requireAuthentication(unlocked)
        var out = self
        out.tabs = tabs.compactMap { page in
            guard let url = Self.templateURL(page.url), let home = Self.templateURL(page.savedURL) else { return nil }
            var page = page; page.url = url; page.home = page.kind == .pinned ? home : nil
            return page
        }
        out.omitted += tabs.count - out.tabs.count
        let kept = Set(out.tabs.map { $0.id.uuidString })
        func clean(_ shape: Pins) -> Pins {
            var shape = shape.mapped { kept.contains($0) ? $0 : nil }
            for entry in shape.entries {
                if let folder = entry.folder {
                    shape.edit(folder: folder.id) { $0.live = nil; $0.owned = nil; $0.dismissed = nil }
                }
            }
            return shape
        }
        out.pins = clean(pins); out.today = clean(today)
        out.splits = splits.compactMap { saved in
            let names = saved.ids ?? []
            let surviving = names.enumerated().filter { kept.contains($0.element) }
            guard surviving.count >= 2 else { return nil }
            let pages = surviving.compactMap { name in out.tabs.first { $0.id.uuidString == name.element } }
            return Split.Saved(urls: pages.map { $0.url.absoluteString }, vertical: saved.vertical,
                active: surviving.firstIndex { $0.offset == saved.active } ?? 0, ids: surviving.map(\.element),
                weights: saved.weights.map { weights in Split.normalised(surviving.map { weights[$0.offset] }) })
        }
        out.selected = selected.flatMap { kept.contains($0.uuidString) ? $0 : nil }
        try out.validate(template: true)
        return out
    }

    /// A new Space must never share mutable tab identities or authentication grants.
    func recreated() throws -> SpaceLayout {
        try validate()
        let names = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, UUID()) })
        let folders = Dictionary(uniqueKeysWithValues: (pins.entries + today.entries).compactMap(\.folder).map { ($0.id, UUID()) })
        var out = self
        out.tabs = tabs.map { var page = $0; page.id = names[page.id]!; return page }
        func shape(_ shape: Pins) -> Pins {
            Pins(entries: shape.entries.map { entry in
                var entry = entry
                entry.parent = entry.parent.flatMap { folders[$0] }
                if var folder = entry.folder { folder.id = folders[folder.id]!; entry.row = .folder(folder) }
                else if let id = entry.tab.flatMap(UUID.init(uuidString:)) { entry.row = .tab(names[id]!.uuidString) }
                return entry
            })
        }
        out.pins = shape(pins); out.today = shape(today)
        out.splits = splits.map { var split = $0; split.ids = split.ids?.map { names[UUID(uuidString: $0)!]!.uuidString }; return split }
        out.selected = selected.flatMap { names[$0] }
        return out
    }

    func matches(_ space: Space) -> Bool {
        tabs.filter { $0.kind == .today }.map(\.savedURL) == space.tabURLs
            && tabs.filter { $0.kind == .pinned }.map(\.savedURL) == (space.pinnedTabURLs ?? [])
    }

    /// Older disk editors change URL lists. Keep surviving occurrence identities and
    /// chrome when those edits append/remove rows, rather than discarding the layout.
    func reconciled(with space: Space) -> SpaceLayout {
        var out = self
        var remaining = tabs
        out.tabs = [TabKind.pinned, .today].flatMap { kind in
            let urls = kind == .pinned ? space.pinnedTabURLs ?? [] : space.tabURLs
            return urls.map { url in
                if let index = remaining.firstIndex(where: { $0.kind == kind && $0.savedURL == url }) {
                    return remaining.remove(at: index)
                }
                return Page(id: UUID(), url: url, kind: kind, title: url.host ?? url.absoluteString,
                            home: kind == .pinned ? url : nil)
            }
        }
        let kept = Set(out.tabs.map { $0.id.uuidString })
        out.pins = pins.mapped { kept.contains($0) ? $0 : nil }
        out.today = today.mapped { kept.contains($0) ? $0 : nil }
        out.pins.sync(tabs: out.tabs.filter { $0.kind == .pinned }.map { $0.id.uuidString })
        out.today.sync(tabs: out.tabs.filter { $0.kind == .today }.map { $0.id.uuidString })
        out.splits = splits.compactMap { saved in
            let surviving = (saved.ids ?? []).enumerated().filter { kept.contains($0.element) }
            guard surviving.count >= 2 else { return nil }
            return .init(urls: surviving.map { name in out.tabs.first { $0.id.uuidString == name.element }!.url.absoluteString },
                         vertical: saved.vertical, active: surviving.firstIndex { $0.offset == saved.active } ?? 0,
                         ids: surviving.map(\.element),
                         weights: saved.weights.map { weights in Split.normalised(surviving.map { weights[$0.offset] }) })
        }
        out.selected = selected.flatMap { kept.contains($0.uuidString) ? $0 : nil }
        return out
    }
}

struct WorkspaceTemplate: Codable, Equatable, Identifiable {
    struct Appearance: Codable, Equatable {
        var colorHex: String?
        var icon: String?
        var appearance: String?
        var tint: Double?
        var colors: [String]?
        var grain: Double?
        init(_ space: Space) {
            colorHex = space.colorHex; icon = space.icon; appearance = space.appearance
            tint = space.tint; colors = space.colors; grain = space.grain
        }
        func apply(to space: inout Space) {
            space.colorHex = colorHex; space.icon = icon; space.appearance = appearance
            space.tint = tint; space.colors = colors; space.grain = grain
        }
    }
    var id = UUID()
    var name: String
    var profileID: UUID
    var modified = Date()
    var appearance: Appearance
    var layout: SpaceLayout
}

enum WorkspaceError: LocalizedError {
    case authentication, damaged, unsupportedVersion, storage, missing, profile, name, changed
    var errorDescription: String? {
        switch self {
        case .authentication: "Authenticate to include locked-folder contents."
        case .damaged: "The saved setup could not be read. The original file is safe. Restore it from a backup, then retry."
        case .unsupportedVersion: "These templates were saved by a newer Vane. Update Vane before editing them."
        case .storage: "The setup could not be saved. Check storage and folder access, then retry. The last saved version is safe."
        case .missing: "This template is no longer available. Refresh the list and try again."
        case .profile: "Templates can only be used in their own profile."
        case .name: "Enter a name of 1–200 characters."
        case .changed: "The Space or template changed. Refresh the preview and try again."
        }
    }
}

@MainActor final class WorkspaceTemplates {
    struct Disk: Codable {
        var version = 1
        var profileID: UUID
        var templates: [WorkspaceTemplate]
    }
    let manager: ProfileManager
    private let writer: (Data, URL) -> Bool
    init(manager: ProfileManager, writer: @escaping (Data, URL) -> Bool = { SnapshotPersistence.write($0, to: $1) }) {
        self.manager = manager; self.writer = writer
    }
    nonisolated static func url(profile: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("space-templates\(ProfileManager.suffix(profile)).json")
    }
    static func validate(_ data: Data, profile: UUID) throws -> [WorkspaceTemplate] {
        let disk: Disk
        do { disk = try JSONDecoder().decode(Disk.self, from: data) }
        catch { throw WorkspaceError.damaged }
        guard disk.version == 1 else { throw WorkspaceError.unsupportedVersion }
        guard disk.profileID == profile, disk.templates.count <= 1_000,
              Set(disk.templates.map(\.id)).count == disk.templates.count else { throw WorkspaceError.damaged }
        for template in disk.templates {
            guard template.profileID == profile, (1...200).contains(template.name.count),
                  template.modified.timeIntervalSinceReferenceDate.isFinite else { throw WorkspaceError.damaged }
            try template.layout.validate(template: true)
        }
        return disk.templates
    }
    private func checkProfile(_ profile: UUID) throws {
        guard profile != Profile.incognito.id, manager.profiles.contains(where: { $0.id == profile }) else { throw WorkspaceError.profile }
    }
    func load(profile: UUID) throws -> [WorkspaceTemplate] {
        try checkProfile(profile)
        let file = Self.url(profile: profile, directory: manager.directory)
        do { return try Self.validate(Data(contentsOf: file), profile: profile) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        catch let error as WorkspaceError { throw error }
        catch { throw WorkspaceError.damaged }
    }
    private func write(_ templates: [WorkspaceTemplate], profile: UUID) throws {
        do {
            let data = try JSONEncoder().encode(Disk(profileID: profile, templates: templates))
            _ = try Self.validate(data, profile: profile)
            guard writer(data, Self.url(profile: profile, directory: manager.directory)) else { throw WorkspaceError.storage }
        } catch let error as WorkspaceError { throw error }
        catch { throw WorkspaceError.storage }
    }
    private func cleaned(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(name.count) else { throw WorkspaceError.name }
        return name
    }
    @discardableResult
    func save(name: String, space: Space, layout: SpaceLayout, unlocked: Set<UUID>) throws -> WorkspaceTemplate {
        var all = try load(profile: space.profileID)
        let template = WorkspaceTemplate(name: try cleaned(name), profileID: space.profileID,
            appearance: .init(space), layout: try layout.forTemplate(unlocked: unlocked))
        all.append(template); try write(all, profile: space.profileID)
        return template
    }
    func rename(_ id: UUID, profile: UUID, name: String) throws {
        var all = try load(profile: profile)
        guard let i = all.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.missing }
        all[i].name = try cleaned(name); all[i].modified = Date()
        try write(all, profile: profile)
    }
    func update(_ id: UUID, space: Space, layout: SpaceLayout, unlocked: Set<UUID>) throws {
        var all = try load(profile: space.profileID)
        guard let i = all.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.missing }
        all[i].layout = try layout.forTemplate(unlocked: unlocked)
        all[i].appearance = .init(space); all[i].modified = Date()
        try write(all, profile: space.profileID)
    }
    func delete(_ id: UUID, profile: UUID) throws {
        let all = try load(profile: profile)
        guard all.contains(where: { $0.id == id }) else { throw WorkspaceError.missing }
        try write(all.filter { $0.id != id }, profile: profile)
    }
    func create(_ id: UUID, profile: UUID, name: String, unlocked: Set<UUID>) throws -> Space {
        guard let template = try load(profile: profile).first(where: { $0.id == id }) else { throw WorkspaceError.missing }
        try template.layout.requireAuthentication(unlocked)
        let layout = try template.layout.recreated()
        var space = Space(name: try cleaned(name), profileID: profile,
                          tabURLs: layout.tabs.filter { $0.kind == .today }.map(\.savedURL),
                          pinnedTabURLs: layout.tabs.filter { $0.kind == .pinned }.map(\.savedURL))
        template.appearance.apply(to: &space); space.layout = layout
        // One file commits the Space and all of its contents. Never overwrite a damaged list.
        let file = ProfileManager.spacesURL(for: profile, in: manager.directory)
        var all: [Space]
        do {
            let bytes = try Data(contentsOf: file)
            all = try JSONDecoder().decode([Space].self, from: bytes)
            guard all.allSatisfy({ $0.profileID == profile }), Set(all.map(\.id)).count == all.count else { throw WorkspaceError.damaged }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { all = [] }
        catch { throw WorkspaceError.damaged }
        guard manager.saveSpaces(all + [space], for: profile) else { throw WorkspaceError.storage }
        return space
    }
}
