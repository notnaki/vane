import Foundation
import CryptoKit
import WebKit

/// Static uBlock list compatibility, owned by one accepted installation. The
/// built-in blocker remains independent; these lists never attach to private pages.
@MainActor final class ExtensionFilterBridge: NSObject {
    private static let active = NSHashTable<ExtensionFilterBridge>.weakObjects()
    private static let controllers = NSMapTable<WKUserContentController, Attachment>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private final class Attachment {
        let profileID: UUID
        let lists: [WKContentRuleList]
        init(_ profileID: UUID, _ lists: [WKContentRuleList]) { self.profileID = profileID; self.lists = lists }
    }

    static func recognizes(_ ext: WKWebExtension) -> Bool {
        ext.manifestVersion == 2 && ext.displayName == "uBlock Origin"
            && ext.requestedPermissions.contains(WKWebExtension.Permission(rawValue: "webRequest"))
    }

    static func apply(to controller: WKUserContentController, profileID: UUID) {
        if let previous = controllers.object(forKey: controller) { previous.lists.forEach(controller.remove) }
        let lists = profileID == Profile.incognito.id ? [] : active.allObjects.filter { $0.profileID == profileID && $0.canApply }.flatMap(\.lists)
        if profileID != Profile.incognito.id {
            for bridge in active.allObjects where bridge.profileID == profileID && !bridge.invalidated {
                if let context = bridge.context, context.isLoaded {
                    ExtensionMV2Compatibility.configureContentWorld(controller, context: context)
                }
            }
        }
        lists.forEach(controller.add)
        controllers.setObject(Attachment(profileID, lists), forKey: controller)
    }

    private static func refreshControllers(profileID: UUID) {
        for controller in controllers.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            if controllers.object(forKey: controller)?.profileID == profileID { apply(to: controller, profileID: profileID) }
        }
    }

    let profileID: UUID
    private weak var context: WKWebExtensionContext?
    private weak var background: WKWebView?
    private let changed: () -> Void
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var invalidated = false
    private var digest = ""
    private var lists: [WKContentRuleList] = []
    private var ruleStore: WKContentRuleListStore?
    private let cachePrefix: String
    private(set) var status = "Static filter compatibility is preparing."

    init(profileID: UUID, context: WKWebExtensionContext, background: WKWebView?, changed: @escaping () -> Void) {
        self.profileID = profileID; self.context = context; self.background = background; self.changed = changed
        cachePrefix = "vane-mv2-" + profileID.uuidString.lowercased() + "-"
            + SHA256.hash(data: Data(context.uniqueIdentifier.utf8)).map { String(format: "%02x", $0) }.joined() + "-"
        super.init()
        Self.active.add(self)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        schedule()
    }

    private var canApply: Bool {
        guard !invalidated, profileID != Profile.incognito.id, let context, context.isLoaded,
              context.hasAccessToAllHosts,
              context.hasPermission(WKWebExtension.Permission(rawValue: "storage")),
              context.hasPermission(WKWebExtension.Permission(rawValue: "webRequest")) else { return false }
        let patterns = Set(context.grantedPermissionMatchPatterns.filter { $0.value > Date() }.keys.map(\.string))
        guard patterns.contains("<all_urls>") || patterns.contains("*://*/*")
            || patterns.isSuperset(of: ["http://*/*", "https://*/*"]) else { return false }
        // A global compiled list cannot reproduce arbitrary per-site runtime grants.
        return !context.deniedPermissionMatchPatterns.values.contains { $0 > Date() }
    }

    func permissionsChanged() {
        if !canApply {
            task?.cancel()
            clear(); setStatus("Static filter compatibility is paused until all website access is allowed.")
        }
        schedule()
    }

    func backgroundChanged(_ web: WKWebView) {
        background = web
        task?.cancel()
        digest = ""
        schedule()
    }

    func invalidate() {
        invalidated = true
        timer?.invalidate(); timer = nil
        task?.cancel()
        clear()
        Self.active.remove(self)
    }

    private func schedule() {
        guard !invalidated, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            await refresh()
        }
    }

    private func setStatus(_ message: String) {
        guard status != message else { return }
        status = message; changed()
    }

    private func clear() {
        let previous = lists
        lists = []; digest = ""
        Self.refreshControllers(profileID: profileID)
        if let ruleStore { Task { for list in previous { try? await ruleStore.removeContentRuleList(forIdentifier: list.identifier) } } }
    }

    private func readSnapshot(lastDigest: String? = nil) async throws -> ExtensionFilterSnapshot.Value {
        guard let background else { throw ExtensionFilterRules.Failure("This WebKit version did not expose the MV2 background page.") }
        var reply: String?
        try await ExtensionBackgroundStartup.wait(timeout: .seconds(15), start: { completion in
            background.callAsyncJavaScript(ExtensionFilterSnapshot.script, arguments: ["lastDigest": lastDigest ?? digest], in: nil, in: .page) { result in
                switch result {
                case .success(let value): reply = value as? String; completion(nil)
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    if let message { completion(ExtensionFilterRules.Failure(message)) }
                    else { completion(error) }
                }
            }
        }, check: { [weak self] in
            guard self?.canApply == true, !Task.isCancelled else { throw CancellationError() }
        })
        guard let reply, reply.utf8.count <= 40 * 1024 * 1024 else { throw ExtensionFilterRules.Failure("The extension returned an oversized or unreadable filter snapshot.") }
        return try JSONDecoder().decode(ExtensionFilterSnapshot.Value.self, from: Data(reply.utf8))
    }

    private func refresh() async {
        guard canApply else {
            clear(); setStatus("Static filter compatibility is paused until all website access is allowed."); return
        }
        var created: [WKContentRuleList] = []
        do {
            let snapshot = try await readSnapshot()
            guard canApply, !Task.isCancelled else { throw CancellationError() }
            if snapshot.unchanged { return }
            let compilation = try await Task.detached(priority: .utility) {
                try ExtensionFilterRules.compile(texts: snapshot.texts, trustedSites: snapshot.trustedSites)
            }.value
            guard canApply, !Task.isCancelled else { throw CancellationError() }
            if ruleStore == nil {
                let directory = Store.directory.appendingPathComponent("ExtensionFilterRules", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                ruleStore = WKContentRuleListStore(url: directory)
            }
            guard let ruleStore else { throw ExtensionFilterRules.Failure("The compiled filter store is unavailable.") }
            for chunk in compilation.chunks {
                guard canApply, !Task.isCancelled else { throw CancellationError() }
                let identifier = cachePrefix + SHA256.hash(data: Data(chunk.utf8)).map { String(format: "%02x", $0) }.joined()
                let cached = try? await ruleStore.contentRuleList(forIdentifier: identifier)
                let compiled: WKContentRuleList?
                if let cached { compiled = cached }
                else { compiled = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: chunk) }
                guard let list = compiled else {
                    throw ExtensionFilterRules.Failure("WebKit could not compile the static filter rules.")
                }
                created.append(list)
            }
            // Compilation can take long enough for the popup power button, list
            // selection or user filters to change. Never publish that stale policy.
            let current = try await readSnapshot(lastDigest: snapshot.digest)
            guard current.unchanged else { throw ExtensionFilterRules.Failure("Filter settings changed during compilation; checking them again.") }
            guard canApply, !Task.isCancelled else { throw CancellationError() }
            lists = created; created = []; digest = snapshot.digest
            Self.refreshControllers(profileID: profileID)
            let reasons = compilation.report.reasonCounts.keys.sorted().map { "\($0): \(compilation.report.reasonCounts[$0]!)" }.joined(separator: "; ")
            setStatus("Static filters active · " + compilation.report.summary + (reasons.isEmpty ? "" : ". " + reasons)
                + ". Settings refresh after compilation; reload changed pages. Document blocking, cosmetics, dynamic request decisions, redirects and header changes remain with uBlock or unavailable.")
            let currentIDs = Set(lists.map(\.identifier))
            for stale in await ruleStore.availableIdentifiers() ?? [] where stale.hasPrefix(cachePrefix) && !currentIDs.contains(stale) {
                guard !invalidated, !Task.isCancelled else { break }
                try? await ruleStore.removeContentRuleList(forIdentifier: stale)
            }
        } catch {
            if let ruleStore { for list in created { try? await ruleStore.removeContentRuleList(forIdentifier: list.identifier) } }
            guard !invalidated else { return }
            // Never keep an old policy after the user's selection or trust changed.
            clear()
            setStatus("Static filter compatibility is unavailable. " + error.localizedDescription)
        }
    }
}
