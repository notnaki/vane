import Foundation
import Security

/// The provider for names and groups. Summaries continue to use AppleAI on this Mac.
@MainActor enum BrowserAI {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.vane.string(forKey: "aiProvider") ?? "") ?? .apple }
        set { UserDefaults.vane.set(newValue.rawValue, forKey: "aiProvider") }
    }
    static var enabled: Bool {
        UserDefaults.vane.object(forKey: "appleAI") as? Bool ?? true
    }
    static var configuration: CloudAI.Configuration {
        .init(provider: provider,
              baseURL: provider == .custom ? UserDefaults.vane.string(forKey: "aiBaseURL") ?? "" : provider.baseURL,
              model: UserDefaults.vane.string(forKey: "aiModel." + provider.rawValue) ?? provider.defaultModel)
    }
    private static var namespace: String? {
        Store.overrideDirectory.map { UserDefaults.suiteName(forDataDir: $0) }
    }
    private static var account: String {
        AIKeys.account(provider: provider, baseURL: configuration.baseURL)
    }
    static var hasKey: Bool { AIKeys.read(account: account, namespace: namespace) != nil }
    static var ready: Bool {
        guard enabled else { return false }
        return provider == .apple ? AppleAI.ready
            : CloudAI.endpoint(configuration.baseURL) != nil && !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasKey
    }
    static var unavailableReason: String? {
        if provider == .apple { return AppleAI.unavailableReason }
        if CloudAI.endpoint(configuration.baseURL) == nil { return "Enter an HTTPS API base URL." }
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the model ID from your provider." }
        if !hasKey { return "Add your own API key to enable cloud naming and grouping." }
        return nil
    }
    static func saveKey(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return false }
        return AIKeys.save(key, account: account, namespace: namespace) == errSecSuccess
    }
    static func removeKey() -> Bool {
        AIKeys.remove(account: account, namespace: namespace) == errSecSuccess
    }

    static func settingsChanged() {
        UserDefaults.vane.set(UserDefaults.vane.integer(forKey: "aiSettingsRevision") + 1,
                              forKey: "aiSettingsRevision")
        limitedConfiguration = nil
        TidyTitles.invalidateGeneratedNames()
    }

    private static var inFlight = 0
    private static var limitedUntil: Date = .distantPast
    private static var limitedConfiguration: CloudAI.Configuration?

    private static func reply<T: Decodable>(_ type: T.Type, prompt: String, tokens: Int) async -> T? {
        guard ready, provider != .apple, inFlight < 2,
              limitedConfiguration != configuration || Date.now >= limitedUntil,
              let key = AIKeys.read(account: account, namespace: namespace) else { return nil }
        let config = configuration
        let revision = UserDefaults.vane.integer(forKey: "aiSettingsRevision")
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let text = try await CloudAI.complete(config, key: key, prompt: prompt, tokens: tokens)
            guard enabled, config == configuration,
                  revision == UserDefaults.vane.integer(forKey: "aiSettingsRevision"), !Task.isCancelled else { return nil }
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch CloudAI.Failure.rateLimited {
            guard enabled, config == configuration,
                  revision == UserDefaults.vane.integer(forKey: "aiSettingsRevision"), !Task.isCancelled else { return nil }
            limitedConfiguration = config
            limitedUntil = .now.addingTimeInterval(60)
            return nil
        } catch { return nil }
    }

    static func testConnection() async -> String {
        guard provider != .apple, let key = AIKeys.read(account: account, namespace: namespace)
        else { return "Save an API key first." }
        let config = configuration
        let revision = UserDefaults.vane.integer(forKey: "aiSettingsRevision")
        let began = Date.now
        do {
            let text = try await CloudAI.complete(config, key: key,
                prompt: #"Return this JSON object exactly: {"text":"Connected"}"#, tokens: 512)
            struct Test: Decodable { let text: String }
            guard let decoded = try? JSONDecoder().decode(Test.self, from: Data(text.utf8)), decoded.text == "Connected"
            else { return "The model did not return the requested JSON. Check the model's JSON support." }
            guard config == configuration, revision == UserDefaults.vane.integer(forKey: "aiSettingsRevision")
            else { return "Provider settings changed. Test the new settings." }
            limitedConfiguration = nil
            return "Connected in \(String(format: "%.1f", Date.now.timeIntervalSince(began))) seconds."
        } catch let failure as CloudAI.Failure {
            return failure.localizedDescription
        } catch { return "Could not connect. Check your internet connection and API base URL." }
    }

    static func shortTitle(for title: String, url: URL) async -> String? {
        if provider == .apple { return await AppleAI.shortTitle(for: title, url: url) }
        struct Title: Decodable { let text: String }
        let prompt = AppleAI.prompt("Host: \(url.host() ?? "")\nTitle: \(title)", ask:
            #"Return JSON {"text":"short title"}. Use at most four words and 32 characters, selected from the original title. Keep the specific subject; omit site names and marketing text. Finish at a whole word."#, limit: 700)
        return await reply(Title.self, prompt: prompt, tokens: 512)?.text
    }

    static func filename(for suggested: String, pageTitle: String?, sourceURL: URL,
                         isPrivate: Bool = false) async -> String? {
        if provider == .apple { return await AppleAI.filename(for: suggested, pageTitle: pageTitle, sourceURL: sourceURL) }
        guard !isPrivate else { return nil }
        struct Stem: Decodable { let stem: String }
        // URLs are minimized: query strings and fragments can contain tokens or search terms.
        let source = (sourceURL.host() ?? "") + sourceURL.path
        let prompt = AppleAI.prompt("Page: \(pageTitle ?? "")\nSource: \(source)\nFile: \(suggested)", ask:
            #"Return JSON {"stem":"descriptive-file-name"}. Use at most six lowercase words joined by hyphens. No extension, paths or invented details."#, limit: 1000)
        guard let stem = await reply(Stem.self, prompt: prompt, tokens: 512)?.stem else { return nil }
        return AppleAI.safeFilename(stem, extension: (suggested as NSString).pathExtension)
    }

    static func group(_ tabs: [(id: String, title: String, host: String)], isPrivate: Bool = false) async -> [(name: String, ids: [String])]? {
        guard !isPrivate else { return nil }
        if provider == .apple { return await AppleAI.group(tabs) }
        guard AppleAI.worthGrouping(tabs.count) else { return nil }
        struct Groups: Decodable {
            struct Group: Decodable { let name: String; let tabs: [Int] }
            let groups: [Group]
        }
        let shown = Array(tabs.prefix(60))
        let prompt = AppleAI.prompt(AppleAI.listing(shown), ask:
            #"Return JSON {"groups":[{"name":"Topic","tabs":[1,2]}]}. Create two to six useful topic groups, with one to three words per name. Assign every numbered tab exactly once."#, limit: 8000)
        guard let answer = await reply(Groups.self, prompt: prompt, tokens: 2048) else { return nil }
        return AppleAI.tidyGroups(answer.groups.map { ($0.name, $0.tabs) }, ids: shown.map(\.id))
    }
}
