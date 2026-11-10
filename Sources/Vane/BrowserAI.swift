import Foundation
import Security
import SwiftUI

/// Resolve a saved connection separately for each Max feature. Apple stays the default.
@MainActor enum BrowserAI {
    static var state: AIConnections { AIConnections.load(UserDefaults.vane) }
    static var enabled: Bool { UserDefaults.vane.object(forKey: "appleAI") as? Bool ?? true }
    /// Invalidate synchronously on each master-switch edge; SwiftUI may coalesce an
    /// off→on sequence before an onChange observer runs, reopening stale admission.
    static var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { value in
            guard value != enabled else { return }
            UserDefaults.vane.set(value, forKey: "appleAI")
            settingsChanged()
        })
    }
    static var namespace: String? { Store.overrideDirectory.map { UserDefaults.suiteName(forDataDir: $0) } }
    static var revision: Int { UserDefaults.vane.integer(forKey: "aiSettingsRevision") }
    static func save(_ state: AIConnections) { state.save(UserDefaults.vane); settingsChanged() }
    static func key(_ connection: AIConnection) -> String? { AIKeys.read(account: connection.credentialAccount, namespace: namespace) }
    static func credentials(_ connection: AIConnection) -> ChatGPTOAuth.Credentials? { ChatGPTOAuth.Credentials.restore(key(connection)) }
    static func hasKey(_ connection: AIConnection) -> Bool { key(connection) != nil }
    static func ready(for feature: AIFeature) -> Bool { enabled && unavailableReason(for: feature) == nil }
    static func unavailableReason(for feature: AIFeature) -> String? {
        guard let connection = state.connection(for: feature) else { return AppleAI.unavailableReason }
        return unavailableReason(connection)
    }
    static func unavailableReason(_ connection: AIConnection) -> String? {
        if connection.provider == .chatGPT {
            if sessions[sessionID(connection)]?.signedOut == true { return ChatGPTFailure.signInRequired.localizedDescription }
            guard connection.registration != nil, let credentials = credentials(connection) else { return "Continue with ChatGPT to connect this account." }
            if !credentials.permitsPlan { return ChatGPTFailure.planDisabled.localizedDescription }
            if credentials.expiresAt <= .now && credentials.refreshToken == nil { return ChatGPTFailure.signInRequired.localizedDescription }
        } else {
            if CloudAI.endpoint(connection.baseURL) == nil { return "Enter an HTTPS API base URL." }
            if !hasKey(connection) { return "Save an API key for this connection." }
        }
        if connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a model for this connection." }
        return nil
    }
    static func saveKey(_ raw: String, for connection: AIConnection) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connection.provider != .chatGPT, ChatGPTOAuth.safeToken(key) else { return false }
        guard AIKeys.save(key, account: connection.credentialAccount, namespace: namespace) == errSecSuccess else { return false }
        settingsChanged(); return true
    }
    static func removeKey(_ connection: AIConnection) -> Bool {
        guard AIKeys.remove(account: connection.credentialAccount, namespace: namespace) == errSecSuccess else { return false }
        sessions.removeValue(forKey: sessionID(connection))?.invalidate()
        settingsChanged(); return true
    }
    static func remove(_ connection: AIConnection) -> Bool {
        guard removeKey(connection) else { return false }
        var next = state; next.remove(connection.id); save(next); return true
    }
    static func settingsChanged() {
        UserDefaults.vane.set(revision + 1, forKey: "aiSettingsRevision")
        pendingRequests.values.forEach { $0.cancel() }
        limitedUntil.removeAll()
        TidyTitles.invalidateGeneratedNames()
    }
    static var hostID: String {
        if let saved = UserDefaults.vane.string(forKey: "chatGPTHostID") { return saved }
        let host = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.vane.set(host, forKey: "chatGPTHostID"); return host
    }
    private static var sessions: [String: ChatGPTSession] = [:]
    private static func sessionID(_ connection: AIConnection) -> String { (namespace ?? "main") + ":" + connection.id.uuidString }
    static func session(_ connection: AIConnection) throws -> ChatGPTSession {
        guard let registration = connection.registration else { throw ChatGPTFailure.signInRequired }
        let id = sessionID(connection)
        if let session = sessions[id], session.registration == registration { return session }
        sessions[id]?.invalidate()
        let account = connection.credentialAccount, namespace = namespace
        let session = ChatGPTSession(registration: registration,
            lockURL: Store.directory.appendingPathComponent("AI/" + connection.id.uuidString + ".lock"),
            read: { ChatGPTOAuth.Credentials.restore(AIKeys.read(account: account, namespace: namespace)) },
            write: { credentials in
                if let credentials, let stored = credentials.stored { return AIKeys.save(stored, account: account, namespace: namespace) == errSecSuccess }
                return credentials == nil && AIKeys.remove(account: account, namespace: namespace) == errSecSuccess
            })
        sessions[id] = session; return session
    }
    static func commitSignIn(_ original: AIConnection, registration: ChatGPTRegistration, credentials: ChatGPTOAuth.Credentials) -> Bool {
        guard state.connections.first(where: { $0.id == original.id }) == original,
              let stored = credentials.stored, AIKeys.save(stored, account: original.credentialAccount, namespace: namespace) == errSecSuccess else { return false }
        var updated = original; updated.registration = registration
        // A model always comes from the account's catalog, selected explicitly in settings.
        var next = state; next.update(updated); save(next)
        sessions.removeValue(forKey: sessionID(original))?.invalidate()
        return true
    }
    static func models(_ connection: AIConnection) async throws -> [ChatGPTResponses.Model] {
        let credentials = try await session(connection).credentials()
        return try await ChatGPTResponses.catalog(token: credentials.accessToken)
    }
    static func signOut(_ connection: AIConnection) async throws -> Bool {
        settingsChanged()
        let revoked = try await session(connection).signOut()
        settingsChanged(); return revoked
    }
    private static var inFlight = 0
    private static var limitedUntil: [UUID: Date] = [:]
    private static var pendingRequests: [UUID: Task<String, Error>] = [:]
    private static func complete(_ connection: AIConnection, prompt: String, tokens: Int, isPrivate: Bool,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        guard !isPrivate, isCurrent() else { throw CancellationError() }
        let id = UUID()
        let task = Task { @MainActor in
            if connection.provider == .chatGPT {
                let grant = try await session(connection).credentials()
                try Task.checkCancellation()
                // Refresh can outlive a route edit, sign-out, or disabling AI. Recheck
                // permission before any page content leaves the Mac, not just on return.
                guard isCurrent() else { throw CancellationError() }
                return try await ChatGPTResponses.complete(connection.configuration, token: grant.accessToken, prompt: prompt, isPrivate: isPrivate)
            }
            try Task.checkCancellation()
            guard isCurrent(), let key = key(connection) else { throw CloudAI.Failure.configuration }
            return try await CloudAI.complete(connection.configuration, key: key, prompt: prompt, tokens: tokens, isPrivate: isPrivate)
        }
        pendingRequests[id] = task
        defer { pendingRequests[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func reply<T: Decodable>(_ type: T.Type, feature: AIFeature, isPrivate: Bool = false, prompt: String, tokens: Int) async -> T? {
        guard !isPrivate, ready(for: feature), let connection = state.connection(for: feature), inFlight < 2,
              Date.now >= (limitedUntil[connection.id] ?? .distantPast) else { return nil }
        let revision = revision
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let text = try await complete(connection, prompt: prompt, tokens: tokens, isPrivate: isPrivate) {
                enabled && revision == self.revision && state.connection(for: feature) == connection
            }
            guard enabled, revision == self.revision, state.connection(for: feature) == connection, !Task.isCancelled else { return nil }
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            guard revision == self.revision, state.connection(for: feature) == connection, !Task.isCancelled else { return nil }
            if (error as? CloudAI.Failure) == .rateLimited || (error as? ChatGPTFailure)?.rateLimited == true { limitedUntil[connection.id] = .now.addingTimeInterval(60) }
            return nil
        }
    }
    static func testConnection(_ connection: AIConnection) async -> String {
        let began = Date.now, revision = revision
        do {
            let text = try await complete(connection, prompt: #"Return this JSON object exactly: {"text":"Connected"}"#, tokens: 512, isPrivate: false) {
                revision == self.revision && state.connections.contains(connection)
            }
            struct Test: Decodable { let text: String }
            guard let decoded = try? JSONDecoder().decode(Test.self, from: Data(text.utf8)), decoded.text == "Connected" else { return "The model did not return the requested JSON. Check the model's JSON support." }
            guard revision == self.revision, state.connections.contains(connection) else { return "Connection settings changed. Test the new settings." }
            limitedUntil[connection.id] = nil
            return "Connected in \(String(format: "%.1f", Date.now.timeIntervalSince(began))) seconds."
        } catch let error as ChatGPTFailure { return error.localizedDescription }
        catch let error as CloudAI.Failure { return error.localizedDescription }
        catch { return "Could not connect. Check your internet connection and model." }
    }

    private static func localReply<T>(feature: AIFeature, operation: () async -> T?) async -> T? {
        guard enabled, state.connection(for: feature) == nil else { return nil }
        let revision = revision
        let answer = await operation()
        guard enabled, revision == self.revision, state.connection(for: feature) == nil, !Task.isCancelled else { return nil }
        return answer
    }

    static func shortTitle(for title: String, url: URL, isPrivate: Bool = false) async -> String? {
        if state.connection(for: .tabTitles) == nil { return await localReply(feature: .tabTitles) { await AppleAI.shortTitle(for: title, url: url) } }
        guard !isPrivate else { return nil }
        struct Title: Decodable { let text: String }
        let prompt = AppleAI.prompt("Host: \(url.host() ?? "")\nTitle: \(title)", ask:
            #"Return JSON {"text":"short title"}. Consider titles of any length. Use at most four words and 32 characters, selected from the original title. Keep the specific subject; omit site names and marketing text. Finish at a whole word."#, limit: 700)
        return await reply(Title.self, feature: .tabTitles, isPrivate: isPrivate, prompt: prompt, tokens: 512)?.text
    }

    static func filename(for suggested: String, pageTitle: String?, sourceURL: URL,
                         isPrivate: Bool = false) async -> String? {
        if state.connection(for: .downloads) == nil { return await localReply(feature: .downloads) { await AppleAI.filename(for: suggested, pageTitle: pageTitle, sourceURL: sourceURL) } }
        guard !isPrivate else { return nil }
        struct Stem: Decodable { let stem: String }
        // URLs are minimized: query strings and fragments can contain tokens or search terms.
        let source = (sourceURL.host() ?? "") + sourceURL.path
        let prompt = AppleAI.prompt("Page: \(pageTitle ?? "")\nSource: \(source)\nFile: \(suggested)", ask:
            #"Return JSON {"stem":"descriptive-file-name"}. Use at most six lowercase words joined by hyphens. No extension, paths or invented details."#, limit: 1000)
        guard let stem = await reply(Stem.self, feature: .downloads, isPrivate: isPrivate, prompt: prompt, tokens: 512)?.stem else { return nil }
        return AppleAI.safeFilename(stem, extension: (suggested as NSString).pathExtension)
    }

    static func group(_ tabs: [(id: String, title: String, host: String)], isPrivate: Bool = false) async -> [(name: String, ids: [String])]? {
        guard !isPrivate else { return nil }
        if state.connection(for: .tabGroups) == nil { return await localReply(feature: .tabGroups) { await AppleAI.group(tabs) } }
        guard AppleAI.worthGrouping(tabs.count) else { return nil }
        struct Groups: Decodable {
            struct Group: Decodable { let name: String; let tabs: [Int] }
            let groups: [Group]
        }
        let shown = Array(tabs.prefix(60))
        let prompt = AppleAI.prompt(AppleAI.listing(shown), ask:
            #"Return JSON {"groups":[{"name":"Topic","tabs":[1,2]}]}. Create two to six useful topic groups, with one to three words per name. Assign every numbered tab exactly once."#, limit: 8000)
        guard let answer = await reply(Groups.self, feature: .tabGroups, isPrivate: isPrivate, prompt: prompt, tokens: 2048) else { return nil }
        return AppleAI.tidyGroups(answer.groups.map { ($0.name, $0.tabs) }, ids: shown.map(\.id))
    }
    static func summarizeStream(_ text: String, sentences: Int = 3, isPrivate: Bool = false) -> AsyncStream<String> {
        let revision = revision
        let local = state.connection(for: .summaries) == nil
        guard enabled, ready(for: .summaries), local || !isPrivate else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let work = Task {
            defer { continuation.finish() }
            guard !Task.isCancelled, enabled, revision == self.revision else { return }
            if local {
                for await element in AppleAI.summarizeStream(text, sentences: sentences) {
                    guard !Task.isCancelled, enabled, revision == self.revision else { continuation.yield(""); return }
                    continuation.yield(element)
                }
            } else {
                let n = min(max(sentences, 1), 8)
                guard let body = AppleAI.payload(text) else { return }
                struct Summary: Decodable { let text: String }
                let prompt = AppleAI.prompt(body, ask: "Return JSON {\"text\":\"summary\"}. Summarize the page text in exactly \(n) sentences.")
                guard let answer = await reply(Summary.self, feature: .summaries, isPrivate: isPrivate, prompt: prompt, tokens: 512)?.text,
                      revision == self.revision, !Task.isCancelled,
                      AppleAI.plausibleSummary(answer, sentences: n, of: body) else { return }
                continuation.yield(answer)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }
}
