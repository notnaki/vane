import SwiftUI

@main struct VaneApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environment(model.library).environment(model.browser).environment(model.sync)
                .task { await model.sync.run() }
                // Links from other apps, including when Vane is the default browser.
                .onOpenURL { url in
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                    model.browser.externalOpen = .now
                    model.browser.open(url)
                }
        }
        .onChange(of: phase) { _, phase in if phase == .active { model.browser.archiveIdle(); Task { await model.sync.run() } } }
    }
}

@MainActor final class AppModel {
    let library: Library
    let browser = Browser()
    let sync: Sync
    init() {
        let defaults = UserDefaults.standard
        let device = defaults.string(forKey: "icloud.deviceID") ?? UUID().uuidString
        defaults.set(device, forKey: "icloud.deviceID")
        library = Library(deviceID: device)
        library.deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        sync = Sync(library: library)
        let (library, browser, sync) = (library, browser, sync)
        if !library.spaces.contains(where: { $0.id == browser.spaceID }), let first = library.spaces.first { browser.switchSpace(first.id) }
        library.onEdit = { sync.soon() }
        browser.onVisit = { tab in
            if let profile = library.publishingProfile(for: tab.spaceID) { library.addVisit(tab.url, title: tab.title, profile: profile) }
        }
        browser.syncedHistory = { library.syncHistory ? library.syncedHistory : [] }
        browser.onTabsChanged = { sync.soon() }
        library.ownTabs = {
            browser.tabs.enumerated().compactMap { index, tab in
                guard ["http", "https"].contains(tab.url.scheme ?? ""), let profile = library.publishingProfile(for: tab.spaceID) else { return nil }
                let space = library.spaces.first { $0.id == tab.spaceID && !$0.isLocal }?.id
                return RemoteTab(id: "\(device)|\(profile)|\(tab.id.uuidString)", deviceID: device, deviceName: library.deviceName,
                                 profileID: profile, spaceID: space, url: tab.url, title: tab.title, position: index, at: nil)
            }
        }
    }
}
