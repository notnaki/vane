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

/// ponytail: `sizeThatFits` is the whole reason this is not a two-line representable. A
/// WKWebView turns its autoresizing mask into constraints, so its fitting size is whatever
/// it currently is — SwiftUI hands that same size back and the page keeps the width it had
/// when the sidebar was last shown. Returning the proposal says "I take whatever you give
/// me", which is what a page inside a card actually wants.
struct WebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }
}

// MARK: - Window

/// The window: a sidebar and the page as a floating card, on a ground of behind-window blur
/// tinted by the current space. Nothing here is opaque — `WindowGlass` is the only ground,
/// so the desktop shows through everything the sidebar does not cover.
struct BrowserWindow: View {
    @EnvironmentObject var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sidebar sliding in over the page because the pointer went to the window's edge.
    @State private var peeking = false
    @State private var peekTask: Task<Void, Never>?

    private var chrome: Bool { store.sidebarShown || peeking }

    var body: some View {
        ZStack(alignment: .leading) {
            WindowGlass()
            Look.ground
            ThemeTint()
            HStack(spacing: 0) {
                if store.sidebarShown { Sidebar().frame(width: Look.sidebarWidth) }
                WebCard()
            }
            edgeStrip
            floatingSidebar
            // Last, so the search bar composites over the sidebar as well as the page.
            if let mode = store.palette {
                PaletteView(mode: mode) { dismissPalette() }
                    // The bar fades itself in; this is the way out — Escape and a click
                    // on the scrim dissolve it rather than cutting to the page.
                    .transition(.opacity)
            }
        }
        // The window is `.fullSizeContentView`, but SwiftUI still keeps a titlebar-sized
        // safe area at the top. Without this the sidebar's first row sits *below* the
        // traffic lights instead of beside them, and the card loses its top inset.
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.sidebarShown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: peeking)
        .animation(reduceMotion ? nil : Look.appear, value: store.palette == nil)
        // Arc hides the traffic lights along with the sidebar: a collapsed window is the
        // page and nothing else. They come back the moment either sidebar does.
        .onChange(of: chrome, initial: true) { showTrafficLights(chrome) }
        .onAppear { store.applySpaceAppearance() }
        // In .background so it costs no layout: the buttons are still in the view tree and
        // in the responder chain, which is all .keyboardShortcut needs.
        .background { Shortcuts() }
    }

    /// The 6pt of window edge that brings the sidebar back. Only live while it is away.
    @ViewBuilder private var edgeStrip: some View {
        if !store.sidebarShown {
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .onHover { if $0 { peekTask?.cancel(); peeking = true } }
                .accessibilityHidden(true)      // ⌘S is the accessible route back
        }
    }

    @ViewBuilder private var floatingSidebar: some View {
        if !store.sidebarShown && peeking {
            Sidebar()
                .frame(width: Look.sidebarWidth)
                .glass(radius: Look.cardRadius)
                // The same near-opaque ground as the command bar: this one floats over the
                // page, and glass alone over a white page is a white panel.
                .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
                .hairline(radius: Look.cardRadius)
                .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
                .padding(Look.inset)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .onHover { $0 ? peekTask?.cancel() : endPeek() }
        }
    }

    /// A small delay on the way out, so crossing the gap between the strip and the panel
    /// does not slam it shut under the pointer.
    private func endPeek() {
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            peeking = false
        }
    }

    private func showTrafficLights(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            store.window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    /// Nothing to undo on dismiss: ⌘T makes no tab until the bar is submitted.
    private func dismissPalette() { store.palette = nil }
}

/// The current space's colour washed over the window, behind the sidebar *and* behind the
/// gap around the card, which is what makes the card read as floating on something rather
/// than sitting in a grey box. Falls back to the profile's colour at a whisper, then to
/// nothing at all.
private struct ThemeTint: View {
    @EnvironmentObject var store: TabStore
    @EnvironmentObject var profiles: ProfileManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One even wash, not a bottom-weighted gradient: the gradient's strongest band
        // landed in the 8pt gap under the card, where it read as a fat coloured bar
        // along the card's bottom edge rather than as the sidebar's tint.
        // Always in the tree, clear when there is no tint, so switching space cross-fades
        // one colour into the next instead of cutting — the fade *is* what says the whole
        // window changed space, not just the list.
        (tint?.0 ?? .clear).opacity(tint?.1 ?? 0)
            .animation(reduceMotion ? nil : Look.appear, value: store.currentSpaceID)
            .animation(reduceMotion ? nil : Look.appear, value: store.spaceRevision)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var tint: (Color, Double)? {
        if let space = store.currentSpace, let hex = space.colorHex, let c = Color(hex: hex) {
            return (c, space.tint ?? 0.35)
        }
        if let c = Color(hex: store.profile.colorHex) { return (c, 0.10) }
        return nil
    }
}

/// ⌘1–⌘8 select tab N and ⌘9 selects the last one, the way Safari and Chrome do; ⌘⇧P and
/// ⌘⇧A open the search bar.
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

    var body: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("Select Tab \(n)") { select(n) }
                    .keyboardShortcut(Keybindings.binding(for: tabCommand(n)).keyboardShortcut)
            }
            Button("Search") { store.palette = .all }
                .keyboardShortcut(Keybindings.binding(for: .commandPalette).keyboardShortcut)
            Button("Search Tabs") { store.palette = .tabs }
                .keyboardShortcut(Keybindings.binding(for: .searchTabs).keyboardShortcut)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        // The sidebar already exposes selecting a tab and searching tabs as real elements
        // and actions. A pile of zero-size buttons on top of that is noise.
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

// MARK: - The page

/// The web view as a rounded card floating on the window's glass, with everything that
/// hovers over the page (find, the save-password prompt) inside its clip.
private struct WebCard: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        ZStack(alignment: .top) {
            if let tab = store.active {
                WebView(web: tab.web).id(tab.id)
            } else {
                // No tabs: nothing to draw. The glass ground shows through, like the sidebar.
                Color.clear
            }
            if let tab = store.active { LoadingBar(tab: tab) }
            VStack(spacing: 8) {
                if store.findOpen, let tab = store.active {
                    FindBar(tab: tab).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let tab = store.active, tab.pendingSave != nil { SavePrompt(tab: tab) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        .clipShape(.rect(cornerRadius: Look.cardRadius))
        // No inset on the leading edge while the sidebar is docked: the sidebar's own
        // padding already leaves the gap, and doubling it reads as a misaligned card.
        .padding(.leading, store.sidebarShown ? 0 : Look.inset)
        .padding([.top, .trailing, .bottom], Look.inset)
    }
}

/// ponytail: a rectangle, not ProgressView(.linear) — that style draws its own track and
/// rounded caps, which at 2pt reads as a stray dash lying on the page.
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
        // Decoration: the tab row says "loading" in words, which is the accessible copy of
        // this. Two elements for one fact is worse than one.
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        VStack(spacing: 8) {
            TopRow()
            AddressPill(tab: store.active)
            ScrollView {
                VStack(spacing: Look.rowGap) {
                    Favorites().padding(.bottom, Look.inset - Look.rowGap)
                    SpaceRow()
                    BookmarkList(tab: store.active)
                    TidyRow()
                    NewTabRow()
                    OpenTabs()
                }
            }
            .scrollIndicators(.never)
            BottomRow()
        }
        .padding(.horizontal, Look.inset)
        .padding(.bottom, Look.inset)
        .padding(.top, Look.topInset)
        .frame(width: Look.sidebarWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }
}

/// Traffic lights, the sidebar toggle, and the page's own navigation. AppKit owns where the
/// lights are drawn, so the row is laid out around them.
private struct TopRow: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 62)          // traffic lights
            Button { store.sidebarShown.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Toggle Sidebar (\(Keybindings.binding(for: .toggleSidebar).display))")
                .accessibilityLabel("Toggle Sidebar")
                .accessibilityValue(store.sidebarShown ? "Shown" : "Hidden")
            if store.isPrivate {
                Image(systemName: "eyeglasses")
                    .help("This window keeps no history, cookies or cache.")
                    .accessibilityLabel("Private window")
            }
            Spacer(minLength: 0)
            NavButtons(tab: store.active)
        }
        .buttonStyle(.plain)
        .font(Look.icon)
        .foregroundStyle(.secondary)
        .frame(height: Look.topRow)
    }
}

/// The page's back, forward and reload. With no page they stay where they are, disabled:
/// nothing in the sidebar's chrome may come and go because a tab closed — the user read
/// that as the window emptying out rather than as one tab going away.
private struct NavButtons: View {
    let tab: Tab?

    var body: some View {
        if let tab {
            LiveNavButtons(tab: tab)
        } else {
            NavGlyphs(tab: nil, back: false, forward: false, loading: false)
        }
    }
}

/// Split from `NavGlyphs` only so the tab can be observed: `@ObservedObject` cannot be
/// optional, and the disabled state above has no tab to observe.
private struct LiveNavButtons: View {
    @ObservedObject var tab: Tab
    var body: some View {
        NavGlyphs(tab: tab, back: tab.canGoBack, forward: tab.canGoForward, loading: tab.loading)
    }
}

private struct NavGlyphs: View {
    let tab: Tab?
    let back: Bool
    let forward: Bool
    let loading: Bool

    var body: some View {
        // Icon-only, so each one carries its own label and tooltip — without them
        // VoiceOver announces three identical "button"s.
        HStack(spacing: 16) {
            Button { tab?.back() } label: { Image(systemName: "arrow.left") }
                .disabled(!back)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
            Button { tab?.forward() } label: { Image(systemName: "arrow.right") }
                .disabled(!forward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
            Button { loading ? tab?.stop() : tab?.reload() } label: {
                Image(systemName: loading ? "xmark" : "arrow.clockwise")
            }
            .disabled(tab == nil)
            .help(loading ? "Stop Loading" : "Reload Page (⌘R)")
            .accessibilityLabel(loading ? "Stop Loading" : "Reload Page")
        }
        .buttonStyle(.plain)
    }
}

/// Where the address bar used to be. It is a button, not a field: typing happens in the
/// search bar, which is the one place in Vane a url or a search is entered.
/// With no tab it stays, empty: same fill, same height, glyphs disabled, and a click opens
/// the search bar to make the first tab. The sidebar keeps its shape whatever is open.
private struct AddressPill: View {
    let tab: Tab?

    var body: some View {
        if let tab {
            LiveAddressPill(tab: tab)
        } else {
            PillBody(tab: nil, host: "", address: "", reader: false, readerOn: false)
        }
    }
}

/// Split from `PillBody` only so the tab can be observed; the empty pill has none.
private struct LiveAddressPill: View {
    @ObservedObject var tab: Tab

    var body: some View {
        PillBody(tab: tab, host: host, address: tab.address,
                 reader: tab.readerAvailable || Reader.isOn(tab), readerOn: Reader.isOn(tab))
    }

    /// The host alone, the way Arc shows it — the scheme and `www.` are noise the user has
    /// never needed to read.
    private var host: String {
        guard let h = tab.currentURL?.host() else {
            return tab.address.isEmpty ? "Search or Enter URL" : tab.address
        }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

private struct PillBody: View {
    @EnvironmentObject var store: TabStore
    let tab: Tab?
    let host: String
    let address: String
    let reader: Bool
    let readerOn: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if reader, let tab {
                Button { Reader.toggle(tab) } label: {
                    Image(systemName: readerOn ? "doc.plaintext.fill" : "doc.plaintext")
                }
                .buttonStyle(.plain)
                .foregroundStyle(readerOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Reader (⌥⌘R)")
                .accessibilityLabel("Reader")
                .accessibilityValue(readerOn ? "On" : "Off")
            }
            Text(host).font(Look.text).lineLimit(1).foregroundStyle(.primary)
            Spacer(minLength: 4)
            // Always there, as in Arc: two quiet glyphs read better than a row that grows
            // controls under the pointer. Disabled, not hidden, when there is no page.
            Button { copyLink() } label: { Image(systemName: "link") }
                .disabled(tab == nil)
                .help("Copy Link")
                .accessibilityLabel("Copy Link")
            Button { SettingsWindow.show() } label: { Image(systemName: "slider.horizontal.3") }
                // ponytail: the whole settings window, not a per-site sheet. Site settings
                // do not exist yet; when they do, this is the one caller to change.
                .disabled(tab == nil)
                .help("Site Settings")
                .accessibilityLabel("Site Settings")
        }
        .buttonStyle(.plain)
        .font(Look.rowText)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Look.barRowInset)
        .frame(height: Look.pillHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A step up under the pointer, the way a row does: the pill is a button, and a
        // button that does not react reads as a label.
        .background(hovering ? Look.selected : Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
        .glass(radius: Look.pillRadius)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .help(address.isEmpty ? "Search or Enter URL" : address)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address and Search")
        .accessibilityValue(address.isEmpty ? "Empty" : address)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the search bar to type a website address or a search.")
        .accessibilityAction { open() }
        .accessibilityAction(named: "Copy Link") { copyLink() }
    }

    /// With a page, the bar opens on its address; with none, on nothing — and what is
    /// submitted becomes the window's first tab.
    private func open() { store.palette = tab == nil ? .newTab : .address }

    private func copyLink() {
        guard let u = tab?.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        axAnnounce("Link copied.")
    }
}

// MARK: - Favourites

/// Pinned tabs as a grid of tiles, Arc's way: a place, not a page. A tile stays put when its
/// page is closed (`TabStore.close` parks it), and only Unpin — or a drag down into the
/// list — takes it out. Columns follow the count (`TabStore.favouriteColumns`), so one
/// favourite is one wide tile and seven are a 4-wide grid, never two fixed slots.
private struct Favorites: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        let pinned = store.tabs.filter(\.pinned)
        if pinned.isEmpty {
            FavoritesPlaceholder()
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.inset),
                                     count: TabStore.favouriteColumns(pinned.count)),
                      spacing: Look.inset) {
                ForEach(pinned) { FavoriteTile(tab: $0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Favourites")
            .accessibilityValue("\(pinned.count) pinned")
        }
    }
}

/// One quiet full-width tile where the grid will be: the sidebar keeps its shape with
/// nothing pinned, and the first favourite has somewhere to be dropped. A card's fill
/// rather than a tile's, so it reads as a place rather than as a tile that lost its icon.
private struct FavoritesPlaceholder: View {
    @EnvironmentObject var store: TabStore
    @State private var side: DropSide?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: Look.pillRadius)
            .fill(side == nil ? Look.cardFill : Look.hovered)
            .frame(maxWidth: .infinity, minHeight: Look.tileHeight)
            .overlay {
                Image(systemName: "star").font(Look.symbol).foregroundStyle(.quaternary)
            }
            .animation(reduceMotion ? nil : Look.quick, value: side == nil)
            .onDrop(of: [.plainText],
                    delegate: TabDrop(store: store, target: nil, axis: .horizontal, extent: 0, side: $side))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Favourites")
            .accessibilityValue("None pinned")
            .accessibilityHint("Drag a tab here to pin it.")
    }
}

private struct FavoriteTile: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var hovering = false
    @State private var side: DropSide?
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected = store.current == tab.id
        TabIcon(tab: tab, size: Look.tileIcon)
            .frame(maxWidth: .infinity, minHeight: Look.tileHeight)
            // Hover steps the tile up to the selected fill, the way the address pill does:
            // a tile is a button, and a button that does not react reads as a label.
            .background(selected || hovering ? Look.selected : Look.pillFill,
                        in: .rect(cornerRadius: Look.pillRadius))
            .glass(radius: Look.pillRadius)
            .overlay(alignment: side == .after ? .trailing : .leading) {
                DropLine(on: side != nil, axis: .horizontal)
            }
            .animation(reduceMotion ? nil : Look.quick, value: hovering)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { store.current = tab.id }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .help(tab.title)
            .onDrag { dragPayload(tab) } preview: { TabIcon(tab: tab, size: Look.tileIcon).padding(6) }
            .onDrop(of: [.plainText],
                    delegate: TabDrop(store: store, target: tab, axis: .horizontal, extent: width, side: $side))
            .contextMenu {
                Button("Unpin Tab") { store.togglePin(tab.id) }
                Divider()
                Button("Close Tab") { store.close(tab.id) }
            }
            // One element per favourite, the way a tab reads: the title is the label, the
            // state is the value, and unpin/close are actions rather than hidden gestures.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TidyTitles.title(for: tab))
            .accessibilityValue(tabState(tab, in: store))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Shows this tab.")
            .accessibilityAction(named: "Unpin Tab") { store.togglePin(tab.id) }
            .accessibilityAction(named: "Close Tab") { store.close(tab.id) }
    }
}

/// Everything a tab row says with a picture, a position or a colour instead of words.
@MainActor private func tabState(_ tab: Tab, in store: TabStore) -> String {
    var bits: [String] = []
    if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) {
        bits.append("tab \(i + 1) of \(store.tabs.count)")
    }
    if tab.pinned { bits.append("pinned") }
    if TabAudio.isMuted(tab) { bits.append("muted") } else if tab.audible { bits.append("playing audio") }
    bits.append(tab.loading ? "loading" : "loaded")
    return bits.joined(separator: ", ")
}

// MARK: Drag and drop

/// Which side of its target a drop will land on.
private enum DropSide { case before, after }

/// The tab being dragged, for the whole app. A drag never leaves the process, so a drop
/// reads it straight back rather than round-tripping the item provider — which is
/// asynchronous, and would leave `dropUpdated` unable to say whether this is one of ours.
/// Observable so every drop line goes out the moment the drop lands: SwiftUI does not send
/// `dropExited` to the target that performed the drop, and a line left behind read as a
/// second, phantom favourite.
@MainActor private final class Dragging: ObservableObject {
    static let shared = Dragging()
    @Published var tab: Tab.ID?
}

/// ponytail: `.onDrag`/`.onDrop` with a delegate rather than `.draggable`/`.dropDestination`.
/// The Transferable pair cannot say which side of the target the pointer is on, so it can
/// only ever drop *onto* a tab, never before or after it; this one gets the location.
@MainActor private func dragPayload(_ tab: Tab) -> NSItemProvider {
    // Published on the next turn, not now: a state change inside the drag's own start
    // re-renders the row under the pointer, and SwiftUI drops the drag with it.
    let id = tab.id
    DispatchQueue.main.async { Dragging.shared.tab = id }
    return NSItemProvider(object: id.uuidString as NSString)
}

/// The 2pt line a drop will land on, at one edge of its target. `on` is the target's own
/// hover state; the line also needs a live drag, so a stale state cannot leave it behind.
private struct DropLine: View {
    let on: Bool
    let axis: Axis
    @ObservedObject private var dragging = Dragging.shared

    var body: some View {
        Rectangle().fill(.tint)
            .frame(width: axis == .horizontal ? Look.dropLine : nil,
                   height: axis == .vertical ? Look.dropLine : nil)
            .opacity(on && dragging.tab != nil ? 1 : 0)
    }
}

/// One drop target for a tile, a row and the empty grid. `target` nil is the placeholder,
/// which simply pins. The side is the half of the target the pointer is in — left/right
/// across `extent` for a tile, top/bottom of `Look.rowHeight` for a row — and is published
/// through `side` so the target can draw its line before the button is released.
private struct TabDrop: DropDelegate {
    let store: TabStore
    let target: Tab?
    let axis: Axis
    let extent: CGFloat
    @Binding var side: DropSide?

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragging = Dragging.shared.tab else { return false }
        return dragging != target?.id
    }
    func dropEntered(info: DropInfo) { side = which(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard Dragging.shared.tab != nil else { return DropProposal(operation: .cancel) }
        side = which(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = which(info) == .after
        side = nil
        guard let id = Dragging.shared.tab else { return false }
        Dragging.shared.tab = nil
        if let target { store.drop(id, onto: target.id, after: after) } else { store.pin(id) }
        return true
    }

    private func which(_ info: DropInfo) -> DropSide {
        switch axis {
        case .horizontal: info.location.x > extent / 2 ? .after : .before
        case .vertical:   info.location.y > Look.rowHeight / 2 ? .after : .before
        }
    }
}

// MARK: - Spaces

/// The space's name at the head of the list, the way Arc labels the tabs below it. Also the
/// right-click target for everything a space can be: its icon, its name, its colour and the
/// profile it belongs to.
private struct SpaceRow: View {
    @EnvironmentObject var store: TabStore
    @State private var icons = false
    @State private var theme = false

    var body: some View {
        if let space = store.currentSpace {
            row(space.icon ?? "cloud", space.name)
            .contextMenu { SpaceMenu(store: store, space: space, icons: $icons, theme: $theme) }
            .popover(isPresented: $icons) { SpaceIcons(store: store, space: space) }
            .popover(isPresented: $theme) { SpaceTheme(store: store, space: space) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space")
            .accessibilityValue(space.name)
            .accessibilityHint("Right-click to rename this space or change its icon and colour.")
            .accessibilityAction(named: "Rename Space") { renameSpace(space, in: store) }
            .accessibilityAction(named: "Change Space Icon") { icons = true }
            .accessibilityAction(named: "Edit Theme Color") { theme = true }
        } else {
            // A window outside any space still has this row, wearing the profile's name:
            // the list below it needs its heading, and the sidebar its shape.
            row("cloud", store.profile.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space")
            .accessibilityValue(store.profile.name)
            .accessibilityHint("This window is not in a space. The plus button below makes one.")
        }
    }

    private func row(_ icon: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16)
            Text(name).font(Look.text)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Look.rowHeight)
        .contentShape(.rect)
    }
}

/// Exactly the items Arc offers, minus the ones Vane has nothing behind.
/// ponytail: no New Folder, no Live Folders, no Share Space and no Export — folders and
/// sharing are whole features, not menu items, and an entry that opens an apology is worse
/// than no entry. They belong above `Manage Spaces…` on the day they exist.
/// ponytail: `store` is passed in rather than read from the environment. A context menu is
/// hosted in its own window, and an `@EnvironmentObject` that fails to reach it is a crash,
/// not a blank menu — not a risk worth taking for a shorter initialiser.
private struct SpaceMenu: View {
    let store: TabStore
    let space: Space
    @Binding var icons: Bool
    @Binding var theme: Bool

    var body: some View {
        Button("Change Space Icon…") { icons = true }
        Button("Rename Space…") { renameSpace(space, in: store) }
        Button("Edit Theme Color…") { theme = true }
        Menu("Set Profile") {
            ForEach(ProfileManager.shared.profiles) { profile in
                Button { moveSpace(space, to: profile, from: store) } label: {
                    if profile.id == space.profileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        }
        Divider()
        // The Profiles pane of Settings is the spaces list; there is no second surface.
        Button("Manage Spaces…") { SettingsWindow.show() }
        Divider()
        Button("Delete Space") { deleteSpace(space, in: store) }
            .disabled(store.spaces.count < 2)
    }
}

@MainActor private func renameSpace(_ space: Space, in store: TabStore) {
    guard let name = askForName("Rename space", space.name) else { return }
    var edited = space
    edited.name = name
    store.update(space: edited)
    rebuild()                      // the Spaces menu lists the names
}

@MainActor private func deleteSpace(_ space: Space, in store: TabStore) {
    guard store.spaces.count > 1 else { return }
    let a = NSAlert()
    a.messageText = "Delete the space “\(space.name)”?"
    a.informativeText = "Its tabs and pinned tabs go with it. Nothing in your history, "
        + "bookmarks or saved passwords is affected."
    a.alertStyle = .critical
    a.addButton(withTitle: "Cancel")
    a.addButton(withTitle: "Delete")
    a.buttons.last?.hasDestructiveAction = true
    guard a.runModal() == .alertSecondButtonReturn else { return }
    let survivor = store.spaces.first { $0.id != space.id }
    ProfileManager.shared.deleteSpace(space.id, in: space.profileID)
    if let survivor { store.switchTo(space: survivor) }
    rebuild()
}

/// ponytail: a window's profile is fixed for its lifetime — the data store, the cookie jar
/// and the extension host are all built from it in `TabStore.init`. So moving a space to
/// another profile opens it in a window there and closes this one, rather than trying to
/// re-home a live WKWebsiteDataStore. Ceiling: the window's position is not carried over.
@MainActor private func moveSpace(_ space: Space, to profile: Profile, from store: TabStore) {
    guard profile.id != space.profileID else { return }
    store.saveCurrentSpace()
    ProfileManager.shared.deleteSpace(space.id, in: space.profileID)
    var moved = space
    moved.profileID = profile.id
    ProfileManager.shared.updateSpace(moved)
    Windows.open(profile: profile, space: moved)
    store.window?.performClose(nil)
    rebuild()
}

/// A grid of SF Symbols. ponytail: a fixed list, not a symbol browser — 24 covers what a
/// space is ever named after, and the alternative is shipping a search field over an API
/// that cannot enumerate itself.
private struct SpaceIcons: View {
    let store: TabStore
    let space: Space
    @Environment(\.dismiss) private var dismiss

    private static let symbols = [
        "cloud", "star", "bolt", "book", "briefcase", "gamecontroller",
        "music.note", "heart", "leaf", "flame", "house", "cart",
        "graduationcap", "hammer", "paintbrush", "globe", "camera", "film",
        "airplane", "car", "cup.and.saucer", "sparkles", "moon", "sun.max",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.rowHeight), spacing: 6), count: 6),
                  spacing: 6) {
            ForEach(Self.symbols, id: \.self) { name in
                Button { pick(name) } label: { tile(name) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(current == name ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space icon")
    }

    private var current: String { space.icon ?? "cloud" }

    private func tile(_ name: String) -> some View {
        Image(systemName: name)
            .font(Look.icon)
            .frame(width: Look.rowHeight, height: Look.rowHeight)
            .background(current == name ? Look.selected : .clear,
                        in: .rect(cornerRadius: Look.pillRadius))
    }

    private func pick(_ name: String) {
        var edited = space
        edited.icon = name
        store.update(space: edited)
        dismiss()
    }
}

/// Arc's theme editor, minus the parts that are a graphics project rather than a control.
/// ponytail: no 2D gradient picker and no grain dial. One colour, one strength and a
/// light/dark switch is the whole model behind `ThemeTint`; a second colour and a noise
/// texture would need a real gradient renderer before they could mean anything.
private struct SpaceTheme: View {
    let store: TabStore
    let space: Space

    var body: some View {
        VStack(spacing: Look.inset * 2) {
            appearance
            swatches
            strength
        }
        .padding(Look.inset * 2)
        // Sized here, not by the popover: NSPopover takes the hosting view's first fitting
        // size, which for a flexible grid plus a slider came out narrower than the content
        // and clipped the row at the bottom.
        .frame(width: Look.themeWidth)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme colour")
    }

    private var appearance: some View {
        HStack(spacing: 10) {
            mode(nil, "sparkles", "Automatic")
            mode("light", "sun.max", "Light")
            mode("dark", "moon", "Dark")
        }
    }

    private func mode(_ value: String?, _ symbol: String, _ label: String) -> some View {
        Button { edit { $0.appearance = value } } label: {
            Image(systemName: symbol)
                .font(Look.symbol)
                .frame(width: Look.topRow + Look.pillRadius, height: Look.topRow)
                .background(space.appearance == value ? Look.selected : .clear,
                            in: .rect(cornerRadius: Look.pillRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(space.appearance == value ? [.isButton, .isSelected] : .isButton)
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.swatch), spacing: Look.inset), count: 7),
                  spacing: Look.inset) {
            ForEach(Look.themeSwatches, id: \.self) { hex in
                swatch(hex)
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: Look.swatch, height: Look.swatch)
            // Arc's ring stands off the swatch (ref 8) rather than lying on its edge, so
            // the chosen colour is still a full disc.
            .overlay {
                Circle().strokeBorder(.primary, lineWidth: 2)
                    .padding(-4)
                    .opacity(space.colorHex == hex ? 1 : 0)
            }
            .contentShape(.circle)
            .onTapGesture { edit { $0.colorHex = hex; $0.tint = $0.tint ?? 0.35 } }
            .accessibilityLabel("Theme colour \(hex)")
            .accessibilityAddTraits(space.colorHex == hex ? [.isButton, .isSelected] : .isButton)
    }

    private var strength: some View {
        HStack(spacing: Look.inset + 2) {
            Image(systemName: "circle.lefthalf.filled").font(Look.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { space.tint ?? 0.35 },
                                  set: { v in edit { $0.tint = v } }), in: 0...1)
                .accessibilityLabel("Colour strength")
            Button("None") { edit { $0.colorHex = nil } }
                .buttonStyle(.plain).font(Look.caption).foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("No theme colour")
        }
    }

    private func edit(_ change: (inout Space) -> Void) {
        var copy = space
        change(&copy)
        store.update(space: copy)
    }
}

/// One dot per space, the current one wearing the space's own icon. A window with no spaces
/// still shows a dot — it is standing on the profile's default set of tabs, which is a space
/// in all but name.
private struct SpaceDots: View {
    @EnvironmentObject var store: TabStore
    @State private var icons = false
    @State private var theme = false

    var body: some View {
        HStack(spacing: 8) {
            if store.spaces.isEmpty {
                Circle().fill(.tint).frame(width: 6, height: 6)
                    .accessibilityLabel("This space")
            } else {
                ForEach(store.spaces) { dot($0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    @ViewBuilder private func dot(_ space: Space) -> some View {
        let here = store.currentSpaceID == space.id
        Group {
            if here {
                Image(systemName: space.icon ?? "cloud").font(Look.small)
                    .foregroundStyle(.primary)
            } else {
                Circle().fill(.tertiary).frame(width: 6, height: 6)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(.rect)
        .onTapGesture { store.switchTo(space: space) }
        .help(space.name)
        .contextMenu { SpaceMenu(store: store, space: space, icons: $icons, theme: $theme) }
        .popover(isPresented: $icons) { SpaceIcons(store: store, space: space) }
        .popover(isPresented: $theme) { SpaceTheme(store: store, space: space) }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(here ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Switches to this space.")
        .accessibilityAction { store.switchTo(space: space) }
    }
}

// MARK: - Bookmarks

/// This profile's bookmarks, standing in for Arc's per-space pinned list.
/// ponytail: Vane has no per-space pinned *pages* (only pinned tabs, which are the grid
/// above), and bookmarks are the list of pages the user already said they care about. The
/// upgrade path is a `Space.pinnedURLs`-backed list once spaces get their own editing UI.
private struct BookmarkList: View {
    let tab: Tab?

    var body: some View {
        if let tab { LiveBookmarkList(tab: tab) } else { BookmarkRows(bookmarked: false) }
    }
}

/// Only here to observe the tab: the list has to redraw the moment ⌘D adds or removes one,
/// and with no tab there is nothing to press ⌘D on.
private struct LiveBookmarkList: View {
    @ObservedObject var tab: Tab
    var body: some View { BookmarkRows(bookmarked: tab.bookmarked) }
}

private struct BookmarkRows: View {
    @EnvironmentObject var store: TabStore
    let bookmarked: Bool
    @State private var marks: [Suggestion] = []

    var body: some View {
        VStack(spacing: Look.rowGap) {
            ForEach(marks) { mark in
                SidebarRow(selected: false, action: { open(mark) }) {
                    // The cached favicon if the page has been visited, a globe if not — the
                    // row should look like the site, not like a list of identical stars.
                    SiteIcon(icon: URL(string: mark.url).flatMap(store.favicons.icon(for:)))
                } label: {
                    Text(mark.title.isEmpty ? mark.url : mark.title)
                } trailing: {
                    EmptyView()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mark.title.isEmpty ? mark.url : mark.title)
                .accessibilityValue("Bookmark, \(mark.url)")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens this page.")
                .accessibilityAction { open(mark) }
            }
        }
        .onAppear { reload() }
        .onChange(of: bookmarked) { reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks")
    }

    private func reload() { marks = store.isPrivate ? [] : store.history.bookmarks(limit: 30) }

    private func open(_ mark: Suggestion) {
        guard let u = URL(string: mark.url) else { return }
        if let t = store.active { t.web.load(URLRequest(url: u)) } else { store.newTab(u) }
    }
}

// MARK: - Rows

/// Every clickable line in the sidebar: an icon, a title, and whatever the row wants on the
/// trailing edge. One shape so the list reads as one list.
private struct SidebarRow<Leading: View, Trailing: View>: View {
    let selected: Bool
    /// Secondary rather than primary type: "New Tab" is an action among places, and Arc
    /// sets it a step quieter than the tabs around it.
    var dimmed = false
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let label: () -> Text
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            leading()
            // Every tab title in primary, selected or not — Arc's list is white on dark
            // all the way down, and the selection is the fill, not a change of ink.
            label().font(Look.text).lineLimit(1)
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: Look.rowHeight)
        .background(fill, in: .rect(cornerRadius: Look.pillRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .environment(\.rowHovering, hovering)
    }

    private var fill: Color {
        selected ? Look.selected : (hovering ? Look.hovered : .clear)
    }
}

extension SidebarRow where Leading == Image, Trailing == EmptyView {
    init(icon: String, title: String, selected: Bool, dimmed: Bool = false,
         action: @escaping () -> Void) {
        self.init(selected: selected, dimmed: dimmed, action: action,
                  leading: { Image(systemName: icon) },
                  label: { Text(title) },
                  trailing: { EmptyView() })
    }
}

/// Whether the row a view sits in is hovered, so a close button can appear without every
/// row needing its own hover plumbing.
private struct RowHoveringKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    fileprivate var rowHovering: Bool {
        get { self[RowHoveringKey.self] }
        set { self[RowHoveringKey.self] = newValue }
    }
}

/// A hairline, then the two housekeeping actions Arc puts here.
private struct TidyRow: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 8) {
            Hairline()
            // The menu item owns the tidy's cancellation and its "undo" bookkeeping — this
            // is the same closure, not a second copy of it.
            Button("Tidy") { Keybindings.actions[.tidyTabs]?() }
                .disabled(!TidyTabs.shouldOffer(store))
                .help("Rename and group tabs (\(Keybindings.binding(for: .tidyTabs).display))")
                .accessibilityLabel("Tidy Tabs")
            Text("|").foregroundStyle(.tertiary)
            Button("Clear") { clear() }
                .help("Close every tab that is not pinned")
                .accessibilityLabel("Close Unpinned Tabs")
        }
        .buttonStyle(.plain)
        .font(Look.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Look.rowHeight)
    }

    /// Closing every tab would close the window, so when nothing is pinned a blank tab is
    /// opened first to hold it open.
    private func clear() {
        let doomed = store.tabs.filter { !$0.pinned }
        guard !doomed.isEmpty else { return }
        if doomed.count == store.tabs.count { store.newBlankTab() }
        doomed.forEach { store.close($0.id) }
        axAnnounce("Closed \(doomed.count) tab\(doomed.count == 1 ? "" : "s").")
    }
}

private struct NewTabRow: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        SidebarRow(icon: "plus", title: "New Tab", selected: false, dimmed: true) { store.newTab(nil) }
            .help("New Tab (\(Keybindings.binding(for: .newTab).display))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New Tab")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.newTab(nil) }
    }
}

private struct OpenTabs: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        let open = store.tabs.filter { !$0.pinned }
        VStack(spacing: Look.rowGap) {
            ForEach(open) { TabRow(tab: $0) }
        }
        // A container of rows, so VoiceOver reads this as a tab list and steps through the
        // tabs instead of announcing an anonymous stack.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityValue("\(open.count) open")
        .accessibilityHint("Command 1 through 8 selects a tab, Command 9 the last one.")
        .accessibilityAction(named: "Search Tabs") { store.palette = .tabs }
        .accessibilityAction(named: "New Tab") { store.newTab(nil) }
    }
}

private struct TabRow: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var side: DropSide?

    var body: some View {
        let selected = store.current == tab.id
        SidebarRow(selected: selected, action: { store.current = tab.id }) {
            TabIcon(tab: tab)
        } label: {
            Text(TidyTitles.title(for: tab))
        } trailing: {
            TabRowTrailing(tab: tab, selected: selected)
        }
        // The drop target is the whole row, so the line shows which side it will land on.
        .overlay(alignment: side == .after ? .bottom : .top) {
            DropLine(on: side != nil, axis: .vertical)
        }
        .help(tab.title)
        .onDrag { dragPayload(tab) } preview: {
            // Drag preview: the row alone would drag the whole list's background with it.
            HStack(spacing: 8) {
                TabIcon(tab: tab)
                Text(TidyTitles.title(for: tab)).lineLimit(1).font(Look.text)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: tab, axis: .vertical, extent: Look.rowHeight, side: $side))
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
        .accessibilityValue(tabState(tab, in: store))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this tab.")
        .accessibilityAction(named: "Close Tab") { store.close(tab.id) }
        .accessibilityAction(named: tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
        .accessibilityAction(named: "Close Other Tabs") { closeOthers() }
        .accessibilityAction(named: TabAudio.isMuted(tab) ? "Unmute Tab" : "Mute Tab") {
            TabAudio.toggleMute(tab)
        }
    }

    private func closeOthers() {
        // Pinned tabs are not "other tabs" — closing them would undo the pin.
        for t in store.tabs where t.id != tab.id && !t.pinned { store.close(t.id) }
    }
}

/// The speaker and the close button. Split out only because one expression with both of
/// them plus the row's own modifiers stopped type-checking in reasonable time.
private struct TabRowTrailing: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    let selected: Bool
    @Environment(\.rowHovering) private var hovering

    var body: some View {
        HStack(spacing: 8) {
            if tab.audible || TabAudio.isMuted(tab) {
                Button { TabAudio.toggleMute(tab) } label: {
                    Image(systemName: TabAudio.isMuted(tab) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(Look.rowGlyph)
                }
                .help(TabAudio.isMuted(tab) ? "Unmute Tab" : "Mute Tab")
                .accessibilityLabel(TabAudio.isMuted(tab) ? "Unmute \(tab.title)" : "Mute \(tab.title)")
            }
            if hovering || selected {
                Button { store.close(tab.id) } label: {
                    Image(systemName: "xmark").font(Look.rowGlyph)
                }
                .help("Close Tab (⌘W)")
                .accessibilityLabel("Close \(TidyTitles.title(for: tab))")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// A site's own icon, with a fallback symbol standing in until it arrives (or forever, for
/// a page that has none).
private struct SiteIcon: View {
    let icon: NSImage?
    var fallback = "globe"
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: fallback).resizable().foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

/// The same, for a tab — separate only because it has to observe the tab to redraw when the
/// favicon lands.
private struct TabIcon: View {
    @ObservedObject var tab: Tab
    var size: CGFloat = 16

    var body: some View { SiteIcon(icon: tab.favicon, size: size) }
}

// MARK: - Sidebar footer

private struct BottomRow: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 8) {
            DownloadsButton(downloads: Downloads.manager(for: store.profileID))
            Spacer(minLength: 0)
            SpaceDots()
            Spacer(minLength: 0)
            // The Spaces menu owns the naming alert; this is the same closure.
            Button { Keybindings.actions[.newSpace]?() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("New Space")
                .accessibilityLabel("New Space")
        }
        .font(Look.icon)
        .frame(height: Look.footer)
        .padding(.horizontal, 6)
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
                    Text("Save password for \(p.host)?").font(Look.rowText)
                    if !p.account.isEmpty {
                        Text(p.account).font(Look.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Button("Not Now") { tab.pendingSave = nil }
                Button("Save") { tab.confirmSave() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)
            .glass(radius: Look.cardRadius)
            .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
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
            Image(systemName: "magnifyingglass").font(Look.caption).foregroundStyle(.secondary)
            TextField("Find on page", text: $text)
                .textFieldStyle(.plain).font(Look.small).frame(width: 180)
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
        .buttonStyle(.plain).font(Look.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glass(radius: Look.cardRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
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
        let empty = downloads.items.isEmpty
        // Always present, dimmed when there is nothing to show: the sidebar's bottom row is
        // a fixed strip, and a button that comes and goes makes the whole row jump.
        Button { open.toggle() } label: { Image(systemName: "arrow.down.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .disabled(empty)
            .help("Downloads")
            .accessibilityLabel("Downloads")
            .accessibilityValue("\(downloads.items.count) item\(downloads.items.count == 1 ? "" : "s")")
            .accessibilityHint("Shows what has been downloaded.")
            .popover(isPresented: $open, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(downloads.items) { DownloadRow(item: $0, downloads: downloads) }
                }
                .padding(14).frame(width: 320)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Downloads")
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
                Text(item.name).lineLimit(1).font(Look.small)
                    .accessibilityLabel(item.name)
                    .accessibilityValue(status)
                Spacer(minLength: 8)
                if item.state == .done {
                    // A renamed download is .done, so this has to sit beside Show rather
                    // than in an else-branch it could never reach.
                    if TidyDownloads.canUndo(item) {
                        Button("Undo Rename") { _ = TidyDownloads.undo(item, in: downloads) }
                            .buttonStyle(.plain).font(Look.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Undo renaming \(item.name)")
                    }
                    Button("Show") { downloads.reveal(item) }
                        .buttonStyle(.plain).font(Look.caption).foregroundStyle(.tint)
                        .help("Show in Finder")
                        // "Show" on its own says nothing once it is out of context.
                        .accessibilityLabel("Show \(item.name) in Finder")
                } else if downloads.canResume(item) {
                    // Item.State stays three cases because UI.swift switches it
                    // exhaustively, so a paused download arrives as .failed("Paused").
                    // Without this it reads as a dead row with no way back.
                    Button("Resume") { _ = downloads.resume(item) }
                        .buttonStyle(.plain).font(Look.caption).foregroundStyle(.tint)
                        .help("Resume this download")
                        .accessibilityLabel("Resume \(item.name)")
                } else if item.status == .running {
                    Button("Pause") { downloads.pause(item) }
                        .buttonStyle(.plain).font(Look.caption).foregroundStyle(.secondary)
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
                Text(why).font(Look.caption).foregroundStyle(.red).lineLimit(2)
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
