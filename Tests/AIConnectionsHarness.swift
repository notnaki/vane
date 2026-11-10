import Foundation

@main struct AIConnectionsHarness {
    static func main() {
        let suite = "vane-ai-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom", forKey: "aiProvider")
        defaults.set("https://legacy.example/v1", forKey: "aiBaseURL")
        defaults.set("legacy-model", forKey: "aiModel.custom")
        var state = AIConnections.load(defaults)
        let legacy = state.connections.first!
        var checks: [(String, Bool)] = [
            ("migrate selected connection and endpoint", legacy.provider == .custom && legacy.baseURL == "https://legacy.example/v1" && legacy.model == "legacy-model"),
            ("migrate existing credential without exposing a key", legacy.credentialAccount == "custom:https://legacy.example/v1/chat/completions"),
            ("migrate naming and grouping routes", state.connection(for: .tabTitles)?.id == legacy.id && state.connection(for: .tabGroups)?.id == legacy.id && state.connection(for: .downloads)?.id == legacy.id),
            ("summary remains on device", state.connection(for: .summaries) == nil),
            ("migration is stable", AIConnections.load(defaults) == state)
        ]
        let first = AIConnection(provider: .openAI)
        let second = AIConnection(provider: .openAI)
        state.connections += [first, second]
        state.route(.tabTitles, to: first.id)
        state.route(.tabGroups, to: second.id)
        checks += [
            ("same provider has independent credentials", first.credentialAccount != second.credentialAccount),
            ("features have independent routes", state.connection(for: .tabTitles)?.id == first.id && state.connection(for: .tabGroups)?.id == second.id),
            ("new connection cannot acquire summaries", state.connection(for: .summaries) == nil)
        ]
        state.save(defaults)
        checks.append(("connections and routing survive restart", AIConnections.load(defaults) == state))
        state.remove(first.id)
        checks.append(("removal only resets routes using that connection", state.connection(for: .tabTitles) == nil && state.connection(for: .tabGroups)?.id == second.id))
        state.route(.summaries, to: second.id)
        checks.append(("cloud summaries require explicit selection", state.connection(for: .summaries)?.id == second.id))
        let encoded = String(decoding: try! JSONEncoder().encode(state), as: UTF8.self)
        checks.append(("preferences do not contain tokens", !encoded.contains("access_token") && !encoded.contains("refresh_token")))
        state.remove(second.id); state.remove(legacy.id); state.save(defaults)
        checks.append(("empty saved state never remigrates removed connection", AIConnections.load(defaults).connections.isEmpty))
        for (name, passed) in checks { print("\(passed ? "ok" : "FAIL") \(name)") }
        exit(checks.allSatisfy(\.1) ? 0 : 1)
    }
}
