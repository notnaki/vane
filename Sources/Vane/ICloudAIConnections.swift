import Foundation

/// Only API connection definitions/routes are portable. Account registrations and
/// ChatGPT credentials/routes belong to this Mac and cannot enter the sync blob.
enum ICloudAIConnections {
    private static func isAPI(_ provider: AIProvider) -> Bool {
        switch provider {
        case .groq, .openAI, .openRouter, .custom: true
        default: false
        }
    }
    static func local(_ defaults: UserDefaults) throws -> AIConnections {
        guard let value = defaults.object(forKey: AIConnections.preferenceKey) else { return AIConnections.load(defaults) }
        guard let data = value as? Data, data.count <= ICloudLimits.inlineBytes else {
            throw ICloudFailure.invalid("The local AI connection metadata could not be read. Credentials were retained.")
        }
        return try JSONDecoder().decode(AIConnections.self, from: data)
    }
    static func portable(_ state: AIConnections) throws -> AIConnections {
        guard state.connections.count <= 256,
              Set(state.connections.map(\.id)).count == state.connections.count else { throw ICloudFailure.invalid("AI connection identities are duplicated or oversized.") }
        var result = AIConnections()
        for var connection in state.connections where isAPI(connection.provider) {
            let expectedLegacy = AIKeys.account(provider: connection.provider, baseURL: connection.baseURL)
            guard connection.name.utf8.count <= 1024, connection.model.utf8.count <= 200,
                  connection.baseURL.utf8.count <= 2048,
                  connection.baseURL.isEmpty || CloudAI.endpoint(connection.baseURL) != nil,
                  connection.legacyCredentialAccount == nil || connection.legacyCredentialAccount == expectedLegacy else {
                throw ICloudFailure.invalid("An AI connection contains nonportable endpoint or credential metadata.")
            }
            connection.registration = nil
            result.connections.append(connection)
        }
        let ids = Set(result.connections.map(\.id))
        for feature in AIFeature.allCases {
            if let connection = state.connection(for: feature), ids.contains(connection.id) { result.route(feature, to: connection.id) }
        }
        return result
    }

    static func accounts(in state: AIConnections) throws -> Set<String> {
        Set(try portable(state).connections.map(\.credentialAccount))
    }

    static func merge(_ incoming: AIConnections, into local: AIConnections) throws -> AIConnections {
        let incoming = try portable(incoming)
        let retained = local.connections.filter { !isAPI($0.provider) }
        guard Set(retained.map(\.id)).isDisjoint(with: incoming.connections.map(\.id)) else {
            throw ICloudFailure.invalid("A synced API connection conflicts with a device-local account identity.")
        }
        var result = local
        for connection in local.connections where isAPI(connection.provider) { result.remove(connection.id) }
        result.connections += incoming.connections
        for feature in AIFeature.allCases {
            if let current = local.connection(for: feature), retained.contains(where: { $0.id == current.id }) { continue }
            result.route(feature, to: incoming.connection(for: feature)?.id)
        }
        return result
    }
}
