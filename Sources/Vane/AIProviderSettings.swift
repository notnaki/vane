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
        VStack(spacing: 16) {
            AIConnectionCard {
                HStack(spacing: 10) {
                    AIConnectionBadge(provider: selectedConnection?.provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedConnection?.name ?? "Add your first connection")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(selectedConnection == nil ? "Apple on-device AI needs no account or key." : "Saved connection")
                            .font(.system(size: 11)).foregroundStyle(Look.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !state.connections.isEmpty {
                        Picker("Saved AI connection", selection: $selected) {
                            ForEach(state.connections) { connection in
                                Text(connection.name).tag(Optional(connection.id))
                            }
                        }.labelsHidden().frame(maxWidth: 150)
                    }
                    Menu {
                        ForEach(AIProvider.allCases.filter { $0 != .apple }, id: \.rawValue) { provider in
                            Button(provider.title) { add(provider) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize().accessibilityLabel("Add AI connection")
                }
                .padding(14)
                .background(AIConnectionLook.plum)

                if !feedback.isEmpty { AIConnectionNote(feedback) }
                if let id = selected, let connection = selectedConnection {
                    AIConnectionEditor(connection: Binding(get: {
                        state.connections.first(where: { $0.id == id }) ?? connection
                    }, set: { updated in
                        var latest = BrowserAI.state
                        latest.update(updated); BrowserAI.save(latest); state = latest
                    }), remove: { message in remove(connection, message: message) })
                    .id(id)
                } else {
                    AIConnectionNote("Add ChatGPT or an API-key connection to use cloud AI, then choose which features use it below.")
                }
            }
            AIConnectionCard {
                Text("Feature connections")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Hairline().padding(.horizontal, 14)
                ForEach(AIFeature.allCases, id: \.rawValue) { feature in
                    AIConnectionRow(feature.title) {
                        Picker(feature.title + " connection", selection: route(feature)) {
                            Text(AIProvider.apple.title).tag(Optional<UUID>.none)
                            ForEach(state.connections) { connection in
                                Text(connection.name).tag(Optional(connection.id))
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let reason = BrowserAI.unavailableReason(for: feature) {
                        AIConnectionNote(feature.title + ": " + reason)
                    }
                }
                DisclosureGroup("Privacy and provider details") {
                    Text("Each feature uses only its selected connection. Cloud naming sends titles, hostnames and download naming details; choosing cloud page summaries also sends extracted page text when a link preview summarizes a page. Cloud AI is never used in private windows. Keys and ChatGPT tokens stay in this Mac's Keychain. Provider pricing and quotas apply.")
                        .font(.system(size: 12)).foregroundStyle(Look.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .font(.system(size: 12)).padding(14)
            }
        }
        .tint(.primary)
        .onAppear { reload() }
        .onChange(of: revision) { reload() }
        .animation(animation, value: state.connections.map(\.id))
        .animation(animation, value: selected)
    }
    private var selectedConnection: AIConnection? {
        state.connections.first { $0.id == selected }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key = ""
    @State private var status = ""
    @State private var busy = false
    @State private var models: [ChatGPTResponses.Model] = []
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var signIn: ChatGPTSignIn?
    private var saved: Bool { BrowserAI.hasKey(connection) }

    var body: some View {
        VStack(spacing: 0) {
            AIConnectionRow("Connection name") {
                TextField("Connection name", text: $connection.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("AI connection name").disabled(busy)
            }
            if connection.provider == .custom {
                AIConnectionRow("API base URL") {
                    // Swift 6.3 crashes in IRGen when the isolated setter is a method reference.
                    TextField("https://api.example.com/v1", text: Binding(
                        get: { connection.baseURL }, set: { value in changeEndpoint(value) }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("API base URL").disabled(busy)
                }
            }
            if connection.provider == .chatGPT {
                AIConnectionRow("ChatGPT account") {
                    VStack(alignment: .trailing, spacing: 8) {
                        if let registration = connection.registration {
                            Text(registration.email ?? "Connected ChatGPT account")
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                        Button(connection.registration == nil ? "Continue with ChatGPT" : "Reconnect with ChatGPT") { connect() }
                            .disabled(busy)
                    }
                }
                AIConnectionRow("Model") {
                    HStack(spacing: 8) {
                        Picker("ChatGPT model", selection: $connection.model) {
                            Text("Choose a model").tag("")
                            if !connection.model.isEmpty, !models.contains(where: { $0.slug == connection.model }) {
                                Text(connection.model).tag(connection.model)
                            }
                            ForEach(models) { model in Text(model.display_name).tag(model.slug) }
                        }.labelsHidden().disabled(busy || models.isEmpty)
                        Button("Refresh Models", systemImage: "arrow.clockwise") { refreshModels() }
                            .labelStyle(.iconOnly).help("Refresh Models").disabled(busy || !saved)
                    }
                }
                AIConnectionNote("Use your eligible ChatGPT plan. Authorize plan usage in the browser and select a model available to this account. ChatGPT limits apply; Vane never switches to a paid API key automatically.")
                AIConnectionRow("ChatGPT usage") {
                    Button("Manage Usage…") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
                }
            } else {
                AIConnectionRow("Model") {
                    TextField("Model ID", text: $connection.model).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("AI model").disabled(busy)
                }
                AIConnectionRow("API key") {
                    VStack(alignment: .trailing, spacing: 8) {
                        SecureField(saved ? "Saved in Keychain" : "Paste your API key", text: $key)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Your API key").disabled(busy)
                        if !key.isEmpty {
                            Button("Save Key") {
                                if BrowserAI.saveKey(key, for: connection) { key = ""; status = "Saved in this Mac's Keychain." }
                                else { status = "Could not save this key. Check the key and Keychain access." }
                            }.disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label(saved ? "Saved in this Mac's Keychain" : "No saved credentials",
                          systemImage: saved ? "lock" : "key")
                        .font(.system(size: 11)).foregroundStyle(Look.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Test Connection") { test() }
                        .buttonStyle(.borderedProminent)
                        .tint(AIConnectionLook.cobalt)
                        .foregroundStyle(.white)
                        .disabled(busy || BrowserAI.unavailableReason(connection) != nil)
                    Menu {
                        if saved {
                            if connection.provider == .chatGPT {
                                Button("Sign Out") { signOut() }
                            } else {
                                Button("Remove Key", role: .destructive) {
                                    status = BrowserAI.removeKey(connection) ? "API key removed." : "Could not remove the key from Keychain."
                                }
                            }
                        }
                        Button("Remove Connection", role: .destructive) { delete() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden).fixedSize().disabled(busy)
                    .accessibilityLabel("More connection actions")
                }
                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Spacer()
                        Button("Cancel") { cancel(); status = "Cancelled." }
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.system(size: 12)).foregroundStyle(Look.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel(status)
                }
            }
            .padding(14)
            if connection.provider == .groq {
                Hairline().padding(.horizontal, 14)
                AIConnectionRow("Free Groq account", divided: false) {
                    Button("Get an API Key…") { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }
                }
            }
        }
        .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: busy)
        .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: key.isEmpty)
        // Changing the selected account cancels its in-flight operation.
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

// Keep this treatment local: Settings and onboarding share the same connection controls.
private enum AIConnectionLook {
    static let cobalt = Color(red: 0.33, green: 0.28, blue: 1)
    static let plum = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.19, green: 0.17, blue: 0.27, alpha: 1)
            : NSColor(srgbRed: 0.93, green: 0.91, blue: 0.98, alpha: 1)
    })
    static let peach = Color(red: 1, green: 0.76, blue: 0.65)
    static let peachInk = Color(red: 0.4, green: 0.22, blue: 0.12)
}

private struct AIConnectionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .foregroundStyle(Look.inkPrimary)
            .background(Look.cardFill, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .hairline(radius: 12, Look.cardStroke)
    }
}

private struct AIConnectionBadge: View {
    let provider: AIProvider?
    var body: some View {
        Group {
            if let provider {
                Text(String(provider.title.prefix(1))).font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AIConnectionLook.peachInk)
            } else {
                Image(systemName: "link").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AIConnectionLook.peachInk)
            }
        }
        .frame(width: 32, height: 32)
        .background(AIConnectionLook.peach, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

private struct AIConnectionRow<Content: View>: View {
    let title: String
    var divided = true
    @ViewBuilder var content: Content
    init(_ title: String, divided: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; self.divided = divided; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(title).font(.system(size: 12)).foregroundStyle(Look.inkSecondary)
                    .frame(width: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                content.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14).frame(minHeight: 48)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
            if divided { Hairline().padding(.horizontal, 14) }
        }
    }
}

private struct AIConnectionNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Look.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }
}
