import AppKit
import SwiftUI
import WebKit

/// Speak something that otherwise only ever changes colour, appears silently, or lives in
/// an overlay VoiceOver has no reason to visit.
/// ponytail: NSAccessibility.post rather than SwiftUI's AccessibilityNotification — one
/// call, no availability dance, and it works from inside any of these views. Ceiling: it
/// is fire-and-forget, so there is no way to know whether it was actually spoken.
@MainActor func axAnnounce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text,
                                    .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

struct WebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

struct BrowserWindow: View {
    @EnvironmentObject var store: TabStore
    @FocusState private var addressFocused: Bool
    /// Per window, not global: two windows can each have their own palette open.
    @State private var palette: PaletteMode?

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(palette: $palette)
            Divider().opacity(0.5)
            Toolbar(addressFocused: $addressFocused)
            ZStack(alignment: .top) {
                if let tab = store.active {
                    WebView(web: tab.web).id(tab.id)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
                if let tab = store.active { LoadingBar(tab: tab) }
                // Everything that floats over the page. Declared after the web view so it
                // composites above it.
                VStack(spacing: 8) {
                    if store.findOpen, let tab = store.active {
                        FindBar(tab: tab).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let tab = store.active, tab.pendingSave != nil { SavePrompt(tab: tab) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                if !store.suggestions.isEmpty && addressFocused { Suggestions() }
                // Last, so it composites over the suggestions too.
                if let mode = palette {
                    PaletteView(mode: mode) { palette = nil }
                }
            }
        }
        .onChange(of: store.focusAddress) { addressFocused = true }
        // In .background so it costs no layout: the buttons are still in the view tree and
        // in the responder chain, which is all .keyboardShortcut needs.
        .background { Shortcuts(palette: $palette) }
    }
}

/// ⌘1–⌘8 select tab N and ⌘9 selects the last one, the way Safari and Chrome do; ⌘⇧P and
/// ⌘⇧A open the palette.
/// ponytail: hidden buttons rather than menu items — Menu.swift is built in AppKit and is
/// not this view's to extend, and a Button with a shortcut is the SwiftUI equivalent. They
/// are zero-size and transparent, *not* .hidden(), which would take them out of the
/// responder chain and stop the shortcuts firing.
/// ⌘9 is "last tab", not "tab 9" — matching Safari and Chrome.
@MainActor private func tabCommand(_ n: Int) -> Command {
    n == 9 ? .selectLastTab : (Command(rawValue: "selectTab\(n)") ?? .selectTab1)
}

private struct Shortcuts: View {
    @EnvironmentObject var store: TabStore
    @Binding var palette: PaletteMode?

    var body: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("Select Tab \(n)") { select(n) }
                    .keyboardShortcut(Keybindings.binding(for: tabCommand(n)).keyboardShortcut)
            }
            Button("Command Palette") { palette = .all }
                .keyboardShortcut(Keybindings.binding(for: .commandPalette).keyboardShortcut)
            Button("Search Tabs") { palette = .tabs }
                .keyboardShortcut(Keybindings.binding(for: .searchTabs).keyboardShortcut)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        // The tab strip already exposes selecting a tab and searching tabs as real
        // elements and actions. A pile of zero-size buttons on top of that is noise.
        .accessibilityHidden(true)
    }

    /// ⌘9 means "the last tab", not "tab nine" — every other Mac browser agrees.
    private func select(_ n: Int) {
        let i = n == 9 ? store.tabs.count - 1 : n - 1
        guard store.tabs.indices.contains(i) else { return }
        store.current = store.tabs[i].id
        axAnnounce("\(store.tabs[i].title), tab \(i + 1) of \(store.tabs.count)")
    }
}

/// ponytail: a rectangle, not ProgressView(.linear) — that style draws its own track and
/// rounded caps, which at 2pt reads as a stray dash sitting under the toolbar.
private struct LoadingBar: View {
    @ObservedObject var tab: Tab
    /// Reduce Motion turns the sweep and the fade into plain cuts — the bar still shows
    /// the same thing, it just stops moving.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.tint)
                .frame(width: geo.size.width * tab.progress)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: tab.progress)
        }
        .frame(height: 2)
        // Fades out on finish instead of vanishing, and never sweeps backwards when the
        // next navigation resets progress to zero behind the fade.
        .opacity(tab.loading ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: tab.loading)
        .allowsHitTesting(false)
        // Decoration: the tab chip says "loading" in words, which is the accessible copy
        // of this. Two elements for one fact is worse than one.
        .accessibilityHidden(true)
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @EnvironmentObject var store: TabStore
    @Binding var palette: PaletteMode?

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 72)          // traffic lights
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { TabChip(tab: $0) }
                }
            }
            // A container of chips, so VoiceOver reads this as a tab list and steps
            // through the tabs, instead of announcing an anonymous scroll area.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
            .accessibilityValue("\(store.tabs.count) open")
            .accessibilityHint("Command 1 through 8 selects a tab, Command 9 the last one.")
            .accessibilityAction(named: "Search Tabs") { palette = .tabs }
            .accessibilityAction(named: "New Tab") { store.newTab(nil) }

            Button { store.newTab(nil) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 6).help("New Tab (⌘T)")
                .accessibilityLabel("New Tab")
            Spacer(minLength: 0)
            if store.isPrivate {
                Label("Private", systemImage: "eyeglasses")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("This window keeps no history, cookies or cache.")
                    .accessibilityLabel("Private window")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(.bar)
    }
}

private struct TabChip: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = store.current == tab.id
        HStack(spacing: 6) {
            TabIcon(tab: tab)
            if !tab.pinned {
                Text(TidyTitles.title(for: tab)).lineLimit(1).font(.system(size: 12))
                    .foregroundStyle(selected ? .primary : .secondary)
                // A pinned tab is a permanent fixture — no close button to fat-finger.
                if hovering || selected {
                    Button { store.close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close Tab (⌘W)")
                    .accessibilityLabel("Close \(TidyTitles.title(for: tab))")
                }
            }
        }
        .padding(.horizontal, tab.pinned ? 0 : 10)
        .frame(width: tab.pinned ? 40 : 170, height: 26, alignment: tab.pinned ? .center : .leading)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 7))
        // The drop target is the whole chip, so the line shows which side it will land on.
        .overlay(alignment: .leading) {
            Rectangle().fill(.tint).frame(width: 2).opacity(targeted ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { store.current = tab.id }
        .help(tab.title)
        .draggable(tab.id.uuidString) {
            // Drag preview: the chip alone would drag the whole strip's background with it.
            HStack(spacing: 6) { TabIcon(tab: tab); Text(TidyTitles.title(for: tab)).lineLimit(1).font(.system(size: 12)) }
                .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .dropDestination(for: String.self) { ids, _ in drop(ids) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
            Divider()
            Button("Close Tab") { store.close(tab.id) }
            Button("Close Other Tabs") { closeOthers() }
        }
        // One element per tab, the way a tab in Safari reads: the title is the label, the
        // state is the value, and the close button becomes an action rather than a second
        // element the user has to find and then guess the meaning of.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TidyTitles.title(for: tab))
        .accessibilityValue(state)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this tab.")
        .accessibilityAction(named: "Close Tab") { store.close(tab.id) }
        .accessibilityAction(named: tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
        .accessibilityAction(named: "Close Other Tabs") { closeOthers() }
    }

    /// Everything the chip says with a picture, a position or a colour instead of words.
    private var state: String {
        var bits: [String] = []
        if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) {
            bits.append("tab \(i + 1) of \(store.tabs.count)")
        }
        if tab.pinned { bits.append("pinned") }
        bits.append(tab.loading ? "loading" : "loaded")
        return bits.joined(separator: ", ")
    }

    private func closeOthers() {
        // Pinned tabs are not "other tabs" — closing them would undo the pin.
        for t in store.tabs where t.id != tab.id && !t.pinned { store.close(t.id) }
    }

    /// The payload is the dragged tab's id; the drop index is this chip's own position.
    private func drop(_ ids: [String]) -> Bool {
        guard let id = ids.first,
              let from = store.tabs.firstIndex(where: { $0.id.uuidString == id }),
              let to = store.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        store.move(from: from, to: to)
        return true
    }
}

/// The site's own icon, with a globe standing in until it arrives (or forever, for a page
/// that has none).
private struct TabIcon: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            if let icon = tab.favicon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 14, height: 14)
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @EnvironmentObject var store: TabStore
    @FocusState.Binding var addressFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let tab = store.active {
                NavButtons(tab: tab)
                AddressField(tab: tab, focused: $addressFocused)
                if tab.readerAvailable || Reader.isOn(tab) {
                    Button { Reader.toggle(tab) } label: {
                        Image(systemName: Reader.isOn(tab) ? "doc.plaintext.fill" : "doc.plaintext")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Reader.isOn(tab) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help("Reader (⌥⌘R)")
                    .accessibilityLabel("Reader")
                    .accessibilityValue(Reader.isOn(tab) ? "On" : "Off")
                }
                Button { tab.toggleBookmark() } label: {
                    Image(systemName: tab.bookmarked ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.bookmarked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(tab.bookmarked ? "Remove Bookmark (⌘D)" : "Bookmark This Page (⌘D)")
                // Label stays constant and the state moves into the value, so VoiceOver
                // reads "Bookmark This Page, bookmarked" rather than renaming the control
                // under the user every time they press it.
                .accessibilityLabel("Bookmark This Page")
                .accessibilityValue(tab.bookmarked ? "Bookmarked" : "Not bookmarked")
                .accessibilityAddTraits(tab.bookmarked ? .isSelected : [])
                DownloadsButton(downloads: Downloads.manager(for: store.profileID))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser toolbar")
    }
}

private struct NavButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        // Icon-only, so each one carries its own label and tooltip — without them
        // VoiceOver announces three identical "button"s.
        Group {
            Button { tab.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
            Button { tab.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
            Button { tab.loading ? tab.stop() : tab.reload() } label: {
                Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
            }
            .help(tab.loading ? "Stop Loading" : "Reload Page (⌘R)")
            .accessibilityLabel(tab.loading ? "Stop Loading" : "Reload Page")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct AddressField: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @FocusState.Binding var focused: Bool
    @State private var draft = ""

    var body: some View {
        keyed
            .onChange(of: draft) { _, now in
                if focused { store.suggest(now) }
            }
            .onChange(of: focused) { _, now in
                tab.editing = now
                if !now { draft = tab.address; store.clearSuggestions() }
            }
            .onChange(of: tab.address) { _, now in if !focused { draft = now } }
            .onChange(of: tab.id) { draft = tab.address }
            .onAppear { draft = tab.address }
    }

    // ponytail: split in two because one chain of this length stopped type-checking in
    // reasonable time once Shift-Return was added. Nothing clever, just fewer modifiers
    // per expression.
    private var field: some View {
        TextField("Search or enter address", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .focused($focused)
    }

    private var keyed: some View {
        field
            .onSubmit {
                // Enter takes the highlighted suggestion if the user arrowed onto one.
                if let pick = store.pickedSuggestion, let u = URL(string: pick.url) {
                    tab.editing = false
                    tab.web.load(URLRequest(url: u))
                } else {
                    tab.go(draft)
                }
                store.clearSuggestions()
                focused = false
            }
            // onKeyPress, not onMoveCommand: a focused TextField's field editor swallows
            // the arrows to move its own insertion point, so onMoveCommand never fired and
            // the suggestion list could not be reached from the keyboard at all. onKeyPress
            // runs first, and .handled keeps the caret from jumping as a side effect.
            .onKeyPress(keys: [.return]) { press in
                // Shift-Return goes straight to the top result instead of the results page.
                guard press.modifiers.contains(.shift) else { return .ignored }
                store.goInstant(draft, from: tab)
                store.clearSuggestions()
                focused = false
                return .handled
            }
            .onKeyPress(.tab) {
                // .handled is required, or the field editor takes Tab as focus navigation.
                guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored }
                tab.ask(draft)
                store.clearSuggestions()
                focused = false
                return .handled
            }
            .onKeyPress(.upArrow) { store.moveSuggestion(-1); return .handled }
            .onKeyPress(.downArrow) { store.moveSuggestion(1); return .handled }
            .onExitCommand { store.clearSuggestions(); focused = false }
            .accessibilityLabel("Address and Search")
            .accessibilityHint("Type a website address or a search, then press Return. "
                               + "Up and down arrows choose a suggestion.")
            // The list is a separate overlay that appears out of nowhere and steals Return.
            // Announcing it is the only way a VoiceOver user finds out it is there at all.
            .onChange(of: store.suggestions.count) { _, n in
                guard focused, n > 0 else { return }
                axAnnounce("\(n) suggestion\(n == 1 ? "" : "s") available.")
            }
            .onChange(of: store.suggestionIndex) { _, i in
                guard let s = store.pickedSuggestion else { return }
                axAnnounce("\(s.title.isEmpty ? s.url : s.title), \(i + 1) of \(store.suggestions.count)")
            }
    }
}

private struct Suggestions: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.suggestions.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 8) {
                    Image(systemName: s.bookmarked ? "star.fill" : "clock")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(s.title.isEmpty ? s.url : s.title).lineLimit(1).font(.system(size: 12))
                    Text(s.url).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(i == store.suggestionIndex ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                .contentShape(.rect)
                .onTapGesture { open(s) }
                // One element per row: the title is the label, where it came from and the
                // url are the value, and the highlight is a trait rather than a colour.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.title.isEmpty ? s.url : s.title)
                .accessibilityValue("\(s.bookmarked ? "Bookmark" : "History"), \(s.url), "
                                    + "\(i + 1) of \(store.suggestions.count)")
                .accessibilityAddTraits(i == store.suggestionIndex ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Opens this page.")
                .accessibilityAction { open(s) }
            }
        }
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 14, y: 6)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address suggestions")
        // Read after the field being typed into, not before it.
        .accessibilitySortPriority(-1)
    }

    private func open(_ s: Suggestion) {
        if let u = URL(string: s.url) { store.active?.web.load(URLRequest(url: u)) }
        store.clearSuggestions()
    }
}

// MARK: - Overlays

/// Asking before storing a credential is the whole trust boundary here — never silent.
private struct SavePrompt: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let p = tab.pendingSave {
            HStack(spacing: 12) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save password for \(p.host)?").font(.system(size: 13, weight: .medium))
                    if !p.account.isEmpty {
                        Text(p.account).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Button("Not Now") { tab.pendingSave = nil }
                Button("Save") { tab.confirmSave() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .shadow(radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Save password for \(p.host)?")
            // A credential decision is the first thing in the window worth reaching, not
            // the last. Not .isModal, though: the page underneath stays usable.
            .accessibilitySortPriority(2)
            // It appears on its own, with no focus change and no sound — say so.
            .onAppear { axAnnounce("Vane can save the password for \(p.host).") }
        }
    }
}

private struct FindBar: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var text = ""
    @State private var miss = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 180)
                .focused($focused)
                .onSubmit { search(forward: true) }
                .onChange(of: text) { search(forward: true) }
                .foregroundStyle(miss ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .accessibilityLabel("Find on Page")
                .accessibilityValue(miss ? "No matches" : "")
            Button { search(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Match").accessibilityLabel("Previous Match")
            Button { search(forward: true) }  label: { Image(systemName: "chevron.down") }
                .help("Next Match").accessibilityLabel("Next Match")
            Button { store.findOpen = false } label: { Image(systemName: "xmark") }
                .help("Close Find Bar").accessibilityLabel("Close Find Bar")
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 10, y: 4)
        // Focus lands in the field the moment the bar opens, so the first thing after ⌘F
        // is typing — for the keyboard and for VoiceOver alike.
        .onAppear { focused = true }
        .onExitCommand { store.findOpen = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on page")
        // Ahead of the page, behind a password prompt.
        .accessibilitySortPriority(1)
    }

    private func search(forward: Bool) {
        Task {
            let hit = await tab.find(text, forward: forward)
            miss = !hit
            // Turning the text red is not an answer for anyone who cannot see it.
            if !hit && !text.isEmpty { axAnnounce("No matches for \(text)") }
        }
    }
}

private struct DownloadsButton: View {
    /// Passed in from the window's own store, not read from `Downloads.shared`. `shared`
    /// resolves to whichever profile is active at the moment the view is built, so a
    /// background window of another profile would show — and act on — the wrong list.
    @ObservedObject var downloads: Downloads
    @State private var open = false

    var body: some View {
        if !downloads.items.isEmpty {   // now includes finished history, not just active
            Button { open.toggle() } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Downloads")
                .accessibilityLabel("Downloads")
                .accessibilityValue("\(downloads.items.count) item\(downloads.items.count == 1 ? "" : "s")")
                .accessibilityHint("Shows what has been downloaded.")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(downloads.items) { DownloadRow(item: $0, downloads: downloads) }
                    }
                    .padding(14).frame(width: 320)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Downloads")
                }
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: Downloads.Item
    /// The manager this row's item actually belongs to.
    let downloads: Downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name).lineLimit(1).font(.system(size: 12))
                    .accessibilityLabel(item.name)
                    .accessibilityValue(status)
                Spacer(minLength: 8)
                if item.state == .done {
                    // A renamed download is .done, so this has to sit beside Show rather
                    // than in an else-branch it could never reach.
                    if TidyDownloads.canUndo(item) {
                        Button("Undo Rename") { _ = TidyDownloads.undo(item, in: downloads) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .accessibilityLabel("Undo renaming \(item.name)")
                    }
                    Button("Show") { downloads.reveal(item) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
                        .help("Show in Finder")
                        // "Show" on its own says nothing once it is out of context.
                        .accessibilityLabel("Show \(item.name) in Finder")
                } else if downloads.canResume(item) {
                    // Item.State stays three cases because UI.swift switches it
                    // exhaustively, so a paused download arrives as .failed("Paused").
                    // Without this it reads as a dead row with no way back.
                    Button("Resume") { _ = downloads.resume(item) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
                        .help("Resume this download")
                        .accessibilityLabel("Resume \(item.name)")
                } else if item.status == .running {
                    Button("Pause") { downloads.pause(item) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Pause this download")
                        .accessibilityLabel("Pause \(item.name)")
                }
            }
            switch item.state {
            case .running:
                ProgressView(value: item.fraction).progressViewStyle(.linear)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int(item.fraction * 100)) percent")
            case .done:    EmptyView()
            case .failed(let why):
                Text(why).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The progress bar and the red text, in words.
    private var status: String {
        switch item.state {
        case .running:         "downloading, \(Int(item.fraction * 100)) percent"
        case .done:            "finished"
        case .failed(let why): "failed, \(why)"
        }
    }
}
