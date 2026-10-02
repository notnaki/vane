import AppKit
import SwiftUI

struct AIProviderSettings: View {
    @AppStorage("aiProvider") private var selected = AIProvider.apple.rawValue
    @AppStorage("aiBaseURL") private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var saved = false
    @State private var status = ""
    @State private var testing = false

    private var provider: AIProvider { AIProvider(rawValue: selected) ?? .apple }

    var body: some View {
        SettingsCard {
            SettingsRow("AI provider") {
                Picker("AI provider", selection: $selected) {
                    ForEach(AIProvider.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 230)
            }
            if provider != .apple {
                if provider == .custom {
                    SettingsRow("API base URL") {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder).frame(width: 270)
                            .accessibilityLabel("API base URL")
                    }
                }
                SettingsRow("Model") {
                    TextField("Model ID", text: $model)
                        .textFieldStyle(.roundedBorder).frame(width: 270)
                        .accessibilityLabel("AI model")
                }
                SettingsRow("Your API key") {
                    SecureField(saved ? "Saved in Keychain" : "Paste your API key", text: $key)
                        .textFieldStyle(.roundedBorder).frame(width: 270)
                        .accessibilityLabel("Your API key")
                }
                SettingsRow("Connection") {
                    HStack {
                        if saved {
                            Button("Remove Key") {
                                if BrowserAI.removeKey() {
                                    key = ""; saved = false; status = "API key removed."
                                    BrowserAI.settingsChanged()
                                } else { status = "Could not remove the key from Keychain." }
                            }
                        }
                        Button("Save Key") {
                            if BrowserAI.saveKey(key) {
                                key = ""; saved = true; status = "Saved in this Mac's Keychain."
                                BrowserAI.settingsChanged()
                            } else { status = "Could not save this key. Check the key and Keychain access." }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(testing ? "Testing…" : "Test Connection") {
                            testing = true
                            status = "Testing…"
                            Task { @MainActor in
                                status = await BrowserAI.testConnection()
                                testing = false
                            }
                        }.disabled(!saved || testing)
                    }.disabled(testing)
                }
                if !status.isEmpty { Footnote(status).accessibilityLabel(status) }
                if provider == .groq {
                    SettingsRow("Free Groq account") {
                        Button("Get an API Key…") { NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!) }
                    }
                }
                Footnote("Each person supplies their own key. It stays in this Mac's Keychain and is sent only to the selected provider. Tab titles, hostnames, and download naming details go to that provider. Cloud AI is never used in private windows. Provider pricing and quotas apply; page summaries stay on-device.")
            } else {
                Footnote(AppleAI.unavailableReason ?? "Apple's model runs on this Mac. No account or API key is needed.")
            }
        }
        .onAppear { load() }
        .onChange(of: selected) { _, _ in
            load()
            BrowserAI.settingsChanged()
        }
        .onChange(of: model) { _, value in
            UserDefaults.vane.set(value, forKey: "aiModel." + provider.rawValue)
            status = ""
            BrowserAI.settingsChanged()
        }
        .onChange(of: baseURL) { _, _ in
            key = ""; saved = BrowserAI.hasKey; status = ""
            BrowserAI.settingsChanged()
        }
    }

    private func load() {
        model = BrowserAI.configuration.model
        key = ""
        saved = provider != .apple && BrowserAI.hasKey
        status = ""
    }
}
