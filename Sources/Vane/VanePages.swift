import AppKit
import Combine
import SwiftUI

// MARK: - Addresses

/// The settings sections a vane://settings tab can show, in Chromium's nav order. The last
/// two are Arc's arc://settings/clearBrowserData and its site-data page: Privacy and
/// Security with that dialog already open over it.
enum VaneSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case passwords, privacy, search, clearBrowserData, siteData

    var id: String { rawValue }
    /// The sections with a row of their own in the page's left nav.
    static let navigable: [VaneSettingsSection] = [.passwords, .privacy, .search]
    /// The pane that draws it.
    var pane: VaneSettingsSection { self == .clearBrowserData || self == .siteData ? .privacy : self }
    var privacyRequest: SettingsSelection.PrivacyRequest? {
        switch self {
        case .clearBrowserData: .clearData
        case .siteData: .websiteData
        default: nil
        }
    }
    var title: String {
        switch self {
        case .passwords: "Passwords"
        case .privacy, .clearBrowserData, .siteData: "Privacy and Security"
        case .search: "Search Engines"
        }
    }
    var icon: String {
        switch self {
        case .passwords: "key.fill"
        case .privacy, .clearBrowserData, .siteData: "lock.fill"
        case .search: "magnifyingglass"
        }
    }
    /// Search preferences are app-wide; every other section belongs to one profile.
    var perProfile: Bool { pane != .search }

    nonisolated init?(path: String) {
        let match = Self.allCases.first { $0.rawValue.lowercased() == path.lowercased() }
        guard let match else { return nil }
        self = match
    }
}

/// vane://settings[/section] and vane://extensions: Vane's own pages, in an ordinary tab.
/// Like an Easel they are drawn natively and never reach WebKit or the history database.
/// Unlike an Easel's, the address carries no profile: which profile's data a page shows is
/// chosen in the page and lives only as long as the tab does.
enum VanePage: Equatable, Sendable {
    case settings(VaneSettingsSection)
    case extensions

    enum Kind: Equatable, Sendable { case settings, extensions }
    var kind: Kind { if case .extensions = self { .extensions } else { .settings } }

    /// Strict, like `EaselAddress`: no credentials, port, query or fragment, and at most one
    /// path component. An unknown settings section opens the first one, as Chromium does.
    nonisolated init?(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "vane",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "settings"?:
            guard parts.count <= 1 else { return nil }
            self = .settings(parts.first.flatMap(VaneSettingsSection.init(path:)) ?? .passwords)
        case "extensions"?:
            guard parts.isEmpty else { return nil }
            self = .extensions
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .settings(let section): URL(string: "vane://settings/\(section.pane.rawValue)")!
        case .extensions: URL(string: "vane://extensions")!
        }
    }
    var title: String { kind == .settings ? "Settings" : "Extensions" }
    var icon: String { kind == .settings ? "gearshape" : "puzzlepiece.extension" }

    /// Who is asking. Typed addresses, the command bar, menus, Settings and Vane's own saved
    /// session are `.app`; anything a page can put a URL into — a link, a redirect, a
    /// `window.open`, a dragged or context-menu link, an extension — is `.web`.
    enum Origin: Sendable { case app, web }
    enum Route: Equatable, Sendable {
        case page(VanePage)
        /// An internal page the asker may not open. Dropped without loading anything.
        case refuse
        case notInternal
    }

    nonisolated static func route(_ url: URL, from origin: Origin) -> Route {
        guard let page = VanePage(url) else { return .notInternal }
        return origin == .app ? .page(page) : .refuse
    }

    /// What the command bar offers for `vane://` and for the sections' names.
    static let catalog: [(title: String, page: VanePage)] = [
        ("Passwords", .settings(.passwords)),
        ("Privacy and Security", .settings(.privacy)),
        ("Search Engines", .settings(.search)),
        ("Extensions", .extensions),
    ]
}

// MARK: - The tab's model

/// What one internal-page tab is showing. `selection` is the Settings window's own model,
/// so the reused panes navigate exactly as they do there: Privacy's Passwords row sets
/// `selection.id`, and this tab follows.
@MainActor final class VanePageSession: ObservableObject {
    let kind: VanePage.Kind
    let selection = SettingsSelection()

    init(_ page: VanePage, profileID: UUID) {
        kind = page.kind
        selection.profileID = profileID
        show(page, profileID: nil)
    }

    func show(_ page: VanePage, profileID: UUID?) {
        if let profileID { selection.profileID = profileID }
        guard case .settings(let section) = page else { return }
        if selection.id != section.pane.rawValue { selection.id = section.pane.rawValue }
        selection.privacyRequest = section.privacyRequest
    }

    var section: VaneSettingsSection? {
        guard kind == .settings else { return nil }
        return VaneSettingsSection(rawValue: selection.id).map(\.pane) ?? .passwords
    }
    var page: VanePage { section.map(VanePage.settings) ?? .extensions }
    var url: URL { page.url }
}

// MARK: - Opening one

@MainActor enum VanePages {
    /// Focus this window's tab of that kind, or open one, showing `profileID`'s data.
    ///
    /// Always an ordinary browser window: `source` when it is one, else the frontmost, else
    /// a new window for the active profile. Never a private window or a Little Vane — an
    /// internal page shows and edits saved profile data, which a private window must not
    /// hold, so from there it opens in the ordinary window behind it. A profile that is
    /// not a saved one (the incognito profile) falls back to that window's own.
    @discardableResult
    static func open(_ page: VanePage, profileID: UUID? = nil, from source: TabStore? = nil) -> Tab? {
        guard !AppLifecycle.shared.persistenceExitInProgress else { return nil }
        let store = source.flatMap { ordinary($0) ? $0 : nil } ?? frontmost
            ?? Windows.open(profile: ProfileManager.shared.active)
        let shown = profileID.flatMap { id in ProfileManager.shared.profiles.first { $0.id == id }?.id }
        let tab = store.tabs.first { $0.vanePage?.kind == page.kind }
            ?? store.newBlankTab(focus: false)
        guard tab.routeVanePage(page, profileID: shown) else { return nil }
        store.libraryOpen = false
        store.palette = nil
        store.findOpen = false
        store.current = tab.id
        if let window = store.window, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        store.focusPage()
        return tab
    }

    private static func ordinary(_ store: TabStore) -> Bool {
        !store.isPrivate && !store.isLittle && !store.isParked && store.window != nil
    }

    private static var frontmost: TabStore? {
        let candidates = TabStore.all.filter(ordinary)
        return candidates.first { $0.window?.isKeyWindow == true } ?? candidates.last
    }

    /// The window a tab is in, for callers that only hold the tab.
    static func store(of tab: Tab) -> TabStore? {
        TabStore.all.first { $0.window != nil && !$0.isParked && $0.everyTab.contains { $0 === tab } }
    }

    /// The Passwords lock counts activity in, and may prompt over, a window whose page is
    /// vane://settings/passwords — as it does for the Settings window.
    static func showsPasswords(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return TabStore.all.contains {
            $0.window === window && $0.active?.vanePage?.section == .passwords && $0.active?.suspended == false
        }
    }

    /// The profile a page should show when the choice is absent or no longer exists.
    static func profile(_ id: UUID?, fallback: UUID) -> Profile {
        let profiles = ProfileManager.shared.profiles
        return profiles.first { $0.id == id } ?? profiles.first { $0.id == fallback } ?? ProfileManager.shared.active
    }

    // MARK: check

    static func check() -> [(String, Bool)] {
        func url(_ s: String) -> URL { URL(string: s)! }
        let settings = url("vane://settings"), extensions = url("vane://extensions")
        return [
            ("vane://settings opens the first section", VanePage(settings) == .settings(.passwords)),
            ("a section is read from the path", VanePage(url("vane://settings/privacy")) == .settings(.privacy)
                && VanePage(url("vane://settings/search")) == .settings(.search)
                && VanePage(url("vane://Settings/Passwords")) == .settings(.passwords)),
            ("an unknown section opens the first one", VanePage(url("vane://settings/nope")) == .settings(.passwords)),
            ("clear browsing data is Privacy with its dialog",
             VanePage(url("vane://settings/clearBrowserData")) == .settings(.clearBrowserData)
                && VaneSettingsSection.clearBrowserData.pane == .privacy
                && VaneSettingsSection.clearBrowserData.privacyRequest == .clearData
                && VanePage.settings(.siteData).url.absoluteString == "vane://settings/privacy"),
            ("vane://extensions is the extensions page", VanePage(extensions) == .extensions),
            ("addresses are canonical", VanePage.settings(.search).url.absoluteString == "vane://settings/search"
                && VanePage.extensions.url == extensions),
            ("query, fragment, port, credentials and deeper paths are refused",
             [url("vane://settings/passwords?profile=x"), url("vane://settings#passwords"),
              url("vane://settings:80"), url("vane://me@settings"), url("vane://settings/passwords/x"),
              url("vane://extensions/abc")].allSatisfy { VanePage($0) == nil }),
            ("other schemes and Vane's other addresses are not internal pages",
             [url("https://settings"), url("vane://easel/\(UUID().uuidString)"),
              url("vane://oauth/github")].allSatisfy { VanePage($0) == nil }),
            ("web content can never open an internal page",
             VanePage.route(settings, from: .web) == .refuse
                && VanePage.route(extensions, from: .web) == .refuse
                && VanePage.route(url("vane://settings/clearBrowserData"), from: .web) == .refuse),
            ("…and WebKit cancels every vane: navigation before that",
             ExternalApps.isOwn(settings.scheme) && ExternalApps.isOwn("VANE")),
            ("…and another app's GetURL event is refused", URLHandling.normalize("vane://settings") == nil),
            ("app code and typed addresses open them",
             VanePage.route(settings, from: .app) == .page(.settings(.passwords))
                && VanePage.route(extensions, from: .app) == .page(.extensions)),
            ("web addresses are not routed", VanePage.route(url("https://example.com"), from: .web) == .notInternal),
            ("the address bar resolves vane://settings to the page",
             VanePage(Search.url(for: "vane://settings/privacy")) == .settings(.privacy)
                && VanePage(Search.url(for: "  vane://extensions ")) == .extensions),
            ("typing a section's name searches rather than opening a page",
             VanePage(Search.url(for: "passwords")) == nil),
            ("internal pages restore after relaunch", TabAddress.restorable(settings)
                && TabAddress.restorable(url("vane://settings/search")) && TabAddress.restorable(extensions)),
            ("…but not malformed ones", !TabAddress.restorable(url("vane://settings/passwords?x=1"))),
            ("search settings are app-wide; the rest follow the profile menu",
             !VaneSettingsSection.search.perProfile && VaneSettingsSection.passwords.perProfile
                && VaneSettingsSection.siteData.perProfile),
            ("the command bar lists every section and extensions",
             Set(VanePage.catalog.map(\.page.url)) == Set(VaneSettingsSection.navigable.map { VanePage.settings($0).url }
                + [extensions])),
        ]
    }
}

// MARK: - The page

/// vane://settings and vane://extensions in a tab: Chromium's settings layout — a left nav
/// beside the section — built from the Settings window's own panes and pieces.
struct VanePageView: View {
    @ObservedObject var session: VanePageSession
    @ObservedObject private var selection: SettingsSelection
    @ObservedObject private var manager = ProfileManager.shared
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let store: TabStore

    init(session: VanePageSession, store: TabStore) {
        self.session = session
        self.store = store
        _selection = ObservedObject(wrappedValue: session.selection)
    }

    private var profile: Profile { VanePages.profile(selection.profileID, fallback: store.profileID) }
    private var section: VaneSettingsSection { session.section ?? .passwords }

    var body: some View {
        Group {
            switch session.kind {
            case .settings: settings
            case .extensions: extensions
            }
        }
        .font(Look.text)
        .defaultAppStorage(.vane)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.windowBackground)
        .vaneMotionPolicy()
    }

    // MARK: settings

    private var settings: some View {
        HStack(spacing: 0) {
            nav.frame(width: 232)
            Rectangle().fill(Look.hairline).frame(width: 1)
            content
        }
        .toggleStyle(SettingsToggleStyle())
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: Look.listRowGap) {
            Text("Settings").font(Look.heading).foregroundStyle(Look.inkPrimary)
                .padding(.horizontal, Look.inset).padding(.bottom, Look.inset)
            ForEach(VaneSettingsSection.navigable) { item in
                navRow(item.title, icon: item.icon, selected: item == section) {
                    Motion.animate(Look.quick) { selection.id = item.rawValue }
                }
            }
            Hairline().padding(.vertical, Look.inset)
            navRow("Extensions", icon: "puzzlepiece.extension.fill", selected: false, external: true) {
                VanePages.open(.extensions, profileID: profile.id, from: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.inset)
        .padding(.top, Look.inset * 3)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func navRow(_ title: String, icon: String, selected: Bool, external: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Look.inset) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(selected ? Color.accentColor : Look.inkSecondary)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if external {
                    Image(systemName: "arrow.up.right").font(Look.caption).foregroundStyle(Look.inkSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Look.inset)
            .frame(height: Look.listRow)
            .background(selected ? chromeTheme.accentSelected : .clear, in: .rect(cornerRadius: Look.chipRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(external ? "\(title), opens in a new tab" : title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 64).padding(.top, Look.inset * 3)
            Group {
                if section == .passwords {
                    // It owns a bounded scrolling list, as it does in the Settings window.
                    pane
                } else {
                    ScrollView { pane }
                }
            }
            .id(section)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.reduced ? nil : Look.quick, value: section)
    }

    @ViewBuilder private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            case .passwords:
                PasswordsPane(settingsProfileID: profile.id)
                    // Leaving the section, the tab or the window is this page's "closing
                    // Settings": the list locks, so coming back asks again.
                    .onDisappear { PasswordPaneLock.shared.lock() }
            case .search: SearchPane()
            default: PrivacyPane(selection: selection)
            }
        }
        // PrivacyPane falls back to the active profile for an unknown id, the header to this
        // window's: keep them on the same, resolved profile (e.g. after a profile is deleted).
        .task(id: profile.id) { if selection.profileID != profile.id { selection.profileID = profile.id } }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 64)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: Look.inset) {
            Text(section.title).font(Look.heading).foregroundStyle(Look.inkPrimary)
            if section.perProfile {
                Text("·").foregroundStyle(Look.inkSecondary).accessibilityHidden(true)
                profileMenu
            } else {
                Text("· All profiles").foregroundStyle(Look.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Look.listRow)
    }

    // MARK: extensions

    /// Only a profile whose extensions are already running is managed here: creating a host
    /// starts every enabled extension against that profile's data, which picking a name in
    /// a menu must not do.
    @ViewBuilder private var extensions: some View {
        if let host = ExtensionHost.running(for: profile.id) {
            ExtensionManagementView(host: host, inTab: true, profileMenu: AnyView(profileMenu))
                .id(profile.id)
        } else {
            VStack(alignment: .leading, spacing: Look.inset) {
                HStack(spacing: Look.inset) {
                    Text("Extensions").font(Look.heading).foregroundStyle(Look.inkPrimary)
                    Text("·").foregroundStyle(Look.inkSecondary).accessibilityHidden(true)
                    profileMenu
                }
                Text("Extensions for \(profile.name) start when a window uses this profile. Open one of its Spaces to manage them.")
                    .foregroundStyle(Look.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
        }
    }

    // MARK: the profile menu

    /// Every saved profile, Spaces or none. Choosing one changes this tab only.
    private var profileMenu: some View {
        Menu {
            ForEach(manager.profiles) { p in
                Button {
                    Motion.animate(Look.quick) { selection.profileID = p.id }
                } label: {
                    if p.id == profile.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            Text(profile.name).foregroundStyle(Look.inkPrimary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Profile: \(profile.name)")
        .help("Show this page for another profile. Only this tab changes.")
    }
}
