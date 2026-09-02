import AppKit
import SwiftUI

/// Preferences that are not owned by the thing they configure. Everything else already has
/// a home (`Settings` in Develop.swift, `Blocker.enabled`, `Search.current`) and is read
/// straight from there.
@MainActor enum Prefs {
    /// Empty means "whatever the current search engine's front page is", so switching
    /// engines moves the homepage with it until the user pins one down.
    static var homepage: URL {
        let stored = UserDefaults.standard.string(forKey: "homepage") ?? ""
        return Search.url(for: stored) ?? Search.current.home ?? Search.defaultEngine.home!
    }

    /// Off is a real preference (a fresh window every launch), so it persists; on is the
    /// behaviour main.swift already had.
    static var restoreSession: Bool {
        get { UserDefaults.standard.object(forKey: "restoreSession") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restoreSession") }
    }
}

/// The settings window. ponytail: one NSWindow we own, made once and reused — the app has
/// no AppDelegate and no `Settings` scene to hang a SwiftUI settings scene off, and the
/// frame autosave gives "remembers where it was" for free.
@MainActor enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = SettingsTab.all[0].title
        w.minSize = NSSize(width: 640, height: 480)
        w.isReleasedWhenClosed = false        // closing must not free the instance we keep
        // Before the hosting view: the pane retitles the window as it appears, and it can
        // only do that once `window` is the one it is inside.
        window = w
        w.contentView = NSHostingView(rootView: SettingsView())
        // Position first, autosave second: setFrameUsingName reports whether there was one.
        if !w.setFrameUsingName("VaneSettings") { w.center() }
        w.setFrameAutosaveName("VaneSettings")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The title bar names the pane you are looking at, the way Arc's and System Settings'
    /// do — the tab bar is icons, so the title is where the full word lives.
    static func retitle(_ title: String) { window?.title = title }
}

// MARK: - Tabs

/// One tab: icon, title (which is also the window title) and its pane. A list of values
/// rather than an enum plus two switches, so adding a tab is one line.
@MainActor struct SettingsTab: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Takes the selection so a pane can send the user to another tab.
    let pane: (Binding<String>) -> AnyView

    static let all: [SettingsTab] = [
        .init(id: "general", title: "General", icon: "gearshape",
              pane: { _ in AnyView(GeneralPane()) }),
        .init(id: "profiles", title: "Profiles", icon: "person",
              pane: { AnyView(ProfilesPane(tab: $0)) }),
        .init(id: "max", title: "Max", icon: "sparkles",
              pane: { _ in AnyView(MaxPane()) }),
        .init(id: "links", title: "Links", icon: "link",
              pane: { _ in AnyView(LinksPane()) }),
        // Shortcuts tab is wired on merge
        .init(id: "advanced", title: "Advanced", icon: "slider.horizontal.3",
              pane: { _ in AnyView(AdvancedPane()) }),
    ]
}

private struct SettingsView: View {
    @State private var selection = SettingsTab.all[0].id

    private var current: SettingsTab {
        SettingsTab.all.first { $0.id == selection } ?? SettingsTab.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $selection)
                .padding(.vertical, Look.inset)
            ScrollView {
                current.pane($selection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Look.inset * 2)
                    .padding(.bottom, Look.inset * 2)
            }
        }
        .background(.windowBackground)
        // Once, here: a preference is a switch in this window, never a checkbox.
        .toggleStyle(.switch)
        .onAppear { SettingsWindow.retitle(current.title) }
        .onChange(of: selection) { SettingsWindow.retitle(current.title) }
    }
}

/// Arc's centred icon bar: a 22pt symbol over an 11pt word, the selected one filled and
/// tinted. ponytail: buttons in an HStack, not a segmented control — a segmented control
/// cannot stack an icon over a label.
private struct TabBar: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: Look.inset / 2) {
            ForEach(SettingsTab.all) { tab in
                let on = tab.id == selection
                Button { selection = tab.id } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 22))
                            .frame(height: 26)
                        Text(tab.title).font(Look.caption)
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(width: 74)
                    .padding(.vertical, Look.inset / 2)
                    .background(on ? Look.selected : .clear,
                                in: .rect(cornerRadius: Look.pillRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Card and row
//
// Two shapes, used by every pane, so a preference looks the same wherever it lives: a
// grouped card of rows split by hairlines, and a row that is a title plus one control.

/// A grouped card. `_VariadicView` is how a container gets at its children one by one —
/// without it a ViewBuilder is one opaque blob and there is nowhere to put the hairlines.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .background(Look.pillFill, in: .rect(cornerRadius: Look.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Look.cardRadius).strokeBorder(Look.pillFill)
            }
    }
}

private struct DividedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { Divider().opacity(0.5) }
            }
        }
    }
}

/// A title on the left, one control on the right. Row height is the list row plus the
/// standard gap: settings rows breathe more than sidebar rows, and this keeps the two
/// numbers related instead of inventing a third.
struct SettingsRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Look.inset) {
            Text(title).font(Look.text)
            Spacer(minLength: Look.inset)
            trailing
        }
        .padding(.horizontal, Look.inset + 4)
        .frame(minHeight: Look.rowHeight + Look.inset)
    }
}

/// The grey sentence under a card. Its own view so every footnote is the same size, the
/// same colour and the same distance from the card it explains.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Look.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Look.inset + 4)
            .padding(.top, -Look.inset / 2)
    }
}

/// The vertical rhythm of a pane: cards a gap apart, footnotes hugging the card above.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) { content }
            .padding(.top, Look.inset)
    }
}

/// A text field that reads as a control rather than a hole in the card.
private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(Look.text)
            .padding(.horizontal, Look.inset)
            .padding(.vertical, Look.inset / 2)
            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
            .overlay { RoundedRectangle(cornerRadius: Look.pillRadius).strokeBorder(Look.pillFill) }
    }
}

private extension View {
    func settingsField() -> some View { modifier(FieldStyle()) }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage("homepage") private var homepage = ""
    // Blocker's own key. Writing it directly skips Blocker.enabled's setter, so the
    // recompile-and-reattach it would have done is hung off onChange instead.
    @AppStorage("blockerEnabled") private var blocking = true
    // HTTPSOnly reads this key straight out of defaults on every navigation, so writing it
    // here is the whole of the preference.
    @AppStorage("httpsOnly") private var httpsOnly = true
    @State private var restore = Prefs.restoreSession
    @State private var isDefault = URLHandling.isDefaultBrowser

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("Homepage") {
                    TextField("", text: $homepage, prompt: Text(Prefs.homepage.absoluteString))
                        .onSubmit {
                            // Same parser as the address bar, so "example.com" is enough.
                            if let u = Search.url(for: homepage) { homepage = u.absoluteString }
                        }
                        .settingsField().frame(width: 280)
                }
                SettingsRow("Reopen windows and tabs on launch") {
                    Toggle("", isOn: $restore).labelsHidden()
                        .onChange(of: restore) { Prefs.restoreSession = restore }
                }
            }

            SettingsCard {
                SettingsRow("Block ads and trackers") {
                    Toggle("", isOn: $blocking).labelsHidden()
                        .onChange(of: blocking) { Blocker.refresh(); rebuild() }
                }
                SettingsRow("Filter lists") {
                    Button("Add Filter List…") { Blocker.chooseAndAddList() }
                }
            }
            Footnote("Filter lists in EasyList syntax — an EasyList, EasyPrivacy or uBlock "
                     + "Origin subscription file.")

            SettingsCard {
                SettingsRow("HTTPS-Only Mode") {
                    Toggle("", isOn: $httpsOnly).labelsHidden()
                        .onChange(of: httpsOnly) { rebuild() }
                }
            }
            Footnote("Every page is loaded over an encrypted connection. A site that only "
                     + "offers http stops on a warning instead of loading in the clear.")

            SettingsCard {
                SettingsRow("Default browser") {
                    Button(isDefault ? "Vane is the default" : "Make Vane Default") {
                        URLHandling.makeDefaultBrowser()
                        isDefault = URLHandling.isDefaultBrowser
                    }
                    .disabled(isDefault)
                }
                SettingsRow("Browsing history") {
                    Button("Clear History…") {
                        if confirm("Clear all browsing history?", "Clear",
                                   "Bookmarks and saved passwords are not affected.") {
                            Store.shared.clearHistory()
                            rebuild()      // the History menu lists what was just deleted
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Profiles

private struct ProfilesPane: View {
    @Binding var tab: String
    @ObservedObject private var manager = ProfileManager.shared
    @State private var selected = ProfileManager.shared.active.id
    /// Non-nil while a profile row is an editable field rather than a label.
    @State private var renaming: UUID?
    @State private var draft = ""
    /// The right-hand name field. Separate from `draft` on purpose: focusing a TextField
    /// writes through its binding, so sharing one would put the list row into rename mode
    /// the moment the field was touched.
    @State private var name = ""
    /// Spaces come off disk, so they are read once per selection rather than per redraw.
    @State private var spaces: [Space] = []
    @State private var newSpace = ""
    /// So a row that has just become a text field is the one the keystrokes go to.
    @FocusState private var renameFocused: Bool

    private var profile: Profile {
        manager.profiles.first { $0.id == selected } ?? manager.profiles[0]
    }

    var body: some View {
        Pane {
            Text("Profiles keep your browsing separate — history, logins, cookies and "
                 + "extensions. A Space lives in exactly one Profile.")
                .font(Look.text).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Look.inset * 1.5) {
                list.frame(width: Look.sidebarWidth)
                VStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    identity
                    spacesCard
                    Text("Your Data and Settings").font(Look.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Look.inset + 4).padding(.bottom, -Look.inset)
                    data
                }
            }
        }
        .onAppear { reload() }
        // Not `renaming = nil` here: creating a profile selects it *and* opens its row for
        // renaming, and this fires after both.
        .onChange(of: selected) { reload() }
        .onChange(of: manager.profiles) { reload() }
    }

    // MARK: the list

    private var list: some View {
        SettingsCard {
            Text("Your Profiles").font(Look.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Look.inset + 4)
                .frame(maxWidth: .infinity, minHeight: Look.rowHeight, alignment: .leading)
            ForEach(manager.profiles) { p in
                row(p)
            }
            HStack(spacing: Look.inset * 2) {
                Button { add() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New Profile")
                Button { remove() } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Delete Profile")
                    .disabled(manager.profiles.count < 2)
                Button { draft = profile.name; renaming = profile.id } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename Profile")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Look.inset + 4)
            .frame(maxWidth: .infinity, minHeight: Look.rowHeight, alignment: .leading)
        }
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
                Text(p.name).font(Look.text)
                Spacer(minLength: Look.inset)
                Text(spaceCount(p)).font(Look.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.rowHeight + Look.inset / 2)
        .background(p.id == selected ? Look.selected : .clear,
                    in: .rect(cornerRadius: Look.pillRadius))
        .padding(.horizontal, 4)
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
                        manager.deleteSpace(space.id, in: profile.id)
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
                        newSpace = ""
                        reload(); rebuild()
                    }
                    .settingsField().frame(width: 200)
            }
        }
    }

    private var data: some View {
        SettingsCard {
            DataRow(icon: "lock.fill", tint: .blue, title: "Privacy and Security") {
                tab = "advanced"
            }
            DataRow(icon: "key.fill", tint: .green, title: "Passwords") {
                // The same place Menu.swift's Manage Saved Passwords… goes: the items are
                // real keychain items, and Keychain Access is the editor for those.
                NSWorkspace.shared.open(
                    URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
            }
            DataRow(icon: "trash.fill", tint: .red, title: "Clear Browsing Data") {
                if confirm("Clear the browsing history of “\(profile.name)”?", "Clear",
                           "Bookmarks and saved passwords are not affected.") {
                    Store.store(for: profile.id).clearHistory()
                    rebuild()
                }
            }
        }
    }

    private func reload() {
        spaces = manager.spaces(for: profile.id)
        name = profile.name
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
            HStack(spacing: Look.inset + 2) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(tint, in: .rect(cornerRadius: Look.pillRadius))
                Text(title).font(Look.text).foregroundStyle(.primary)
                Spacer(minLength: Look.inset)
                Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, Look.inset + 4)
            .frame(minHeight: Look.rowHeight + Look.inset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Max

private struct MaxPane: View {
    @AppStorage("appleAI") private var appleAI = true
    @AppStorage("tidyTabs") private var tidyTabs = true
    @AppStorage("tidyDownloads") private var tidyDownloads = false
    @AppStorage("tidyTitles") private var tidyTitles = true
    @AppStorage("linkPreviews") private var previews = true
    @AppStorage("instantLinks") private var instant = true

    private var off: Bool { !appleAI || !AppleAI.isAvailable }

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow("On-device AI features") {
                    Toggle("", isOn: $appleAI).labelsHidden().disabled(!AppleAI.isAvailable)
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
            }
            Footnote(AppleAI.unavailableReason
                     ?? "Apple's on-device model. Nothing is sent anywhere, and nothing "
                     + "happens until you ask for it — grouping tabs takes around twelve "
                     + "seconds, so it is a menu item, never automatic.")

            SettingsCard {
                // Not under the AI switch: the page render and its own description arrive in
                // well under a second and need no model. The summary is the part that does,
                // and it is extra rather than the point.
                SettingsRow("Link previews") { Toggle("", isOn: $previews).labelsHidden() }
            }
            Footnote("Hovering a link loads the page in the background to show it, which "
                     + "means the site sees a visit you did not make. If on-device AI is on, "
                     + "a summary follows once it is ready.")

            SettingsCard {
                SettingsRow("Instant Links") { Toggle("", isOn: $instant).labelsHidden() }
            }
            Footnote("Shift-Return on a search opens the top result directly instead of the "
                     + "results page. The query goes to DuckDuckGo whichever engine you use, "
                     + "because it is the only one that answers without JavaScript. Never in "
                     + "a private window, and never for anything that looks like an address.")
        }
    }
}

// MARK: - Links

private struct LinksPane: View {
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
            }
            Footnote("Press Tab in the address bar to ask this assistant instead of "
                     + "searching. Starting with an assistant's name — \u{201C}claude …\u{201D}, "
                     + "\u{201C}chatgpt …\u{201D} — overrides it for that one query. Vane opens the "
                     + "assistant's own site with the question; ChatGPT and Perplexity send "
                     + "it automatically, Claude fills it in for you to send.")

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
            }
            Footnote("Search suggestions send what you type in the address bar to your "
                     + "search engine as you type it. Never in a private window, and never "
                     + "for anything that looks like an address. A custom engine's address "
                     + "needs %s where the search words go.")

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
                    Text(bangError).font(Look.caption).foregroundStyle(.red)
                        .padding(.horizontal, Look.inset + 4)
                        .padding(.bottom, Look.inset)
                }
            }
            Footnote("A bang jumps straight to a site's own search: !gh swift searches "
                     + "GitHub. Around forty are built in; yours win over those.")
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

// MARK: - Advanced

private struct AdvancedPane: View {
    @AppStorage("userAgent") private var userAgent = safariUA
    @AppStorage("inspector") private var inspector = true

    var body: some View {
        Pane {
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
            }
            Footnote(Inspector.available
                     ? "Sites that sniff the browser see the user agent instead. Reload the "
                     + "page to apply it."
                     : "Sites that sniff the browser see the user agent instead. Reload the "
                     + "page to apply it. The in-app inspector is unavailable on this "
                     + "macOS — right-click → Inspect Element still works.")

            SettingsCard {
                SettingsRow("Camera and microphone") {
                    Button("Reset Permissions…") {
                        if confirm("Forget camera and microphone permissions for every site?",
                                   "Reset") {
                            SitePermissions.resetAll()
                        }
                    }
                }
                SettingsRow("Certificates you trusted anyway") {
                    Button("Forget Exceptions…") {
                        if confirm("Forget every certificate you chose to trust anyway?",
                                   "Forget",
                                   "Those sites will ask again the next time you visit them.") {
                            CertificateTrust.forgetAll()
                        }
                    }
                }
            }
        }
    }
}

/// The same NSAlert shape the menus use, so a destructive settings button asks the same way.
@MainActor private func confirm(_ message: String, _ verb: String, _ detail: String = "") -> Bool {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = detail
    a.addButton(withTitle: verb)
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}
