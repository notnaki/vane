import AppKit
import Combine
import SwiftUI

// MARK: - Addresses

/// The settings sections a vane://settings tab can show, in Chromium's nav order. Two are
/// Arc's arc://settings/clearBrowserData and its site-data page: Privacy and Security with
/// that dialog already open over it.
enum VaneSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case passwords, privacy, search, extensions, clearBrowserData, siteData

    var id: String { rawValue }
    /// The sections with a row of their own in the page's left nav.
    static let navigable: [VaneSettingsSection] = [.passwords, .privacy, .search, .extensions]
    /// The pane that draws it.
    var pane: VaneSettingsSection { self == .clearBrowserData || self == .siteData ? .privacy : self }
    var privacyRequest: SettingsSelection.PrivacyRequest? {
        switch self {
        case .clearBrowserData: .clearData
        case .siteData: .websiteData
        default: nil
        }
    }
    /// Chromium's names, in its sentence case.
    var title: String {
        switch self {
        case .passwords: "Passwords"
        case .privacy, .clearBrowserData, .siteData: "Privacy and security"
        case .search: "Search engine"
        case .extensions: "Extensions"
        }
    }
    var icon: String {
        switch self {
        case .passwords: "key.fill"
        case .privacy, .clearBrowserData, .siteData: "lock.fill"
        case .search: "magnifyingglass"
        case .extensions: "puzzlepiece.extension"
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

/// vane://settings[/section]: Vane's own page, in an ordinary tab. vane://extensions is an
/// alias of vane://settings/extensions, for typed addresses and tabs saved before it was a
/// section. Like an Easel it is drawn natively and never reaches WebKit or the history
/// database. Unlike an Easel's, the address carries no profile: which profile's data the
/// page shows is chosen in the page and lives only as long as the tab does.
enum VanePage: Equatable, Sendable {
    case settings(VaneSettingsSection)

    nonisolated static let extensions = VanePage.settings(.extensions)
    var section: VaneSettingsSection { switch self { case .settings(let section): section } }

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
            self = .settings(.extensions)
        default: return nil
        }
    }

    var url: URL { URL(string: "vane://settings/\(section.pane.rawValue)")! }
    var title: String { "Settings" }
    var icon: String { "gearshape" }

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

    /// Pages a command bar action already reaches by name: "Manage Extensions" opens
    /// vane://settings/extensions, so typing "extensions" lists that action and not a second row
    /// going to the same place.
    static let reachedByCommand: [VanePage] = [.extensions]

    /// The catalog rows the command bar ranks for `typed`. A page an action covers stays in
    /// the list only while the query is an address — `vane://` lists every page.
    static func catalog(for typed: String) -> [(title: String, page: VanePage)] {
        let address = typed.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("vane:")
        return catalog.filter { address || !reachedByCommand.contains($0.page) }
    }
}

// MARK: - The tab's model

/// What one internal-page tab is showing. `selection` is the Settings window's own model,
/// so the reused panes navigate exactly as they do there: Privacy's Passwords row sets
/// `selection.id`, and this tab follows.
@MainActor final class VanePageSession: ObservableObject {
    let selection = SettingsSelection()

    init(_ page: VanePage, profileID: UUID) {
        selection.profileID = profileID
        show(page, profileID: nil)
    }

    func show(_ page: VanePage, profileID: UUID?) {
        if let profileID { selection.profileID = profileID }
        let section = page.section
        if selection.id != section.pane.rawValue { selection.id = section.pane.rawValue }
        selection.privacyRequest = section.privacyRequest
    }

    var section: VaneSettingsSection { VaneSettingsSection(rawValue: selection.id).map(\.pane) ?? .passwords }
    var page: VanePage { .settings(section) }
    var url: URL { page.url }
}

// MARK: - Opening one

@MainActor enum VanePages {
    /// Show `page` in this window's settings tab, or a new one, with `profileID`'s data.
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
        // Only a Today row is reused: a pinned or favourite Settings row keeps its home section.
        let tab = store.tabs.first { $0.vanePage != nil && $0.kind == .today }
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
            ("vane://extensions is an alias of the Extensions section",
             VanePage(extensions) == .settings(.extensions) && VanePage(url("vane://Extensions")) == .extensions
                && VanePage(url("vane://settings/extensions")) == .extensions),
            ("addresses are canonical", VanePage.settings(.search).url.absoluteString == "vane://settings/search"
                && VanePage.extensions.url.absoluteString == "vane://settings/extensions"),
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
                && VanePage.route(url("vane://settings/extensions"), from: .web) == .refuse
                && VanePage.route(url("vane://settings/clearBrowserData"), from: .web) == .refuse),
            ("…and WebKit cancels every vane: navigation before that",
             ExternalApps.isOwn(settings.scheme) && ExternalApps.isOwn("VANE")),
            ("…and another app's GetURL event is refused", URLHandling.normalize("vane://settings") == nil),
            ("app code and typed addresses open them",
             VanePage.route(settings, from: .app) == .page(.settings(.passwords))
                && VanePage.route(extensions, from: .app) == .page(.settings(.extensions))),
            ("web addresses are not routed", VanePage.route(url("https://example.com"), from: .web) == .notInternal),
            ("the address bar resolves vane://settings to the page",
             VanePage(Search.url(for: "vane://settings/privacy")) == .settings(.privacy)
                && VanePage(Search.url(for: "  vane://extensions ")) == .settings(.extensions)),
            ("typing a section's name searches rather than opening a page",
             VanePage(Search.url(for: "passwords")) == nil),
            ("internal pages restore after relaunch, old vane://extensions tabs too", TabAddress.restorable(settings)
                && TabAddress.restorable(url("vane://settings/search")) && TabAddress.restorable(extensions)
                && TabAddress.restorable(url("vane://settings/extensions"))),
            ("…but not malformed ones", !TabAddress.restorable(url("vane://settings/passwords?x=1"))),
            ("search settings are app-wide; the rest follow the profile menu",
             !VaneSettingsSection.search.perProfile && VaneSettingsSection.passwords.perProfile
                && VaneSettingsSection.siteData.perProfile && VaneSettingsSection.extensions.perProfile),
            ("the command bar lists every section",
             Set(VanePage.catalog.map(\.page.url)) == Set(VaneSettingsSection.navigable.map { VanePage.settings($0).url })),
            ("…under vane://, all of them", VanePage.catalog(for: "vane://").count == VanePage.catalog.count
                && VanePage.catalog(for: "Vane://ext").contains { $0.page == .extensions }),
            ("…but by name, extensions is left to the Manage Extensions action",
             !VanePage.catalog(for: "extensions").contains { $0.page == .extensions }
                && VanePage.catalog(for: "passwords").contains { $0.page == .settings(.passwords) }),
        ]
    }
}

// MARK: - The page

/// vane://settings in a tab: arc://settings' layout — the app's mark and the page title
/// across the top; a left nav whose selected row is Chromium's pill; the section in rounded
/// cards beside it — built from the Settings window's own panes and, for Extensions, the
/// extension manager's card grid.
struct VanePageView: View {
    @ObservedObject var session: VanePageSession
    @ObservedObject private var selection: SettingsSelection
    @ObservedObject private var manager = ProfileManager.shared
    let store: TabStore
    @Namespace private var pill

    init(session: VanePageSession, store: TabStore) {
        self.session = session
        self.store = store
        _selection = ObservedObject(wrappedValue: session.selection)
    }

    private var profile: Profile { VanePages.profile(selection.profileID, fallback: store.profileID) }
    private var section: VaneSettingsSection { session.section }

    var body: some View {
        VanePageShell(title: "Settings") {
            ForEach(VaneSettingsSection.navigable) { item in
                VanePageNavRow(item.title, icon: item.icon, selected: item == section, namespace: pill) { show(item) }
            }
        } content: {
            content
        }
        .font(Look.text)
        .defaultAppStorage(.vane)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.windowBackground)
        .vaneMotionPolicy()
    }

    private func show(_ item: VaneSettingsSection) {
        Motion.animate(Look.quick) { selection.id = item.rawValue }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Look.inset) {
                Text(section.title).font(VanePageLayout.sectionFont).foregroundStyle(Look.inkPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Look.inset)
                if section.perProfile { profileMenu }
            }
            .frame(minHeight: VanePageLayout.chipHeight)
            .vanePageColumn()
            .padding(.top, Look.inset)
            Group {
                switch section {
                // Each owns its scrolling, as it does in the Settings window.
                case .passwords: pane
                case .extensions: extensions
                default: ScrollView { pane }
                }
            }
            .id(section)
            .transition(.opacity)
            // PrivacyPane falls back to the active profile for an unknown id, the header to
            // this window's: keep them on the same, resolved profile (e.g. after a profile is
            // deleted).
            .task(id: profile.id) { if selection.profileID != profile.id { selection.profileID = profile.id } }
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
        .toggleStyle(SettingsToggleStyle())
        .vanePageColumn()
        .padding(.bottom, 24)
    }

    /// Only a profile whose extensions are already running is managed here: creating a host
    /// starts every enabled extension against that profile's data, which picking a name in
    /// a menu must not do.
    @ViewBuilder private var extensions: some View {
        if let host = ExtensionHost.running(for: profile.id) {
            ExtensionManagementView(host: host, inTab: true,
                                    openStore: { store.openBeside(URL(string: "https://chromewebstore.google.com/")!, focus: true) })
                .id(profile.id)
        } else {
            VanePageCard {
                Text("Extensions for \(profile.name) start when a window uses this profile. Open one of its Spaces to manage them.")
                    .foregroundStyle(Look.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(VanePageLayout.cardPadding)
            }
            .vanePageColumn()
            .padding(.top, Look.inset)
        }
    }

    // MARK: the profile menu

    /// Every saved profile, Spaces or none, as Chromium's chip. Choosing one changes this
    /// tab only.
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
            HStack(spacing: 6) {
                Circle().fill(Color(hex: profile.colorHex) ?? Color.accentColor)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Text(profile.name.prefix(1).uppercased()).font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                Text(profile.name).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Look.inkSecondary).accessibilityHidden(true)
            }
            .font(Look.small)
            .padding(.horizontal, 10)
            .frame(height: VanePageLayout.chipHeight)
            .background(Look.ink(0.05), in: Capsule())
            .overlay { Capsule().strokeBorder(Look.ink(0.16), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Profile: \(profile.name)")
        .help("Show this page for another profile. Only this tab changes.")
    }
}

// MARK: - Chromium's page chrome

/// arc://settings and arc://extensions, measured off Arc's own pages (1.4px a point in the
/// reference shots): a 232pt nav of 34pt rows, the content a little under 60pt beyond it.
enum VanePageLayout {
    static let navWidth: CGFloat = 232
    static let navRow: CGFloat = 34
    /// From the page's edge to a nav row's icon.
    static let navLeading: CGFloat = 20
    /// From the nav to the search field and the section's cards, which line up.
    static let contentInset: CGFloat = 48
    /// Chromium's 680px main column.
    static let contentWidth: CGFloat = 680
    static let headerHeight: CGFloat = 60
    static let searchHeight: CGFloat = 36
    static let chipHeight: CGFloat = 26
    static let cardPadding: CGFloat = 14
    static let titleFont = Font.system(size: 20, weight: .semibold)
    static let navFont = Font.system(size: 13, weight: .medium)
    static let sectionFont = Font.system(size: 15, weight: .regular)
}

extension View {
    /// The content column: in from the nav by `contentInset`, no wider than Chromium's.
    func vanePageColumn() -> some View {
        frame(maxWidth: VanePageLayout.contentWidth, alignment: .leading)
            .padding(.leading, VanePageLayout.contentInset)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page's frame: header row, nav, content.
struct VanePageShell<Nav: View, Content: View>: View {
    let title: String
    @ViewBuilder let nav: Nav
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder nav: () -> Nav, @ViewBuilder content: () -> Content) {
        self.title = title
        self.nav = nav()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(title).font(VanePageLayout.titleFont).foregroundStyle(Look.inkPrimary)
                    .lineLimit(1).accessibilityAddTraits(.isHeader)
            }
            .padding(.leading, VanePageLayout.navLeading - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: VanePageLayout.headerHeight)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) { nav }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Look.inset)
                }
                .scrollIndicators(.never)
                .frame(width: VanePageLayout.navWidth)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// Chromium's search field: a wide capsule that rings in the accent while it has focus.
struct VanePageSearchField: View {
    let prompt: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    var identifier: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Look.inkSecondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(Look.text)
                .focused(focus)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier ?? "")
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = ""; focus.wrappedValue = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Look.inkSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: VanePageLayout.searchHeight)
        .background(Look.ink(0.05), in: Capsule())
        .overlay {
            Capsule().strokeBorder(focus.wrappedValue ? Color.accentColor : Look.ink(0.14),
                                   lineWidth: focus.wrappedValue ? 2 : 1)
        }
        .animation(Motion.reduced ? nil : Look.quick, value: focus.wrappedValue)
    }
}

/// A nav row. The selected one wears Chromium's pill — flush with the page's edge, round
/// on the right, in the accent — which slides to the next selection.
struct VanePageNavRow: View {
    let title: String
    let icon: String
    var selected = false
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, icon: String, selected: Bool = false,
         namespace: Namespace.ID, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.namespace = namespace
        self.action = action
    }

    private var shape: UnevenRoundedRectangle {
        let radius = VanePageLayout.navRow / 2
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: radius, topTrailingRadius: radius,
                                      style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                    .accessibilityHidden(true)
                Text(title).font(VanePageLayout.navFont).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                                      : AnyShapeStyle(Look.inkPrimary))
            .padding(.leading, VanePageLayout.navLeading)
            .padding(.trailing, 12)
            .frame(height: VanePageLayout.navRow)
            .background {
                if selected {
                    shape.fill(Color.accentColor).matchedGeometryEffect(id: "pill", in: namespace)
                } else if hovered {
                    shape.fill(Look.hovered)
                }
            }
            .padding(.trailing, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A Chromium card: lifted from the page, rounded, with a hairline edge.
struct VanePageCard<Content: View>: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(chromeTheme.cardFill, in: .rect(cornerRadius: Look.pageRadius - 2))
            .hairline(radius: Look.pageRadius - 2, Look.cardStroke)
    }
}

/// Chromium's outlined button — Details, Remove: a capsule with a hairline edge and the
/// accent's text.
struct VanePageOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Look.small.weight(.medium))
            .foregroundStyle(enabled ? Color.accentColor : Look.inkDisabled)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.14 : 0), in: Capsule())
            .overlay { Capsule().strokeBorder(Look.ink(0.18), lineWidth: 1) }
            .contentShape(Capsule())
    }
}
