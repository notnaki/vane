import SwiftUI

/// AppKit exposes this title to the Window menu, accessibility and other applications,
/// even though Vane hides the visual title bar. Keep private pages out of that boundary.
@MainActor enum WindowTitle {
    static let preferenceKey = "pageTitlesInWindows"

    static func current(in store: TabStore) -> String {
        text(in: store, tab: store.active, profile: store.profile,
             includePage: UserDefaults.vane.object(forKey: preferenceKey) as? Bool ?? true)
    }

    static func text(in store: TabStore, tab: Tab?, profile: Profile, includePage: Bool) -> String {
        let app = store.isLittle ? "Little Vane" : "Vane"
        guard !store.isPrivate else { return app + " — Incognito" }
        let page = includePage && tab?.currentURL != nil
            ? tab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        if store.isLittle { return page.isEmpty ? app : page }
        let named = profile.isDefault ? "" : " — " + profile.name
        return (page.isEmpty ? app : page + " — " + app) + named
    }
}

/// One title path for ordinary and Little Vane windows. The child observes only the
/// selected page, and its identity changes even when two selected pages have equal titles.
/// SwiftUI releases that observation when selection changes or the page closes.
struct WindowTitleSync: View {
    @EnvironmentObject private var store: TabStore
    @EnvironmentObject private var profiles: ProfileManager
    @AppStorage(WindowTitle.preferenceKey, store: .vane) private var includePage = true

    var body: some View {
        let profile = profiles.profiles.first { $0.id == store.profileID } ?? store.profile
        Group {
            if let tab = store.active {
                SelectedWindowTitleSync(tab: tab, profile: profile, includePage: includePage)
                    .id(tab.id)
            } else {
                WindowTitleValueSync(value: WindowTitle.text(in: store, tab: nil, profile: profile,
                                                            includePage: includePage), tabID: nil)
            }
        }
    }
}

private struct SelectedWindowTitleSync: View {
    @ObservedObject var tab: Tab
    let profile: Profile
    let includePage: Bool
    @EnvironmentObject private var store: TabStore

    var body: some View {
        WindowTitleValueSync(value: WindowTitle.text(in: store, tab: tab, profile: profile,
                                                    includePage: includePage), tabID: tab.id)
    }
}

private struct WindowTitleValueSync: View {
    let value: String
    let tabID: Tab.ID?
    @EnvironmentObject private var store: TabStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: value, initial: true) {
                // A departing tab's last queued update cannot rename its replacement.
                // Parked profiles have no window, so their cached hosts cannot write either.
                guard store.active?.id == tabID else { return }
                store.window?.title = value
            }
            .accessibilityHidden(true)
    }
}
