import Foundation

enum AIFeature: String, CaseIterable, Codable, Sendable {
    case tabTitles, tabGroups, downloads, summaries
    var title: String {
        switch self {
        case .tabTitles: "Tab titles"
        case .tabGroups: "Tab grouping"
        case .downloads: "Download names"
        case .summaries: "Page summaries"
        }
    }
}

struct ChatGPTRegistration: Codable, Equatable, Sendable {
    var clientID: String
    var subject: String
    var email: String?
}

/// Preferences contain connection metadata only. Credentials live in Keychain.
struct AIConnection: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: AIProvider
    var baseURL: String
    var model: String
    var registration: ChatGPTRegistration?
    var legacyCredentialAccount: String?

    init(provider: AIProvider) {
        self.provider = provider
        name = provider.title
        baseURL = provider.baseURL
        model = provider.defaultModel
    }
    var credentialAccount: String { legacyCredentialAccount ?? "connection:" + id.uuidString }
    var configuration: CloudAI.Configuration { .init(provider: provider, baseURL: baseURL, model: model) }
}

struct AIConnections: Codable, Equatable, Sendable {
    var connections: [AIConnection] = []
    private var routes: [String: UUID] = [:]
    static let preferenceKey = "aiConnections.v1"

    static func load(_ defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: preferenceKey) {
            return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
        }
        var state = Self()
        if let provider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? ""), provider != .apple, provider != .chatGPT {
            var connection = AIConnection(provider: provider)
            connection.baseURL = provider == .custom ? defaults.string(forKey: "aiBaseURL") ?? "" : provider.baseURL
            connection.model = defaults.string(forKey: "aiModel." + provider.rawValue) ?? provider.defaultModel
            connection.legacyCredentialAccount = provider == .custom
                ? provider.rawValue + ":" + (CloudAI.endpoint(connection.baseURL)?.absoluteString ?? connection.baseURL)
                : provider.rawValue
            state.connections.append(connection)
            for feature in [AIFeature.tabTitles, .tabGroups, .downloads] { state.route(feature, to: connection.id) }
        }
        state.save(defaults)
        return state
    }
    func save(_ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
    func connection(for feature: AIFeature) -> AIConnection? {
        guard let id = routes[feature.rawValue] else { return nil }
        return connections.first { $0.id == id }
    }
    mutating func route(_ feature: AIFeature, to id: UUID?) {
        routes[feature.rawValue] = id
    }
    mutating func remove(_ id: UUID) {
        connections.removeAll { $0.id == id }
        routes = routes.filter { $0.value != id }
    }
    mutating func update(_ connection: AIConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
    }
}
