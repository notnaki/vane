import AppKit
import Combine
import Darwin
import SwiftUI
import WebKit

// MARK: - Wiring (read this before touching Engine.swift)
//
// A WKWebView only participates in the extension system if the *configuration it was
// created with* names the controller. There is no way to attach one afterwards, so this
// has to happen inside `Tab.configuration(isPrivate:)`:
//
//     cfg.webExtensionController = ExtensionHost.host(for: profileID).controller
//
// One line, and it must run before `WKWebView(frame:configuration:)`. There is one host per
// *profile*, so an extension loaded in one profile never sees another profile's tabs.
// Incognito has an empty, non-persistent controller of its own, plus a non-persistent
// website data store and a fresh WKUserContentController per Tab.
//
// `configuration(for:)` below is the same thing spelled for a call site that has a store.
//
// Menu, Settings, and the command palette present ExtensionManagement for a profile.

/// Host for Apple's WebExtension API. Owns the one controller, the loaded contexts, and
/// the adapters that let an extension see Vane's tabs and windows.
///
/// ponytail: one controller per profile, not per window — WKWebExtension is modelled that
/// way (windows are things the controller asks *you* about). Profiles are exactly the level
/// where a separate persistent store identifier is warranted. Incognito's host uses
/// `.nonPersistent()` and loads none of the saved profiles' extensions.
@MainActor final class ExtensionHost: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    /// The active profile's host. One host — one controller, one extension set, one set of
    /// background pages — per profile, so an extension in one profile cannot see another
    /// profile's tabs or storage.
    static var shared: ExtensionHost { host(for: ProfileManager.shared.active.id) }

    private static var hosts: [UUID: ExtensionHost] = [:]

    private struct DataPurgeKey: Hashable {
        let profileID: UUID
        let runtimeID: String
    }
    private struct DataPurge {
        let token: UUID
        let task: Task<Void, Never>
    }
    // A WebKit deletion already submitted cannot be cancelled. Keep it visible across
    // host replacement so no successor loads that identity before deletion finishes.
    private static var dataPurges: [DataPurgeKey: DataPurge] = [:]

    static func host(for profileID: UUID) -> ExtensionHost {
        if let hit = hosts[profileID] { return hit }
        let fresh = ExtensionHost(profileID: profileID)
        hosts[profileID] = fresh
        return fresh
    }

    /// Unload everything and forget the host. Called when a profile is deleted.
    static func forget(_ profileID: UUID) {
        guard let host = hosts[profileID] else { return }
        host.invalidated = true
        ExtensionManagement.close(for: profileID)
        for task in host.restoring.values { task.cancel() }
        host.restoring.removeAll()
        host.operations.removeAll()
        for context in host.installed + Array(host.candidates.values) {
            host.closePages(for: context)
            try? host.controller.unload(context)
        }
        host.candidates.removeAll()
        host.icons.removeAll()
        host.anchors.removeAll()
        host.loaded.removeAll()
        SiteChanges.shared.bump()
        hosts[profileID] = nil
    }

    /// Normal launches retain the controller identifiers shipped before data-directory
    /// isolation. A VANE_DATA_DIR launch gets the same stable, directory-scoped identity as
    /// its website data store, so extension storage and background pages cannot cross into
    /// the installed app even for the fixed default profile.
    nonisolated static func controllerIdentifier(for profileID: UUID, dataDirectory: String?) -> UUID? {
        ProfileManager.dataStoreIdentifier(for: profileID, dataDirectory: dataDirectory)
    }

    let profileID: UUID
    let controller: WKWebExtensionController
    private let userAgent = ExtensionUserAgent()

    #if DEBUG
    // Test-owned diagnostics observe only an already-created background page.
    var backgroundCreationObserver: ((WKWebView, WKWebExtensionContext) -> Void)?
    #endif

    static func applyUserAgent() {
        for host in hosts.values { host.userAgent.apply() }
    }

    /// Folder path alongside the context, because WKWebExtension does not report the
    /// resource base URL it was built from and uninstall has to erase the stored path.
    @Published private(set) var loaded: [(path: String, context: WKWebExtensionContext)] = []

    var installed: [WKWebExtensionContext] { loaded.map(\.context) }

    struct Entry: Identifiable {
        let path: String
        let name: String
        let context: WKWebExtensionContext?
        let status: String
        let failure: String?
        let busy: Bool
        var version: String = "Unknown"
        var summary: String = ""
        var icon: NSImage? = nil
        var enabled: Bool = false
        var managed: Bool = false
        var sourceAvailable: Bool = false
        var sourcePath: String = ""
        var safariApp: Bool = false
        var requiredAccess: ExtensionAccess? = nil
        var optionalAccess: ExtensionAccess? = nil
        var compatibility: [String] = []
        var id: String { path }
    }

    @Published private var folders: [String: String] = [:]
    @Published private var failures: [String: String] = [:]
    @Published private var operations: [String: UUID] = [:]
    @Published private var disabled: Set<String> = []
    private var candidates: [String: WKWebExtensionContext] = [:]
    private var limitations: [String: [String]] = [:]
    private let codeStore: ExtensionCodeStore
    private var records: [String: ExtensionCodeStore.Record] = [:]
    private var metadataFailure: String?
    private static let integratedCapabilities: Set<String> = ["contextMenus", "menus"]
    private var metadataIcons: [String: NSImage] = [:]
    private struct LegacyMetadata {
        var version: String
        var summary: String
        var optional: ExtensionAccess
    }
    private var legacyMetadata: [String: LegacyMetadata] = [:]
    private var metadataObservations = Set<AnyCancellable>()

    var isBusy: Bool { !operations.isEmpty || !restoring.isEmpty }

    private struct InstallationGeneration: Equatable {
        let identity: String?
        let revision: String?
        let contextID: String?
        let disabled: Bool
    }

    /// Discovery initially has no trusted extension key. Once verification supplies
    /// one, compare its installation against this snapshot before adopting anything.
    private func installationGenerations() -> [String: InstallationGeneration] {
        let identities = contextIdentifiers
        return Dictionary(uniqueKeysWithValues: folders.keys.map { path in
            (path, InstallationGeneration(identity: records[path]?.identity, revision: records[path]?.revision,
                contextID: identities[path], disabled: disabled.contains(path)))
        })
    }

    var entries: [Entry] {
        folders.keys.sorted { (folders[$0] ?? "").localizedStandardCompare(folders[$1] ?? "") == .orderedAscending }.map { path in
            let context = loaded.first { $0.path == path }?.context
            let record = records[path]
            let source = sourceFolder(for: path)
            let busy = operations[path] != nil || restoring[path] != nil
            let runtimeErrors = context.map { ExtensionDiagnostics.blockingErrors($0.errors, manifest: $0.webExtension.manifest) } ?? []
            let failure = failures[path] ?? (runtimeErrors.isEmpty ? nil : ExtensionDiagnostics.describe(runtimeErrors))
            return Entry(path: path, name: record?.name ?? folders[path] ?? URL(fileURLWithPath: path).lastPathComponent,
                         context: context, status: busy ? "Checking…" : failure != nil ? (context != nil ? "Update needs attention" : "Needs attention")
                            : context != nil ? "Enabled" : disabled.contains(path) ? "Disabled" : "Inactive",
                         failure: failure, busy: busy,
                         version: record?.version ?? context?.webExtension.version ?? legacyMetadata[path]?.version ?? "Unknown",
                         summary: record?.summary ?? context?.webExtension.displayDescription ?? legacyMetadata[path]?.summary ?? "",
                         icon: metadataIcons[path] ?? context?.webExtension.icon(for: CGSize(width: 40, height: 40)),
                         enabled: context != nil, managed: record != nil,
                         sourceAvailable: FileManager.default.isReadableFile(atPath: record?.safari != nil ? source.path : source.appendingPathComponent("manifest.json").path),
                         sourcePath: source.path, safariApp: record?.safari != nil || path.hasPrefix("/safari-extension/"),
                         requiredAccess: record?.required ?? ExtensionConsent.saved(for: URL(fileURLWithPath: path), profileID: profileID),
                         optionalAccess: record?.optional ?? legacyMetadata[path]?.optional,
                         compatibility: (record?.compatibility ?? limitations[path] ?? [])
                            + (userAgent.limitation.map { [$0] } ?? []))
        }
    }

    private init(profileID: UUID) {
        self.profileID = profileID
        self.codeStore = ExtensionCodeStore(profileID: profileID)
        // Existing controller identities and context origins remain unchanged.
        let configuration = profileID == Profile.incognito.id
            ? WKWebExtensionController.Configuration.nonPersistent()
            : Self.controllerIdentifier(for: profileID, dataDirectory: Store.overrideDirectory)
                .map(WKWebExtensionController.Configuration.init(identifier:))
                ?? WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = ProfileManager.dataStore(for: profileID)
        let webConfiguration: WKWebViewConfiguration = configuration.webViewConfiguration
        // Older WebKit keeps the page seed separate from the controller's cookie/API
        // store. Bind both to this profile before WebKit copies the configuration.
        webConfiguration.websiteDataStore = configuration.defaultWebsiteDataStore
        webConfiguration.processPool = WebKitStartup.processPool
        userAgent.configure(webConfiguration)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        for name in [WKWebExtensionContext.errorsDidUpdateNotification,
                     WKWebExtensionContext.permissionsWereGrantedNotification,
                     WKWebExtensionContext.permissionsWereDeniedNotification,
                     WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
                     WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
                     WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
                     WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self, let context = note.object as? WKWebExtensionContext,
                          self.installed.contains(where: { $0 === context }) else { return }
                    self.objectWillChange.send()
                }.store(in: &metadataObservations)
        }
        guard profileID != Profile.incognito.id else { return }
        do {
            records = try codeStore.records()
            try? codeStore.sweepUnreferencedRevisions()
        }
        catch { metadataFailure = "Saved extension metadata could not be read. Choose Update from Folder or Update from App to review and repair each installation. Existing code files and settings are retained. " + error.localizedDescription }
        folders = UserDefaults.vane.dictionary(forKey: ProfileManager.defaultsKey(Self.namesKey, profileID)) as? [String: String] ?? [:]
        disabled = Set(UserDefaults.vane.stringArray(forKey: ProfileManager.defaultsKey(Self.disabledKey, profileID)) ?? [])
        for (path, record) in records { folders[path] = record.name }
        for choice in ScopedPaths.savedChoices(myKey) {
            let old = contextBookmarks.first(where: { $0.value == choice.data })?.key ?? choice.originalPath
            if let old, folders[old] != nil || contextIdentifiers[old] != nil {
                var bookmarks = contextBookmarks
                bookmarks[old] = choice.data
                contextBookmarks = bookmarks
            }
            if let old, records[old] == nil, let folder = choice.url,
               folder.resolvingSymlinksInPath().path != old,
               folders[old] != nil || contextIdentifiers[old] != nil {
                do { try relocate(old, to: folder, bookmark: choice.data) }
                catch { failures[old] = error.localizedDescription }
            }
        }
        for folder in ScopedPaths.urls(myKey, preservingUnavailable: true) {
            let path = folder.resolvingSymlinksInPath().path
            // Managed installations retain their original key when a source bookmark moves.
            if records.values.contains(where: { $0.sourcePath == path }) || contextBookmarks.contains(where: { key, data in
                records[key] != nil && ScopedPaths.savedChoices(myKey).contains { $0.data == data && $0.url?.resolvingSymlinksInPath().path == path }
            }) { continue }
            if folders[path] == nil { folders[path] = folder.lastPathComponent }
        }
        for path in contextIdentifiers.keys where folders[path] == nil { folders[path] = URL(fileURLWithPath: path).lastPathComponent }
        for path in Array(folders.keys) {
            if let metadataFailure { failures[path] = metadataFailure; continue }
            if let record = records[path] { cacheIcon(for: path, in: record.safari == nil ? codeStore.code(for: record) : codeStore.code(for: record).appendingPathComponent("extension.appex/Contents/Resources")) }
            else if let manifest = try? Self.validate(sourceFolder(for: path)) {
                func optional(_ key: String) -> [String] { manifest[key] as? [String] ?? [] }
                let declarations = optional("optional_permissions")
                legacyMetadata[path] = LegacyMetadata(version: manifest["version"] as? String ?? "Unknown",
                    summary: manifest["description"] as? String ?? "",
                    optional: ExtensionAccess(permissions: Set(declarations.filter { !$0.contains("://") && $0 != "<all_urls>" }),
                        sites: Set(declarations.filter { $0.contains("://") || $0 == "<all_urls>" } + optional("optional_host_permissions"))))
                cacheIcon(for: path, in: sourceFolder(for: path))
            }
            if !disabled.contains(path), failures[path] == nil { begin(path) }
        }
    }

    private func sourceFolder(for path: String) -> URL {
        if let source = records[path]?.safari { return URL(fileURLWithPath: source.appPath, isDirectory: true) }
        if let bookmark = contextBookmarks[path],
           let resolved = ScopedPaths.bookmarkedURL(bookmark) {
            return resolved.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: records[path]?.sourcePath ?? path, isDirectory: true)
    }

    private func cacheIcon(for path: String, in folder: URL) {
        guard let manifest = try? Self.validate(folder), let icons = manifest["icons"] as? [String: String] else { return }
        let choices = icons.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        guard let icon = (choices.first { (Int($0.key) ?? 0) >= 40 } ?? choices.last)?.value else { return }
        let url = folder.appendingPathComponent(icon).standardizedFileURL
        guard url.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return }
        metadataIcons[path] = NSImage(contentsOf: url)
    }

    /// The controller a new WKWebView's configuration must be pointed at. See the wiring note
    /// at the top of this file. Resolves through the store's *profile*, so calling it on the
    /// wrong host still returns the right controller.
    func configuration(for store: TabStore) -> WKWebExtensionController {
        Self.host(for: store.profileID).controller
    }

    // MARK: Install / remove

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// Nothing is persisted or granted until the user has reviewed WebKit's parsed access.
    func install(folder: URL) async throws {
        let path = folder.resolvingSymlinksInPath().path
        _ = try await load(folder, installing: true, replacing: folders[path] != nil)
    }

    private var myKey: String { Self.key(for: profileID) }

    func remove(_ context: WKWebExtensionContext) {
        guard let path = path(of: context) else { return }
        do { try remove(folder: path) }
        catch { warn("Could not remove that extension.", error.localizedDescription) }
    }

    func remove(folder path: String) throws {
        cancelOperation(path)
        try deactivate(path)
        if let record = records[path] {
            var next = records
            next[path] = nil
            do { try codeStore.save(next) }
            catch {
                failures[path] = "The extension was stopped, but its installation could not be removed. Check profile storage permissions and retry removal. " + error.localizedDescription
                throw error
            }
            records = next
            codeStore.discard(record)
        }
        ScopedPaths.remove(path: sourceFolder(for: path).path, from: myKey, bookmark: contextBookmarks[path])
        var bookmarks = contextBookmarks
        bookmarks[path] = nil
        contextBookmarks = bookmarks
        ExtensionConsent.remove(for: URL(fileURLWithPath: path), profileID: profileID)
        var identities = contextIdentifiers
        identities.removeValue(forKey: path)
        contextIdentifiers = identities
        folders[path] = nil
        failures[path] = nil
        limitations[path] = nil
        metadataIcons[path] = nil
        legacyMetadata[path] = nil
        disabled.remove(path)
        saveManagement()
        setPins(pins.filter { $0 != path })
    }

    func disable(_ path: String) throws {
        cancelOperation(path)
        try deactivate(path)
        disabled.insert(path)
        failures[path] = nil
        saveManagement()
    }

    private func cancelOperation(_ path: String) {
        operations[path] = nil
        restoring[path]?.cancel()
        restoring[path] = nil
    }

    private func deactivate(_ path: String) throws {
        if let context = candidates[path] {
            if context.isLoaded { try controller.unload(context) }
            closePages(for: context)
            candidates[path] = nil
        }
        guard let context = loaded.first(where: { $0.path == path })?.context else { return }
        try controller.unload(context)
        closePages(for: context)
        forget(context, tab: nil)
        loaded.removeAll { $0.path == path }
        SiteChanges.shared.bump()
    }

    private func saveManagement() {
        UserDefaults.vane.set(folders, forKey: ProfileManager.defaultsKey(Self.namesKey, profileID))
        UserDefaults.vane.set(disabled.sorted(), forKey: ProfileManager.defaultsKey(Self.disabledKey, profileID))
    }

    @discardableResult
    func refresh(_ path: String,
                 review: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws -> Bool {
        guard folders[path] != nil else { throw Failure("This extension has been removed. Install it again.") }
        if let source = records[path]?.safari {
            guard operations[path] == nil else { return false }
            let token = UUID()
            operations[path] = token
            defer { if operations[path] == token { operations[path] = nil }; rebuild() }
            let candidate = try await source.resolve()
            try Task.checkCancellation()
            guard !invalidated, operations[path] == token else { throw CancellationError() }
            return try await loadSafariCandidate(candidate, path: path, installing: false,
                enable: !disabled.contains(path), operationToken: token, review: review)
        }
        return try await loadCandidate(sourceFolder(for: path), path: path, installing: false,
                                       replacing: true, enable: !disabled.contains(path), review: review)
    }

    func setEnabled(_ enabled: Bool, for path: String,
                    review: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws {
        guard folders[path] != nil else { throw Failure("This extension has been removed.") }
        if !enabled { try disable(path); return }
        guard !loaded.contains(where: { $0.path == path }) else { return }
        if records[path] != nil { try await restoreAccepted(path, enabling: true, review: review) }
        else { _ = try await loadCandidate(sourceFolder(for: path), path: path, installing: false, replacing: true, enable: true, review: review) }
    }

    func retry(_ path: String) async throws {
        if records[path] != nil, !loaded.contains(where: { $0.path == path }) {
            try await restoreAccepted(path, enabling: !disabled.contains(path))
        } else { _ = try await refresh(path) }
    }

    func chooseUpdate(for path: String) {
        guard folders[path] != nil, profileID != Profile.incognito.id else { return }
        if records[path]?.safari != nil || path.hasPrefix("/safari-extension/") { chooseAndInstall(updating: path); return }
        let panel = NSOpenPanel()
        panel.title = "Update Extension from Folder"
        panel.message = "Choose the replacement extension folder containing manifest.json. Vane checks a separate copy and reviews added access. Your extension identity and settings are kept."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = sourceFolder(for: path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            do { _ = try await loadCandidate(source, path: path, installing: false, replacing: true, enable: !disabled.contains(path)) }
            catch is CancellationError { }
            catch { warn("Could not update that extension.", error.localizedDescription) }
        }
    }

    private var invalidated = false
    private var restoring: [String: Task<Void, Never>] = [:]

    private func begin(_ path: String) {
        restoring[path] = Task {
            defer { restoring[path] = nil; prunePins(); rebuild() }
            do {
                if records[path] != nil { try await restoreAccepted(path, enabling: true) }
                else { _ = try await loadCandidate(sourceFolder(for: path), path: path, installing: false, replacing: false, enable: true) }
            } catch is CancellationError { }
            catch { if folders[path] != nil { failures[path] = error.localizedDescription }; rebuild() }
        }
    }

    /// All source reads finish before WebKit parsing or consent. WebKit only sees the
    /// private staged copy, never a developer's mutable source after adoption.
    @discardableResult
    func load(_ folder: URL, installing: Bool, replacing: Bool = false,
              review: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws -> Bool {
        if ["app", "appex"].contains(folder.pathExtension.lowercased()) {
            let generations = installationGenerations()
            let candidates = try await Task.detached(priority: .utility) { try SafariExtensionSource.candidates(in: folder) }.value
            try Task.checkCancellation()
            guard candidates.count == 1, let candidate = candidates.first else { throw Failure("This app contains several Safari extensions. Choose its specific .appex bundle, or use Install Extension in the extension manager.") }
            let path = candidate.source.key
            guard !invalidated, installationGenerations()[path] == generations[path] else { throw CancellationError() }
            return try await loadSafariCandidate(candidate, path: path, installing: folders[path] == nil, enable: !disabled.contains(path), review: review)
        }
        let path = folder.resolvingSymlinksInPath().path
        return try await loadCandidate(folder, path: path, installing: installing, replacing: replacing,
                                       enable: !disabled.contains(path), review: review)
    }

    @discardableResult
    private func loadCandidate(_ source: URL, path: String, installing: Bool, replacing: Bool,
                               enable: Bool, review: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws -> Bool {
        guard !invalidated, profileID != Profile.incognito.id else { throw CancellationError() }
        guard records[path]?.safari == nil, !path.hasPrefix("/safari-extension/") else { throw Failure("Use Update from App for this Safari extension.") }
        if let metadataFailure, !replacing || installing || folders[path] == nil { throw Failure(metadataFailure) }
        try Task.checkCancellation()
        guard operations[path] == nil else { return false }
        guard replacing || !loaded.contains(where: { $0.path == path }) else { return false }
        let token = UUID()
        operations[path] = token
        let oldRecord = records[path]
        let previous = ExtensionConsent.saved(for: URL(fileURLWithPath: path), profileID: profileID)
        var stage: ExtensionCodeStore.Stage?
        var accepted = false
        var replaced = false
        var approvalChanged = false
        var bookmarkAdded = false
        defer {
            if operations[path] == token { operations[path] = nil }
            if !accepted, let stage { codeStore.discard(stage) }
            if !accepted, bookmarkAdded { ScopedPaths.remove(path: source.resolvingSymlinksInPath().path, from: myKey) }
            prunePins()
            rebuild()
        }
        func checkLifetime() throws {
            try Task.checkCancellation()
            guard !invalidated, operations[path] == token else { throw CancellationError() }
        }
        do {
            let store = codeStore
            let frozen = try await Task.detached(priority: .utility) { try store.stage(source) }.value
            stage = frozen
            try checkLifetime()
            let manifestData = try Self.readManifest(frozen.url)
            let manifest = try Self.validate(frozen.url, data: manifestData)
            try ExtensionDiagnostics.validateResources(manifest, in: frozen.url)
            let ext = try await WKWebExtension(resourceBaseURL: frozen.url)
            try checkLifetime()
            let parseErrors = ExtensionDiagnostics.blockingErrors(ext.errors, manifest: manifest)
            guard parseErrors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(parseErrors) + "\nFix the extension folder and retry.") }
            let issues = ExtensionDiagnostics.limitations(manifest, extension: ext)
            let requested = ExtensionAccess(ext)
            let request = ExtensionConsent.Review(name: ext.displayName ?? source.lastPathComponent,
                requested: requested, previous: previous, installing: installing, limitations: issues,
                newlySupportedCapabilities: installing ? [] : requested.permissions.intersection(Self.integratedCapabilities).subtracting(oldRecord?.integratedCapabilities ?? []),
                updating: !installing && (replacing || oldRecord == nil), currentVersion: oldRecord?.version, candidateVersion: ext.version)
            if request.needsApproval, !review(request) {
                try checkLifetime()
                if folders[path] != nil { failures[path] = "The update was not approved. The accepted version and its approval are kept. Choose Update from Folder when you are ready to review it again." }
                return false
            }
            try checkLifetime()
            // Preserve the existing warning for an edited manifest, even though the staged
            // copy is safe. Other source resource edits cannot change reviewed bytes.
            guard (try? Self.readManifest(source)) == manifestData else {
                throw Failure("manifest.json changed while Vane was checking it. Retry to review the current extension before enabling it.")
            }
            let identity = oldRecord?.identity ?? contextIdentifiers[path].flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
            let record = ExtensionCodeStore.Record(identity: identity, revision: frozen.revision,
                sourcePath: source.resolvingSymlinksInPath().path, name: ext.displayName ?? source.lastPathComponent,
                version: ext.version ?? "Unknown", summary: ext.displayDescription ?? "",
                required: requested,
                optional: ExtensionAccess(permissions: Set(ext.optionalPermissions.map(\.rawValue)), sites: Set(ext.optionalPermissionMatchPatterns.map(\.string))),
                compatibility: issues, integratedCapabilities: requested.permissions.intersection(Self.integratedCapabilities))
            if enable {
                try deactivate(path)
                replaced = true
                let context = makeContext(ext, identity: identity)
                candidates[path] = context
                try controller.load(context)
                if ext.hasBackgroundContent { try await ExtensionBackgroundStartup.load(context, checkLifetime: checkLifetime) }
                try checkLifetime()
                let errors = ExtensionDiagnostics.blockingErrors(context.errors, manifest: manifest)
                guard errors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(errors)) }
            }
            try checkLifetime()
            let alreadyBookmarked = ScopedPaths.savedChoices(myKey).contains { $0.url?.resolvingSymlinksInPath().path == record.sourcePath }
            guard ScopedPaths.add(source, to: myKey) else { throw Failure("macOS would not let Vane keep access to the source folder. Choose it again; the accepted version is retained.") }
            bookmarkAdded = !alreadyBookmarked
            try ExtensionConsent.save(requested, for: URL(fileURLWithPath: path), profileID: profileID)
            approvalChanged = true
            var next = records
            next[path] = record
            if metadataFailure != nil { try codeStore.retainUnusableIndex() }
            try codeStore.save(next)
            records = next
            metadataFailure = nil
            var identities = contextIdentifiers
            identities[path] = identity
            contextIdentifiers = identities
            if let bookmark = ScopedPaths.savedChoices(myKey).first(where: { $0.url?.resolvingSymlinksInPath().path == record.sourcePath })?.data {
                var bookmarks = contextBookmarks
                let oldBookmark = bookmarks[path]
                bookmarks[path] = bookmark
                contextBookmarks = bookmarks
                if let oldBookmark, oldBookmark != bookmark { ScopedPaths.remove(path: oldRecord?.sourcePath ?? path, from: myKey, bookmark: oldBookmark) }
            }
            folders[path] = record.name
            if enable { disabled.remove(path) }
            failures[path] = nil
            limitations[path] = issues
            saveManagement()
            metadataIcons[path] = ext.icon(for: CGSize(width: 40, height: 40))
            if let context = candidates.removeValue(forKey: path) { loaded.append((path, context)) }
            accepted = true
            if let oldRecord { codeStore.discard(oldRecord) }
            startPolling()
            SiteChanges.shared.bump()
            return true
        } catch {
            if operations[path] == token, !invalidated {
                if approvalChanged {
                    if let previous { try? ExtensionConsent.save(previous, for: URL(fileURLWithPath: path), profileID: profileID) }
                    else { ExtensionConsent.remove(for: URL(fileURLWithPath: path), profileID: profileID) }
                }
                if replaced {
                    do {
                        try deactivate(path)
                        if let oldRecord, enable {
                            // A caller may cancel only its update task. Recover independently
                            // of that cancellation, while disable/remove/profile deletion still
                            // invalidate the operation token and prevent resurrection.
                            let recovery = Task { @MainActor in
                                try await self.context(for: oldRecord, path: path) {
                                    guard !self.invalidated, self.operations[path] == token else { throw CancellationError() }
                                }
                            }
                            let restored = try await recovery.value
                            guard !invalidated, operations[path] == token else {
                                try? controller.unload(restored); closePages(for: restored); throw CancellationError()
                            }
                            loaded.append((path, restored))
                        }
                    } catch {
                        failures[path] = "The update failed and the accepted version could not be restarted. Choose Retry. Your identity and settings are retained.\n" + error.localizedDescription
                        throw error
                    }
                }
                if folders[path] != nil {
                    failures[path] = ExtensionDiagnostics.describe([error]) + (oldRecord != nil
                        ? "\nThe accepted code, approval, identity, and settings are retained. Choose Update from Folder to repair the source, or Retry to restart the accepted version."
                        : "\nRepair or locate the source folder and choose Update from Folder. Your identity, approval, and settings are retained.")
                }
            }
            throw error
        }
    }

    private func waitForDataPurge(_ runtimeID: String, checkLifetime: () throws -> Void) async throws {
        if let purge = Self.dataPurges[DataPurgeKey(profileID: profileID, runtimeID: runtimeID)] {
            await purge.task.value
        }
        try checkLifetime()
    }

    // Session storage belongs to the old context in memory. WebKit cannot query
    // or delete it after unload; a fresh context receives a fresh session store.
    // Only local/synchronized storage survives a removed Safari installation.
    private static let persistentExtensionDataTypes: Set<WKWebExtension.DataType> = [.local, .synchronized]

    private func purgeData(_ data: WKWebExtension.DataRecord, runtimeID: String) async {
        let key = DataPurgeKey(profileID: profileID, runtimeID: runtimeID)
        let token = UUID(), controller = controller
        let task = Task { @MainActor in
            await controller.removeData(ofTypes: Self.persistentExtensionDataTypes, from: [data])
        }
        Self.dataPurges[key] = DataPurge(token: token, task: task)
        await task.value
        if Self.dataPurges[key]?.token == token { Self.dataPurges[key] = nil }
    }

    private static func verifySnapshot(_ url: URL, source: SafariExtensionSource) async throws {
        try await Task.detached(priority: .utility) {
            let signature = try SafariExtensionSource.verify(url)
            guard signature.identifier == source.extensionBundleID, signature.team == source.teamID,
                  signature.hash == source.signatureHash else {
                throw Failure("The accepted Safari extension’s verified signing identity or resources changed. Choose Update from App to review a fresh copy.")
            }
        }.value
    }

    /// Run the same consent/transaction lifecycle as unpacked code, but preserve the
    /// signed bundle and derive runtime.id solely from its verified identity.
    @discardableResult
    private func loadSafariCandidate(_ candidate: SafariExtensionSource.Candidate, path: String,
                                     installing: Bool, enable: Bool, operationToken: UUID? = nil,
                                     review: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws -> Bool {
        guard !invalidated, profileID != Profile.incognito.id else { throw CancellationError() }
        guard candidate.source.isValid, candidate.source.key == path else { throw Failure("Invalid Safari extension identity.") }
        if let metadataFailure, installing || folders[path] == nil { throw Failure(metadataFailure) }
        try Task.checkCancellation()
        let token: UUID
        if let operationToken {
            guard operations[path] == operationToken else { throw CancellationError() }
            token = operationToken
        } else {
            guard operations[path] == nil else { return false }
            token = UUID()
        }
        let oldRecord = records[path]
        if let saved = oldRecord?.safari, !saved.matches(candidate.source) {
            throw Failure("The app’s verified Safari extension identity changed. The saved installation is retained.")
        }
        guard oldRecord == nil || oldRecord?.safari != nil else { throw Failure("That identity conflicts with a folder installation.") }
        operations[path] = token
        let consentURL = URL(fileURLWithPath: path)
        let previous = ExtensionConsent.saved(for: consentURL, profileID: profileID)
        var stage: ExtensionCodeStore.Stage?
        var accepted = false, replaced = false, approvalChanged = false
        defer {
            if operations[path] == token { operations[path] = nil }
            if !accepted, let stage { codeStore.discard(stage) }
            prunePins(); rebuild()
        }
        func checkLifetime() throws {
            try Task.checkCancellation()
            guard !invalidated, operations[path] == token else { throw CancellationError() }
        }
        do {
            let store = codeStore
            let frozen = try await Task.detached(priority: .utility) { try store.stage(candidate.bundleURL, appExtension: true) }.value
            stage = frozen
            try checkLifetime()
            let bundleURL = frozen.url.appendingPathComponent("extension.appex", isDirectory: true)
            try await Self.verifySnapshot(bundleURL, source: candidate.source)
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            let manifest = try Self.validate(resources)
            try ExtensionDiagnostics.validateResources(manifest, in: resources)
            guard let bundle = Bundle(url: bundleURL) else { throw Failure("The Safari extension bundle is invalid.") }
            let ext = try await WKWebExtension(appExtensionBundle: bundle)
            try checkLifetime()
            let errors = ExtensionDiagnostics.blockingErrors(ext.errors, manifest: manifest)
            guard errors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(errors)) }
            let issues = ExtensionDiagnostics.limitations(manifest, extension: ext)
            let requested = ExtensionAccess(ext)
            let request = ExtensionConsent.Review(name: ext.displayName ?? candidate.source.extensionBundleID,
                requested: requested, previous: previous, installing: installing, limitations: issues,
                newlySupportedCapabilities: installing ? [] : requested.permissions.intersection(Self.integratedCapabilities).subtracting(oldRecord?.integratedCapabilities ?? []),
                updating: !installing, currentVersion: oldRecord?.version, candidateVersion: ext.version)
            if request.needsApproval, !review(request) {
                try checkLifetime()
                if folders[path] != nil { failures[path] = "The app update was not approved. Your accepted code, access, identity, and settings are retained. Choose Update from App when ready to review it." }
                return false
            }
            try checkLifetime()
            // Verify both live signed bundles again after the modal review, before any
            // candidate can run. The immutable private snapshot supplies every web file.
            let current = try await Task.detached(priority: .utility) {
                try SafariExtensionSource.candidates(in: URL(fileURLWithPath: candidate.source.appPath))
                    .first { candidate.source.matches($0.source) }
            }.value
            guard current?.source.signatureHash == candidate.source.signatureHash else {
                throw Failure("The app changed while Vane was reviewing it. Retry to review its current Safari extension.")
            }
            try checkLifetime()
            let identity = oldRecord?.identity ?? contextIdentifiers[path].flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
            let record = ExtensionCodeStore.Record(identity: identity, revision: frozen.revision,
                sourcePath: candidate.source.appPath, name: ext.displayName ?? candidate.source.extensionBundleID,
                version: ext.version ?? "Unknown", summary: ext.displayDescription ?? "", required: requested,
                optional: ExtensionAccess(permissions: Set(ext.optionalPermissions.map(\.rawValue)), sites: Set(ext.optionalPermissionMatchPatterns.map(\.string))),
                compatibility: issues, integratedCapabilities: requested.permissions.intersection(Self.integratedCapabilities), safari: candidate.source)
            if enable {
                try deactivate(path); replaced = true
                let context = makeContext(ext, identity: identity, runtimeID: candidate.source.runtimeID)
                candidates[path] = context
                try await waitForDataPurge(candidate.source.runtimeID, checkLifetime: checkLifetime)
                if oldRecord == nil && folders[path] == nil {
                    let types = Self.persistentExtensionDataTypes
                    let data = await controller.dataRecord(ofTypes: types, for: context)
                    try checkLifetime()
                    if let data {
                        await purgeData(data, runtimeID: candidate.source.runtimeID)
                        try checkLifetime()
                        guard data.errors.isEmpty else { throw Failure("Data from a removed Safari extension could not be cleared. Retry before reinstalling it.\n" + ExtensionDiagnostics.describe(data.errors)) }
                    }
                }
                try checkLifetime()
                try controller.load(context)
                if ext.hasBackgroundContent { try await ExtensionBackgroundStartup.load(context, checkLifetime: checkLifetime) }
                try checkLifetime()
                let errors = ExtensionDiagnostics.blockingErrors(context.errors, manifest: manifest)
                guard errors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(errors)) }
            }
            try checkLifetime()
            try ExtensionConsent.save(requested, for: consentURL, profileID: profileID); approvalChanged = true
            var next = records; next[path] = record
            if metadataFailure != nil { try codeStore.retainUnusableIndex() }
            try codeStore.save(next)
            records = next; metadataFailure = nil
            var identities = contextIdentifiers; identities[path] = identity; contextIdentifiers = identities
            folders[path] = record.name
            if enable { disabled.remove(path) }
            failures[path] = nil; limitations[path] = issues
            saveManagement()
            metadataIcons[path] = ext.icon(for: CGSize(width: 40, height: 40))
            if let context = candidates.removeValue(forKey: path) { loaded.append((path, context)) }
            accepted = true
            if let oldRecord { codeStore.discard(oldRecord) }
            startPolling(); SiteChanges.shared.bump()
            return true
        } catch {
            if !invalidated, operations[path] == token {
                if approvalChanged {
                    if let previous { try? ExtensionConsent.save(previous, for: consentURL, profileID: profileID) }
                    else { ExtensionConsent.remove(for: consentURL, profileID: profileID) }
                }
                if replaced {
                    try? deactivate(path)
                    if let oldRecord, enable {
                        // Updates retain the prior verified snapshot. The installed app
                        // can already have changed, so recovery checks its signed identity
                        // without requiring the old resource digest still be installed.
                        do {
                            let restored = try await Task { @MainActor in
                                try await self.context(for: oldRecord, path: path, recoveringSafariUpdate: true) {
                                    guard !self.invalidated, self.operations[path] == token else { throw CancellationError() }
                                }
                            }.value
                            guard !invalidated, operations[path] == token else { try? controller.unload(restored); throw CancellationError() }
                            loaded.append((path, restored))
                        } catch { failures[path] = "The app update failed and the accepted extension could not restart. Choose Retry. Your settings are retained. " + error.localizedDescription }
                    }
                }
                if folders[path] != nil, failures[path] == nil { failures[path] = error.localizedDescription + "\nChoose Retry or Update from App. Your installation and settings are retained." }
            }
            throw error
        }
    }

    private func makeContext(_ ext: WKWebExtension, identity: String, runtimeID: String? = nil) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = runtimeID ?? identity.lowercased()
        context.baseURL = URL(string: "webkit-extension://\(identity.lowercased())/")!
        context.isInspectable = Settings.inspectorEnabled
        context.inspectionName = ext.displayName
        context.unsupportedAPIs = ExtensionDiagnostics.unsupportedAPIs
        for permission in ext.requestedPermissions where !ExtensionDiagnostics.unsupportedPermissions.contains(permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.requestedPermissionMatchPatterns.union(ext.allRequestedMatchPatterns) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        return context
    }

    private func context(for record: ExtensionCodeStore.Record, path: String, recoveringSafariUpdate: Bool = false, checkLifetime: @escaping @MainActor () throws -> Void) async throws -> WKWebExtensionContext {
        let folder: URL
        let appBundle: Bundle?
        if let safari = record.safari {
            let current = try await safari.resolve()
            guard recoveringSafariUpdate || current.source.signatureHash == safari.signatureHash else { throw Failure("The app was updated. Choose Update from App to review its extension before enabling it.") }
            let bundleURL = codeStore.code(for: record).appendingPathComponent("extension.appex", isDirectory: true)
            try await Self.verifySnapshot(bundleURL, source: safari)
            folder = bundleURL.appendingPathComponent("Contents/Resources")
            guard let bundle = Bundle(url: bundleURL) else { throw Failure("The accepted Safari extension bundle is unavailable.") }
            appBundle = bundle
        } else {
            folder = codeStore.code(for: record)
            appBundle = nil
        }
        let manifest = try Self.validate(folder)
        try ExtensionDiagnostics.validateResources(manifest, in: folder)
        let ext: WKWebExtension
        if let appBundle { ext = try await WKWebExtension(appExtensionBundle: appBundle) }
        else { ext = try await WKWebExtension(resourceBaseURL: folder) }
        let errors = ExtensionDiagnostics.blockingErrors(ext.errors, manifest: manifest)
        guard errors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(errors)) }
        // Record access is checked against the actual code before anything can execute.
        guard ExtensionAccess(ext) == record.required else { throw Failure("The accepted extension files changed. Choose " + (record.safari == nil ? "Update from Folder" : "Update from App") + " to validate and review a fresh copy.") }
        try checkLifetime()
        let context = makeContext(ext, identity: record.identity, runtimeID: record.safari?.runtimeID)
        candidates[path] = context
        do {
            if let safari = record.safari { try await waitForDataPurge(safari.runtimeID, checkLifetime: checkLifetime) }
            try controller.load(context)
            if ext.hasBackgroundContent { try await ExtensionBackgroundStartup.load(context, checkLifetime: checkLifetime) }
            try checkLifetime()
            let errors = ExtensionDiagnostics.blockingErrors(context.errors, manifest: manifest)
            guard errors.isEmpty else { throw Failure(ExtensionDiagnostics.describe(errors)) }
            if candidates[path] === context { candidates[path] = nil }
            return context
        } catch {
            if candidates[path] === context { candidates[path] = nil }
            try? controller.unload(context); closePages(for: context); throw error
        }
    }

    private func restoreAccepted(_ path: String, enabling: Bool,
                                 review ask: @MainActor (ExtensionConsent.Review) -> Bool = ExtensionConsent.ask) async throws {
        guard !invalidated, profileID != Profile.incognito.id, let record = records[path] else { throw CancellationError() }
        if let metadataFailure { throw Failure(metadataFailure) }
        guard operations[path] == nil, !loaded.contains(where: { $0.path == path }) else { return }
        let token = UUID()
        operations[path] = token
        defer { if operations[path] == token { operations[path] = nil }; prunePins(); rebuild() }
        do {
            try Task.checkCancellation()
            if let safari = record.safari {
                let current = try await safari.resolve()
                try Task.checkCancellation()
                guard !invalidated, operations[path] == token else { throw CancellationError() }
                if current.source.signatureHash != safari.signatureHash {
                    _ = try await loadSafariCandidate(current, path: path, installing: false,
                        enable: enabling, operationToken: token, review: ask)
                    return
                }
            }
            let previous = ExtensionConsent.saved(for: URL(fileURLWithPath: path), profileID: profileID)
            let review = ExtensionConsent.Review(name: record.name, requested: record.required, previous: previous, installing: false, limitations: record.compatibility,
                newlySupportedCapabilities: record.required.permissions.intersection(Self.integratedCapabilities).subtracting(record.integratedCapabilities ?? []))
            if review.needsApproval, !ask(review) {
                guard !invalidated, operations[path] == token, !Task.isCancelled else { throw CancellationError() }
                failures[path] = "Access was not approved. Enable the extension when you are ready to review its access."
                return
            }
            guard !invalidated, operations[path] == token else { throw CancellationError() }
            try Task.checkCancellation()
            try ExtensionConsent.save(record.required, for: URL(fileURLWithPath: path), profileID: profileID)
            if enabling {
                let restored = try await context(for: record, path: path) {
                    try Task.checkCancellation()
                    guard !self.invalidated, self.operations[path] == token else { throw CancellationError() }
                }
                guard !invalidated, operations[path] == token, !Task.isCancelled else {
                    try? controller.unload(restored); closePages(for: restored); throw CancellationError()
                }
                // Refresh cached platform limitations on adoption of new Vane support.
                // Persist before exposing the active context; failed writes unload it.
                var revised = record
                revised.integratedCapabilities = record.required.permissions.intersection(Self.integratedCapabilities)
                revised.compatibility = ExtensionDiagnostics.limitations(restored.webExtension.manifest, extension: restored.webExtension)
                var next = records
                next[path] = revised
                do { try codeStore.save(next) }
                catch { try? controller.unload(restored); closePages(for: restored); throw error }
                records = next
                loaded.append((path, restored))
                disabled.remove(path)
            }
            failures[path] = nil
            saveManagement()
            startPolling()
            SiteChanges.shared.bump()
        } catch {
            if operations[path] == token, !invalidated { failures[path] = error.localizedDescription + "\nChoose Retry or " + (record.safari == nil ? "Update from Folder" : "Update from App") + ". Your saved identity and settings are retained." }
            throw error
        }
    }

    // MARK: Manifest validation (pure — this is what `check()` exercises)

    /// The cheap half of what WebKit will do, done synchronously so a wrong folder is
    /// rejected before anything is written down. Returns the parsed manifest.
    static func readManifest(_ folder: URL) throws -> Data {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure("\(folder.lastPathComponent) is not a folder.")
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let descriptor = open(manifestURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Failure("No manifest.json in \(folder.lastPathComponent) — pick the folder that "
                + "contains the manifest, not the one above it.")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let limit = 4 * 1024 * 1024
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else {
            throw Failure("manifest.json must be a regular readable file no larger than 4 MB.")
        }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure("manifest.json exceeds the 4 MB limit.") }
        return data
    }

    static func validate(_ folder: URL, data: Data? = nil) throws -> [String: Any] {
        let data = try data ?? readManifest(folder)
        guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure("manifest.json is not valid JSON.")
        }
        guard let name = manifest["name"] as? String, !name.isEmpty else {
            throw Failure("manifest.json has no \"name\".")
        }
        // WebKit implements MV2 and MV3. Anything else is not going to load.
        let version = (manifest["manifest_version"] as? NSNumber)?.doubleValue ?? 0
        guard version == 2 || version == 3 else {
            throw Failure("manifest_version must be 2 or 3 (found \(manifest["manifest_version"] ?? "nothing")).")
        }
        return manifest
    }

    // MARK: Persistence

    /// Security-scoped bookmarks, isolated by profile.
    static let baseKey = "extensionFolders"
    static let identifiersKey = "extensionIdentifiers"
    static let namesKey = "extensionNames"
    static let disabledKey = "extensionDisabled"
    static let bookmarksKey = "extensionBookmarks"

    /// Per profile, so an extension installed in one profile is not loaded into another.
    static func key(for profileID: UUID) -> String {
        ProfileManager.defaultsKey(baseKey, profileID)
    }

    private var contextIdentifiers: [String: String] {
        get { UserDefaults.vane.dictionary(forKey: ProfileManager.defaultsKey(Self.identifiersKey, profileID)) as? [String: String] ?? [:] }
        set { UserDefaults.vane.set(newValue, forKey: ProfileManager.defaultsKey(Self.identifiersKey, profileID)) }
    }

    private var contextBookmarks: [String: Data] {
        get { UserDefaults.vane.dictionary(forKey: ProfileManager.defaultsKey(Self.bookmarksKey, profileID)) as? [String: Data] ?? [:] }
        set { UserDefaults.vane.set(newValue, forKey: ProfileManager.defaultsKey(Self.bookmarksKey, profileID)) }
    }

    /// A bookmark follows a folder moved in Finder. Carry the installation, including
    /// its disabled state, to that resolved location rather than making a second install.
    private func relocate(_ old: String, to folder: URL, bookmark: Data) throws {
        let path = folder.resolvingSymlinksInPath().path
        guard path != old else { return }
        guard folders[path] == nil, contextIdentifiers[path] == nil else {
            throw Failure("The moved folder conflicts with another saved extension. Remove the obsolete installation in Manage Extensions before retrying.")
        }
        if let consent = ExtensionConsent.saved(for: URL(fileURLWithPath: old), profileID: profileID) {
            try ExtensionConsent.save(consent, for: folder, profileID: profileID)
            ExtensionConsent.remove(for: URL(fileURLWithPath: old), profileID: profileID)
        }
        var identities = contextIdentifiers
        identities[path] = identities.removeValue(forKey: old)
        contextIdentifiers = identities
        folders[path] = folders.removeValue(forKey: old) ?? folder.lastPathComponent
        if disabled.remove(old) != nil { disabled.insert(path) }
        var bookmarks = contextBookmarks
        bookmarks[old] = nil
        bookmarks[path] = bookmark
        contextBookmarks = bookmarks
        setPins(pins.map { $0 == old ? path : $0 })
        saveManagement()
    }

    // MARK: Actions
    //
    // An extension's *action* is its button: the icon, the badge and the enabled flag it
    // sets with `browser.action.*`, all of them per tab. Vane draws it in two places — a
    // row in the Site Control Center, and a glyph in the address pill once pinned — and
    // both go through here so the anchoring, the caching and the private-window rule are
    // decided once.

    /// The extensions a window may show. A private window offers only the ones that have
    /// been let into private browsing: WebKit gates every other extension API on the same
    /// flag, so a button for one of them would be a button that does nothing.
    func visible(private isPrivate: Bool) -> [WKWebExtensionContext] {
        installed.filter { !isPrivate || $0.hasAccessToPrivateData }
    }

    func visible(in tab: Tab?) -> [WKWebExtensionContext] {
        guard let tab else { return [] }
        return visible(private: tab.isPrivate)
    }

    /// The action as *this tab* sees it. With a tab, the default action (`for: nil`) is the
    /// wrong one to draw — the badge a page's content script just set lives on the tab's.
    /// With no tab, the default action is exactly right: it is what an empty pill shows.
    func action(_ context: WKWebExtensionContext, for tab: Tab?) -> WKWebExtension.Action? {
        context.action(for: shim(tab))
    }

    /// The action's icon in a `Look.rowIcon` box, cached. `icon(for:)` re-decodes the
    /// extension's PNG on every call and the pill asks on every redraw; an entry is dropped
    /// the moment WebKit says that action changed, so nothing here can go stale.
    func icon(_ context: WKWebExtensionContext, for tab: Tab?) -> NSImage? {
        let key = ActionKey(context, tab)
        if let hit = icons[key] { return hit }
        let box = CGSize(width: Look.rowIcon, height: Look.rowIcon)
        // WebKit already falls back to the extension's own icon; this is the second fall,
        // for an extension whose icons will not load at all.
        guard let image = action(context, for: tab)?.icon(for: box)
            ?? context.webExtension.icon(for: box) else { return nil }
        icons[key] = image
        return image
    }

    /// Run an action the way a click on its button does — fire its event, or present its
    /// popup hanging off `view`. `performAction` also marks the tab as having had a user
    /// gesture, which is what `activeTab` extensions actually wait for.
    func run(_ context: WKWebExtensionContext, for tab: Tab?, from view: NSView?) {
        guard installed.contains(where: { $0 === context }) else { return }
        let shim = shim(tab)
        // Only an action that *has* a popup will ever ask for its anchor. Recording one for
        // an onClicked-only extension would leave it in the table with nothing to consume
        // it, and the next popup would come up on a button nobody pressed.
        if let view, context.action(for: shim)?.presentsPopup == true {
            anchors[ActionKey(context, tab)] = WeakView(view: view)
        }
        context.performAction(for: shim)
        if let action = context.action(for: shim), action.isEnabled, action.presentsPopup, let web = action.popupWebView {
            userAgent.track(web)
        }
    }

    /// The button each pending popup was run from, keyed by extension *and* tab.
    ///
    /// WebKit calls `presentActionPopup` once the popup has finished loading, not on the
    /// next turn of the loop, so two clicks can be in flight at once — and one shared slot
    /// would open a slow popup on whichever button was pressed last, in whichever window.
    /// Weak, because the row that was clicked can be gone by then, and the fallback below
    /// is what that falls back to.
    private var anchors: [ActionKey: WeakView] = [:]

    /// One extension's action on one tab: what an anchor and a cached icon are both about.
    /// A `nil` tab is the default action, which is what an empty pill draws.
    struct ActionKey: Hashable {
        let context: ObjectIdentifier
        let tab: Tab.ID?
        init(_ context: WKWebExtensionContext, _ tab: Tab?) {
            self.context = ObjectIdentifier(context)
            self.tab = tab?.id
        }
        init(_ context: ObjectIdentifier, _ tab: Tab.ID?) {
            self.context = context
            self.tab = tab
        }
    }

    private struct WeakView { weak var view: NSView? }

    private var icons: [ActionKey: NSImage] = [:]

    private func shim(_ tab: Tab?) -> (any WKWebExtensionTab)? {
        guard let tab, let store = store(holding: tab) else { return nil }
        return adapter(for: tab, in: store)
    }

    /// The Tab behind an action, when WebKit says which one it is about.
    private func subject(of action: WKWebExtension.Action) -> Tab? {
        (action.associatedTab as? ExtTab)?.tab
    }

    /// Everything remembered about one closed tab's buttons, across every extension. `sync`
    /// drops the tab's shim and its state in the same breath; without this the icon cache —
    /// and any anchor left by a popup that never opened — would grow by a row per closed tab
    /// for the life of the process.
    private func forget(tab id: Tab.ID) {
        icons = icons.filter { $0.key.tab != id }
        anchors = anchors.filter { $0.key.tab != id }
    }

    /// Everything remembered about one extension's buttons. `tab` of `.some(id)` forgets one
    /// tab's, `.some(nil)` the default action's, and `nil` the lot — which is what unloading
    /// an extension does.
    private func forget(_ context: WKWebExtensionContext, tab: Tab.ID??) {
        let id = ObjectIdentifier(context)
        guard case .some(let one) = tab else {
            icons = icons.filter { $0.key.context != id }
            anchors = anchors.filter { $0.key.context != id }
            return
        }
        icons[ActionKey(id, one)] = nil
        anchors[ActionKey(id, one)] = nil
    }

    // MARK: Pinned to the pill

    private var pinKey: String { ProfileManager.defaultsKey(ExtensionPins.key, profileID) }

    /// The raw stored list. It can still name an extension that is not here — a folder
    /// deleted or moved between launches — which is why nothing counts or draws from it.
    var pins: [String] { UserDefaults.vane.stringArray(forKey: pinKey) ?? [] }

    /// The pins that have an extension behind them, in order and capped. This is what the
    /// cap is counted against and what the pill draws from: a pin left behind by a folder
    /// that will never load again must not hold one of the three slots for ever.
    var livePins: [String] { ExtensionPins.visible(stored: pins, installed: loaded.map(\.path)) }

    private func setPins(_ paths: [String]) {
        // No explicit bump: writing defaults posts `didChangeNotification`, which is exactly
        // what `SiteChanges` listens to. Bumping as well would redraw every pill twice.
        objectWillChange.send()
        UserDefaults.vane.set(paths, forKey: pinKey)
    }

    /// Once nothing is still loading, the stored list is rewritten to the pins that survived
    /// it, so a dead pin is dropped for good rather than re-examined every launch.
    private func prunePins() {
        guard restoring.isEmpty, operations.isEmpty else { return }
        let recoverable = ExtensionPins.visible(stored: pins, installed: Array(folders.keys))
        if recoverable != pins { setPins(recoverable) }
    }

    /// What the pill draws, in pin order, capped — and in a private window, only what is
    /// allowed there. Takes the window's privacy rather than a tab, because a window with no
    /// tab still draws its pinned glyphs; the pill's chrome does not come and go.
    func pinned(private isPrivate: Bool) -> [WKWebExtensionContext] {
        let allowed = visible(private: isPrivate)
        let live = loaded.filter { pair in allowed.contains { $0 === pair.context } }
        return ExtensionPins.visible(stored: pins, installed: live.map(\.path))
            .compactMap { path in live.first { $0.path == path }?.context }
    }

    func isPinned(_ context: WKWebExtensionContext) -> Bool {
        path(of: context).map(livePins.contains) ?? false
    }

    /// True when the pill has room. False is the cap being reached, which the menu item says
    /// out loud rather than quietly dropping somebody else's pin.
    var canPin: Bool { savedPins.count < ExtensionPins.cap }

    private var savedPins: [String] { ExtensionPins.visible(stored: pins, installed: Array(folders.keys)) }

    func togglePin(_ context: WKWebExtensionContext) {
        guard let path = path(of: context) else { return }
        togglePin(path)
    }

    func togglePin(_ path: String) {
        guard folders[path] != nil, let next = ExtensionPins.toggled(path, in: savedPins) else { return }
        setPins(next)
    }

    func path(of context: WKWebExtensionContext) -> String? {
        loaded.first { $0.context === context }?.path
    }

    // MARK: UI

    func chooseAndInstall(updating path: String? = nil) {
        guard profileID != Profile.incognito.id else { ExtensionManagement.show(for: self); return }
        let generations = installationGenerations()
        let expectedSource = path.flatMap { records[$0]?.safari }
        let operationToken: UUID?
        if let path {
            guard folders[path] != nil, operations[path] == nil else { return }
            operationToken = UUID()
            operations[path] = operationToken
        } else { operationToken = nil }
        var transferred = false
        defer {
            if !transferred, let path, let operationToken, operations[path] == operationToken {
                operations[path] = nil; rebuild()
            }
        }
        let panel = NSOpenPanel()
        panel.title = path == nil ? "Install Extension" : "Update Extension from App"
        panel.message = path == nil ? "Choose an unpacked extension folder containing manifest.json, or an installed app containing Safari web extensions." : "Choose the installed app containing this Safari extension. Its verified identity must match the saved installation."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        transferred = true
        Task {
            defer {
                if let path, let operationToken, operations[path] == operationToken { operations[path] = nil; rebuild() }
            }
            @MainActor func checkLifetime(_ key: String) throws {
                try Task.checkCancellation()
                guard !invalidated, installationGenerations()[key] == generations[key] else { throw CancellationError() }
                if let operationToken, operations[key] != operationToken { throw CancellationError() }
            }
            do {
                if ["app", "appex"].contains(folder.pathExtension.lowercased()) {
                    var candidates = try await Task.detached(priority: .utility) { try SafariExtensionSource.candidates(in: folder) }.value
                    if let path {
                        try checkLifetime(path)
                        candidates = candidates.filter { candidate in
                            candidate.source.key == path && (expectedSource.map { $0.matches(candidate.source) } ?? true)
                        }
                        guard !candidates.isEmpty else { throw Failure("That app does not contain the saved Safari extension with the same verified signing identity.") }
                    }
                    let candidate: SafariExtensionSource.Candidate
                    if candidates.count == 1 { candidate = candidates[0] }
                    else {
                        let alert = NSAlert(); alert.messageText = "Choose a Safari extension"
                        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
                        choice.addItems(withTitles: candidates.map { $0.source.extensionBundleID })
                        alert.accessoryView = choice
                        alert.addButton(withTitle: "Review Extension"); alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        candidate = candidates[choice.indexOfSelectedItem]
                    }
                    let key = candidate.source.key
                    try checkLifetime(key)
                    _ = try await loadSafariCandidate(candidate, path: key, installing: folders[key] == nil,
                        enable: !disabled.contains(key), operationToken: operationToken)
                } else {
                    guard path == nil else { throw Failure("Choose the original signed app to update this Safari extension.") }
                    try await install(folder: folder)
                }
            }
            catch is CancellationError { }
            catch { warn("Could not install that extension.", error.localizedDescription) }
        }
    }

    private func warn(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }

    /// One modal for all three permission prompts. Returns what the user allowed.
    private func ask(_ context: WKWebExtensionContext, _ what: [String]) -> Bool {
        guard !what.isEmpty, !invalidated, installed.contains(where: { $0 === context }) else { return false }
        let a = NSAlert()
        a.messageText = "“\(context.webExtension.displayName ?? "An extension")” wants more access."
        a.informativeText = what.sorted().joined(separator: "\n")
            + "\n\nAllowed access lasts until the extension is reloaded, disabled, or Vane quits. Manage Extensions can revoke additional access."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Deny").keyEquivalent = "\u{1b}"
        let allowed = a.runModal() == .alertFirstButtonReturn
        return allowed && !invalidated && installed.contains(where: { $0 === context })
    }

    // MARK: Adapters
    //
    // WebKit identifies tabs and windows by object identity, so an adapter has to be the
    // same object for as long as the Tab or TabStore it wraps is alive. Hence the tables.

    private var tabShims: [Tab.ID: ExtTab] = [:]
    private var windowShims: [ObjectIdentifier: ExtWindow] = [:]

    func adapter(for store: TabStore) -> ExtWindow {
        let key = ObjectIdentifier(store)
        if let existing = windowShims[key] { return existing }
        let shim = ExtWindow(store)
        windowShims[key] = shim
        return shim
    }

    func adapter(for tab: Tab, in store: TabStore) -> ExtTab {
        if let existing = tabShims[tab.id] {
            existing.rebind(to: store)
            return existing
        }
        let shim = ExtTab(tab, in: store)
        tabShims[tab.id] = shim
        return shim
    }

    /// ponytail: `tabs`, not `everyTab`. WebExtensions are told about the strip and nothing
    /// else — `browser.tabs.query` answers off it, and a Space kept alive behind the one on
    /// screen has no rows to report. Finding nothing for a stashed page is what keeps the
    /// query, the events and this in agreement.
    private func store(holding tab: Tab) -> TabStore? {
        myStores.first { $0.windowID == tab.presentationOwner && $0.tabs.contains { $0 === tab } }
            ?? myStores.first { $0.tabs.contains { $0 === tab } }
    }

    // MARK: Change notification
    //
    // Mutators and native focus callbacks push a profile-scoped diff. WebKit retains
    // adapters by object identity; keep old positions until move/close events are sent.

    private var announcedWindows: Set<ObjectIdentifier> = []
    private var announcedTabs: Set<Tab.ID> = []
    private var focusedWindow: ObjectIdentifier?
    private var activeTabs: [ObjectIdentifier: Tab.ID] = [:]
    private var tabState: [Tab.ID: String] = [:]
    private var tabPositions: [Tab.ID: (window: ObjectIdentifier, index: Int)] = [:]
    private var selectedTabs: [ObjectIdentifier: Set<Tab.ID>] = [:]

    /// Engine.swift pushes sync() on tab open/close/activate and on url/title changes, so
    /// there is nothing left for a timer to notice. Kept as a single call site in case a
    /// future mutator forgets to push.
    private func startPolling() { sync() }

    /// Tell the controller about anything that changed since last time. Safe to call as
    /// often as you like; it does nothing when nothing moved.
    /// Only this profile's windows exist as far as this host is concerned.
    private var myStores: [TabStore] {
        TabStore.all.filter { $0.profileID == profileID && !$0.isParked && $0.window != nil }
    }

    private var myFocusedStore: TabStore? {
        // An extension's idea of "the active tab" is a tab in the browser window; a Little
        // Arc is a page passing through and has no row for an extension to act on.
        myStores.first { !$0.isLittle && $0.window?.isKeyWindow == true }
    }

    func sync() {
        guard !loaded.isEmpty else { return }
        let stores = myStores
        let liveWindows = Set(stores.map(ObjectIdentifier.init))

        let closingWindows = announcedWindows.subtracting(liveWindows)
        // Announce tabs before their window disappears from WebKit's registry. Keep the
        // old adapters until movement/closure has finished so events retain old IDs.
        let liveTabs = Set(stores.flatMap { $0.accessibleTabs.map(\.id) })
        for id in announcedTabs.subtracting(liveTabs) {
            if let shim = tabShims[id] {
                controller.didCloseTab(shim, windowIsClosing: tabPositions[id].map { closingWindows.contains($0.window) } ?? false)
            }
            tabShims[id] = nil
            tabState[id] = nil
            tabPositions[id] = nil
            forget(tab: id)
        }
        announcedTabs.formIntersection(liveTabs)

        for store in stores where !announcedWindows.contains(ObjectIdentifier(store)) {
            announcedWindows.insert(ObjectIdentifier(store))
            controller.didOpenWindow(adapter(for: store))
        }
        // Shared favourite/pinned tabs have one WebKit identity. Report their actual
        // presentation owner once, rather than oscillating between mirrored strips.
        var visited: Set<Tab.ID> = []
        for store in stores {
            for (index, tab) in store.accessibleTabs.enumerated() {
                guard self.store(holding: tab) === store, visited.insert(tab.id).inserted else { continue }
                let shim = adapter(for: tab, in: store)
                let position = (window: ObjectIdentifier(store), index: index)
                if announcedTabs.insert(tab.id).inserted {
                    controller.didOpenTab(shim)
                } else if let previous = tabPositions[tab.id], previous.window != position.window || previous.index != index {
                    controller.didMoveTab(shim, from: previous.index, in: windowShims[previous.window])
                }
                tabPositions[tab.id] = position
                let state = tab.title + "\u{0}" + (tab.currentURL?.absoluteString ?? "")
                    + "\u{0}" + (tab.loading ? "L" : "")
                let previous = tabState.updateValue(state, forKey: tab.id)
                if let previous, previous != state {
                    controller.didChangeTabProperties([.title, .URL, .loading], for: shim)
                }
            }
            let key = ObjectIdentifier(store)
            let current = store.active.flatMap { tab in
                store.accessibleTabs.contains(where: { $0 === tab }) && self.store(holding: tab) === store ? tab : nil
            }
            if activeTabs[key] != current?.id {
                let previous = activeTabs[key].flatMap { tabShims[$0] }
                activeTabs[key] = current?.id
                if let current { controller.didActivateTab(adapter(for: current, in: store), previousActiveTab: previous) }
            }
            var selected = store.selection.ids
            if selected.isEmpty, let current { selected.insert(current.id) }
            selected = selected.intersection(Set(store.accessibleTabs.filter { self.store(holding: $0) === store }.map(\.id)))
            let previous = selectedTabs[key] ?? []
            if previous != selected {
                let deselected = previous.subtracting(selected).compactMap { tabShims[$0] }
                if !deselected.isEmpty { controller.didDeselectTabs(deselected) }
                let added = selected.subtracting(previous).compactMap { tabShims[$0] }
                if !added.isEmpty { controller.didSelectTabs(added) }
                selectedTabs[key] = selected
            }
        }
        for key in closingWindows {
            if let shim = windowShims[key] { controller.didCloseWindow(shim) }
            windowShims[key] = nil
            activeTabs[key] = nil
            selectedTabs[key] = nil
        }
        announcedWindows.formIntersection(liveWindows)

        let current = myFocusedStore
        let focused = current.map(ObjectIdentifier.init)
        if focused != focusedWindow {
            focusedWindow = focused
            controller.didFocusWindow(current.map { adapter(for: $0) })
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        myStores
            .filter { context.hasAccessToPrivateData || !$0.isPrivate }
            .map { adapter(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let store = myFocusedStore,
              context.hasAccessToPrivateData || !store.isPrivate else { return nil }
        return adapter(for: store)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        try requireActive(context)
        if let requested = configuration.window {
            guard let store = (requested as? ExtWindow)?.store,
                  myStores.contains(where: { $0 === store }) else {
                throw Failure("The requested extension window is no longer open.")
            }
        }
        let store = (configuration.window as? ExtWindow)?.store ?? myFocusedStore ?? myStores.last
            ?? Windows.open(profile: ProfileManager.shared.profiles.first { $0.id == profileID })
        let tab = store.newBlankTab()
        if let url = configuration.url { tab.navigate(to: url) }
        if !configuration.shouldBeActive, let first = store.tabs.first { store.current = first.id }
        sync()
        return adapter(for: tab, in: store)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        try requireActive(context)
        let store = Windows.open(isPrivate: configuration.shouldBePrivate,
                                 urls: configuration.tabURLs,
                                 profile: ProfileManager.shared.profiles.first { $0.id == profileID })
        if !configuration.frame.isNull, let window = store.window {
            window.setFrame(flip(configuration.frame, into: window), display: true)
        }
        sync()
        return adapter(for: store)
    }

    /// The options page lives at a `webkit-extension:` URL, and WebKit cancels those in any
    /// web view not built from `context.webViewConfiguration`. A Vane Tab builds its own
    /// configuration, so the page cannot go in a tab — it gets its own window instead.
    /// ponytail: separate window rather than tab-with-swapped-web-view. Upgrade path is the
    /// web-view swap Apple documents, once Tab can be told to adopt a foreign configuration.
    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor context: WKWebExtensionContext) async throws {
        try requireActive(context)
        guard let url = context.optionsPageURL, let cfg = context.webViewConfiguration else { return }
        if let existing = pages.first(where: { $0.context === context && $0.window.isVisible }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        present(url, cfg, context: context, title: context.webExtension.displayName ?? "Extension Options")
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        // Taken first, whatever happens next: an anchor left in the table would come up
        // under the *next* popup, on a button nobody pressed.
        try requireActive(context)
        let anchor = anchors.removeValue(forKey: ActionKey(context, subject(of: action)))?.view
        let name = context.webExtension.displayName ?? "An extension"
        guard let popover = action.popupPopover else {
            throw Failure("“\(name)” has no popup to show.")
        }
        if let web = action.popupWebView { userAgent.track(web) }
        let id = ObjectIdentifier(context)
        popovers[id] = (popovers[id] ?? []).filter(\.isShown) + [popover]
        // The button that ran the action: the pill's pinned glyph, or the extension's row in
        // the Site Control Center. Each window — a Little Vane and a private one included —
        // hands over its own, so a popup never opens over the wrong pill.
        if let anchor, anchor.window != nil {
            return popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        // Nothing was clicked: an extension opened its own popup from a background script.
        // The top of the frontmost window is where a toolbar would be, which is the honest
        // fallback — and a popup with nowhere at all to go is an error, not a silent no-op.
        guard let host = frontmostStore?.window?.contentView else {
            throw Failure("There is no window open to show “\(name)”'s popup in.")
        }
        let rect = NSRect(x: host.bounds.maxX - 40, y: host.bounds.maxY - 8, width: 32, height: 4)
        popover.show(relativeTo: rect, of: host, preferredEdge: .minY)
    }

    /// Any of this profile's windows that is actually key, Little Vane included — unlike
    /// `myFocusedStore`, which is the browser window an extension is allowed to *act* on and
    /// deliberately skips a Little Vane. A popup only needs somewhere to be drawn.
    private var frontmostStore: TabStore? {
        myStores.first { $0.window?.isKeyWindow == true } ?? myFocusedStore ?? myStores.first
    }

    /// Live badges and icons. WebKit says when an extension has changed its action, so the
    /// pill's glyph and the popover's row redraw off that rather than off a timer.
    ///
    /// Two guards, because an extension counting in the background fires this per tab per
    /// tick and every bump rebuilds a `SiteControlModel` for each window's pill and any open
    /// popover: a change to a tab nobody is looking at is dropped outright, and the ones that
    /// survive are coalesced into a single bump per turn of the loop.
    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        guard installed.contains(where: { $0 === context }) else { return }
        let tab = subject(of: action)
        forget(context, tab: .some(tab?.id))
        guard drawn(tab) else { return }
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task { @MainActor in
            bumpScheduled = false
            SiteChanges.shared.bump()
        }
    }

    private var bumpScheduled = false

    /// Whether anybody can see this tab's action. It tests `current` and nothing else because
    /// only the current tab has a pill — a background tab's badge is drawn nowhere — and the
    /// default action (no tab) is what a pill with no tab draws, so that one counts too.
    private func drawn(_ tab: Tab?) -> Bool {
        guard let tab else { return true }
        return myStores.contains { $0.current == tab.id }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let supported = permissions.filter { !ExtensionDiagnostics.unsupportedPermissions.contains($0.rawValue) }
        return ask(context, supported.map(\.rawValue)) ? (supported, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        ask(context, urls.map(\.absoluteString)) ? (urls, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        ask(context, patterns.map(\.string)) ? (patterns, nil) : ([], nil)
    }

    /// WebKit invokes this optional SPI before loading background content, including a
    /// recreated service worker. Public customUserAgent then applies before startup.
    @objc(_webExtensionController:didCreateBackgroundWebView:forExtensionContext:)
    func extensionController(_ controller: WKWebExtensionController, didCreateBackgroundWebView web: WKWebView,
                             for context: WKWebExtensionContext) {
        guard controller === self.controller else { return }
        userAgent.track(web)
        #if DEBUG
        backgroundCreationObserver?(web, context)
        #endif
    }

    // MARK: Helpers

    private var pages: [(context: WKWebExtensionContext, window: NSWindow)] = []
    private var popovers: [ObjectIdentifier: [NSPopover]] = [:]

    private func closePages(for context: WKWebExtensionContext) {
        for popover in popovers.removeValue(forKey: ObjectIdentifier(context)) ?? [] { popover.close() }
        for page in pages where page.context === context {
            (page.window.contentView as? WKWebView)?.stopLoading()
            page.window.contentView = nil
            page.window.close()
        }
        pages.removeAll { $0.context === context }
    }

    private func requireActive(_ context: WKWebExtensionContext) throws {
        guard !invalidated, context.isLoaded,
              installed.contains(where: { $0 === context }) || candidates.values.contains(where: { $0 === context }) else {
            throw Failure("This extension is no longer enabled.")
        }
    }

    func revokeRuntimeAccess(_ context: WKWebExtensionContext) {
        guard installed.contains(where: { $0 === context }) else { return }
        let required = context.webExtension.requestedPermissions
        let patterns = context.webExtension.requestedPermissionMatchPatterns.union(context.webExtension.allRequestedMatchPatterns)
        context.grantedPermissions = context.grantedPermissions.filter { required.contains($0.key) }
        context.grantedPermissionMatchPatterns = context.grantedPermissionMatchPatterns.filter { patterns.contains($0.key) }
        context.deniedPermissions = [:]
        context.deniedPermissionMatchPatterns = [:]
        for tab in tabShims.values { context.clearUserGesture(in: tab) }
        objectWillChange.send()
    }

    /// Export only structured, allowlisted metadata. In-app errors/access can contain
    /// URLs, paths and third-party strings; none of those are copied into this report.
    func diagnostic(for entry: Entry) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func version(_ value: String?) -> String {
            guard let value, value.count <= 64,
                  value.range(of: #"^[0-9]+([._+\-][A-Za-z0-9]+)*$"#, options: .regularExpression) != nil else { return "Unavailable" }
            return value
        }
        var sections = ["Vane extension diagnostics",
            "Vane: " + version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Extension version: " + version(entry.version),
            "Code: " + (entry.managed ? "Managed accepted copy" : "Legacy source folder"),
            "State: " + (entry.busy ? "Checking" : entry.enabled ? "Enabled" : disabled.contains(entry.path) ? "Disabled" : "Inactive"),
            "Needs attention: " + (entry.failure == nil ? "No" : "Yes")]
        if let identity = records[entry.path]?.identity ?? contextIdentifiers[entry.path], let uuid = UUID(uuidString: identity) {
            sections.append("Installation identity: " + uuid.uuidString.lowercased())
        }
        let known: Set<String> = ["activeTab", "alarms", "clipboardWrite", "contextMenus", "menus", "cookies",
            "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback", "nativeMessaging",
            "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]
        if let required = entry.requiredAccess {
            let names = required.permissions.intersection(known).sorted()
            sections.append("Required capabilities: " + (names.isEmpty ? "None recognized" : names.joined(separator: ", ")))
        }
        if let context = entry.context {
            sections.append("Manifest version: " + String(Int(context.webExtension.manifestVersion)))
            let errorCodes = context.errors.map { error in
                let value = error as NSError
                let domain = value.domain == WKWebExtension.errorDomain ? "WebKit extension"
                    : value.domain == WKWebExtensionContext.errorDomain ? "WebKit context"
                    : value.domain == NSCocoaErrorDomain ? "Cocoa" : "Other"
                return domain + ":" + String(value.code)
            }
            if !errorCodes.isEmpty { sections.append("Error codes: " + errorCodes.joined(separator: ", ")) }
        }
        sections.append("Compatibility limitations: " + (entry.compatibility.isEmpty ? "None identified from the manifest" : "Present; inspect in manager"))
        sections.append("Native messaging: unavailable. Chrome Web Store installation and full Chromium compatibility are not provided.")
        sections.append("Source paths, website targets, error messages, credentials, browsing content and extension storage are excluded.")
        return sections.joined(separator: "\n")
    }

    private func present(_ url: URL, _ cfg: WKWebViewConfiguration, context: WKWebExtensionContext, title: String) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 780, height: 620), configuration: cfg)
        userAgent.track(web)
        web.isInspectable = Settings.inspectorEnabled
        let window = NSWindow(contentRect: web.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        pages.removeAll { !$0.window.isVisible }
        pages.append((context, window))
        web.load(URLRequest(url: url))
    }

    /// Extensions speak web coordinates (origin top-left of the main screen); AppKit puts
    /// the origin at the bottom-left.
    private func flip(_ rect: CGRect, into window: NSWindow) -> CGRect {
        guard let screen = window.screen ?? NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    // MARK: Offline check

    /// `check()` — everything here is pure: temp folders on disk and a throwaway defaults
    /// suite. No network, no real extension, no WebKit.
    static func check() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func expect(_ name: String, _ body: () throws -> Bool) {
            results.append((name, (try? body()) ?? false))
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vane-extcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func folder(_ name: String, manifest: String?) -> URL {
            let dir = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let manifest {
                try? Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
            }
            return dir
        }

        func rejects(_ url: URL) -> Bool {
            do { _ = try validate(url); return false } catch { return true }
        }

        let namedProfile = UUID()
        expect("the installed default profile keeps the default extension controller") {
            controllerIdentifier(for: ProfileManager.defaultID, dataDirectory: nil) == nil
        }
        expect("an installed named profile keeps its existing extension controller") {
            controllerIdentifier(for: namedProfile, dataDirectory: nil) == namedProfile
        }
        expect("a data-dir default profile gets an isolated extension controller") {
            controllerIdentifier(for: ProfileManager.defaultID, dataDirectory: "/tmp/vane-ext-a") != nil
        }
        expect("extension controller isolation is stable and directory-scoped") {
            let first = controllerIdentifier(for: ProfileManager.defaultID, dataDirectory: "/tmp/vane-ext-a")
            return first == controllerIdentifier(for: ProfileManager.defaultID, dataDirectory: "/tmp/vane-ext-a")
                && first != controllerIdentifier(for: ProfileManager.defaultID, dataDirectory: "/tmp/vane-ext-b")
        }

        let good = folder("good", manifest:
            #"{"manifest_version":3,"name":"Vane Test","version":"1.0"}"#)
        expect("a valid MV3 folder validates") { try validate(good)["name"] as? String == "Vane Test" }

        let mv2 = folder("mv2", manifest: #"{"manifest_version":2,"name":"Old","version":"1"}"#)
        expect("MV2 is still accepted") { _ = try validate(mv2); return true }

        expect("a folder with no manifest.json is rejected") { rejects(folder("empty", manifest: nil)) }
        expect("malformed JSON is rejected") { rejects(folder("junk", manifest: "{ not json")) }
        expect("a manifest with no name is rejected") {
            rejects(folder("noname", manifest: #"{"manifest_version":3,"version":"1"}"#))
        }
        expect("manifest_version 1 is rejected") {
            rejects(folder("mv1", manifest: #"{"manifest_version":1,"name":"Ancient"}"#))
        }
        expect("a file rather than a folder is rejected") {
            rejects(good.appendingPathComponent("manifest.json"))
        }
        expect("a folder that does not exist is rejected") {
            rejects(root.appendingPathComponent("nope"))
        }

        let suite = "vane-extcheck-\(UUID().uuidString)"
        defer { UserDefaults.dropScratchSuite(suite) }
        expect("a bookmarked folder round-trips through UserDefaults") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            return ScopedPaths.add(good, to: "folders", in: defaults)
                && ScopedPaths.paths("folders", in: defaults).count == 1
        }
        expect("the same folder is not bookmarked twice") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            _ = ScopedPaths.add(good, to: "folders", in: defaults)
            return ScopedPaths.paths("folders", in: defaults).count == 1
        }
        expect("removing a folder by path actually removes it") {
            guard let defaults = UserDefaults(suiteName: suite) else { return false }
            ScopedPaths.remove(path: good.path, from: "folders", in: defaults)
            return ScopedPaths.paths("folders", in: defaults).isEmpty
        }

        // Pure WebKit parsing, no extension and no network — proves the match-pattern type
        // the permission prompts hand around actually behaves.
        expect("<all_urls> matches an https page") {
            let all = try WKWebExtension.MatchPattern(string: "<all_urls>")
            return all.matches(URL(string: "https://example.com/x")!)
        }
        expect("a host pattern does not match another host") {
            let one = try WKWebExtension.MatchPattern(string: "https://example.com/*")
            return !one.matches(URL(string: "https://evil.test/")!)
        }

        return results
    }
}

// MARK: - Pinning an action to the pill

/// Which extensions show their action button in the address pill, and what it may say.
/// Pure: the order, the cap and the badge's truncation are rules rather than state, so
/// `selfcheck --pure` proves them with no extension to load and no window to draw in.
///
/// ponytail: paths, not `WKWebExtensionContext.uniqueIdentifier` — that identifier is a
/// fresh UUID on every load unless the app assigns one, while the folder path is what
/// `ExtensionHost` already writes down and already keeps unique per profile.
enum ExtensionPins {
    /// Three. The pill is a sidebar-width button holding a host, a zoom chip and two hover
    /// glyphs; a fourth extension icon starts eating the address. Asking for a fourth is
    /// refused out loud (the menu item says the bar is full) rather than pushing one out.
    static let cap = 3

    static let key = "pinnedExtensions"

    /// The stored order, minus anything no longer installed, then capped — filtered first,
    /// so an uninstalled extension does not spend one of the three slots.
    static func visible(stored: [String], installed: [String]) -> [String] {
        let live = Set(installed)
        return Array(stored.filter(live.contains).prefix(cap))
    }

    /// Pin at the end, unpin from anywhere. `nil` is the cap: no room, nothing written.
    /// Unpinning is always allowed, cap or no cap.
    static func toggled(_ path: String, in stored: [String]) -> [String]? {
        if stored.contains(path) { return stored.filter { $0 != path } }
        guard stored.count < cap else { return nil }
        return stored + [path]
    }

    /// What a badge reads on a 16pt glyph. An extension can set its badge to anything —
    /// "1", "99+", or a sentence — and four characters is what fits before the icon under
    /// it stops being visible. Empty is no badge, which is what WebKit means by "".
    static func badge(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count <= 4 ? t : String(t.prefix(3)) + "…"
    }

    /// The rules, proved offline.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        let all = ["a", "b", "c", "d"]
        out.append(("the pill holds three pinned extensions", cap == 3))
        out.append(("a pin whose extension is gone takes no slot",
                    visible(stored: ["gone", "a", "b"], installed: all) == ["a", "b"]))
        out.append(("…and the ones that remain keep the order they were pinned in",
                    visible(stored: ["c", "a"], installed: all) == ["c", "a"]))
        out.append(("a fourth pin is not drawn even if one is stored",
                    visible(stored: all, installed: all).count == cap))
        out.append(("nothing pinned draws nothing", visible(stored: [], installed: all).isEmpty))
        out.append(("pinning appends, so the pill does not reshuffle",
                    toggled("c", in: ["a", "b"]) == ["a", "b", "c"]))
        out.append(("unpinning from the middle leaves the others in order",
                    toggled("b", in: ["a", "b", "c"]) == ["a", "c"]))
        out.append(("a fourth pin is refused rather than pushing one out",
                    toggled("d", in: ["a", "b", "c"]) == nil))
        // What the cap is counted against. A folder deleted between launches leaves its pin
        // in the stored list for ever, and counting *that* would cost a slot nothing fills.
        let surviving = visible(stored: ["gone", "a", "b"], installed: all)
        out.append(("a pin left by a deleted extension does not spend one of the three",
                    surviving.count == 2))
        out.append(("…so there is still room to pin another",
                    toggled("c", in: surviving) == ["a", "b", "c"]))
        out.append(("…and the dead pin is gone from what gets written back",
                    !(toggled("c", in: surviving) ?? []).contains("gone")))
        out.append(("three dead pins leave the bar completely empty",
                    visible(stored: ["x", "y", "z"], installed: all).isEmpty))
        out.append(("…and unpinning still works at the cap",
                    toggled("a", in: ["a", "b", "c"]) == ["b", "c"]))
        out.append(("an empty badge is no badge", badge("") == nil))
        out.append(("…and so is a badge of spaces", badge("  ") == nil))
        out.append(("a count is shown as it is", badge("7") == "7"))
        out.append(("99+ fits", badge("99+") == "99+"))
        out.append(("four characters still fit", badge("1234") == "1234"))
        out.append(("a longer badge is truncated rather than overflowing the glyph",
                    badge("12345") == "123…"))
        out.append(("…and a sentence never grows past four characters",
                    badge("blocked 12 trackers")?.count == 4))
        out.append(("surrounding whitespace is not mistaken for a character",
                    badge(" 3 ") == "3"))
        return out
    }
}

/// An extension action's button face: its icon at `Look.rowIcon` with its badge on it. One
/// view, because the Site Control Center's row and the pill's pinned glyph draw the same
/// button — and because the badge belongs *on* the icon, not beside it.
struct ActionIcon: View {
    /// Passed rather than taken off the tab, because a pill with no tab still draws its
    /// pinned glyphs and the profile's host is the only thing that knows about them.
    let host: ExtensionHost
    let context: WKWebExtensionContext
    let tab: Tab?
    /// Already truncated by `ExtensionPins.badge`. Nil is no badge.
    let badge: String?

    var body: some View {
        glyph(host.icon(context, for: tab))
            .frame(width: Look.rowIcon, height: Look.rowIcon)
            .overlay(alignment: .topTrailing) { mark }
    }

    @ViewBuilder private func glyph(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "puzzlepiece.extension").resizable().aspectRatio(contentMode: .fit)
        }
    }

    @ViewBuilder private var mark: some View {
        if let badge {
            Text(badge)
                .font(Look.badgeText).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1)
                // Four characters of "99+"-sized type is wider than the 16pt icon under it,
                // and a capsule that keeps growing reaches the glyph beside it. The width is
                // capped and the type shrinks inside it instead. The ellipsis
                // `ExtensionPins.badge` appends is a neutral character, so bidi puts it at
                // the trailing end in an RTL layout, which is where it belongs.
                .minimumScaleFactor(Look.badgeShrink)
                .padding(.horizontal, Look.badgeInset)
                .frame(minWidth: Look.badgeHeight, maxWidth: Look.badgeWidth,
                       minHeight: Look.badgeHeight)
                .background(Color.accentColor, in: .capsule)
                .offset(x: Look.badgeOffset, y: -Look.badgeOffset)
        }
    }
}

/// The AppKit view an action popup hangs off, handed to `ExtensionHost` without SwiftUI
/// having to own it — the trick `HoldMenu` plays for the back/forward menu.
@MainActor final class ActionAnchor: ObservableObject {
    private(set) weak var view: NSView?
    fileprivate func adopt(_ view: NSView) { self.view = view }
}

private struct ActionAnchorView: NSViewRepresentable {
    let holder: ActionAnchor
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        holder.adopt(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Nothing but a rectangle for a popover to point at. It must be invisible to the mouse:
/// sitting in a SwiftUI `background` it is a real AppKit view, and a plain `NSView` hit-tests
/// to itself — which swallows the button's own mouseDown and lets whatever tap gesture is
/// wrapped around the button fire instead. Measured: with this returning `self`, clicking a
/// pinned glyph opened the pill's search bar rather than the extension.
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Marks this view as the thing an extension popup should point at.
    @MainActor func actionAnchor(_ holder: ActionAnchor) -> some View {
        background { ActionAnchorView(holder: holder) }
    }
}

// MARK: - Tab / window adapters
//
// Tab and TabStore cannot conform to the WebKit protocols directly (they are not mine to
// edit), so these wrap them. Both hold their subject weakly: the tables in ExtensionHost
// own the adapters, and a dead subject just makes every accessor return its default.

/// A Vane `Tab`, as an extension sees it.
@MainActor final class ExtTab: NSObject, WKWebExtensionTab {
    private(set) weak var tab: Tab?
    private weak var originalStore: TabStore?
    var store: TabStore? {
        guard let tab else { return nil }
        if originalStore?.sharesTabs == false { return originalStore }
        let holders = TabStore.all.filter {
            $0.sharesTabs && $0.profileID == tab.profileID && $0.tabs.contains { $0 === tab }
        }
        return holders.first { $0.windowID == tab.presentationOwner } ?? holders.first
    }

    init(_ tab: Tab, in store: TabStore) {
        self.tab = tab
        self.originalStore = store
    }

    fileprivate func rebind(to store: TabStore) {
        guard let tab, store.profileID == tab.profileID, store.tabs.contains(where: { $0 === tab }) else { return }
        originalStore = store
    }

    private var accessible: Bool {
        guard let tab, let store, store.profileID == tab.profileID,
              store.window != nil, !store.isParked, TabStore.all.contains(where: { $0 === store }),
              store.tabs.contains(where: { $0 === tab }) else { return false }
        return !store.isTabLocked(tab.id)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard accessible else { return nil }
        return store.map { ExtensionHost.host(for: $0.profileID).adapter(for: $0) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard accessible, let tab, let i = store?.accessibleTabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return i
    }

    // Everything WebKit can read straight off the web view (zoom, loading, snapshots,
    // back/forward, reload) is deliberately left unimplemented — the protocol's documented
    // defaults already do it against `webView(for:)`.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { accessible ? tab?.existingWeb : nil }

    func url(for context: WKWebExtensionContext) -> URL? { accessible ? tab?.currentURL : nil }

    func loadURL(_ url: URL, for context: WKWebExtensionContext,
                 completionHandler: @escaping (Error?) -> Void) {
        guard accessible, let tab else {
            completionHandler(ExtensionHost.Failure("This tab is locked or closed."))
            return
        }
        tab.navigate(to: url)
        completionHandler(nil)
    }

    func title(for context: WKWebExtensionContext) -> String? { accessible ? tab?.title : nil }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { accessible && !(tab?.loading ?? false) }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard accessible, let tab, let store else { return false }
        return store.selection.isEmpty ? store.current == tab.id : store.selection.contains(tab.id)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { accessible && (tab?.isPrivate ?? false) }

    /// activeTab is the permission almost every extension actually relies on.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { accessible }

    func activate(for context: WKWebExtensionContext) async throws {
        guard accessible else { throw ExtensionHost.Failure("This tab is locked or closed.") }
        guard let tab, let store else { return }
        store.current = tab.id
        store.window?.makeKeyAndOrderFront(nil)
        ExtensionHost.host(for: store.profileID).sync()
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        guard accessible, let tab, let store else { throw ExtensionHost.Failure("This tab is locked or closed.") }
        let alreadySelected = isSelected(for: context)
        guard selected != alreadySelected else { return }
        guard store.section(of: tab.id).ids.contains(tab.id) else {
            throw ExtensionHost.Failure("This tab has no visible sidebar row. Expand its folder or Pinned section, select its Split View’s leading tab, or activate it instead.")
        }
        if !selected, store.current == tab.id, store.selection.ids.count <= 1 {
            throw ExtensionHost.Failure("The active tab must stay selected. Select another tab before deselecting it.")
        }
        store.toggleSelection(tab.id)
        ExtensionHost.host(for: store.profileID).sync()
    }

    /// `chrome.tabs.remove`. It is `TabStore.close`, so an extension gets exactly what the
    /// row's × and ⌘W get and no more: a Today tab goes, a favourite is parked in place, and
    /// a pinned tab takes the first of `TabRowGlyph`'s two steps — its page is unloaded, and
    /// only a call against a pinned tab with nothing left to unload takes the pin off. An
    /// extension cannot delete a pinned tab, any more than the user can by accident.
    ///
    /// Ceiling, stated plainly: an extension calling `remove` twice therefore unpins rather
    /// than closing, and gets no error saying so. That is the price of the two-step being one
    /// rule for every route, and it is the right side of the trade — the alternative is an
    /// extension being the one thing in the browser that can drop a row the user arranged.
    func close(for context: WKWebExtensionContext) async throws {
        guard accessible else { throw ExtensionHost.Failure("This tab is locked or closed.") }
        guard let tab, let store else { return }
        store.close(tab.id)
        ExtensionHost.host(for: store.profileID).sync()
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration,
                   for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard accessible else { throw ExtensionHost.Failure("This tab is locked or closed.") }
        guard let store, let url = tab?.currentURL else { return nil }
        let copy = store.newBlankTab()
        copy.navigate(to: url)
        let host = ExtensionHost.host(for: store.profileID)
        host.sync()
        return host.adapter(for: copy, in: store)
    }
}

/// A Vane window (`TabStore` + its `NSWindow`), as an extension sees it.
@MainActor final class ExtWindow: NSObject, WKWebExtensionWindow {
    private(set) weak var store: TabStore?

    init(_ store: TabStore) { self.store = store }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store else { return [] }
        let host = ExtensionHost.host(for: store.profileID)
        return store.accessibleTabs.map { host.adapter(for: $0, in: store) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store, let tab = store.active else { return nil }
        return ExtensionHost.host(for: store.profileID).adapter(for: tab, in: store)
    }

    // Vane never opens popup windows, so every window is a normal one.
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { store?.isPrivate ?? false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = store?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState,
                        for context: WKWebExtensionContext) async throws {
        guard let window = store?.window else { return }
        let full = window.styleMask.contains(.fullScreen)
        switch state {
        case .minimized:  window.miniaturize(nil)
        case .maximized:  if window.isMiniaturized { window.deminiaturize(nil) }
                          if !window.isZoomed { window.zoom(nil) }
        case .fullscreen: if !full { window.toggleFullScreen(nil) }
        default:          if full { window.toggleFullScreen(nil) }
                          if window.isMiniaturized { window.deminiaturize(nil) }
        }
    }

    // frame/screenFrame are both prerequisites for setFrame on macOS, hence all three.
    func frame(for context: WKWebExtensionContext) -> CGRect { store?.window?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        store?.window?.screen?.frame ?? NSScreen.screens.first?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        store?.window?.setFrame(frame, display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        store?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.map { ExtensionHost.host(for: $0.profileID).sync() }
    }

    func close(for context: WKWebExtensionContext) async throws {
        store?.window?.performClose(nil)
        store.map { ExtensionHost.host(for: $0.profileID).sync() }
    }
}
