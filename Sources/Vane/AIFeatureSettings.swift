import SwiftUI

/// The same controls in Settings and onboarding; one master opt-in gates inference.
struct AIFeatureSettings: View {
    @AppStorage("appleAI", store: .vane) private var enabled = false
    @AppStorage("tidyTabs", store: .vane) private var tabs = true
    @AppStorage("tidyPreview", store: .vane) private var preview = true
    @AppStorage("tidyDownloads", store: .vane) private var downloads = false
    @AppStorage("tidyTitles", store: .vane) private var titles = true
    @AppStorage("aiSettingsRevision", store: .vane) private var revision = 0

    private func unavailable(_ feature: AIFeature) -> Bool {
        _ = revision
        return !enabled || !BrowserAI.ready(for: feature)
    }

    var body: some View {
        SettingsCard {
            SettingsRow("AI features") {
                Toggle("AI features", isOn: BrowserAI.enabledBinding).labelsHidden()
            }
            SettingsRow("Group tabs by topic") {
                Toggle("Group tabs by topic", isOn: $tabs).labelsHidden().disabled(unavailable(.tabGroups))
            }
            SettingsRow("Preview before tidying") {
                Toggle("Preview before tidying", isOn: $preview).labelsHidden()
            }
            Footnote("Turn off to apply Tidy groups immediately. You can undo the grouping afterward.")
            SettingsRow("Rename messy downloads") {
                Toggle("Rename messy downloads", isOn: $downloads).labelsHidden().disabled(unavailable(.downloads))
            }
            SettingsRow("Rename favorite and pinned tab titles") {
                Toggle("Rename favorite and pinned tab titles", isOn: $titles).labelsHidden().disabled(unavailable(.tabTitles))
            }
            Footnote(!enabled ? "AI is off. Browsing works without it."
                : "Each feature uses its selected AI connection. Grouping runs when you choose Tidy Tabs.")
        }
    }
}

struct OnboardingAIChoices: View {
    @AppStorage("appleAI", store: .vane) private var enabled = false
    var body: some View {
        VStack(spacing: 16) {
            AIFeatureSettings()
            if enabled {
                AIProviderSettings()
                    .defaultAppStorage(.vane)
                Text("Apple Intelligence runs on this Mac. ChatGPT and API-key connections send task data to the service selected for each feature. Cloud page summaries also send extracted page text.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .background(Color(white: 0.09), in: .rect(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Look.inkPrimary)
    }
}
