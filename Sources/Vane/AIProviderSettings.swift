import AppKit
import SwiftUI

struct AIProviderSettings: View {
    @AppStorage("aiSettingsRevision") private var revision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = AIConnections()
    @State private var selected: UUID?
    @State private var feedback = ""
    private var animation: Animation? { reduceMotion || Motion.reduced ? nil : Look.quick }

    var body: some View {
        SettingsCard {
            SettingsRow("AI connections") {
                HStack {
                    if !state.connections.isEmpty {
                        Picker("Saved AI connection", selection: $selected) {
                            ForEach(state.connections) { connection in
                                Text(connection.name).tag(Optional(connection.id))
                            }
                        }.labelsHidden().frame(width: 220)
                    }
                    Menu("Add Connection") {
                        ForEach(AIProvider.allCases.filter { $0 != .apple }, id: \.rawValue) { provider in
                            Button(provider.title) { add(provider) }
                        }
                    }.fixedSize()
                }
            }
            if !feedback.isEmpty { Footnote(feedback) }
            if let id = selected, let connection = state.connections.first(where: { $0.id == id }) {
                AIConnectionEditor(connection: Binding(get: {
                    state.connections.first(where: { $0.id == id }) ?? connection
                }, set: { updated in
                    var latest = BrowserAI.state
                    latest.update(updated); BrowserAI.save(latest); state = latest
                }), remove: { message in remove(connection, message: message) })
                .id(id)
            } else {
                Footnote("Apple's on-device model needs no account or key. Add ChatGPT or an API-key connection to use cloud AI, then choose which features use it below.")
            }
        }
        SettingsCard {
            ForEach(AIFeature.allCases, id: \.rawValue) { feature in
                SettingsRow(feature.title) {
                    Picker(feature.title + " connection", selection: route(feature)) {
                        Text(AIProvider.apple.title).tag(Optional<UUID>.none)
                        ForEach(state.connections) { connection in
                            Text(connection.name).tag(Optional(connection.id))
                        }
                    }.labelsHidden().frame(width: 270)
                }
                if let reason = BrowserAI.unavailableReason(for: feature) {
                    Footnote(feature.title + ": " + reason)
                }
            }
            Footnote("Each feature uses only its selected connection. Cloud naming sends titles, hostnames and download naming details; choosing cloud page summaries also sends extracted page text when a link preview summarizes a page. Cloud AI is never used in private windows. API keys use local Keychain originals, with optional API-key sync in Settings → iCloud. ChatGPT tokens stay on this Mac. Provider pricing and quotas apply.")
        }
        .onAppear { reload() }
        .onChange(of: revision) { reload() }
        .animation(animation, value: state.connections.map(\.id))
        .animation(animation, value: selected)
    }
    private func reload() {
        state = BrowserAI.state
        if !state.connections.contains(where: { $0.id == selected }) { selected = state.connections.first?.id }
    }
    private func route(_ feature: AIFeature) -> Binding<UUID?> {
        Binding(get: { state.connection(for: feature)?.id }, set: { id in
            var next = BrowserAI.state; next.route(feature, to: id); BrowserAI.save(next); state = next
        })
    }
    private func add(_ provider: AIProvider) {
        var next = BrowserAI.state
        var connection = AIConnection(provider: provider)
        var suffix = 2
        while next.connections.contains(where: { $0.name == connection.name }) {
            connection.name = provider.title + " \(suffix)"; suffix += 1
        }
        next.connections.append(connection); BrowserAI.save(next)
        state = next; selected = connection.id
    }
    private func remove(_ connection: AIConnection, message: String?) -> Bool {
        guard BrowserAI.remove(connection) else { return false }
        feedback = message ?? "Connection removed. Its features now use Apple on-device AI."
        reload(); return true
    }
}

private struct AIConnectionEditor: View {
    @Binding var connection: AIConnection
    var remove: (String?) -> Bool
    @State private var key = ""
    @State private var status = ""
    @State private var busy = false
    @State private var models: [ChatGPTResponses.Model] = []
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var signIn: ChatGPTSignIn?
    private var saved: Bool { BrowserAI.hasKey(connection) }

    var body: some View {
        SettingsRow("Connection name") {
            TextField("Connection name", text: $connection.name).textFieldStyle(.roundedBorder).frame(width: 270)
                .accessibilityLabel("AI connection name").disabled(busy)
        }
        if connection.provider == .custom {
            SettingsRow("API base URL") {
                // Swift 6.3 crashes in IRGen when the isolated setter is a method reference.
                TextField("https://api.example.com/v1", text: Binding(
                    get: { connection.baseURL }, set: { value in changeEndpoint(value) }))
                    .textFieldStyle(.roundedBorder).frame(width: 270).accessibilityLabel("API base URL").disabled(busy)
            }
        }
        if connection.provider == .chatGPT {
            SettingsRow("ChatGPT account") {
                HStack {
                    if let registration = connection.registration {
                        Text(registration.email ?? "Connected ChatGPT account").font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                    }
                    Button(connection.registration == nil ? "Continue with ChatGPT" : "Reconnect with ChatGPT") { connect() }.disabled(busy)
                }
            }
            SettingsRow("Model") {
                HStack {
                    Picker("ChatGPT model", selection: $connection.model) {
                        Text("Choose a model").tag("")
                        if !connection.model.isEmpty, !models.contains(where: { $0.slug == connection.model }) {
                            Text(connection.model).tag(connection.model)
                        }
                        ForEach(models) { model in Text(model.display_name).tag(model.slug) }
                    }.labelsHidden().frame(width: 190).disabled(busy || models.isEmpty)
                    Button("Refresh Models") { refreshModels() }.disabled(busy || !saved)
                }
            }
            Footnote("Use your eligible ChatGPT plan. Authorize plan usage in the browser and select a model available to this account. ChatGPT limits apply; Vane never switches to a paid API key automatically.")
            SettingsRow("ChatGPT usage") {
                Button("Manage Usage…") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
            }
        } else {
            SettingsRow("Model") {
                TextField("Model ID", text: $connection.model).textFieldStyle(.roundedBorder).frame(width: 270)
                    .accessibilityLabel("AI model").disabled(busy)
            }
            SettingsRow("Your API key") {
                SecureField(saved ? "Saved in Keychain" : "Paste your API key", text: $key)
                    .textFieldStyle(.roundedBorder).frame(width: 270).accessibilityLabel("Your API key").disabled(busy)
            }
        }
        SettingsRow("Connection") {
            HStack {
                if connection.provider != .chatGPT {
                    Button("Save Key") {
                        if BrowserAI.saveKey(key, for: connection) { key = ""; status = "Saved in this Mac's Keychain." }
                        else { status = "Could not save this key. Check the key and Keychain access." }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if saved {
                        Button("Remove Key") {
                            status = BrowserAI.removeKey(connection) ? "API key removed." : "Could not remove the key from Keychain."
                        }
                    }
                } else if saved {
                    Button("Sign Out") { signOut() }
                }
                Button("Test Connection") { test() }.disabled(BrowserAI.unavailableReason(connection) != nil)

            }.disabled(busy)
            if busy {
                ProgressView().controlSize(.small)
                Button("Cancel") { cancel(); status = "Cancelled." }
            }
        }
        SettingsRow("Saved connection") {
            Button("Remove Connection", role: .destructive) { delete() }.disabled(busy)
        }
        if !status.isEmpty { Footnote(status).accessibilityLabel(status) }
        if connection.provider == .groq {
            SettingsRow("Free Groq account") {
                Button("Get an API Key…") { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }
            }
        }
        // Cancel an account-specific attempt when the editor changes or settings closes.
        Color.clear.frame(height: 0)
            .onAppear { if connection.provider == .chatGPT, saved { refreshModels() } }
            .onDisappear { cancel() }
    }
    private func changeEndpoint(_ value: String) {
        guard value != connection.baseURL else { return }
        // Editing a destination never forwards a previously saved key to the new endpoint.
        if saved, !BrowserAI.removeKey(connection) { status = "Remove the saved key before changing its destination."; return }
        key = ""; connection.baseURL = value; status = "Save the key for this API endpoint."
    }
    private func cancel() { operationID = UUID(); task?.cancel(); task = nil; signIn?.cancel(); signIn = nil; busy = false }
    private func perform(_ action: @escaping @MainActor () async throws -> String) {
        let id = UUID(); operationID = id
        busy = true; status = "Connecting…"
        task = Task { @MainActor in
            defer { if operationID == id { busy = false } }
            do {
                let message = try await action()
                guard !Task.isCancelled, operationID == id else { return }
                status = message
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                status = (error as? ChatGPTFailure)?.localizedDescription ?? "Could not connect to ChatGPT. Try again."
            }
        }
    }
    private func connect() {
        let original = connection
        let attempt = ChatGPTSignIn(); signIn = attempt
        perform {
            let (registration, credentials) = try await attempt.run(connection: original, hostID: BrowserAI.hostID,
                                                                    hint: BrowserAI.credentials(original)?.idToken)
            try Task.checkCancellation()
            guard BrowserAI.commitSignIn(original, registration: registration, credentials: credentials) else { throw ChatGPTFailure.storage }
            guard credentials.permitsPlan else { return ChatGPTFailure.planDisabled.localizedDescription }
            let saved = BrowserAI.state.connections.first { $0.id == original.id }!
            let catalog = try await BrowserAI.models(saved)
            try Task.checkCancellation()
            models = catalog
            return "ChatGPT connected. Choose a model, then assign features to this connection."
        }
    }
    private func refreshModels() {
        let original = connection
        perform {
            let catalog = try await BrowserAI.models(original)
            try Task.checkCancellation()
            guard BrowserAI.state.connections.first(where: { $0.id == original.id }) == original else { throw CancellationError() }
            models = catalog
            return catalog.isEmpty ? "No models are available for this account." : "Models refreshed."
        }
    }
    private func test() {
        let original = connection
        perform { await BrowserAI.testConnection(original) }
    }
    private func signOut() {
        let original = connection
        perform {
            let revoked = try await BrowserAI.signOut(original)
            try Task.checkCancellation()
            models = []
            return revoked ? "Signed out of ChatGPT." : "Signed out locally. Remote revocation could not be confirmed; disconnect Vane in ChatGPT Settings."
        }
    }
    private func delete() {
        if connection.provider == .chatGPT, saved {
            let original = connection
            perform {
                let revoked = try await BrowserAI.signOut(original)
                try Task.checkCancellation()
                guard remove(revoked ? nil : "Connection removed locally. Remote revocation could not be confirmed; disconnect Vane in ChatGPT Settings.") else { throw ChatGPTFailure.storage }
                return "Connection removed."
            }
        } else {
            if !remove(nil) { status = "Could not remove the connection's key from Keychain." }
        }
    }
}
