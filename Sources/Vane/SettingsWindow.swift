import AppKit
import SwiftUI

/// Preferences that are not owned by the thing they configure. Everything else already has
/// a home (`Settings` in Develop.swift, `Blocker.enabled`, `Search.current`) and is read
/// straight from there.
@MainActor enum Prefs {
    static var folderUnlockMethod: FolderUnlockMethod {
        get { FolderUnlockMethod(rawValue: UserDefaults.vane.string(forKey: FolderUnlockMethod.key) ?? "") ?? .touchID }
        set { UserDefaults.vane.set(newValue.rawValue, forKey: FolderUnlockMethod.key) }
    }

    /// Empty means "whatever the current search engine's front page is", so switching
    /// engines moves the homepage with it until the user pins one down.
    static var homepage: URL {
        let stored = UserDefaults.vane.string(forKey: "homepage") ?? ""
        return Search.url(for: stored) ?? Search.current.home ?? Search.defaultEngine.home!
    }

    /// The background half of the updater. Off stops the polling; Vane ▸ Check for Updates…
    /// still works, because asking on purpose is not the thing anyone turned off.
    static var checkForUpdates: Bool {
        UserDefaults.vane.object(forKey: "checkForUpdates") as? Bool ?? true
    }

    /// Off is a real preference (a fresh window every launch), so it persists; on is the
    /// behaviour main.swift already had.
    static var restoreSession: Bool {
        get { UserDefaults.vane.object(forKey: "restoreSession") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "restoreSession") }
    }

    /// Settings › Advanced: what a launch after an unclean exit does. "continue" reopens the
    /// session without asking, exactly as a launch after a clean quit does; "fresh" opens
    /// one empty window; "ask" is the old alert, for whoever wants to be asked.
    static let afterCrashChoices: [(name: String, key: String)] = [
        ("Continue where I left off", "continue"), ("Start fresh", "fresh"), ("Ask me", "ask"),
    ]
    static var afterCrash: String {
        get { UserDefaults.vane.string(forKey: "afterCrash") ?? "continue" }
        set { UserDefaults.vane.set(newValue, forKey: "afterCrash") }
    }

    /// Settings › Advanced: which way a new split opens. Side by side is Arc's answer and the
    /// default, so the key is only ever written by someone asking for stacked — and it is
    /// stored as the Bool `Split.vertical` already asks, rather than a second spelling of it.
    static var stackSplits: Bool {
        get { UserDefaults.vane.bool(forKey: "stackSplits") }
        set { UserDefaults.vane.set(newValue, forKey: "stackSplits") }
    }

    /// Settings › Advanced: how long an ordinary toast stands before it goes on its own.
    /// `Look.toastDuration` is the default and stays the number the look is drawn around;
    /// this is only the clock. The hover hold and the × are unaffected — a toast the pointer
    /// is on never ages out however short this is, and any toast can be closed outright.
    static var toastSeconds: Double {
        get { UserDefaults.vane.object(forKey: "toastSeconds") as? Double ?? Look.toastDuration }
        set { UserDefaults.vane.set(newValue, forKey: "toastSeconds") }
    }

    /// What the setting offers. ponytail: a fixed list like `archiveChoices`, not a seconds
    /// field — "4.5 s" is not a thing anyone wants from a toast, and a free field needs
    /// parsing, clamping and a unit to say the same five things.
    static let toastChoices: [(name: String, seconds: Double)] = [
        ("2 seconds", 2), ("3 seconds", 3), ("5 seconds", 5),
        ("8 seconds", 8), ("15 seconds", 15),
    ]

    /// Settings › Links. Little Vane (Arc's Little Arc) is Arc's default and Vane's: a link
    /// is something you look at once, not a tab you meant to collect. Stored as a string
    /// rather than a Bool so the Picker in `LinksPane` has something to tag its rows with,
    /// and so a third target (Arc's "Most Recent Space") can be added without a migration.
    static var openLinksInLittleArc: Bool {
        UserDefaults.vane.string(forKey: LinkTarget.key) != LinkTarget.currentSpace
    }

    /// Settings › General › Previews: a link out of a Favourite or a Pinned
    /// tab opens *over* the window rather than navigating the tab away from the place it is
    /// supposed to be. Absent means on, so the key is only ever written by someone turning
    /// it off. What it decides, exactly, is `Peek.route`.
    static var peekLinks: Bool {
        UserDefaults.vane.object(forKey: Peek.prefKey) as? Bool ?? true
    }
}

enum FolderUnlockMethod: String, CaseIterable {
    case touchID, system
    static let key = "folderUnlockMethod"
}

/// The two answers the Links pane's "Open links from other apps in" offers.
enum LinkTarget {
    static let key = "externalLinks"
    static let littleArc = "little"
    static let currentSpace = "space"
}

/// The settings window. ponytail: one NSWindow we own, made once and reused — the app has
/// no AppDelegate and no `Settings` scene to hang a SwiftUI settings scene off, and the
/// frame autosave gives "remembers where it was" for free.
@MainActor enum SettingsWindow {
    private static var window: NSWindow?
    /// The selected tab, shared by the toolbar (AppKit) and the panes (SwiftUI).
    private static let selection = SettingsSelection()
    private static let tabs = SettingsToolbar(selection)

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = SettingsTab.all[0].title
        // Keep both profile columns and all toolbar tabs visible at the minimum width.
        w.minSize = NSSize(width: 760, height: 520)
        w.collectionBehavior = [.fullScreenNone]
        w.isReleasedWhenClosed = false        // closing must not free the instance we keep
        // Arc's tab bar is a preference-style toolbar: icon over word, the selected one in
        // a rounded tile, the title centred above, and the whole band a shade lighter than
        // the content. AppKit draws every part of that; a row of SwiftUI buttons drew none.
        let toolbar = NSToolbar(identifier: "VaneSettingsTabs")
        toolbar.delegate = tabs
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        w.toolbarStyle = .preference
        w.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(selection.id)
        selection.toolbar = toolbar
        // Before the hosting view: the pane retitles the window as it appears, and it can
        // only do that once `window` is the one it is inside.
        window = w
        // Every `@AppStorage` in this file binds to `UserDefaults.standard` unless told
        // otherwise, which would leave a test instance's Settings toggles in the user's own
        // preferences. `UserDefaults.vane` *is* `.standard` in normal use; see Store.swift.
        w.contentView = NSHostingView(rootView: SettingsView(selection: selection)
            .font(Look.text)
            .defaultAppStorage(.vane))
        // Position first, autosave second: setFrameUsingName reports whether there was one.
        if !w.setFrameUsingName("VaneSettings") { w.center() }
        w.setFrameAutosaveName("VaneSettings")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Open straight at one pane — Help ▸ Keyboard Shortcuts, and anything else that means
    /// "the setting you are after is over there".
    static func show(tab: String, profileID: UUID? = nil) {
        show()
        if ["passwords", "privacy"].contains(tab) {
            selection.profileID = profileID ?? ProfileManager.shared.active.id
        }
        selection.id = tab
    }

    /// The title bar names the pane you are looking at, the way Arc's and System Settings'
    /// do — the tab bar is icons, so the title is where the full word lives.
    static func retitle(_ title: String) { window?.title = title }

    /// Whether a key event landed in this window. `ShortcutsPane`'s recorder asks: its event
    /// monitor is app-wide, so a keystroke anywhere else is not the shortcut being typed —
    /// see `ShortcutsPane.reach`. False once the window is closed, which is the case that
    /// left the recorder eating every key in the browser.
    static func holds(_ candidate: NSWindow?) -> Bool {
        guard let candidate, let window else { return false }
        return candidate === window && window.isVisible
    }

    /// Told when this window closes; the token unregisters it again. Recorders and password
    /// drafts must let go of their temporary state as soon as Settings closes. The pane's
    /// `.onDisappear` never fires because its hosting view is kept for the next opening.
    static func onClose(_ then: @escaping @MainActor () -> Void) -> Any? {
        guard let window else { return nil }
        return NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated(then) }
    }
}

// MARK: - Tabs

/// One tab: icon, title (which is also the window title) and its pane. A list of values
/// rather than an enum plus two switches, so adding a tab is one line.
@MainActor struct SettingsTab: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Detail pages stay under their parent tab instead of crowding the toolbar.
    var parent: String? = nil
    let pane: (SettingsSelection) -> AnyView

    var toolbarID: String { parent ?? id }
    static var toolbarTabs: [SettingsTab] { all.filter { $0.parent == nil } }

    static let all: [SettingsTab] = [
        .init(id: "general", title: "General", icon: "gearshape",
              pane: { AnyView(GeneralPane(selection: $0)) }),
        .init(id: "profiles", title: "Profiles", icon: "person",
              pane: { AnyView(ProfilesPane(selection: $0)) }),
        .init(id: "max", title: "Max", icon: "command",
              pane: { _ in AnyView(MaxPane()) }),
        .init(id: "links", title: "Links", icon: "macwindow.on.rectangle",
              pane: { _ in AnyView(LinksPane()) }),
        .init(id: "shortcuts", title: "Shortcuts", icon: "keyboard",
              pane: { _ in AnyView(ShortcutsPane()) }),
        .init(id: "icon", title: "Icon", icon: "v.square",
              pane: { _ in AnyView(IconPane()) }),
        .init(id: "advanced", title: "Advanced", icon: "slider.horizontal.3",
              pane: { _ in AnyView(AdvancedPane()) }),
        .init(id: "passwords", title: "Passwords", icon: "key", parent: "profiles",
              pane: { AnyView(PasswordsPane(settingsProfileID: $0.profileID)) }),
        .init(id: "privacy", title: "Privacy and Security", icon: "lock", parent: "profiles",
              pane: { AnyView(PrivacyPane(selection: $0)) }),
        .init(id: "search", title: "Search Settings", icon: "magnifyingglass", parent: "profiles",
              pane: { _ in AnyView(SearchPane()) }),
        .init(id: "previews", title: "Previews", icon: "rectangle.on.rectangle", parent: "general",
              pane: { _ in AnyView(PreviewsPane()) }),
    ]
}

/// Which tab is showing. An object rather than SwiftUI state because two worlds write it:
/// the toolbar's action, and a pane sending the user elsewhere ("Privacy and Security" →
/// Advanced). Whichever writes, the toolbar's own highlight follows.
@MainActor final class SettingsSelection: ObservableObject {
    @Published var id = SettingsTab.all[0].id {
        didSet {
            let tab = SettingsTab.all.first { $0.id == id } ?? SettingsTab.all[0]
            toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.toolbarID)
        }
    }
    @Published var profileID: UUID?
    weak var toolbar: NSToolbar?
}

/// Feeds `SettingsTab.all` to the window's toolbar, one selectable item per tab.
@MainActor private final class SettingsToolbar: NSObject, NSToolbarDelegate {
    private let selection: SettingsSelection
    init(_ selection: SettingsSelection) { self.selection = selection }

    private var ids: [NSToolbarItem.Identifier] { SettingsTab.toolbarTabs.map { .init($0.id) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.all.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    @objc private func pick(_ sender: NSToolbarItem) { selection.id = sender.itemIdentifier.rawValue }
}

private struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection

    private var current: SettingsTab {
        SettingsTab.all.first { $0.id == selection.id } ?? SettingsTab.all[0]
    }

    var body: some View {
        Group {
            if ["shortcuts", "passwords"].contains(current.id) {
                // This pane owns a bounded scrolling list, so its search and guidance
                // stay in place while the rows scroll.
                pane
            } else {
                ScrollView { pane }.id(current.id)
            }
        }
        .background(.windowBackground)
        .toggleStyle(SettingsToggleStyle())
        .controlSize(.small)
        .onAppear { SettingsWindow.retitle(current.title) }
        .onChange(of: selection.id) { SettingsWindow.retitle(current.title) }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let parent = current.parent,
               let tab = SettingsTab.all.first(where: { $0.id == parent }) {
                Button { selection.id = parent } label: {
                    Label("Back to \(tab.title)", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 20)
                if ["passwords", "privacy"].contains(current.id),
                   let profile = ProfileManager.shared.profiles.first(where: { $0.id == selection.profileID }) {
                    Text(profile.name).font(Look.caption).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            current.pane(selection)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 64)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

}

private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).controlSize(.mini)
    }
}

// MARK: - Card and row
//
// The shapes every pane is built from, so a preference looks the same wherever it lives: a
// grouped card of rows split by hairlines, a row that is a title plus one control, a grey
// footnote inside the card, a grey caption over it. Internal, not private: ShortcutsPane
// is built from the same pieces.

/// A grouped card. `_VariadicView` is how a container gets at its children one by one —
/// without it a ViewBuilder is one opaque blob and there is nowhere to put the hairlines.
/// `divided: false` for a card of links, which Arc runs together without lines.
struct SettingsCard<Content: View>: View {
    var divided = true
    @ViewBuilder var content: Content

    init(divided: Bool = true, @ViewBuilder content: () -> Content) {
        self.divided = divided
        self.content = content()
    }

    var body: some View {
        Group {
            if divided {
                _VariadicView.Tree(DividedRows()) { content }
            } else {
                VStack(alignment: .leading, spacing: 0) { content }
            }
        }
        .background(Look.cardFill, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius, Look.cardStroke)
    }
}

private struct DividedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                // Inset to the row content, like Arc's — a line that runs edge to edge
                // reads as a card boundary, not a row boundary.
                if child.id != last { Hairline().padding(.horizontal, Look.cardInset) }
            }
        }
    }
}

/// A title on the left, one control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Look.inset) {
            Text(title).font(Look.text).foregroundStyle(Look.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Look.inset)
            trailing.layoutPriority(1)
        }
        .padding(.horizontal, Look.cardInset)
        .padding(.vertical, 9)
        .frame(minHeight: Look.settingsRow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The grey sentence that explains a card, as its last row — under a hairline, inside the
/// stroke, the way Arc keeps an explanation with the thing it explains.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // Arc's footnotes are a size down and a quiet grey (115 on 30).
        Text(text).font(Look.footnote).foregroundStyle(Look.inkQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Look.cardInset)
            .padding(.vertical, Look.inset + 2)
    }
}

/// A grey title over a card ("Your Data and Settings", "File"), set in from the margin by
/// the same inset as the rows beneath it, so it lines up with their text.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset - 2) {
            // Caption-sized, the way Arc heads "Your Data and Settings" (11pt, 109 on 27).
            Text(title).font(Look.caption).foregroundStyle(Look.inkQuiet)
                .padding(.horizontal, Look.cardInset)
            content
        }
    }
}

/// The vertical rhythm of a pane: cards a gap apart.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) { content }
            .padding(.top, Look.inset * 2)
    }
}

/// A text field that reads as a control rather than a hole in the card.
private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(Look.text)
            .padding(.horizontal, Look.inset)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
    }
}

private extension View {
    func settingsField() -> some View { modifier(FieldStyle()) }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var selection: SettingsSelection
    @AppStorage("warnBeforeQuit") private var warnQuit = true
    @AppStorage("checkForUpdates") private var autoUpdate = true
    @AppStorage(InteractionSounds.preferenceKey) private var interactionSounds = false
    @State private var isDefault = URLHandling.isDefaultBrowser

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("Automatically check for Vane updates") {
                    Toggle("Automatically check for Vane updates", isOn: $autoUpdate).labelsHidden()
                }
                SettingsRow("Warn before quitting") {
                    Toggle("Warn before quitting", isOn: $warnQuit).labelsHidden()
                }
                SettingsRow("Play subtle interaction sounds") {
                    Toggle("Play subtle interaction sounds", isOn: $interactionSounds).labelsHidden()
                        .onChange(of: interactionSounds) { _, enabled in
                            if enabled { InteractionSounds.play(.copy) }
                        }
                }
            }

            SettingsCard {
                SettingsRow("Previews") {
                    Button("Previews Settings…") { selection.id = "previews" }
                }
                SettingsRow("Manage your search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { selection.id = "profiles" }
                }
            }

            SettingsCard {
                SettingsRow("Default browser") {
                    Button(isDefault ? "Vane is your default browser" : "Make Vane Default…") {
                        URLHandling.makeDefaultBrowser()
                        isDefault = URLHandling.isDefaultBrowser
                    }
                    .disabled(isDefault)
                }
            }
        }
        .onAppear { isDefault = URLHandling.isDefaultBrowser }
    }
}

private struct PreviewsPane: View {
    @AppStorage("linkPreviews") private var previews = true
    @AppStorage(Peek.prefKey) private var peekLinks = true
    @AppStorage(LibraryHoverCategory.key) private var libraryPreview = "downloads"

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("Library hover preview") {
                    Picker("Library hover preview", selection: $libraryPreview) {
                        ForEach(LibraryHoverCategory.allCases) { category in
                            Text(category.title).tag(category.rawValue)
                        }
                    }.labelsHidden().frame(width: 160)
                }
                Footnote("Hover the sidebar bucket to see up to four items from this section, with the newest at the bottom. Downloads is the default. Off hides the preview. Private windows show only their own downloads, media, and archived tabs.")
            }
            SettingsCard {
                SettingsRow("Preview links on hover") {
                    Toggle("Preview links on hover", isOn: $previews).labelsHidden()
                }
                Footnote("Hover over a link to preview the page. The website sees a visit when its preview loads. An on-device summary appears when Max is available.")
            }
            SettingsCard {
                SettingsRow("Open links from pinned tabs in Peek") {
                    Toggle("Open links from pinned tabs in Peek", isOn: $peekLinks).labelsHidden()
                }
                Footnote("Links to other sites open over your window, keeping your pinned tab in place. Escape closes the preview; ⌘O keeps it as a tab. Shift-click reverses this preference for one link.")
            }
        }
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var manager = ProfileManager.shared
    private var selected: UUID {
        get { selection.profileID ?? manager.active.id }
        nonmutating set { selection.profileID = newValue }
    }
    @AppStorage("searchEngine") private var engineID = Search.defaultEngine.id
    @AppStorage("searchSuggestions") private var suggestions = false
    @State private var archiveAfter = Prefs.archiveAfter
    /// Non-nil while a profile row is an editable field rather than a label.
    @State private var renaming: UUID?
    /// The Clear Browsing Data dialog, which is a sheet rather than an alert: it has four
    /// controls and a sentence, and an NSAlert accessory view is a worse way to draw those.
    @State private var clearing = false
    @State private var draft = ""
    /// The right-hand name field. Separate from `draft` on purpose: focusing a TextField
    /// writes through its binding, so sharing one would put the list row into rename mode
    /// the moment the field was touched.
    @State private var name = ""
    /// Spaces come off disk, so they are read once per selection rather than per redraw.
    @State private var spaces: [Space] = []
    @State private var newSpace = ""
    /// Where this profile's downloads go, and whether it asks first. Read on selection
    /// rather than through @AppStorage: the key is per profile, so it changes as the
    /// selection does.
    @State private var downloadDirectory = DownloadLocation.systemDownloads
    @State private var askWhereToSave = false
    /// So a row that has just become a text field is the one the keystrokes go to.
    @FocusState private var renameFocused: Bool

    private var profile: Profile {
        manager.profiles.first { $0.id == selected } ?? manager.profiles[0]
    }

    var body: some View {
        Pane {
            Text("Profiles keep your browsing separate — history, logins, cookies and "
                 + "extensions. A Space lives in exactly one Profile.")
                .font(Look.text)
                .fixedSize(horizontal: false, vertical: true)

            if !manager.saveFailures.isEmpty {
                ProfileSaveNotice(manager: manager)
            }

            HStack(alignment: .top, spacing: 10) {
                // The list runs the full height of the controls beside it, like Arc's, so
                // the two columns read as one layout rather than a card and a stack.
                list.frame(width: 200).frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    searchCard
                    downloadsCard
                    SettingsSection("Your Data and Settings") { data }
                    DisclosureGroup("Manage Profile and Spaces") {
                        VStack(alignment: .leading, spacing: 12) {
                            identity
                            spacesCard
                        }
                        .padding(.top, 10)
                    }
                    .font(Look.text)
                    .padding(.horizontal, Look.cardInset)
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $clearing) {
            ClearDataSheet(profileID: profile.id, profileName: profile.name)
        }
        // Not `renaming = nil` here: creating a profile selects it *and* opens its row for
        // renaming, and this fires after both.
        .onChange(of: selected) { reload() }
        .onChange(of: manager.profiles) { reload() }
    }

    // MARK: the list

    private var list: some View {
        SettingsCard(divided: false) {
            Text("Your Profiles").font(Look.caption).foregroundStyle(Look.inkSecondary)
                .padding(.horizontal, Look.cardInset)
                .frame(maxWidth: .infinity, minHeight: Look.settingsRow, alignment: .leading)
            Hairline()
            VStack(spacing: 0) {
                ForEach(Array(manager.profiles.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Hairline().padding(.horizontal, Look.cardInset) }
                    row(p)
                }
            }
            .padding(.vertical, Look.inset / 2)
            Spacer(minLength: 0)
            Hairline()
            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Profile")
                rule
                Button { remove() } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Delete Profile")
                    .disabled(manager.profiles.count < 2)
                rule
                Button { draft = profile.name; renaming = profile.id } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename Profile")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(height: Look.settingsRow)
            .padding(.horizontal, Look.inset)
        }
    }

    /// Between the list's footer buttons, the way Arc rules them apart.
    private var rule: some View {
        Rectangle().fill(Look.hairline)
            .frame(width: 1, height: Look.rowHeight - Look.inset)
            .padding(.horizontal, Look.inset + 2)
    }

    private func row(_ p: Profile) -> some View {
        HStack(spacing: Look.inset) {
            if renaming == p.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(Look.text)
                    .focused($renameFocused)
                    .onAppear { renameFocused = true }
                    .onSubmit { manager.rename(p.id, to: draft); renaming = nil; rebuild() }
            } else {
                Text(p.name).font(Look.text).foregroundStyle(Look.inkPrimary)
                Spacer(minLength: Look.inset)
                Text(spaceCount(p)).font(Look.caption).foregroundStyle(Look.inkSecondary)
            }
        }
        .padding(.horizontal, Look.inset)
        // Arc's list rows: a 32pt fill set 15 in from the card, on a 40 pitch.
        .frame(height: Look.listRow)
        .background(p.id == selected ? Look.accentSelected : .clear,
                    in: .rect(cornerRadius: Look.chipRadius))
        .padding(.horizontal, Look.cardInset)
        .padding(.vertical, Look.listRowGap)
        .contentShape(.rect)
        .onTapGesture { renaming = nil; selected = p.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(p.id == selected ? [.isSelected] : [])
    }

    /// New profiles land in rename mode: naming a thing is the point of making it, and this
    /// is the settings surface, so it does not need Menu.swift's NSAlert prompt.
    private func add() {
        let p = manager.create(name: "New Profile")
        selected = p.id
        draft = p.name
        renaming = p.id
        rebuild()
    }

    private func remove() {
        let victim = profile
        guard confirm("Delete the profile “\(victim.name)”?", "Delete",
                      "Its history, bookmarks, saved passwords, cookies and extensions are "
                      + "deleted with it. This cannot be undone.") else { return }
        if manager.delete(victim.id) {
            selected = manager.active.id
            _ = Windows.switchTo(profile: manager.active)
            rebuild()
        } else {
            Toasts.show("Couldn’t delete profile. Its data was kept.")
        }
    }

    // MARK: the profile

    private var identity: some View {
        SettingsCard {
            SettingsRow("Name") {
                TextField("", text: $name)
                    .onSubmit { manager.rename(profile.id, to: name); rebuild() }
                    .settingsField().frame(width: 200)
            }
            SettingsRow("Colour") {
                HStack(spacing: Look.inset) {
                    ForEach(ProfileManager.palette, id: \.self) { hex in
                        Circle().fill(swatch(hex))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(Color.primary,
                                                      lineWidth: hex == profile.colorHex ? 2 : 0)
                            }
                            .onTapGesture { manager.setColor(hex, for: profile.id) }
                            .accessibilityLabel("Colour \(hex)")
                            .accessibilityAddTraits(hex == profile.colorHex ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    private var spacesCard: some View {
        SettingsCard {
            ForEach(spaces) { space in
                SettingsRow(space.name) {
                    Button {
                        // The sidebar's own Delete Space, minus the alert: the pages go to
                        // the Archive and the folder shape is forgotten. This used to call
                        // `deleteSpace` bare, which dropped both.
                        Spaces.delete(space.id, in: profile.id)
                        reload(); rebuild()
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Delete the space \(space.name)")
                }
            }
            SettingsRow("New Space…") {
                TextField("", text: $newSpace, prompt: Text("Name"))
                    .onSubmit {
                        let name = newSpace.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        manager.createSpace(name: name, in: profile.id)
                        for store in TabStore.all where store.profileID == profile.id {
                            store.resolveStaleSpace()
                            store.spacesChanged()
                        }
                        newSpace = ""
                        reload(); rebuild()
                    }
                    .settingsField().frame(width: 200)
            }
        }
    }

    private var searchCard: some View {
        SettingsCard {
            SettingsRow("Search engine") {
                Picker("Search engine", selection: $engineID) {
                    ForEach(Search.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 145)
            }
            SettingsRow("Manage search") {
                Button("Search Settings…") { selection.id = "search" }
            }
            SettingsRow("Include search engine suggestions") {
                Toggle("Include search engine suggestions", isOn: $suggestions).labelsHidden()
            }
            Footnote("Search and archive preferences apply to all profiles. Suggestions send what you type to your search engine; they stay off in private windows.")
        }
    }

    /// Arc keeps the download folder in Profiles, beside the search engine and the archive
    /// cadence — work and personal do not file their downloads in the same place.
    private var downloadsCard: some View {
        SettingsCard {
            SettingsRow("Archive tabs after") {
                Picker("Archive tabs after", selection: $archiveAfter) {
                    ForEach(Prefs.archiveChoices, id: \.after) { Text($0.name).tag($0.after) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: archiveAfter) { Prefs.archiveAfter = archiveAfter }
            }
            SettingsRow("Download location") {
                Button(DownloadLocation.label(downloadDirectory)) {
                    if let picked = DownloadLocation.choose(for: profile.id,
                                                            current: downloadDirectory) {
                        downloadDirectory = picked
                    }
                }
                .help(downloadDirectory.path)
                .accessibilityLabel("Download location, \(downloadDirectory.path)")
                .accessibilityHint("Choose the folder downloads are saved into.")
                .disabled(askWhereToSave)
            }
            SettingsRow("Ask where to save each file") {
                Toggle("", isOn: $askWhereToSave).labelsHidden()
                    .onChange(of: askWhereToSave) {
                        DownloadLocation.setAskEveryTime(askWhereToSave, for: profile.id)
                    }
            }
            Footnote("Only Today tabs auto-archive. Favourites and pinned tabs stay put. Downloads are saved to this profile’s folder.")
        }
    }

    private var data: some View {
        SettingsCard(divided: false) {
            VStack(spacing: 0) {
                DataRow(icon: "lock.fill", tint: .blue, title: "Privacy and Security") {
                    selection.profileID = profile.id
                    selection.id = "privacy"
                }
                DataRow(icon: "key.fill", tint: .green, title: "Passwords") {
                    // The same place Menu.swift's Manage Saved Passwords… goes.
                    selection.profileID = profile.id
                    selection.id = "passwords"
                }
                DataRow(icon: "trash.fill", tint: .red, title: "Clear Browsing Data") {
                    clearing = true
                }
            }
            .padding(.vertical, Look.inset / 2)
        }
    }

    private func reload() {
        spaces = manager.spaces(for: profile.id)
        name = profile.name
        downloadDirectory = DownloadLocation.directory(for: profile.id)
        askWhereToSave = DownloadLocation.askEveryTime(for: profile.id)
        archiveAfter = Prefs.archiveAfter
        engineID = Search.current.id
    }

    /// "1 Space", not "1 Spaces".
    private func spaceCount(_ p: Profile) -> String {
        let n = manager.spaces(for: p.id).count
        return n == 1 ? "1 Space" : "\(n) Spaces"
    }

    /// `colorHex` is the one place a hex colour is allowed — it is the user's own accent for
    /// a profile, not a colour this design chose. Anything unparseable falls back to the
    /// accent colour rather than to black.
    private func swatch(_ hex: String) -> Color {
        var value: UInt64 = 0
        guard Scanner(string: String(hex.drop { $0 == "#" })).scanHexInt64(&value) else {
            return .accentColor
        }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

/// A row from Arc's "Your Data and Settings": a white glyph in a coloured square, a title,
/// and an arrow saying this goes somewhere.
private struct DataRow: View {
    let icon: String
    let tint: Color
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Look.inset) {
                Image(systemName: icon).font(Look.glyph)
                    .foregroundStyle(.white)
                    .frame(width: Look.iconTile, height: Look.iconTile)
                    .background(tint, in: .rect(cornerRadius: Look.iconTileRadius))
                Text(title).font(Look.text).foregroundStyle(Look.inkPrimary)
                Spacer(minLength: Look.inset)
                Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, Look.cardInset)
            .frame(height: Look.linkRow)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The label is an HStack, so VoiceOver would otherwise reach an unnamed button.
        .accessibilityLabel(title)
    }
}

// MARK: - Max

private struct MaxPane: View {
    @AppStorage("appleAI") private var appleAI = true
    @AppStorage("tidyTabs") private var tidyTabs = true
    @AppStorage("tidyDownloads") private var tidyDownloads = false
    @AppStorage("tidyTitles") private var tidyTitles = true
    @AppStorage("instantLinks") private var instant = true
    @AppStorage("aiSettingsRevision") private var aiRevision = 0

    private var off: Bool {
        _ = aiRevision
        return !appleAI || !BrowserAI.ready
    }

    var body: some View {
        Pane {
            AIProviderSettings()
            SettingsCard {
                SettingsRow("AI features") {
                    Toggle("", isOn: $appleAI).labelsHidden()
                }
                // Each feature is separately switchable, because they do not cost the same.
                // Grouping tabs is ~12 seconds of model time; the others are far cheaper or
                // usually answered without the model at all.
                SettingsRow("Group tabs by topic") {
                    Toggle("", isOn: $tidyTabs).labelsHidden().disabled(off)
                }
                SettingsRow("Rename messy downloads") {
                    Toggle("", isOn: $tidyDownloads).labelsHidden().disabled(off)
                }
                SettingsRow("Shorten pinned tab titles") {
                    Toggle("", isOn: $tidyTitles).labelsHidden().disabled(off)
                }
                Footnote(BrowserAI.unavailableReason
                         ?? "Names and groups use your selected AI provider. Grouping runs when you choose Tidy Tabs; download naming and pinned title shortening use the switches above.")
            }

            SettingsCard {
                SettingsRow("Instant Links") { Toggle("", isOn: $instant).labelsHidden() }
                Footnote("Shift-Return on a search opens the top result directly instead of the "
                         + "results page. The query goes to DuckDuckGo whichever engine you use, "
                         + "because it is the only one that answers without JavaScript. Never in "
                         + "a private window, and never for anything that looks like an address.")
            }
        }
    }
}

// MARK: - Links

private struct LinksPane: View {
    @AppStorage(LinkTarget.key) private var externalLinks = LinkTarget.littleArc
    @AppStorage(LinkInteraction.Preferences.littleKey) private var littleLinks = true
    @AppStorage(LinkInteraction.Preferences.shiftKey) private var shiftPeek = true

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("Open links from other apps in") {
                    Picker("", selection: $externalLinks) {
                        Text("Little Vane").tag(LinkTarget.littleArc)
                        Text("Current Space").tag(LinkTarget.currentSpace)
                    }
                    .labelsHidden().fixedSize()
                }
                Footnote("A Little Vane is a small window with one page and no sidebar: read "
                         + "it, then close it with \u{2318}W — or press \u{2318}O to keep it as a "
                         + "tab in a Space. Current Space puts every link straight into the "
                         + "window you already have open.")
            }

            SettingsCard {
                SettingsRow("Open ⌥⌘-clicked links in Little Vane") {
                    Toggle("Open ⌥⌘-clicked links in Little Vane", isOn: $littleLinks).labelsHidden()
                }
                SettingsRow("Open ⇧-clicked links in Peek") {
                    Toggle("Open ⇧-clicked links in Peek", isOn: $shiftPeek).labelsHidden()
                }
                Footnote("Hold ⌘ over a link to open a background tab, or ⇧⌘ to open and focus it. "
                         + "⌥ opens a link in Split View. The hint at the bottom of the page "
                         + "updates as you hold or release these keys.")
            }

            // Arc's Air Traffic Control, directly under the preference it overrides — a rule
            // only makes sense next to the default it is an exception to. See AirTraffic.swift.
            SettingsSection("Air Traffic Control") { AirTrafficCard() }

        }
    }
}

// MARK: - Search Settings

private struct SearchPane: View {
    // The key `Search.current` reads. AppStorage so the picker redraws itself.
    @AppStorage("searchEngine") private var engineID = Search.defaultEngine.id
    @AppStorage("aiAssistant") private var assistantID = AIChat.all[0].id
    // Absent = off. Deliberately not defaulted on: turning this on sends what you type to
    // the search engine before you press Return.
    @AppStorage("searchSuggestions") private var suggestions = false
    // Neither list is @Published, so the views mirror them and refresh on every mutation.
    @State private var engines = Search.all
    @State private var newName = ""
    @State private var newTemplate = ""
    @State private var bangs = Bangs.custom
    @State private var newBang = ""
    @State private var newBangURL = ""
    /// The sentence `Bangs.add` came back with when it refused.
    @State private var bangError: String?

    private var engineIsValid: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && newTemplate.contains("%s")
            && newTemplate.contains("://")
    }

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("AI assistant") {
                    Picker("", selection: $assistantID) {
                        ForEach(AIChat.all) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                Footnote("Press Tab in the address bar to ask this assistant instead of "
                         + "searching. Starting with an assistant's name — \u{201C}claude …\u{201D}, "
                         + "\u{201C}chatgpt …\u{201D} — overrides it for that one query. Vane opens the "
                         + "assistant's own site with the question; ChatGPT and Perplexity send "
                         + "it automatically, Claude fills it in for you to send.")
            }

            SettingsCard {
                SettingsRow("Search engine") {
                    Picker("", selection: $engineID) {
                        ForEach(engines) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("Search suggestions") {
                    Toggle("", isOn: $suggestions).labelsHidden()
                }
                ForEach(Search.custom) { engine in
                    SettingsRow(engine.name) {
                        Text(engine.queryTemplate).font(Look.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button {
                            Search.remove(engine)
                            engines = Search.all
                            engineID = Search.current.id
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Remove the engine \(engine.name)")
                    }
                }
                SettingsRow("Add an engine") {
                    TextField("", text: $newName, prompt: Text("Name"))
                        .settingsField().frame(width: 100)
                    TextField("", text: $newTemplate,
                              prompt: Text("https://example.com/search?q=%s"))
                        .settingsField().frame(width: 230)
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        Search.add(SearchEngine(
                            id: id(for: name), name: name,
                            queryTemplate: newTemplate.trimmingCharacters(in: .whitespaces)))
                        engines = Search.all
                        newName = ""; newTemplate = ""
                    }
                    .disabled(!engineIsValid)
                }
                Footnote("Search suggestions send what you type in the address bar to your "
                         + "search engine as you type it. Never in a private window, and never "
                         + "for anything that looks like an address. A custom engine's address "
                         + "needs %s where the search words go.")
            }

            SettingsCard {
                SettingsRow("Your bangs") {
                    Button("Restore Defaults") { Bangs.reset(); bangs = Bangs.custom }
                        .disabled(bangs.isEmpty)
                }
                ForEach(bangs) { bang in
                    SettingsRow("!" + bang.keyword) {
                        Text(bang.queryTemplate).font(Look.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button {
                            Bangs.remove(bang.keyword)
                            bangs = Bangs.custom
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Remove the bang !\(bang.keyword)")
                    }
                }
                SettingsRow("Add a bang") {
                    TextField("", text: $newBang, prompt: Text("!gh"))
                        .settingsField().frame(width: 70)
                    TextField("", text: $newBangURL,
                              prompt: Text("https://github.com/search?q=%s"))
                        .settingsField().frame(width: 260)
                    Button("Add") { addBang() }
                        .disabled(newBang.isEmpty || newBangURL.isEmpty)
                }
                if let bangError {
                    Text(bangError).font(Look.text).foregroundStyle(.red)
                        .padding(.horizontal, Look.cardInset)
                        .padding(.vertical, Look.inset + 2)
                }
                Footnote("A bang jumps straight to a site's own search: !gh swift searches "
                         + "GitHub. Type a keyword or site name and press Tab for a search chip. "
                         + "\(Bangs.builtIn.count) sites are built in; yours win over those.")
            }
        }
    }

    private func addBang() {
        let result = Bangs.add(Bang(bang: newBang, newBang, newBangURL))
        switch result {
        case .rejected(let reason):
            bangError = reason
        case .accepted:
            bangError = nil
            newBang = ""; newBangURL = ""
            bangs = Bangs.custom
        }
    }

    /// ponytail: slugged name plus a counter. Two engines called the same thing is the
    /// only collision that matters and this is enough to stop it.
    private func id(for name: String) -> String {
        let base = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let slug = base.isEmpty ? "custom" : base
        var candidate = slug
        var n = 2
        while Search.all.contains(where: { $0.id == candidate }) {
            candidate = slug + String(n)
            n += 1
        }
        return candidate
    }
}

// MARK: - Icon

private struct IconPane: View {
    @State private var chosen = AppIcon.current
    var body: some View {
        Pane {
            SettingsCard {
                ForEach(AppIcon.variants, id: \.name) { variant in
                    iconRow(variant.image, title: variant.name, selected: chosen == variant.name) {
                        AppIcon.apply(variant.name)
                        chosen = AppIcon.current
                    }
                }
            }
        }
    }

    private func iconRow(_ image: NSImage, title: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Look.Typography.sidebarHeading.font)
                        .foregroundStyle(Look.inkPrimary)
                    if selected {
                        Text("CURRENT ICON").font(Look.Typography.compactCaption.font)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject private var batterySaver = BatterySaver.shared
    @AppStorage("userAgent") private var userAgent = safariUA
    @AppStorage("inspector") private var inspector = true
    @AppStorage("homepage") private var homepage = ""
    @AppStorage(PictureInPicture.prefKey) private var autoPiP = true
    @State private var restore = Prefs.restoreSession
    @State private var afterCrash = Prefs.afterCrash
    @State private var toastSeconds = Prefs.toastSeconds
    @State private var stackSplits = Prefs.stackSplits

    var body: some View {
        Pane {
            SettingsSection("Performance") {
                SettingsCard {
                    SettingsRow("Battery Saver") {
                        Picker("Battery Saver", selection: Binding(
                            get: { batterySaver.mode }, set: { batterySaver.setMode($0) }
                        )) {
                            ForEach(BatterySaver.Mode.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingsRow("Status") {
                        Label(batterySaver.isActive ? "Active" : "Inactive",
                              systemImage: batterySaver.isActive ? "bolt.fill" : "bolt")
                            .foregroundStyle(batterySaver.isActive ? Color.green : Color.secondary)
                    }
                    Footnote("Automatic turns on below 20% battery while unplugged. Always On keeps it active on any power source; Off disables it.")
                    Footnote("While active, eligible idle tabs sleep after five minutes, hover link previews pause, and sidebar motion is reduced. Active pages, pinned tabs, media, private tabs, and unfinished forms stay protected. Sleeping tabs reload when you return.")
                }
            }
            SettingsSection("Windows and Tabs") {
                SettingsCard {
                    SettingsRow("Reopen windows and tabs on launch") {
                        Toggle("Reopen windows and tabs on launch", isOn: $restore).labelsHidden()
                            .onChange(of: restore) { Prefs.restoreSession = restore }
                    }
                    SettingsRow("If Vane didn’t quit cleanly") {
                        Picker("After an unclean exit", selection: $afterCrash) {
                            ForEach(Prefs.afterCrashChoices, id: \.key) { Text($0.name).tag($0.key) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: afterCrash) { Prefs.afterCrash = afterCrash }
                    }
                    SettingsRow("Homepage") {
                        TextField("Homepage", text: $homepage, prompt: Text(Prefs.homepage.absoluteString))
                            .onSubmit {
                                if let url = Search.url(for: homepage) { homepage = url.absoluteString }
                            }
                            .settingsField().frame(width: 280)
                    }
                    SettingsRow("Open new Split Views") {
                        Picker("Open new Split Views", selection: $stackSplits) {
                            Text("Side by side").tag(false)
                            Text("Stacked").tag(true)
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: stackSplits) { Prefs.stackSplits = stackSplits }
                    }
                }
            }

            SettingsSection("Media and Notifications") {
                SettingsCard {
                    SettingsRow("Automatically enter Picture in Picture") {
                        Toggle("Automatically enter Picture in Picture", isOn: $autoPiP).labelsHidden()
                    }
                    Footnote("Keep a playing video in view when switching tabs. Return to its tab to put it back in the page.")
                    SettingsRow("Show notifications for") {
                        Picker("Show notifications for", selection: $toastSeconds) {
                            ForEach(Prefs.toastChoices, id: \.seconds) { Text($0.name).tag($0.seconds) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: toastSeconds) { Prefs.toastSeconds = toastSeconds }
                    }
                }
            }

            SettingsSection("Developer") {
                SettingsCard {
                    SettingsRow("User agent") {
                        Picker("", selection: $userAgent) {
                            ForEach(Settings.userAgents, id: \.value) { Text($0.name).tag($0.value) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: userAgent) { Settings.apply(); rebuild() }
                    }
                    SettingsRow("Allow Web Inspector") {
                        Toggle("", isOn: $inspector).labelsHidden()
                            .onChange(of: inspector) { Settings.apply(); rebuild() }
                    }
                    SettingsRow("Extensions") {
                        Button("Install Extension…") {
                            ExtensionHost.shared.chooseAndInstall(); rebuild()
                        }
                    }
                    Footnote(Inspector.available
                             ? "Sites that sniff the browser see the user agent instead. Reload the "
                             + "page to apply it."
                             : "Sites that sniff the browser see the user agent instead. Reload the "
                             + "page to apply it. The in-app inspector is unavailable on this "
                             + "macOS — right-click → Inspect Element still works.")
                }
            }

            SettingsSection("Reset Vane") {
                SettingsCard {
                    SettingsRow("Start over") {
                        Button("Erase Everything…") { EraseEverything.ask() }
                    }
                    Footnote("Erase all profiles, Spaces, passwords, browsing data, extensions, and settings. Vane asks you to type a confirmation before starting over.")
                }
            }

        }
    }
}

// MARK: - Privacy and Security

/// Arc's "Privacy and Security" row opens Chromium's privacy page. Vane has no Chromium, so
/// this is the pane that row means: what is switched on to protect you, what has been
/// answered on your behalf per site, and the one button that takes it all back.
private struct PrivacyPane: View {
    @ObservedObject var selection: SettingsSelection
    @AppStorage("httpsOnly") private var httpsOnly = true
    @State private var blocking = true
    @AppStorage("searchSuggestions") private var suggestions = false
    @ObservedObject private var manager = ProfileManager.shared
    /// Read once per appearance: they come out of UserDefaults, not out of a publisher.
    @State private var grants: [SitePermissions.Grant] = []
    @State private var httpExceptions: [String] = []
    @State private var clearing = false

    private var profile: Profile {
        manager.profiles.first { $0.id == selection.profileID } ?? manager.active
    }

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("HTTPS-Only Mode") {
                    Toggle("", isOn: $httpsOnly).labelsHidden().onChange(of: httpsOnly) { rebuild() }
                }
                SettingsRow("Block ads and trackers") {
                    Toggle("", isOn: $blocking).labelsHidden()
                        .onChange(of: blocking) { Blocker.setEnabled(blocking, for: profile.id); rebuild() }
                }
                SettingsRow("Search suggestions") {
                    Toggle("", isOn: $suggestions).labelsHidden()
                }
                Footnote("Pages load over an encrypted connection or stop on a warning. Ads and "
                         + "trackers are blocked from a filter list on device — nothing about "
                         + "what you visit leaves the machine. Search suggestions are the one "
                         + "exception: they send what you type to your search engine before you "
                         + "press Return, and they are off unless you turn them on.")
            }

            BlockerSettingsSection(profileID: profile.id)

            SettingsSection("Site Permissions") {
                SettingsCard {
                    if grants.isEmpty && httpExceptions.isEmpty {
                        Footnote("No camera, microphone, or location decisions are saved, and no "
                                 + "site has been allowed to load without encryption.")
                    }
                    ForEach(grants) { grant in
                        SettingsRow(grant.scope.origin) {
                            Text("\(grant.what): \(grant.allowed ? "Allowed" : "Blocked")")
                                .font(Look.caption).foregroundStyle(Look.inkSecondary)
                            Button {
                                SitePermissions.reset(scope: grant.scope)
                                reload()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Forget \(grant.what.lowercased()) for \(grant.scope.origin)")
                        }
                    }
                    ForEach(httpExceptions, id: \.self) { host in
                        SettingsRow(host) {
                            Text("Allowed without encryption")
                                .font(Look.caption).foregroundStyle(Look.inkSecondary)
                            Button {
                                HTTPSOnly.forget(host: host, profileID: profile.id)
                                reload()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Stop allowing \(host) without encryption")
                        }
                    }
                    SettingsRow("Site permissions") {
                        Button("Reset Permissions…") {
                            if confirm("Forget camera, microphone, and location permissions for every site in this profile?",
                                       "Reset") {
                                SitePermissions.resetAll(profileID: profile.id)
                                reload()
                            }
                        }
                        .disabled(grants.isEmpty)
                    }
                    SettingsRow("Website Boosts") {
                        Button("Reset Boosts…") {
                            if confirm("Reset every website Boost in this profile?", "Reset",
                                       "Fonts, colors, hidden elements, and custom code will be removed. Reload pages to remove script effects.") {
                                SiteBoosts.forget(profile: profile.id)
                                reload()
                            }
                        }
                    }
                    SettingsRow("Certificates you trusted anyway") {
                        Button("Forget Exceptions…") {
                            if confirm("Forget certificate exceptions for “\(profile.name)”?",
                                       "Forget",
                                       "Those sites will ask again the next time you visit them.") {
                                CertificateTrust.forget(profile: profile.id)
                            }
                        }
                    }
                }
            }

            SettingsSection("Your Data") {
                SettingsCard(divided: false) {
                    VStack(spacing: 0) {
                        DataRow(icon: "trash.fill", tint: .red, title: "Clear Browsing Data") {
                            clearing = true
                        }
                        DataRow(icon: "key.fill", tint: .green, title: "Passwords") {
                            selection.id = "passwords"
                        }
                    }
                    .padding(.vertical, Look.inset / 2)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: profile.id) { reload() }
        .sheet(isPresented: $clearing) {
            ClearDataSheet(profileID: profile.id, profileName: profile.name)
        }
    }

    private func reload() {
        blocking = Blocker.enabled(for: profile.id)
        grants = SitePermissions.all(profileID: profile.id)
        httpExceptions = HTTPSOnly.exceptions(profileID: profile.id)
    }
}

/// The same NSAlert shape the menus use, so a destructive settings button asks the same way.
/// Internal: ShortcutsPane's Reset All asks with it too.
@MainActor func confirm(_ message: String, _ verb: String, _ detail: String = "") -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = detail
    a.addButton(withTitle: verb)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
