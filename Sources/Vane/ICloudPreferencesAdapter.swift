import Foundation
import CryptoKit
import WebKit

/// Portable preferences are a positive allowlist. Security decisions, paths, bookmarks,
/// credentials, local sync controls and opaque WebKit databases never enter this adapter.
@MainActor final class ICloudPreferencesAdapter: ICloudAdapter {
    let categories: Set<ICloudCategory> = [.appearance, .readerPreferences, .search, .keyboardShortcuts,
        .portablePreferences, .siteSettings, .extensions]
    private let directory: URL
    private let defaults: UserDefaults
    private let profileIDs: @MainActor () -> [UUID]
    private let ensureProfile: @MainActor (UUID) throws -> Void
    private let parseExtension: @MainActor (URL) async throws -> WKWebExtension
    private let readExtensions: @Sendable (URL, [UUID]) throws -> [ICloudItem]
    private var updatesOwners: Bool { defaults === UserDefaults.vane && directory.standardizedFileURL == Store.directory.standardizedFileURL }

    init(directory: URL = Store.directory, defaults: UserDefaults = .vane,
         profileIDs: (@MainActor () -> [UUID])? = nil,
         ensureProfile: (@MainActor (UUID) throws -> Void)? = nil,
         parseExtension: (@MainActor (URL) async throws -> WKWebExtension)? = nil,
         readExtensions: (@Sendable (URL, [UUID]) throws -> [ICloudItem])? = nil) {
        self.directory = directory; self.defaults = defaults
        self.profileIDs = profileIDs ?? { ProfileManager.shared.profiles.map(\.id) }
        if let ensureProfile { self.ensureProfile = ensureProfile }
        else if profileIDs == nil { self.ensureProfile = { try ProfileManager.shared.ensureICloudProfile($0) } }
        else { self.ensureProfile = { _ in } }
        self.parseExtension = parseExtension ?? { try await WKWebExtension(resourceBaseURL: $0) }
        self.readExtensions = readExtensions ?? Self.readExtensionItems
    }

    private static let keys: [ICloudCategory: Set<String>] = [
        .appearance: ["showSpaceIconsInFooter", "searchBarVisibleRows", "searchBarTop", "searchBarAnimations",
            "pageTitlesInWindows", "uiAnimationSpeed.sidebar", "uiAnimationSpeed.tabList", "uiAnimationSpeed.tabClosing",
            "uiAnimationSpeed.surfaces", "uiAnimationSpeed.feedback", "uiAnimationSpeed.status"],
        .readerPreferences: ["readerFontSize", "readerSerif", "readerLineSpacing", "readerWidth"],
        .search: ["searchEngine", "searchSuggestions", "customSearchEngines", "homepage"],
        .keyboardShortcuts: ["keybindings.v1"],
        .portablePreferences: ["warnBeforeQuit", "restoreSession", "afterCrash", "stackSplits", "toastSeconds",
            "interactionSounds", "linkPreviews", "peekLinks", "libraryHoverCategory", "favouritePreviews",
            "favouritePreviews.github", "favouritePreviews.gmail", "favouritePreviews.calendar", "autoPiP",
            "externalLinks", "optionCommandClickLittleVane", "shiftClickPeek", "userAgent", "inspector",
            AIConnections.preferenceKey, "appleAI", "tidyTabs", "tidyPreview", "tidyDownloads", "tidyTitles", "instantLinks", "aiAssistant"],
        // Permissions, certificate exceptions and HTTPS bypasses remain local decisions.
        .siteSettings: ["siteZoom"]
    ]

    private var regularProfiles: [UUID] { Array(Set(profileIDs().filter { $0 != Profile.incognito.id })).sorted { $0.uuidString < $1.uuidString } }
    nonisolated private static func itemID(_ key: String, profile: UUID?) -> String { profile.map { $0.uuidString.lowercased() + "/" + key } ?? key }
    nonisolated private static func cloudIdentity(_ record: ExtensionCodeStore.Record, profile: UUID) -> String {
        ICloudExtensionIdentity.portableID(record, profile: profile)
    }
    private func key(_ item: ICloudItem) -> String? {
        guard Self.keys[item.category] != nil else { return nil }
        if let profile = item.profileID {
            guard item.category == .siteSettings, regularProfiles.contains(profile) else { return nil }
            let prefix = profile.uuidString.lowercased() + "/"
            guard item.id.hasPrefix(prefix) else { return nil }
            let key = String(item.id.dropFirst(prefix.count))
            return Self.keys[item.category]?.contains(key) == true ? key : nil
        }
        guard item.category != .siteSettings, Self.keys[item.category]?.contains(item.id) == true else { return nil }
        return item.id
    }

    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        try ICloudApplyContext.check()
        var result: [ICloudItem] = []
        for category in enabled.intersection(categories).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let keys = Self.keys[category] else { continue }
            if category == .siteSettings {
                for profile in regularProfiles {
                    let table = defaults.dictionary(forKey: ProfileManager.defaultsKey("siteZoom", profile)) ?? [:]
                    try Self.validatePreference(table, key: "siteZoom")
                    for host in table.keys.sorted() {
                        result.append(ICloudItem(category: .siteSettings,
                            id: Self.itemID("siteZoom/" + Self.digest(Data(host.utf8)), profile: profile), profileID: profile, parentID: nil,
                            fields: ["host": try Self.plist(host), "value": try Self.plist(table[host]!)]))
                    }
                }
                continue
            }
            let profiles: [UUID?] = category == .siteSettings ? regularProfiles.map(Optional.some) : [nil]
            for profile in profiles {
                for key in keys.sorted() {
                    let localKey = profile.map { ProfileManager.defaultsKey(key, $0) } ?? key
                    guard let object = defaults.object(forKey: localKey) else { continue }
                    let value = try Self.encodePreference(object, key: key)
                    result.append(ICloudItem(category: category, id: Self.itemID(key, profile: profile), profileID: profile,
                        parentID: nil, fields: ["value": value]))
                }
            }
        }
        if enabled.contains(.extensions) {
            let reader = readExtensions, directory = directory, profiles = regularProfiles
            let worker = Task.detached(priority: .utility) { try reader(directory, profiles) }
            result += try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try ICloudApplyContext.check()
        }
        try ICloudApplyContext.check()
        guard result.reduce(0, { $0 + $1.fields.values.reduce(0) { $0 + $1.count } }) <= ICloudLimits.cycleBytes else {
            throw ICloudFailure.limitExceeded
        }
        return result
    }

    private struct PendingPreference {
        var item: ICloudItem
        var baseKey: String
        var deleted: Bool
        var host: String?
    }

    private func admitProfile(_ profile: UUID) throws -> Bool {
        guard profile != Profile.incognito.id else { return false }
        try ICloudApplyContext.check()
        if !regularProfiles.contains(profile) { try ensureProfile(profile) }
        return regularProfiles.contains(profile)
    }

    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        try ICloudApplyContext.check()
        var pending: [PendingPreference] = []
        // Validate the selected child before creating an opaque missing parent.
        for (rows, isDeletion) in [(items, false), (deleted, true)] {
            for item in rows where enabled.contains(item.category) && item.category != .extensions {
                if item.category == .siteSettings {
                    guard let profile = item.profileID, profile != Profile.incognito.id else { continue }
                    let (host, _) = try siteSetting(item)
                    if isDeletion {
                        guard regularProfiles.contains(profile) else { continue }
                    } else { guard try admitProfile(profile) else { continue } }
                    pending.append(PendingPreference(item: item, baseKey: "siteZoom", deleted: isDeletion, host: host))
                    continue
                }
                guard let base = key(item) else { continue }
                if !isDeletion {
                    guard Set(item.fields.keys) == ["value"], let data = item.fields["value"] else {
                        throw ICloudFailure.invalid("An iCloud preference contains unexpected fields.")
                    }
                    _ = try Self.decodePreference(data, key: base)
                }
                pending.append(PendingPreference(item: item, baseKey: base, deleted: isDeletion, host: nil))
            }
        }
        if enabled.contains(.extensions) {
            for item in items where item.category == .extensions {
                guard let profile = item.profileID, profile != Profile.incognito.id else { continue }
                let wasPresent = regularProfiles.contains(profile)
                let package = try await Task.detached(priority: .utility) {
                    let package = try item.decode(ExtensionPackage.self)
                    try package.validate()
                    return package
                }.value
                try ICloudApplyContext.check()
                if wasPresent && !regularProfiles.contains(profile) { throw CancellationError() }
                guard item.id == Self.itemID(package.identity.lowercased(), profile: profile) else {
                    throw ICloudFailure.invalid("An iCloud extension has an inconsistent identity.")
                }
                guard try admitProfile(profile) else { continue }
                try await importPackage(package, incoming: item, profile: profile)
            }
            for item in deleted where item.category == .extensions {
                guard let profile = item.profileID, regularProfiles.contains(profile), profile != Profile.incognito.id else { continue }
                try ICloudApplyContext.check()
                try removePackage(item.id, profile: profile)
            }
        }
        // Extension parsing yields. Re-read preferences and reconcile at the actual
        // write boundary, preserving edits made while those asynchronous owners ran.
        for write in pending {
            try ICloudApplyContext.check()
            let item = write.item
            if let profile = item.profileID, !regularProfiles.contains(profile) { throw CancellationError() }
            let local = item.profileID.map { ProfileManager.defaultsKey(write.baseKey, $0) } ?? write.baseKey
            if let host = write.host {
                var table = defaults.dictionary(forKey: local) as? [String: Double] ?? [:]
                if write.deleted { table.removeValue(forKey: host) }
                else {
                    let current: [String: Data] = try table[host].map {
                        ["host": try Self.plist(host), "value": try Self.plist($0)]
                    } ?? [:]
                    let patch = ICloudApplyContext.reconcile(item, current: current)
                    guard patch.fields["host"] != nil, patch.fields["value"] != nil else { continue }
                    table[host] = try siteSetting(patch).1
                }
                try ICloudApplyContext.check()
                if table.isEmpty { defaults.removeObject(forKey: local) }
                else { defaults.set(table, forKey: local) }
            } else if write.deleted {
                try ICloudApplyContext.check()
                if write.baseKey == AIConnections.preferenceKey {
                    let retained = try ICloudAIConnections.merge(AIConnections(), into: ICloudAIConnections.local(defaults))
                    defaults.set(try JSONEncoder().encode(retained), forKey: local)
                    if updatesOwners { BrowserAI.settingsChanged() }
                } else {
                    defaults.removeObject(forKey: local)
                    if updatesOwners, write.baseKey == "appleAI" { BrowserAI.settingsChanged() }
                }
            } else {
                let current: [String: Data] = try defaults.object(forKey: local).map {
                    ["value": try Self.encodePreference($0, key: write.baseKey)]
                } ?? [:]
                let patch = ICloudApplyContext.reconcile(item, current: current)
                guard let value = patch.fields["value"] else { continue }
                let decoded = try Self.decodePreference(value, key: write.baseKey)
                try ICloudApplyContext.check()
                if write.baseKey == AIConnections.preferenceKey, let data = decoded as? Data {
                    let incoming = try JSONDecoder().decode(AIConnections.self, from: data)
                    let merged = try ICloudAIConnections.merge(incoming, into: ICloudAIConnections.local(defaults))
                    defaults.set(try JSONEncoder().encode(merged), forKey: local)
                    if updatesOwners { BrowserAI.settingsChanged() }
                } else if updatesOwners, write.baseKey == "appleAI", let value = decoded as? NSNumber {
                    BrowserAI.enabledBinding.wrappedValue = value.boolValue
                } else { defaults.set(decoded, forKey: local) }
            }
        }
        try ICloudApplyContext.check()
        if !pending.isEmpty, !defaults.synchronize() {
            throw ICloudFailure.storage("Portable preferences could not be saved. Pending iCloud changes have been retained.")
        }
        if updatesOwners, pending.contains(where: { $0.item.category == .keyboardShortcuts }) {
            Keybindings.reloadICloudPreferences()
        }
    }

    private static func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func siteSetting(_ item: ICloudItem) throws -> (String, Double) {
        guard let profile = item.profileID, let hostData = item.fields["host"], let valueData = item.fields["value"],
              hostData.count <= ICloudLimits.inlineBytes, valueData.count <= ICloudLimits.inlineBytes,
              Set(item.fields.keys) == ["host", "value"],
              let host = try PropertyListSerialization.propertyList(from: hostData, format: nil) as? String,
              let zoom = try PropertyListSerialization.propertyList(from: valueData, format: nil) as? Double,
              item.id == Self.itemID("siteZoom/" + Self.digest(Data(host.utf8)), profile: profile) else {
            throw ICloudFailure.invalid("An iCloud site preference has invalid fields or identity.")
        }
        try Self.validatePreference([host: zoom], key: "siteZoom")
        return (host, zoom)
    }

    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func encodePreference(_ value: Any, key: String) throws -> Data {
        let value = try normalizedPreference(value, key: key)
        try validatePreference(value, key: key)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard data.count <= ICloudLimits.inlineBytes else { throw ICloudFailure.limitExceeded }
        return data
    }
    private static func decodePreference(_ data: Data, key: String) throws -> Any {
        guard data.count <= ICloudLimits.inlineBytes else { throw ICloudFailure.limitExceeded }
        let value = try normalizedPreference(PropertyListSerialization.propertyList(from: data, format: nil), key: key)
        try validatePreference(value, key: key)
        return value
    }

    private struct ShortcutTable: Codable {
        var bindings: [String: Keybinding]?
        var priorities: [String: Keybindings.Priority]?
        var migrated: Int?
    }
    private static func normalizedPreference(_ value: Any, key: String) throws -> Any {
        if key == AIConnections.preferenceKey, let data = value as? Data {
            guard data.count <= ICloudLimits.inlineBytes else { throw ICloudFailure.limitExceeded }
            return try JSONEncoder().encode(ICloudAIConnections.portable(JSONDecoder().decode(AIConnections.self, from: data)))
        }
        // Re-encode typed blobs so future/unknown fields cannot smuggle paths, grants
        // or credentials through an otherwise allowlisted data-valued preference.
        if key == "customSearchEngines", let data = value as? Data {
            return try JSONEncoder().encode(JSONDecoder().decode([SearchEngine].self, from: data))
        }
        if key == "keybindings.v1", let data = value as? Data {
            var table = try JSONDecoder().decode(ShortcutTable.self, from: data)
            table.bindings = table.bindings?.filter { Command(rawValue: $0.key) != nil }
            table.priorities = table.priorities?.filter { Command(rawValue: $0.key) != nil }
            table.migrated = min(max(table.migrated ?? 0, 0), Keybindings.migration)
            return try JSONEncoder().encode(table)
        }
        return value
    }
    private static func validatePreference(_ value: Any, key: String) throws {
        var valid = false
        switch key {
        case "appleAI":
            valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case AIConnections.preferenceKey:
            if let data = value as? Data { _ = try ICloudAIConnections.portable(JSONDecoder().decode(AIConnections.self, from: data)); valid = true }
        case "siteZoom":
            if let values = value as? [String: Double] {
                valid = values.count <= 10_000 && values.allSatisfy { host, zoom in
                    !host.isEmpty && host.utf8.count <= 255 && !host.contains("/") && zoom.isFinite && (0.5...3).contains(zoom)
                }
            }
        case "customSearchEngines":
            if let data = value as? Data, let engines = try? JSONDecoder().decode([SearchEngine].self, from: data) {
                valid = engines.count <= 1000 && engines.allSatisfy {
                    $0.name.utf8.count <= 1000 && $0.id.utf8.count <= 1000 && $0.queryTemplate.contains("%s")
                        && ["http", "https"].contains($0.home?.scheme?.lowercased() ?? "") && $0.home?.user == nil && $0.home?.password == nil
                }
            }
        case "keybindings.v1":
            if let data = value as? Data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                valid = Set(object.keys).isSubset(of: ["bindings", "priorities", "migrated"])
                    && (object["bindings"] == nil || object["bindings"] is [String: Any])
                    && (object["priorities"] == nil || object["priorities"] is [String: Any])
            }
        case "homepage":
            if let string = value as? String {
                valid = string.isEmpty || URL(string: string).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.user == nil && $0.password == nil } == true
            }
        default:
            if let string = value as? String { valid = string.utf8.count <= 16_384 && !string.hasPrefix("file:") && !string.hasPrefix("/") }
            else if let number = value as? NSNumber { valid = number.doubleValue.isFinite }
        }
        guard valid else { throw ICloudFailure.invalid("The portable preference “\(key)” has an unsupported value. Local settings have been retained.") }
    }

    struct SafariIdentity: Codable, Sendable {
        var appBundleID: String
        var extensionBundleID: String
        var teamID: String
        var signatureHash: String
        init(_ source: SafariExtensionSource) {
            appBundleID = source.appBundleID; extensionBundleID = source.extensionBundleID
            teamID = source.teamID; signatureHash = source.signatureHash
        }
        var source: SafariExtensionSource {
            SafariExtensionSource(appBundleID: appBundleID, extensionBundleID: extensionBundleID,
                teamID: teamID, appPath: "/Applications/ICloudHost.app", signatureHash: signatureHash)
        }
    }

    struct ExtensionPackage: Codable, Sendable {
        var identity: String
        var resources: [String: Data]
        var digests: [String: String]
        var safari: SafariIdentity?
        var storeID: String?
        func validate() throws {
            guard UUID(uuidString: identity) != nil, resources.count <= 20_000,
                  Set(resources.keys) == Set(digests.keys),
                  storeID.map(ChromeWebStore.validID) ?? true,
                  safari.map({ $0.source.isValid && resources.isEmpty && storeID == nil }) ?? !resources.isEmpty else {
                throw ICloudFailure.invalid("An iCloud extension package has invalid metadata.")
            }
            var bytes = 0
            for (path, data) in resources {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.isEmpty, path.utf8.count <= 2048, !path.contains("\\"),
                      parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                      data.count <= ICloudLimits.assetBytes, digests[path] == Self.hash(data) else {
                    throw ICloudFailure.invalid("An iCloud extension resource is damaged or has an unsafe path.")
                }
                bytes += data.count
                guard bytes <= ICloudLimits.assetBytes else { throw ICloudFailure.limitExceeded }
            }
            if safari == nil { guard resources["manifest.json"] != nil else { throw ICloudFailure.invalid("The iCloud extension has no manifest.") } }
        }
        private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }

    nonisolated private static func extensionItem(_ record: ExtensionCodeStore.Record, profile: UUID,
                                                   store: ExtensionCodeStore) throws -> ICloudItem {
        let resources = record.safari == nil ? try store.resources(in: store.code(for: record)) : [:]
        let identity = cloudIdentity(record, profile: profile)
        let package = ExtensionPackage(identity: identity, resources: resources,
            digests: resources.mapValues(digest), safari: record.safari.map(SafariIdentity.init),
            storeID: record.store?.id ?? record.iCloudStoreID)
        try package.validate()
        let item = ICloudItem(category: .extensions, id: itemID(identity, profile: profile), profileID: profile,
            parentID: nil, fields: try ICloudItem.encodedFields(package))
        try item.validate()
        return item
    }

    nonisolated private static func readExtensionItems(directory: URL, profiles: [UUID]) throws -> [ICloudItem] {
        var result: [ICloudItem] = [], bytes = 0
        for profile in profiles where profile != Profile.incognito.id {
            let store = ExtensionCodeStore(profileID: profile, directory: directory)
            for record in try store.records().values.sorted(by: { $0.identity < $1.identity }) {
                try Task.checkCancellation()
                let item = try extensionItem(record, profile: profile, store: store)
                bytes += item.fields.values.reduce(0) { $0 + $1.count }
                guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
                result.append(item)
            }
        }
        return result
    }

    private struct ExtensionSnapshot: Sendable {
        var key: String?
        var record: ExtensionCodeStore.Record?
        var item: ICloudItem?
    }

    nonisolated private static func readExtensionSnapshot(directory: URL, profile: UUID,
                                                         itemID: String) throws -> ExtensionSnapshot {
        let store = ExtensionCodeStore(profileID: profile, directory: directory)
        guard let entry = try store.records().first(where: {
            Self.itemID(cloudIdentity($0.value, profile: profile), profile: profile) == itemID
        }) else { return ExtensionSnapshot() }
        return ExtensionSnapshot(key: entry.key, record: entry.value,
            item: try extensionItem(entry.value, profile: profile, store: store))
    }

    private func checkProfile(_ profile: UUID) throws {
        try ICloudApplyContext.check()
        // A parent admitted before an await may have been retired locally. Never
        // call ensure here: late callbacks cannot recreate a removed profile.
        guard profile != Profile.incognito.id, regularProfiles.contains(profile) else { throw CancellationError() }
    }

    private func importPackage(_ package: ExtensionPackage, incoming: ICloudItem, profile: UUID) async throws {
        try checkProfile(profile)
        let store = ExtensionCodeStore(profileID: profile, directory: directory)
        let directory = directory
        let initial = try await Task.detached(priority: .utility) {
            try Self.readExtensionSnapshot(directory: directory, profile: profile, itemID: incoming.id)
        }.value
        try checkProfile(profile)
        if initial.item?.fields == incoming.fields { return }
        let stage: ExtensionCodeStore.Stage
        let manifestRoot: URL
        let safari: SafariExtensionSource?
        if let identity = package.safari {
            let candidate = try await identity.source.resolve()
            try checkProfile(profile)
            if let accepted = initial.record?.safari, accepted.matches(candidate.source),
               accepted.signatureHash == candidate.source.signatureHash { return }
            stage = try await Task.detached(priority: .utility) {
                try store.stage(candidate.bundleURL, appExtension: true)
            }.value
            manifestRoot = stage.url.appendingPathComponent("extension.appex/Contents/Resources")
            safari = candidate.source
        } else {
            stage = try await Task.detached(priority: .utility) {
                let temporary = directory.appendingPathComponent("ICloudExtension-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                for (path, data) in package.resources {
                    try Task.checkCancellation()
                    let destination = temporary.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    try data.write(to: destination, options: [.atomic])
                }
                return try store.stage(temporary)
            }.value
            manifestRoot = stage.url
            safari = nil
        }
        var committed = false
        defer { if !committed { store.discard(stage) } }
        try checkProfile(profile)
        let manifest = try ExtensionHost.validate(manifestRoot)
        try ExtensionDiagnostics.validateResources(manifest, in: manifestRoot)
        // Parsing produces declarations without loading a context or executing code.
        let ext = try await parseExtension(manifestRoot)
        try checkProfile(profile)
        let current = try await Task.detached(priority: .utility) {
            try Self.readExtensionSnapshot(directory: directory, profile: profile, itemID: incoming.id)
        }.value
        try checkProfile(profile)
        let patch = ICloudApplyContext.reconcile(incoming, current: current.item?.fields ?? [:])
        // Package bytes and their digests are one safety boundary. A local package
        // edit during parsing wins as a whole, rather than mixing its code with a
        // remote manifest or source identity.
        guard patch.fields == incoming.fields else { return }
        if let baseline = ICloudApplyContext.baseline[incoming.key],
           baseline.fields != (current.item?.fields ?? [:]) { return }
        var records = try store.records()
        let existing = records.first { entry in
            Self.itemID(Self.cloudIdentity(entry.value, profile: profile), profile: profile) == incoming.id
        }
        // A writer can replace the index while the detached snapshot is finishing.
        // Never publish over that newer accepted revision or discard unrelated rows.
        guard existing?.key == current.key,
              existing?.value.revision == current.record?.revision,
              existing?.value.identity == current.record?.identity else { return }
        let path = safari?.key ?? (existing?.value.store == nil ? existing?.key : nil)
            ?? "/icloud-extension/" + package.identity.lowercased()
        try checkProfile(profile)
        if updatesOwners { try ExtensionHost.prepareICloudImport(profileID: profile, identity: existing?.value.identity ?? package.identity) }
        let record = ExtensionCodeStore.Record(identity: existing?.value.identity ?? package.identity, revision: stage.revision,
            sourcePath: safari?.appPath ?? stage.url.path,
            name: ext.displayName ?? "Synced extension", version: ext.version ?? "Unknown", summary: ext.displayDescription ?? "",
            required: ExtensionAccess(ext), optional: ExtensionAccess(permissions: Set(ext.optionalPermissions.map(\.rawValue)),
                sites: Set(ext.optionalPermissionMatchPatterns.map(\.string))), compatibility: ExtensionDiagnostics.limitations(manifest, extension: ext),
            safari: safari, iCloudIdentity: package.identity, iCloudStoreID: package.storeID)
        if let existing, existing.key != path {
            records.removeValue(forKey: existing.key)
            try checkProfile(profile)
            ExtensionConsent.remove(for: URL(fileURLWithPath: existing.key), profileID: profile, in: defaults)
        }
        records[path] = record
        var disabled = Set(defaults.stringArray(forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile)) ?? [])
        disabled.insert(path)
        try checkProfile(profile)
        defaults.set(disabled.sorted(), forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile))
        ExtensionConsent.remove(for: URL(fileURLWithPath: path), profileID: profile, in: defaults)
        guard defaults.synchronize() else { throw ICloudFailure.storage("The inactive extension could not be saved. Pending iCloud changes have been retained.") }
        try checkProfile(profile)
        try store.save(records)
        committed = true
        if updatesOwners { try ExtensionHost.reloadICloudInstallations(profileID: profile) }
    }

    private func removePackage(_ itemID: String, profile: UUID) throws {
        try checkProfile(profile)
        let store = ExtensionCodeStore(profileID: profile, directory: directory)
        var records = try store.records()
        guard let existing = records.first(where: { Self.itemID(Self.cloudIdentity($0.value, profile: profile), profile: profile) == itemID }) else { return }
        if updatesOwners { try ExtensionHost.prepareICloudImport(profileID: profile, identity: existing.value.identity) }
        records.removeValue(forKey: existing.key)
        try checkProfile(profile)
        try store.save(records)
        ExtensionConsent.remove(for: URL(fileURLWithPath: existing.key), profileID: profile, in: defaults)
        var names = defaults.dictionary(forKey: ProfileManager.defaultsKey(ExtensionHost.namesKey, profile)) ?? [:]
        names.removeValue(forKey: existing.key)
        defaults.set(names, forKey: ProfileManager.defaultsKey(ExtensionHost.namesKey, profile))
        if updatesOwners { try ExtensionHost.reloadICloudInstallations(profileID: profile) }
    }
}
