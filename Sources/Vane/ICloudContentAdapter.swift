import Foundation
import Darwin

/// Saved content crosses iCloud as individual entities and immutable digest-addressed
/// bytes. None of the payloads contain local paths, grants, or execution permission.
@MainActor final class ICloudContentAdapter: ICloudAdapter {
    let categories: Set<ICloudCategory> = [.easels, .readingQueue, .offlineArticles, .boosts, .contentBlocking]
    private let directory: URL
    private let defaults: UserDefaults
    private let profileIDs: () -> [UUID]
    private let ensureProfile: (UUID) throws -> Void
    private let easelStore: (UUID) -> EaselStore
    private let readingStore: (UUID) throws -> ReadingQueueStore
    private let boosts: SiteBoostStore
    private let subscriptions: FilterSubscriptions
    private let blockerChanged: () -> Void
    private let boostChanged: (String, UUID) -> Void

    convenience init(manager: ProfileManager = .shared, defaults: UserDefaults = .vane) {
        self.init(directory: manager.directory, defaults: defaults,
            profileIDs: { manager.profiles.map(\.id) },
            easelStore: { EaselStore.shared(profileID: $0, directory: manager.directory) },
            readingStore: { try ReadingQueueStore.shared(profileID: $0, directory: manager.directory) },
            boosts: SiteBoosts.synchronizationStore, subscriptions: .shared,
            ensureProfile: { try manager.ensureICloudProfile($0) }, blockerChanged: { Blocker.refresh() },
            boostChanged: { origin, profile in
                SiteBoosts.set(SiteBoosts.records(profile: profile)[origin] ?? SiteBoost(), origin: origin, profile: profile)
            })
    }

    init(directory: URL, defaults: UserDefaults, profileIDs: @escaping () -> [UUID],
         easelStore: @escaping (UUID) -> EaselStore,
         readingStore: @escaping (UUID) throws -> ReadingQueueStore,
         boosts: SiteBoostStore, subscriptions: FilterSubscriptions,
         ensureProfile: @escaping (UUID) throws -> Void = { _ in },
         blockerChanged: @escaping () -> Void = {}, boostChanged: @escaping (String, UUID) -> Void = { _, _ in }) {
        self.directory = directory; self.defaults = defaults; self.profileIDs = profileIDs
        self.easelStore = easelStore; self.readingStore = readingStore; self.boosts = boosts
        self.subscriptions = subscriptions; self.ensureProfile = ensureProfile; self.blockerChanged = blockerChanged
        self.boostChanged = boostChanged
    }

    private struct Board: Codable, Sendable {
        var version: Int; var title: String; var modified: Date
        var itemsDigest: String; var imageDigests: [String: String]
    }
    private struct Metadata: Codable, Sendable {
        var title: String; var sourceURL: String; var capturedAt: Date; var isRead: Bool; var byline: String
        init(_ article: ReadingArticle) {
            title = article.title; sourceURL = article.sourceURL; capturedAt = article.capturedAt
            isRead = article.isRead; byline = article.byline
        }
        func update(_ article: inout ReadingArticle) {
            article.title = title; article.sourceURL = sourceURL; article.capturedAt = capturedAt
            article.isRead = isRead; article.byline = byline; article.hasQueueMetadata = true
        }
    }
    private struct Offline: Codable, Sendable {
        var nodesDigest: String; var resources: [ReadingArticle.Resource]; var missingImages: Int
    }
    private struct Boost: Codable, Sendable {
        var origin: String; var enabled: Bool; var font: String; var textScale: Double
        var background: String; var textColor: String; var linkColor: String; var hidden: [String]
        var cssDigest: String; var scriptDigest: String
    }
    private struct Blocking: Codable, Sendable { var enabled: Bool }
    private struct SiteException: Codable, Sendable { var host: String }
    private struct Filter: Codable, Sendable { var title: String; var textDigest: String }
    private struct Subscription: Codable, Sendable { var url: URL; var textDigest: String }

    private nonisolated static func entityID(_ profile: UUID, _ id: UUID) -> String {
        profile.uuidString.lowercased() + "/" + id.uuidString.lowercased()
    }
    private nonisolated static func addAsset(_ bytes: Data, to fields: inout [String: Data]) throws -> String {
        guard bytes.count <= ICloudLimits.assetBytes else { throw ICloudFailure.limitExceeded }
        let digest = ReadingArticleCodec.digest(bytes)
        fields["asset." + digest] = bytes
        return digest
    }
    private nonisolated static func asset(_ digest: String, from item: ICloudItem) throws -> Data {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let bytes = item.fields["asset." + digest], bytes.count <= ICloudLimits.assetBytes,
              ReadingArticleCodec.digest(bytes) == digest else {
            throw ICloudFailure.invalid("A synced saved-content asset is missing or damaged. The local copy was kept.")
        }
        return bytes
    }
    private nonisolated static func assetJSON<T: Decodable>(_ type: T.Type, digest: String, item: ICloudItem, limit: Int) throws -> T {
        let bytes = try asset(digest, from: item)
        guard bytes.count <= limit else { throw ICloudFailure.limitExceeded }
        var depth = 0, quoted = false, escaped = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 140 { throw ICloudFailure.limitExceeded } }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        return try JSONDecoder().decode(type, from: bytes)
    }
    private nonisolated static func decoded<T: Decodable>(_ type: T.Type, item: ICloudItem) throws -> T {
        var metadata = item
        metadata.fields = item.fields.filter { !$0.key.hasPrefix("asset.") }
        return try metadata.decode(type)
    }
    private nonisolated static func item<T: Encodable>(_ payload: T, category: ICloudCategory, id: String,
                                                       profile: UUID? = nil, assets: [String: Data] = [:]) throws -> ICloudItem {
        var fields = try ICloudItem.encodedFields(payload)
        fields.merge(assets) { _, new in new }
        return ICloudItem(category: category, id: id, profileID: profile,
            parentID: profile?.uuidString.lowercased(), fields: fields)
    }
    private nonisolated static func boardItem(_ board: EaselBoard, profile: UUID) throws -> ICloudItem {
        try EaselStore.validate(board)
        var fields: [String: Data] = [:], images: [String: String] = [:]
        var objects = board.items
        for index in objects.indices {
            if let bytes = objects[index].image {
                images[objects[index].id.uuidString.lowercased()] = try addAsset(bytes, to: &fields)
                objects[index].image = nil
            }
        }
        let digest = try addAsset(JSONEncoder().encode(objects), to: &fields)
        return try item(Board(version: board.version, title: board.title, modified: board.modified,
            itemsDigest: digest, imageDigests: images), category: .easels,
            id: entityID(profile, board.id), profile: profile, assets: fields)
    }
    private nonisolated static func offlineItem(_ candidate: ReadingQueueCandidate) throws -> ICloudItem {
        try ReadingArticleCodec.validate(candidate)
        var fields: [String: Data] = [:]
        let digest = try addAsset(JSONEncoder().encode(candidate.article.nodes), to: &fields)
        for resource in candidate.article.resources {
            guard let bytes = candidate.images[resource.name] else { throw ReadingQueueFailure.missing }
            _ = try addAsset(bytes, to: &fields)
        }
        return try item(Offline(nodesDigest: digest, resources: candidate.article.resources,
            missingImages: candidate.article.missingImages), category: .offlineArticles,
            id: entityID(candidate.article.profileID, candidate.article.id), profile: candidate.article.profileID, assets: fields)
    }

    private nonisolated static func boostItem(_ value: SiteBoost, origin: String, profile: UUID) throws -> ICloudItem {
        var assets: [String: Data] = [:]
        let css = try addAsset(Data(value.css.utf8), to: &assets)
        let script = try addAsset(Data(value.script.utf8), to: &assets)
        let portable = Boost(origin: origin, enabled: value.enabled, font: value.font, textScale: value.textScale,
            background: value.background, textColor: value.textColor, linkColor: value.linkColor,
            hidden: value.hidden, cssDigest: css, scriptDigest: script)
        return try item(portable, category: .boosts, id: profile.uuidString.lowercased() + "/" + ICloudIdentity.digest(origin), profile: profile, assets: assets)
    }
    private nonisolated static func subscriptionItem(_ subscription: FilterSubscription) throws -> ICloudItem {
        var assets: [String: Data] = [:]
        let digest = try addAsset(Data(subscription.text.utf8), to: &assets)
        return try item(Subscription(url: subscription.url, textDigest: digest), category: .contentBlocking,
            id: "subscription/" + subscription.id.uuidString.lowercased(), assets: assets)
    }

    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        let enabled = enabled.intersection(categories)
        guard !enabled.isEmpty else { return [] }
        var result: [ICloudItem] = [], bytes = 0
        func append(_ items: [ICloudItem]) throws { try Self.append(items, to: &result, bytes: &bytes) }
        let profiles = Set(profileIDs().filter { $0 != Profile.incognito.id })
        if enabled.contains(.boosts), !(await boosts.flush()) { throw ICloudFailure.storage("Boosts could not be saved before iCloud capture.") }
        for profile in profiles.sorted(by: { $0.uuidString < $1.uuidString }) {
            if enabled.contains(.easels) {
                let store = easelStore(profile); try await store.flush()
                let boards = store.boards
                try append(try await Task.detached(priority: .utility) { try boards.map { try Self.boardItem($0, profile: profile) } }.value)
            }
            if !enabled.isDisjoint(with: [.readingQueue, .offlineArticles]) {
                let candidates = try await readingStore(profile).iCloudSnapshot(includeOffline: enabled.contains(.offlineArticles))
                try append(try await Task.detached(priority: .utility) {
                    var items: [ICloudItem] = []
                    for candidate in candidates {
                        let article = candidate.article
                        if enabled.contains(.readingQueue), article.hasQueueMetadata != false {
                            items.append(try Self.item(Metadata(article), category: .readingQueue,
                                id: Self.entityID(profile, article.id), profile: profile))
                        }
                        if enabled.contains(.offlineArticles), article.hasOfflineContent != false {
                            items.append(try Self.offlineItem(candidate))
                        }
                    }
                    return items
                }.value)
            }
            if enabled.contains(.boosts) {
                // Inspect persisted bytes too: the UI's tolerant read must not turn a
                // damaged table into a successful empty authoritative sync snapshot.
                if let data = defaults.data(forKey: SiteBoostStore.key(profile)) {
                    let table = try JSONDecoder().decode([String: SiteBoost].self, from: data)
                    guard table.allSatisfy({ origin, boost in
                        URL(string: origin).flatMap(SiteBoosts.origin) == origin && boost == boost.sanitized
                    }) else { throw ICloudFailure.invalid("A saved Boost needs recovery before syncing.") }
                }
                let records = boosts.records(profile: profile)
                try append(try await Task.detached(priority: .utility) {
                    try records.map { try Self.boostItem($0.value, origin: $0.key, profile: profile) }
                }.value)
            }
            if enabled.contains(.contentBlocking) {
                let blocking = Blocking(enabled: defaults.object(forKey: ProfileManager.defaultsKey("blockerEnabled", profile)) as? Bool ?? true)
                try append([try Self.item(blocking, category: .contentBlocking, id: "settings/" + profile.uuidString.lowercased(), profile: profile)])
                for host in Set(try stringList(ProfileManager.defaultsKey("blockerSiteExceptions", profile))).sorted() {
                    guard Self.validHost(host) else { throw ICloudFailure.invalid("A blocker site exception needs recovery.") }
                    try append([try Self.item(SiteException(host: host), category: .contentBlocking,
                        id: "exception/" + profile.uuidString.lowercased() + "/" + ICloudIdentity.digest(host), profile: profile)])
                }
            }
        }
        if enabled.contains(.contentBlocking) { try append(try await captureFilters()) }
        let snapshot = result
        try await Task.detached(priority: .utility) { try Self.validate(snapshot) }.value
        guard profiles == Set(profileIDs().filter { $0 != Profile.incognito.id }) else { throw ReadingQueueFailure.staleCapture }
        return snapshot
    }

    private func captureFilters() async throws -> [ICloudItem] {
        var result: [ICloudItem] = [], bytes = 0
        let names = try filterNames()
        let root = directory.appendingPathComponent("FilterLists")
        for name in try stringList("blockerImportedLists") {
            guard let uuid = Self.ownedListID(name) else { throw ICloudFailure.invalid("A saved filter-list identity needs recovery.") }
            let directory = directory, title = names[name] ?? "Filter list"
            let captured = try await Task.detached(priority: .utility) {
                try ReadingQueueFiles.check(directory, directory: true, mayBeMissing: true)
                try ReadingQueueFiles.check(root, directory: true)
                let file = root.appendingPathComponent(name)
                try ReadingQueueFiles.check(file, directory: false)
                let text = try BlockerFiles.readText(file)
                var assets: [String: Data] = [:]
                let digest = try Self.addAsset(Data(text.utf8), to: &assets)
                return try Self.item(Filter(title: title, textDigest: digest), category: .contentBlocking,
                    id: "list/" + uuid.uuidString.lowercased(), assets: assets)
            }.value
            try Self.append([captured], to: &result, bytes: &bytes)
        }
        // Legacy selected files contribute their accepted rule bytes, never their path
        // or security-scoped bookmark. Each local reference receives a random sync ID.
        for reference in try filterReferences() {
            guard let id = try legacyIdentity(reference, create: true) else { throw ICloudFailure.invalid("A selected filter identity needs recovery.") }
            if result.contains(where: { $0.id == "list/" + id.uuidString.lowercased() }) { continue }
            let captured = try await captureSelectedFilter(reference, id: id)
            try Self.append([captured], to: &result, bytes: &bytes)
        }
        let savedSubscriptions = try await subscriptions.iCloudSnapshot()
        guard Set(savedSubscriptions.map(\.id)).count == savedSubscriptions.count else { throw ICloudFailure.invalid("Duplicate saved filter identities need recovery.") }
        for subscription in savedSubscriptions {
            guard Self.validSubscriptionURL(subscription.url) else { throw ICloudFailure.invalid("A saved filter subscription needs recovery.") }
            let captured = try await Task.detached(priority: .utility) { try Self.subscriptionItem(subscription) }.value
            try Self.append([captured], to: &result, bytes: &bytes)
        }
        return result
    }

    private func filterNames() throws -> [String: String] {
        let raw = defaults.object(forKey: "blockerImportedNames")
        guard raw == nil || raw is [String: String] else { throw ICloudFailure.invalid("Saved filter names need recovery before syncing.") }
        return raw as? [String: String] ?? [:]
    }
    private func filterReferences() throws -> [Any] {
        let raw = defaults.object(forKey: "blockerLists")
        guard raw == nil || raw is [Any] else { throw ICloudFailure.invalid("Selected filter references need recovery before syncing.") }
        return raw as? [Any] ?? []
    }
    private func stringList(_ key: String) throws -> [String] {
        guard let raw = defaults.object(forKey: key) else { return [] }
        guard let strings = raw as? [String] else { throw ICloudFailure.invalid("Saved filter settings need recovery before syncing.") }
        return strings
    }
    private static let legacyIDsKey = "icloud.filterSourceIDs.v1"
    private func legacyIdentity(_ reference: Any, create: Bool) throws -> UUID? {
        let bytes: Data
        if let bookmark = reference as? Data { bytes = bookmark }
        else if let path = reference as? String { bytes = Data(path.utf8) }
        else { throw ICloudFailure.invalid("A selected filter reference needs recovery.") }
        let key = ReadingArticleCodec.digest(bytes)
        let raw = defaults.object(forKey: Self.legacyIDsKey)
        guard raw == nil || raw is [String: String] else { throw ICloudFailure.invalid("Saved filter sync identities need recovery.") }
        var identities = raw as? [String: String] ?? [:]
        if let value = identities[key] {
            guard let id = UUID(uuidString: value) else { throw ICloudFailure.invalid("A saved filter sync identity needs recovery.") }
            return id
        }
        guard create else { return nil }
        let id = UUID(); identities[key] = id.uuidString
        defaults.set(identities, forKey: Self.legacyIDsKey)
        return id
    }
    private func selectedFilterURL(_ reference: Any) throws -> URL {
        if let bookmark = reference as? Data {
            var stale = false
            guard let resolved = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)) else {
                throw ICloudFailure.storage("A selected filter file is unavailable. Reconnect it before syncing.")
            }
            return resolved
        } else if let path = reference as? String { return URL(fileURLWithPath: path) }
        throw ICloudFailure.invalid("A selected filter reference needs recovery.")
    }
    private func captureSelectedFilter(_ reference: Any, id: UUID) async throws -> ICloudItem {
        let url = try selectedFilterURL(reference)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .utility) {
            let text = try BlockerFiles.readText(url)
            var assets: [String: Data] = [:]
            let digest = try Self.addAsset(Data(text.utf8), to: &assets)
            return try Self.item(Filter(title: url.deletingPathExtension().lastPathComponent, textDigest: digest),
                category: .contentBlocking, id: "list/" + id.uuidString.lowercased(), assets: assets)
        }.value
    }
    private func removeLegacyReference(_ id: UUID) throws {
        guard let raw = defaults.object(forKey: "blockerLists") else { return }
        guard let references = raw as? [Any] else { throw ICloudFailure.invalid("Selected filter references need recovery.") }
        let kept = try references.filter { try legacyIdentity($0, create: false) != id }
        if kept.count != references.count { defaults.set(kept, forKey: "blockerLists") }
    }
    private nonisolated static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host == host.lowercased(),
              !host.contains(where: { $0.isWhitespace || "/\\@#?".contains($0) }) else { return false }
        var components = URLComponents(); components.scheme = "https"; components.host = host
        return components.url?.host == host
    }
    private nonisolated static func validSubscriptionURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
    private nonisolated static func ownedListID(_ name: String) -> UUID? {
        guard name.hasSuffix(".txt"), !name.contains("/"), !name.contains("\\"),
              let id = UUID(uuidString: String(name.dropLast(4))),
              name.lowercased() == id.uuidString.lowercased() + ".txt" else { return nil }
        return id
    }
    private nonisolated static func append(_ items: [ICloudItem], to result: inout [ICloudItem], bytes: inout Int) throws {
        for item in items {
            bytes += item.fields.values.reduce(0) { $0 + $1.count }
            guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            result.append(item)
        }
    }
    private nonisolated static func validate(_ items: [ICloudItem]) throws {
        var total = 0
        for item in items {
            try item.validate()
            for (name, value) in item.fields {
                total += value.count
                guard total <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
                if name.hasPrefix("asset") {
                    guard name.hasPrefix("asset.") else { throw ICloudFailure.invalid("Invalid synced asset identity.") }
                    _ = try asset(String(name.dropFirst(6)), from: item)
                } else if value.count > ICloudLimits.inlineBytes { throw ICloudFailure.limitExceeded }
            }
        }
    }

    private nonisolated static func identity(_ item: ICloudItem) throws -> (UUID, UUID) {
        guard let profile = item.profileID, profile != Profile.incognito.id else { throw ICloudFailure.invalid("Invalid saved-content profile.") }
        let parts = item.id.split(separator: "/")
        // The merge journal can emit a conflict's stable UUID directly. The payload's
        // original board ID never overrides the journal's new identity.
        if parts.count == 1, let id = UUID(uuidString: item.id), item.category == .easels { return (profile, id) }
        guard parts.count == 2, UUID(uuidString: String(parts[0])) == profile,
              let id = UUID(uuidString: String(parts[1])) else { throw ICloudFailure.invalid("Invalid saved-content identity.") }
        return (profile, id)
    }
    private nonisolated static func placeholder(profile: UUID, id: UUID) -> ReadingArticle {
        var article = ReadingArticle(id: id, profileID: profile, title: "Saved article",
            sourceURL: "https://offline.invalid/" + id.uuidString.lowercased(), capturedAt: Date(timeIntervalSince1970: 0),
            nodes: [.init(x: "Offline content is not available on this Mac.")])
        article.hasQueueMetadata = false; article.hasOfflineContent = false
        return article
    }

    private enum Change: Sendable {
        case board(UUID, EaselBoard), metadata(UUID, UUID, Metadata), offline(UUID, UUID, [ReadingArticle.Node], [ReadingArticle.Resource], Int, [String: Data])
        case boost(UUID, String, SiteBoost), settings(UUID, Blocking), exception(UUID, String), filter(UUID, Filter, String), subscription(UUID, Subscription, String)
    }
    private nonisolated static func prepare(_ item: ICloudItem) throws -> Change {
        switch item.category {
        case .easels:
            let (profile, id) = try identity(item), portable = try decoded(Board.self, item: item)
            var objects = try assetJSON([EaselItem].self, digest: portable.itemsDigest, item: item, limit: ICloudLimits.assetBytes)
            guard Set(portable.imageDigests.keys).isSubset(of: Set(objects.map { $0.id.uuidString.lowercased() })) else { throw ICloudFailure.invalid("An Easel asset has no owning object.") }
            for index in objects.indices {
                guard objects[index].image == nil else { throw ICloudFailure.invalid("Easel bytes must be immutable assets.") }
                if let digest = portable.imageDigests[objects[index].id.uuidString.lowercased()] { objects[index].image = try asset(digest, from: item) }
            }
            let board = EaselBoard(version: portable.version, id: id, title: portable.title, modified: portable.modified, items: objects)
            try EaselStore.validate(board)
            return .board(profile, board)
        case .readingQueue:
            let (profile, id) = try identity(item), metadata = try decoded(Metadata.self, item: item)
            var article = placeholder(profile: profile, id: id); metadata.update(&article)
            try ReadingArticleCodec.validateRecord(article)
            return .metadata(profile, id, metadata)
        case .offlineArticles:
            let (profile, id) = try identity(item), offline = try decoded(Offline.self, item: item)
            let nodes = try assetJSON([ReadingArticle.Node].self, digest: offline.nodesDigest, item: item, limit: ReadingArticleCodec.recordLimit)
            var images: [String: Data] = [:], article = placeholder(profile: profile, id: id)
            for resource in offline.resources { images[resource.name] = try asset(resource.digest, from: item) }
            article.nodes = nodes; article.resources = offline.resources; article.missingImages = offline.missingImages
            try ReadingArticleCodec.validate(.init(article: article, images: images))
            return .offline(profile, id, nodes, offline.resources, offline.missingImages, images)
        case .boosts:
            guard let profile = item.profileID, profile != Profile.incognito.id else { throw ICloudFailure.invalid("Invalid Boost profile.") }
            let portable = try decoded(Boost.self, item: item)
            guard let url = URL(string: portable.origin), url.user == nil, url.password == nil,
                  SiteBoosts.origin(url) == portable.origin,
                  item.id == profile.uuidString.lowercased() + "/" + ICloudIdentity.digest(portable.origin),
                  let css = String(data: try asset(portable.cssDigest, from: item), encoding: .utf8),
                  let script = String(data: try asset(portable.scriptDigest, from: item), encoding: .utf8),
                  portable.hidden.count <= 4096 else { throw ICloudFailure.invalid("Invalid synced Boost.") }
            let boost = SiteBoost(enabled: portable.enabled, font: portable.font, textScale: portable.textScale,
                background: portable.background, textColor: portable.textColor, linkColor: portable.linkColor,
                hidden: portable.hidden, css: css, script: script, scriptEnabled: false)
            guard boost == boost.sanitized else { throw ICloudFailure.invalid("Invalid synced Boost settings.") }
            return .boost(profile, portable.origin, boost)
        case .contentBlocking:
            let parts = item.id.split(separator: "/")
            if parts.count == 3, parts[0] == "exception", let profile = UUID(uuidString: String(parts[1])), item.profileID == profile, profile != Profile.incognito.id {
                let exception = try decoded(SiteException.self, item: item)
                guard validHost(exception.host), String(parts[2]) == ICloudIdentity.digest(exception.host) else { throw ICloudFailure.invalid("Invalid blocker site exception.") }
                return .exception(profile, exception.host)
            }
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { throw ICloudFailure.invalid("Invalid filter identity.") }
            switch parts[0] {
            case "settings":
                guard item.profileID == id, id != Profile.incognito.id else { throw ICloudFailure.invalid("Invalid blocker profile.") }
                return .settings(id, try decoded(Blocking.self, item: item))
            case "list":
                let filter = try decoded(Filter.self, item: item)
                guard filter.title.utf8.count <= 16384, let text = String(data: try asset(filter.textDigest, from: item), encoding: .utf8) else { throw ICloudFailure.invalid("Invalid filter text.") }
                _ = try Blocker.convertBoundedSources([text])
                guard text.utf8.count <= BlockerFiles.sourceByteLimit else { throw ICloudFailure.limitExceeded }
                return .filter(id, filter, text)
            case "subscription":
                let subscription = try decoded(Subscription.self, item: item), url = subscription.url
                guard validSubscriptionURL(url),
                      let text = String(data: try asset(subscription.textDigest, from: item), encoding: .utf8) else { throw ICloudFailure.invalid("Invalid filter subscription.") }
                if !text.isEmpty { _ = try FilterSubscriptions.usableText(.init(status: 200, text: text)) }
                return .subscription(id, subscription, text)
            default: throw ICloudFailure.invalid("Unknown synced filter type.")
            }
        default: throw ICloudFailure.invalid("Unsupported saved-content category.")
        }
    }

    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        let admission = ICloudApplyContext.admission ?? ICloudAdmission()
        try await withTaskCancellationHandler {
            try await ICloudApplyContext.$admission.withValue(admission) {
                try await applyAdmitted(items, deleted: deleted, enabled: enabled)
            }
        } onCancel: { admission.revoke() }
    }

    private nonisolated static func reconciled(_ incoming: ICloudItem, current: ICloudItem, baseline: [String: ICloudItem]) -> ICloudItem {
        let patch = ICloudApplyContext.$baseline.withValue(baseline) {
            ICloudApplyContext.reconcile(incoming, current: current.fields)
        }
        var merged = current
        merged.fields.merge(patch.fields) { _, incoming in incoming }
        return merged
    }

    private func applyAdmitted(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        try ICloudApplyContext.check()
        let enabled = enabled.intersection(categories)
        let admitted = items.filter { enabled.contains($0.category) }
        let removed = deleted.filter { enabled.contains($0.category) }
        guard !admitted.isEmpty || !removed.isEmpty else { return }
        // Preflight the complete remote batch before the first local mutation.
        let changes = try await Task.detached(priority: .utility) {
            try Self.validate(admitted)
            return try admitted.map(Self.prepare)
        }.value
        let baseline = ICloudApplyContext.baseline
        for (incoming, change) in zip(admitted, changes) {
            try ICloudApplyContext.check()
            switch change {
            case .board(let profile, let board):
                let original = baseline[incoming.key]
                let reconciliation = try await Task.detached(priority: .utility) {
                    var expected: EaselBoard?
                    if let original, case .board(_, let saved) = try Self.prepare(original) { expected = saved }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let digest = ReadingArticleCodec.digest(try encoder.encode(board))
                    let conflict = ICloudIdentity.uuid("late-easel/" + incoming.key + "/" + digest)
                    return (expected, conflict)
                }.value
                try ICloudApplyContext.check()
                try ensureProfile(profile)
                try await easelStore(profile).mergeICloudBoard(board, expected: reconciliation.0, conflictID: reconciliation.1)
            case .metadata(let profile, let id, _):
                try ensureProfile(profile)
                let store = try readingStore(profile)
                try await store.mergeICloudArticle(id) { existing in
                    if baseline[incoming.key] != nil, existing == nil || existing?.article.hasQueueMetadata == false { return nil }
                    var candidate = existing ?? .init(article: Self.placeholder(profile: profile, id: id), images: [:])
                    let current = try Self.item(Metadata(candidate.article), category: .readingQueue, id: incoming.id, profile: profile)
                    let merged = Self.reconciled(incoming, current: current, baseline: baseline)
                    try Self.decoded(Metadata.self, item: merged).update(&candidate.article)
                    return candidate
                }
            case .offline(let profile, let id, _, _, _, _):
                try ensureProfile(profile)
                let store = try readingStore(profile)
                try await store.mergeICloudArticle(id) { existing in
                    if baseline[incoming.key] != nil, existing == nil || existing?.article.hasOfflineContent == false { return nil }
                    var candidate = existing ?? .init(article: Self.placeholder(profile: profile, id: id), images: [:])
                    let current = try Self.offlineItem(candidate)
                    // The nodes and resource manifest are one validated document. Keep
                    // that complete local snapshot when it changed after capture.
                    if let expected = baseline[incoming.key], ["nodesDigest", "resources", "missingImages"].contains(where: { current.fields[$0] != expected.fields[$0] }) { return nil }
                    let merged = Self.reconciled(incoming, current: current, baseline: baseline)
                    guard case .offline(_, _, let nodes, let resources, let missing, let images) = try Self.prepare(merged) else { throw ICloudFailure.invalid("Invalid saved article content.") }
                    candidate.article.nodes = nodes; candidate.article.resources = resources; candidate.article.missingImages = missing
                    candidate.article.hasOfflineContent = true; candidate.images = images
                    return candidate
                }
            case .boost(let profile, let origin, _):
                try ensureProfile(profile)
                try await mergeBoost(incoming, origin: origin, profile: profile, baseline: baseline)
            case .settings(let profile, _):
                try ensureProfile(profile)
                let key = ProfileManager.defaultsKey("blockerEnabled", profile)
                let local = try Self.item(Blocking(enabled: defaults.object(forKey: key) as? Bool ?? true), category: .contentBlocking, id: incoming.id, profile: profile)
                let merged = Self.reconciled(incoming, current: local, baseline: baseline)
                let settings = try Self.decoded(Blocking.self, item: merged)
                try ICloudApplyContext.check()
                defaults.set(settings.enabled, forKey: key); blockerChanged()
            case .exception(let profile, let host):
                try ensureProfile(profile)
                let key = ProfileManager.defaultsKey("blockerSiteExceptions", profile)
                var hosts = Set(try stringList(key))
                if baseline[incoming.key] != nil, !hosts.contains(host) { continue }
                hosts.insert(host)
                try ICloudApplyContext.check()
                defaults.set(hosts.sorted(), forKey: key); blockerChanged()
            case .filter(let id, let filter, let text):
                try await mergeFilter(incoming, id: id, title: filter.title, text: text, baseline: baseline)
            case .subscription(let id, let subscription, _):
                try await subscriptions.modifyICloudSubscription(id) { current in
                    if baseline[incoming.key] != nil, current == nil { return nil }
                    var value = current ?? FilterSubscription(id: id, url: subscription.url)
                    let local = try Self.subscriptionItem(value)
                    let merged = Self.reconciled(incoming, current: local, baseline: baseline)
                    guard case .subscription(_, let portable, let text) = try Self.prepare(merged) else { throw ICloudFailure.invalid("Invalid synced filter subscription.") }
                    if value.url != portable.url || value.text != text {
                        value.etag = nil; value.lastModified = nil; value.lastAttempt = nil
                        value.lastSuccess = nil; value.lastError = nil; value.report = nil
                    }
                    value.url = portable.url; value.text = text
                    return value
                }
            }
        }
        for item in removed { try ICloudApplyContext.check(); try await remove(item, enabled: enabled) }
    }

    private func mergeBoost(_ incoming: ICloudItem, origin: String, profile: UUID, baseline: [String: ICloudItem]) async throws {
        while true {
            try ICloudApplyContext.check()
            let snapshot = boosts.get(origin: origin, profile: profile)
            let updated = try await Task.detached(priority: .utility) {
                let local = try Self.boostItem(snapshot, origin: origin, profile: profile)
                let merged = Self.reconciled(incoming, current: local, baseline: baseline)
                guard case .boost(_, _, let value) = try Self.prepare(merged) else { throw ICloudFailure.invalid("Invalid synced Boost.") }
                return value
            }.value
            try ICloudApplyContext.check()
            // Encoding runs off the main actor. Recompute if an editor changed this
            // value in that interval; no await separates this check from cache set.
            let current = boosts.get(origin: origin, profile: profile)
            guard current == snapshot else { continue }
            if baseline[incoming.key] != nil, !boosts.records(profile: profile).keys.contains(origin) { return }
            var value = updated
            value.scriptEnabled = current.scriptEnabled && current.script == value.script
            // The owner cache is the native mutation boundary. Its already-admitted
            // ordinary writer may finish after revocation, preserving existing copies.
            boosts.set(value, origin: origin, profile: profile)
            boostChanged(origin, profile)
            guard await boosts.flush() else { throw ICloudFailure.storage("A synced Boost could not be saved.") }
            return
        }
    }

    private struct LocalFilter: Equatable, Sendable { var file: URL; var title: String; var owned: Bool }
    private struct FilterRevision: Equatable, Sendable {
        var device: Int64; var inode: UInt64; var size: Int64; var seconds: Int64; var nanoseconds: Int64
    }
    private nonisolated static func filterRevision(_ file: URL) throws -> FilterRevision {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ICloudFailure.invalid("A saved filter source contains an unsupported file or symbolic link.") }
        return FilterRevision(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
    private func localFilter(_ id: UUID) throws -> LocalFilter? {
        let names = try filterNames()
        if let name = try stringList("blockerImportedLists").first(where: { Self.ownedListID($0) == id }) {
            return LocalFilter(file: directory.appendingPathComponent("FilterLists").appendingPathComponent(name), title: names[name] ?? "Filter list", owned: true)
        }
        for reference in try filterReferences() where try legacyIdentity(reference, create: false) == id {
            let file = try selectedFilterURL(reference)
            return LocalFilter(file: file, title: file.deletingPathExtension().lastPathComponent, owned: false)
        }
        return nil
    }
    private func mergeFilter(_ incoming: ICloudItem, id: UUID, title: String, text: String, baseline: [String: ICloudItem]) async throws {
        while true {
            try ICloudApplyContext.check()
            guard let local = try localFilter(id) else {
                // Known identity removed since capture: preserve that local deletion.
                if baseline[incoming.key] != nil { return }
                try installFilter(id, title: title, text: text); return
            }
            let accessed = local.file.startAccessingSecurityScopedResource()
            defer { if accessed { local.file.stopAccessingSecurityScopedResource() } }
            let directory = directory
            let prepared = try await Task.detached(priority: .utility) { () -> (FilterRevision, String, String, Bool)? in
                if local.owned {
                    try ReadingQueueFiles.check(directory, directory: true)
                    try ReadingQueueFiles.check(directory.appendingPathComponent("FilterLists"), directory: true)
                }
                let before = try Self.filterRevision(local.file)
                let currentText = try BlockerFiles.readText(local.file)
                let after = try Self.filterRevision(local.file)
                guard before == after else { return nil }
                var assets: [String: Data] = [:]
                let digest = try Self.addAsset(Data(currentText.utf8), to: &assets)
                let current = try Self.item(Filter(title: local.title, textDigest: digest), category: .contentBlocking, id: incoming.id, assets: assets)
                let merged = Self.reconciled(incoming, current: current, baseline: baseline)
                guard case .filter(_, let filter, let text) = try Self.prepare(merged) else { throw ICloudFailure.invalid("Invalid synced filter content.") }
                return (after, filter.title, text, filter.title != local.title || text != currentText)
            }.value
            try ICloudApplyContext.check()
            guard let prepared else { continue }
            // File reads/encoding suspend off-main. Validate both the source revision
            // and native manifest immediately before this actor's atomic publication.
            guard try localFilter(id) == local, try Self.filterRevision(local.file) == prepared.0 else { continue }
            if local.owned, !prepared.3 { return }
            try installFilter(id, title: prepared.1, text: prepared.2); return
        }
    }

    private func installFilter(_ id: UUID, title: String, text: String) throws {
        let folder = directory.appendingPathComponent("FilterLists")
        try ReadingQueueFiles.check(directory, directory: true, mayBeMissing: true)
        try ReadingQueueFiles.ensureDirectory(directory); try ReadingQueueFiles.ensureDirectory(folder)
        var lists = try stringList("blockerImportedLists")
        var names = try filterNames()
        let references = try filterReferences()
        let remaining = try references.filter { try legacyIdentity($0, create: false) != id }
        let name = lists.first(where: { Self.ownedListID($0) == id }) ?? id.uuidString + ".txt"
        let file = folder.appendingPathComponent(name)
        try ReadingQueueFiles.check(file, directory: false, mayBeMissing: true)
        let bytes = Data(text.utf8)
        try ICloudApplyContext.check()
        try bytes.write(to: file, options: .atomic)
        lists.removeAll { Self.ownedListID($0) == id }; lists.append(name)
        names[name] = title
        defaults.set(lists, forKey: "blockerImportedLists"); defaults.set(names, forKey: "blockerImportedNames")
        if remaining.count != references.count { defaults.set(remaining, forKey: "blockerLists") }
        blockerChanged()
    }
    private func remove(_ item: ICloudItem, enabled: Set<ICloudCategory>) async throws {
        try item.validate()
        switch item.category {
        case .easels:
            let (profile, id) = try Self.identity(item)
            guard profileIDs().contains(profile) else { return }
            try await easelStore(profile).deleteICloudBoard(id)
        case .readingQueue, .offlineArticles:
            let (profile, id) = try Self.identity(item)
            guard profileIDs().contains(profile) else { return }
            let store = try readingStore(profile); await store.waitUntilReady()
            guard store.articles.contains(where: { $0.id == id }) else { return }
            let current = try await store.candidate(id)
            if item.category == .readingQueue {
                if enabled.contains(.offlineArticles) || current.article.hasOfflineContent == false { try await store.remove(id); return }
            } else if current.article.hasQueueMetadata == false { try await store.remove(id); return }
            let removeMetadata = item.category == .readingQueue
            try await store.mergeICloudArticle(id) { existing in
                guard var current = existing else { throw ReadingQueueFailure.missing }
                if removeMetadata {
                    let placeholder = Self.placeholder(profile: profile, id: id)
                    current.article.title = placeholder.title; current.article.sourceURL = placeholder.sourceURL
                    current.article.byline = ""; current.article.isRead = false
                    current.article.capturedAt = placeholder.capturedAt; current.article.hasQueueMetadata = false
                } else {
                    current.article.nodes = Self.placeholder(profile: profile, id: id).nodes
                    current.article.resources = []; current.article.missingImages = 0; current.images = [:]
                    current.article.hasOfflineContent = false
                }
                return current
            }
        case .boosts:
            guard let profile = item.profileID, profile != Profile.incognito.id else { throw ICloudFailure.invalid("Invalid Boost profile.") }
            for origin in boosts.records(profile: profile).keys where item.id == profile.uuidString.lowercased() + "/" + ICloudIdentity.digest(origin) {
                boosts.set(SiteBoost(), origin: origin, profile: profile)
            }
            guard await boosts.flush() else { throw ICloudFailure.storage("Boost deletion could not be saved.") }
        case .contentBlocking:
            let parts = item.id.split(separator: "/")
            if parts.count == 3, parts[0] == "exception", let profile = UUID(uuidString: String(parts[1])), item.profileID == profile {
                let key = ProfileManager.defaultsKey("blockerSiteExceptions", profile)
                defaults.set(try stringList(key).filter { ICloudIdentity.digest($0) != String(parts[2]) }, forKey: key)
                blockerChanged(); return
            }
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { throw ICloudFailure.invalid("Invalid filter deletion.") }
            if parts[0] == "subscription" { try await subscriptions.mergeICloudSubscription(nil, deleting: id) }
            else if parts[0] == "list" {
                let lists = defaults.stringArray(forKey: "blockerImportedLists") ?? []
                for name in lists where Self.ownedListID(name) == id {
                    let folder = directory.appendingPathComponent("FilterLists")
                    try ReadingQueueFiles.check(directory, directory: true, mayBeMissing: true)
                    try ReadingQueueFiles.check(folder, directory: true, mayBeMissing: true)
                    let file = folder.appendingPathComponent(name)
                    if ReadingQueueFiles.exists(file) { try ReadingQueueFiles.check(file, directory: false); try ICloudApplyContext.check(); try FileManager.default.removeItem(at: file) }
                }
                defaults.set(lists.filter { Self.ownedListID($0) != id }, forKey: "blockerImportedLists")
                try removeLegacyReference(id)
                blockerChanged()
            } else if parts[0] == "settings", item.profileID == id {
                defaults.removeObject(forKey: ProfileManager.defaultsKey("blockerEnabled", id)); blockerChanged()
            }
        default: break
        }
    }
}
