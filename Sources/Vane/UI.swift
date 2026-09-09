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
    /// Out of the window's key loop and out of the accessibility tree: a page kept running
    /// off screen (see `OffscreenPages`) must not be Tab-able to or readable by VoiceOver.
    var offscreen = false

    func makeNSView(context: Context) -> WebHost { WebHost(web) }
    func updateNSView(_ host: WebHost, context: Context) {
        host.show(web)
        host.offscreen = offscreen
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width,
               height: proposal.height ?? nsView.frame.height)
    }
}

/// A plain box whose only job is to hold whichever WKWebView the tab has *now*.
///
/// `Tab.suspend()` throws the web view away and puts a fresh one in its place, so a
/// representable that hands back the view it was made with and does nothing in
/// `updateNSView` leaves the dead one on screen — a blank page when you come back to a tab
/// that was suspended under memory pressure. The swap has to happen somewhere, and this is
/// the only place that sees both the old view and the new one.
final class WebHost: NSView {
    private(set) var web: WKWebView?
    /// Kept running but not on screen. `isHidden` is the whole of it: a hidden view is out
    /// of the window's key loop and out of the accessibility tree, so an invisible page is
    /// neither Tab-able nor readable by VoiceOver, and it costs no compositing either.
    /// Measured: it does *not* stop the page's media, unlike taking the view out of the
    /// window, which is what the mini audio player is up against in the first place.
    var offscreen = false {
        didSet { if offscreen != oldValue { isHidden = offscreen } }
    }

    init(_ web: WKWebView) {
        super.init(frame: .zero)
        show(web)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }

    func show(_ next: WKWebView) {
        guard next !== web else { return }
        web?.removeFromSuperview()
        next.frame = bounds
        next.autoresizingMask = [.width, .height]
        addSubview(next)
        web = next
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
    /// App-wide, so every window's sidebar is the width the user last dragged one to.
    @ObservedObject private var sidebar = SidebarWidth.shared
    @ObservedObject private var library = Library.shared
    /// The window's own width, so the Library can be told how much it may take from the
    /// page. `onGeometryChange` rather than a `GeometryReader` around the stack: the reader
    /// would have to wrap everything to measure it, and this is one number.
    @State private var windowWidth: CGFloat = 0

    /// Whether the window is showing any chrome at all, which is what the traffic lights
    /// follow. The Library counts: it stands where the sidebar does, with the lights' own
    /// strip blank at the top of its rail, so a panel with no lights beside it is a hole.
    private var chrome: Bool { store.sidebarShown || peeking || store.libraryOpen }

    /// How many Spaces the profile has. Read when that changes, never per frame: `store.spaces`
    /// decodes spaces.json every time it is touched, and this number feeds the `.animation`
    /// key the page's slide follows — reading it there put a file read and a JSON decode in
    /// every frame of a two-finger Space swipe.
    @State private var spaceCount = 0

    /// The rail plus its list column, or — in the Spaces section — a card per Space, up to
    /// what the page can spare. Zero with the Library shut, so nothing animates on a number
    /// nobody is looking at. See `Library.panelWidth`.
    private var libraryWidth: CGFloat {
        guard store.libraryOpen else { return 0 }
        return Library.panelWidth(section: library.section, spaces: spaceCount,
                                  private: store.isPrivate, available: windowWidth)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            WindowGlass()
            SpaceGround()
            HStack(spacing: 0) {
                // Arc's Library replaces the *sidebar*, not the window: a rail and one list
                // column stand where the sidebar stood, and the page simply moves over by
                // the difference in width. Nothing is covered and nothing is unmounted, so
                // media, the mini player and picture-in-picture carry straight on.
                if store.libraryOpen {
                    LibraryPanel().frame(width: libraryWidth)
                } else if store.sidebarShown {
                    Sidebar().frame(width: sidebar.width)
                }
                WebCard()
            }
            // On the seam, over the card: the sidebar's own trailing edge is what Arc's
            // resize handle is, and it has to be above the web view to see a drag at all.
            // Not while the Library is up: the rail is not the sidebar, and is not dragged.
            if store.sidebarShown && !store.libraryOpen {
                SidebarHandle().offset(x: sidebar.width - SidebarHandle.hitTestWidth / 2)
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
        // “Open “Zoom”?”, anchored to the window whose page asked. See ExternalApps.swift.
        .externalAppPrompt(store)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // The one place the Space list is counted: when it changes, and when the Library
        // opens onto it. `spaceRevision` is bumped by everything that adds or removes one.
        .onChange(of: store.spaceRevision, initial: true) { spaceCount = store.spaces.count }
        .onChange(of: store.libraryOpen) { if store.libraryOpen { spaceCount = store.spaces.count } }
        // The page slides over as the panel takes its width, and back when it gives it up —
        // including when the Spaces section widens the panel to fit another card.
        .animation(reduceMotion ? nil : Look.appear, value: libraryWidth)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: store.sidebarShown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: peeking)
        .animation(reduceMotion ? nil : Look.appear, value: store.libraryOpen)
        .animation(reduceMotion ? nil : Look.appear, value: store.palette == nil)
        // Arc hides the traffic lights along with the sidebar: a collapsed window is the
        // page and nothing else. They come back the moment either sidebar does.
        .onChange(of: chrome, initial: true) { showTrafficLights(chrome) }
        // ⌘S while the peek is up keeps `chrome` true, so the line above never fires and the
        // lights would stay on the peeked panel's inset line. Docking or hiding the sidebar
        // always ends the peek, and the lights follow the row that is actually there.
        .onChange(of: store.sidebarShown) { peekTask?.cancel(); peeking = false; showTrafficLights(chrome) }
        .onChange(of: peeking) { showTrafficLights(chrome) }
        // Opening the Library ends any peek in flight, for the same reason: the lights
        // belong to the rail's row now, not to a panel sliding in behind it.
        .onChange(of: store.libraryOpen) {
            if store.libraryOpen { peekTask?.cancel(); peeking = false }
            showTrafficLights(chrome)
        }
        .onAppear { store.applySpaceAppearance() }
        // In .background so it costs no layout: the buttons are still in the view tree and
        // in the responder chain, which is all .keyboardShortcut needs.
        .background { Shortcuts() }
    }

    /// The 6pt of window edge that brings the sidebar back. Only live while it is away.
    @ViewBuilder private var edgeStrip: some View {
        // Not while the Library is open: the strip is under the panel, and a sidebar
        // peeking out from behind it is two sidebars.
        if !store.sidebarShown && !store.libraryOpen {
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .onHover { if $0 { peekTask?.cancel(); peeking = true } }
                .accessibilityHidden(true)      // ⌘S is the accessible route back
        }
    }

    @ViewBuilder private var floatingSidebar: some View {
        // Never over the Library: the panel would cover the rail, and the traffic lights
        // would follow the peeked panel's inset line off the rail's own row.
        if !store.sidebarShown && peeking && !store.libraryOpen {
            Sidebar()
                .frame(width: sidebar.width)
                // The same near-opaque ground as the command bar: this one floats over
                // the page, and a bare material over a white page is a white panel.
                .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
                .background(Look.barMaterial, in: .rect(cornerRadius: Look.cardRadius))
                .hairline(radius: Look.cardRadius)
                .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
                .padding(Look.cardGap)
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
        // Which row the lights belong to depends on which sidebar is showing: the docked one
        // starts at the window's edge, the peeked panel is inset by `Look.inset` all round.
        let window = store.window as? VaneWindow
        window?.peekingSidebar = !store.sidebarShown && peeking
        // Unhiding re-lays the group, so put it back on the row's centre line before the
        // frame it comes back in — otherwise ⌘S twice leaves the lights off the row.
        window?.centreTrafficLights()
    }

    /// Nothing to undo on dismiss: ⌘T makes no tab until the bar is submitted.
    private func dismissPalette() { store.palette = nil }
}

/// The window's ground: the space's colour, derived the way Arc derives a theme
/// (`Look.ground`), laid over the behind-window blur behind the sidebar *and* behind the gap
/// around the card, which is what makes the card read as floating on something rather than
/// sitting in a grey box. A space with no colour of its own wears its profile's — Arc has
/// no colourless space, and a grey slab was what the old fallback amounted to.
struct SpaceGround: View {
    @EnvironmentObject var store: TabStore
    @EnvironmentObject var profiles: ProfileManager
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        // One read of the Space per render, not one per thing asked of it: `store.spaces`
        // decodes spaces.json every time it is touched, and this redraws on every frame of a
        // swipe. `currentSpace` answers from the theme editor's preview without a read at all
        // while a colour is being dragged.
        let here = store.currentSpace
        let mine = colors(of: here)
        let pull = pulled(from: here)
        let stops = Look.groundStops(mine, towards: pull.colors,
                                     fraction: pull.fraction, dark: dark,
                                     strength: here?.tint ?? Look.defaultTint)
        // Grain crosses the swipe with the colour: the neighbour's texture arrives with its
        // wash rather than snapping on at the end.
        let noise = (here?.grain ?? 0) * (1 - pull.fraction) + pull.grain * pull.fraction
        // Always in the tree, so switching space cross-fades one ground into the next instead
        // of cutting — the fade *is* what says the whole window changed space. While a
        // two-finger swipe is live the wash is dragged towards the Space being pulled in, by
        // the same fraction the strip has travelled: the colour has to arrive with the
        // content, or one switch reads as two events.
        ZStack {
            wash(stops)
                .opacity(Look.groundOpacity(dark: dark))
                // A `LinearGradient` is not animatable, so a switch between two multi-colour
                // Spaces would cut where a single colour faded. Identity keyed on the colours
                // — never on the swipe's fraction, which changes every frame — turns the
                // switch into a removal and an insertion, and two opacity transitions inside
                // the animations below are the cross-fade.
                .id(mine.joined(separator: "-") + "|" + pull.colors.joined(separator: "-"))
                .transition(.opacity)
            if noise > 0 {
                Image(nsImage: Look.grain)
                    .resizable(resizingMode: .tile)
                    // Nearest neighbour: the tile is one noisy pixel per pixel, and smoothing
                    // it up to a 2x backing store turns the grain into mottle.
                    .interpolation(.none)
                    .opacity(noise * Look.grainMax)
            }
        }
        .animation(reduceMotion ? nil : Look.appear, value: store.currentSpaceID)
        .animation(reduceMotion ? nil : Look.appear, value: store.spaceRevision)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One colour is one even wash — deliberately not a bottom-weighted gradient: that one's
    /// strongest band landed in the 8pt gap under the card, where it read as a fat coloured
    /// bar along the card's bottom edge rather than as the sidebar's tint. Several colours are
    /// the theme editor's extra dots, mixed across the window's diagonal at that same
    /// strength.
    @ViewBuilder private func wash(_ stops: [Color]) -> some View {
        if stops.count > 1 {
            LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            stops.first ?? .clear
        }
    }

    /// A Space's colours, falling back to its profile's — Arc has no colourless space, and a
    /// grey slab was what the old fallback amounted to.
    private func colors(of space: Space?) -> [String] {
        let list = space.map(Spaces.themeColors(of:)) ?? []
        return list.isEmpty ? [store.profile.colorHex] : list
    }

    /// The Space the fingers are pulling in, its grain, and how much of it is already
    /// showing. `store.spaces` — the one thing here that reads the file — is only touched
    /// while a swipe is actually live; at rest, and at the ends where the strip only
    /// rubber-bands, this is the current Space at fraction 0.
    private func pulled(from here: Space?) -> (colors: [String], grain: Double, fraction: Double) {
        let idle = (colors(of: here), here?.grain ?? 0, 0.0)
        let width = SidebarWidth.shared.width
        guard store.spaceDrag != 0, width > 0 else { return idle }
        let list = store.spaces
        guard let i = list.firstIndex(where: { $0.id == store.currentSpaceID }) else { return idle }
        let f = Double(max(-1, min(1, store.spaceDrag / width)))
        let n = f < 0 ? i + 1 : i - 1
        guard list.indices.contains(n) else { return idle }
        return (colors(of: list[n]), list[n].grain ?? 0, abs(f))
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
struct WebCard: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        ZStack(alignment: .top) {
            // A split is one card holding several pages; everything that floats over the
            // page — find, the save prompt, the status bar — still belongs to `store.active`,
            // which *is* the active pane's tab.
            if let split = store.activeSplit {
                SplitPanes(split: split)
            } else if let tab = store.active {
                // The list of saved accounts hangs off a field *in this page*, so it is an
                // overlay on the page and not on the window's card — which is also what puts
                // it in the right pane in a split. See SplitView's own `Pane`.
                WebView(web: tab.web).id(tab.id)
                    .overlay(alignment: .topLeading) { PasswordChooser(tab: tab) }
            } else {
                // No tabs: the sheet a page will land on, and nothing in it. With nothing
                // mounted there is also no WKWebView to argue with over a dropped file, so
                // the bare card is the one part of the page area that can take one: dropping
                // a PDF on a window showing nothing is not ambiguous. Everywhere else files
                // go to the sidebar — see `SidebarDrop`.
                EmptyPane()
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        Files.openDropped(providers, in: store)
                        return true
                    }
            }
            OffscreenPages()
            if let tab = store.active { LoadingBar(tab: tab) }
            VStack(spacing: 8) {
                if store.findOpen, let tab = store.active {
                    FindBar(tab: tab).frame(maxWidth: .infinity, alignment: .trailing)
                }
                // Under the address pill, at the top-right of the page card — where the
                // find bar goes, and where a browser's own chrome belongs.
                //
                // Mounted whether or not there is an offer, and the card decides for itself.
                // `TabStore` does not republish its tabs' changes, so a `tab.pendingSave !=
                // nil` test *here* is read once and never again — which is why the save
                // prompt has never actually appeared. The view has to be the one observing.
                if let tab = store.active {
                    PasswordOffer(tab: tab)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            // Last in the stack, so it is above the page: a dragged sidebar tab lands on the
            // card's edge bands as a new pane. Only in the tree while a drag is in flight.
            SplitDropWell()
        }
        // The status bar: the hovered link's url, bottom-left, inside the card's clip the
        // way Arc's sits on the page rather than under it.
        .overlay(alignment: .bottomLeading) {
            if let tab = store.active { StatusBarView(tab: tab).padding(Look.statusInset) }
        }
        // ⌃⇥: the recent tabs, centred on the page rather than on the window.
        .overlay { TabSwitcherOverlay() }
        .clipShape(.rect(cornerRadius: Look.pageRadius))
        // No inset on the leading edge while the sidebar is docked — its own padding
        // already leaves the gap, and doubling it reads as a misaligned card. The Library's
        // column stands in the same place and leaves the same gap.
        .padding(.leading, store.sidebarShown || store.libraryOpen ? 0 : Look.cardGap)
        .padding([.top, .trailing, .bottom], Look.cardGap)
    }
}

/// The page area with no page in it: Arc draws the sheet the page will land on rather than
/// running the sidebar's colour across the whole window, so a browser with nothing open
/// still shows you where the next thing goes.
///
/// It is drawn *inside* `WebCard`'s own clip and padding, so it inherits the live card's
/// corner (`Look.pageRadius`) and gap exactly — nothing on screen moves when the first tab arrives, the outline
/// just fills with a page. One of these and never two: a window with no tab has no split to
/// divide, and the branch that draws it is the one where there is no tab at all. Little Vane
/// gets it too — ⌥⌘N opens one empty, and its card is this same `WebCard`.
///
/// ponytail: a shape, not a `Color` with a `.background` and a `.hairline` — a fill and a
/// stroke on one rounded rectangle is the whole of it.
struct EmptyPane: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Look.pageRadius)
            .fill(Look.emptyPaneFill)
            .hairline(radius: Look.pageRadius)
            // Decoration. The window already says it has no tabs — the sidebar's empty list
            // and the command bar over it — and a second element saying so is noise.
            .accessibilityHidden(true)
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
    @ObservedObject private var sidebar = SidebarWidth.shared
    /// The scroll viewport's height, so its content can be made to fill it. See below.
    @State private var scrollHeight: CGFloat = 0
    /// One geometry group for the whole strip, so a tab changing section — a row becoming a
    /// tile, a tile a row — travels from where it was to where it is going.
    @Namespace private var strip

    var body: some View {
        VStack(spacing: Look.inset) {
            TopRow()
            AddressPill(tab: store.active)
            ScrollView {
                VStack(spacing: Look.rowGap) {
                    Favorites()
                    // Everything a Space owns, and nothing it shares: the grid above stays
                    // put while these slide in from the direction of travel.
                    VStack(spacing: Look.rowGap) {
                        SpaceRow()
                        PinnedTabs()
                        TidyRow()
                        NewTabRow()
                        OpenTabs()
                    }
                    .spaceSlide(store)
                }
                // The list is at least as tall as what it is scrolling in, so the emptiness
                // under the last tab is part of the *content* — which is what lets the drag
                // ground behind it see the pointer. A scroll view claims the hover over its
                // own frame, so a ground laid behind the scroll view never gets it.
                .frame(minHeight: scrollHeight, alignment: .top)
                .background(WindowDragArea())
            }
            .scrollIndicators(.never)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollHeight = $0 }
            .spaceSwipe(store)
            BottomRow()
        }
        .environment(\.strip, strip)
        .padding(.horizontal, Look.inset)
        .padding(.bottom, Look.footerInset)
        .padding(.top, Look.topInset)
        // Toasts and the mini audio player slide up from under the footer and sit just
        // above it, over the list — the toast above the player, so neither covers the other.
        .overlay(alignment: .bottom) {
            VStack(spacing: Look.inset) { ToastHost(); MediaTrayView() }
                .padding(.bottom, Look.footer + Look.footerInset + Look.inset)
        }
        .frame(width: sidebar.width, alignment: .leading)
        // Under everything in the sidebar, so a row, a button or the pill takes the pointer
        // first and only the bare ground picks the window up.
        .background(WindowDragArea())
        // Arc's other way of making a tab: drop a link, a url or a selection anywhere on the
        // sidebar. Outermost, so the per-section drop targets keep reordering to themselves.
        .onDrop(of: [.url, .fileURL, .plainText], delegate: SidebarDrop(store: store))
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
            Spacer().frame(width: Look.trafficLights)   // traffic lights
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
        .foregroundStyle(Look.inkSecondary)
        .frame(height: Look.topRow)
    }
}

/// The page's back, forward and reload. With no page they stay where they are, disabled:
/// nothing in the sidebar's chrome may come and go because a tab closed — the user read
/// that as the window emptying out rather than as one tab going away.
struct NavButtons: View {
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
    /// One per glyph, and kept across redraws: the AppKit view the menu hangs off is
    /// reached through it, and a new holder every frame would lose that view.
    @StateObject private var backMenu = HoldMenu()
    @StateObject private var forwardMenu = HoldMenu()

    var body: some View {
        // Icon-only, so each one carries its own label and tooltip — without them
        // VoiceOver announces three identical "button"s.
        HStack(spacing: 16) {
            Button { tab?.back() } label: { Image(systemName: "arrow.left") }
                .disabled(!back)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
                // Arc: hold it, or right-click it, for the pages behind this one.
                .holdMenu(backMenu, enabled: back, named: "Show History") {
                    tab.flatMap { NavHistory.menu(for: $0, back: true) }
                }
            Button { tab?.forward() } label: { Image(systemName: "arrow.right") }
                .disabled(!forward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
                .holdMenu(forwardMenu, enabled: forward, named: "Show History") {
                    tab.flatMap { NavHistory.menu(for: $0, back: false) }
                }
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
struct AddressPill: View {
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
    /// The site glyph's badge is not on the tab: it is a remembered permission, written by
    /// a modal prompt that has no route back into this view. See `SiteChanges`.
    @ObservedObject private var changes = SiteChanges.shared

    var body: some View {
        // Built *here*, where the tab is observed, and handed down as a value. Built inside
        // the glyph instead, SwiftUI would be free to skip that view's body across a
        // navigation — its one stored property, the Tab, is unchanged — and leave the lock
        // and the badge describing the page before last.
        let site = SiteControlModel(tab)
        PillBody(tab: tab, host: host, address: tab.address,
                 reader: tab.readerAvailable || Reader.isOn(tab), readerOn: Reader.isOn(tab),
                 site: site,
                 zoom: PillState.zoomLabel(tab.zoom))
    }

    /// The host alone, the way Arc shows it — or a local file's own name. See
    /// `Files.pillLabel`, which is where both are decided.
    private var host: String {
        if let label = Files.pillLabel(tab.currentURL) { return label }
        return tab.address.isEmpty ? "Search or Enter URL" : tab.address
    }
}

private struct PillBody: View {
    @EnvironmentObject var store: TabStore
    let tab: Tab?
    let host: String
    let address: String
    let reader: Bool
    let readerOn: Bool
    /// The page as the Site Control Center sees it: which glyph the pill leads with,
    /// whether it is badged, and what the popover will say. Empty with no tab.
    var site = SiteControlModel()
    /// "125%" while the page is zoomed, nil at 100 %. Clicking it puts the page back.
    var zoom: String?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
        .buttonStyle(.plain)
        .font(Look.pillGlyph)
        .foregroundStyle(Look.inkSecondary)
        .padding(.horizontal, Look.pillInset)
        .frame(height: Look.pillHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A step up under the pointer, the way a row does: the pill is a button, and a
        // button that does not react reads as a label.
        .background(hovering ? Look.selected : Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        // Arc's "drag a tab to the top of the sidebar" to make it a favourite: the pill is
        // the top of the sidebar, and it is what the empty grid used to be dropped on.
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: nil, into: .favourite,
                                  axis: .horizontal, extent: 0, side: .constant(nil)))
        .help(address.isEmpty ? "Search or Enter URL" : address)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address and Search")
        .accessibilityValue(axValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the search bar to type a website address or a search.")
        .accessibilityAction { open() }
        // The two glyphs are only drawn on hover, so the actions they stand for have to be
        // on the pill itself — a pointer gesture is not a route VoiceOver has.
        .accessibilityAction(named: "Copy Link") { copyLink() }
        .accessibilityAction(named: "Browser Settings") { SettingsWindow.show() }
        .accessibilityAction(named: "Actual Size") { if let tab, zoom != nil { Zoom.reset(tab) } }
    }

    private var content: some View {
        HStack(spacing: Look.pillGlyphGap) {
            SiteGlyph(tab: tab, site: site)
            if reader, let tab { ReaderGlyph(tab: tab, on: readerOn) }
            // Secondary ink, the way Arc sets the host (179 on 84): the address is a
            // label for the page, not a title among titles.
            Text(host).font(Look.text).lineLimit(1)
            Spacer(minLength: 4)
            if let zoom, let tab { ZoomChip(label: zoom, tab: tab) }
            // On hover only, the way Arc's are: ref 2 catches the bar at rest and it is a
            // host and nothing else; ref 9 catches it hovered and the two glyphs are there.
            // They sit past a Spacer, so arriving and leaving never moves the host.
            if hovering { PillHoverGlyphs(enabled: tab != nil, copyLink: copyLink) }
            // Pinned extension actions, last: everything after the Spacer is flush right, so
            // the *last* item is the one the hover glyphs appearing beside it cannot move —
            // and a button that slides out from under the pointer as you reach for it is not
            // a button. The host gives up their width once, when one is pinned, never on
            // hover, and nothing at all is reserved while none are.
            PinnedExtensions(store: store, tab: tab)
        }
    }

    /// The address, and the two things the glyph and the chip say about it.
    private var axValue: String {
        var s = address.isEmpty ? "Empty" : address
        if site.insecure { s += ", not secure" }
        if let zoom { s += ", zoomed to \(zoom)" }
        return s
    }

    /// With a page, the bar opens on its address; with none, on nothing — and what is
    /// submitted becomes the window's first tab.
    private func open() { store.palette = tab == nil ? .newTab : .address }

    private func copyLink() {
        guard let u = tab?.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        axAnnounce("Link copied.")
        Toasts.show("Copied URL", in: store)
    }
}

/// The reader toggle, before the host.
private struct ReaderGlyph: View {
    let tab: Tab
    let on: Bool
    var body: some View {
        Button { Reader.toggle(tab) } label: {
            Image(systemName: on ? "doc.plaintext.fill" : "doc.plaintext")
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help("Reader (⌥⌘R)")
        .accessibilityLabel("Reader")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Copy Link and Site Settings, the two glyphs Arc's pill grows on hover.
private struct PillHoverGlyphs: View {
    let enabled: Bool
    let copyLink: () -> Void
    var body: some View {
        Button { copyLink() } label: { Image(systemName: "link") }
            .disabled(!enabled)
            .help("Copy Link (\(Keybindings.binding(for: .copyPageURL).display))")
            .accessibilityLabel("Copy Link")
        Button { SettingsWindow.show() } label: { Image(systemName: "slider.horizontal.3") }
            // Browser-wide, not per-site: per-site lives in the Site Control Center on the
            // pill's leading glyph (SiteControl.swift), which is where Arc keeps it.
            .disabled(!enabled)
            .help("Browser Settings")
            .accessibilityLabel("Browser Settings")
    }
}

/// Arc's site mark, before the host, and the button that opens the Site Control Center.
/// Always drawn — a lock, a broken lock, or a globe with no page — because the sidebar's
/// chrome does not come and go, and a control the user has to make a page insecure to find
/// is not a control.
private struct SiteGlyph: View {
    let tab: Tab?
    /// Passed in rather than derived, so this view redraws whenever the page does — see
    /// the note in `LiveAddressPill`. `SiteControlModel` is `Equatable`, so an unchanged
    /// page still costs nothing.
    let site: SiteControlModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: site.glyph)
                // Tiny on purpose: it says "this site holds a grant", and anything bigger
                // would read as a warning about the connection instead.
                .overlay(alignment: .topTrailing) {
                    if site.badge != nil {
                        Circle().fill(Color.accentColor)
                            .frame(width: Look.badge, height: Look.badge)
                            .offset(x: Look.badgeOffset, y: -Look.badgeOffset)
                    }
                }
        }
        .buttonStyle(.plain)
        // A broken lock drawn in the same grey as the host beside it is not a warning. Only
        // a live insecure page tints: with no tab there is nothing to warn about, and the
        // glyph keeps the ink `PillBody` hands down, dimmed with the rest of the pill.
        .foregroundStyle(tab != nil && site.insecure ? Look.warning : Look.inkSecondary)
        .disabled(tab == nil)
        .help(site.siteless ? "Site Controls" : "\(site.title) — \(site.connection)")
        .accessibilityLabel("Site Controls")
        .accessibilityValue([site.connection, site.badge].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows what this site is allowed to do, and its zoom, extensions and data.")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let tab { SiteControlPopover(tab: tab) }
        }
    }
}

/// Arc's pinned extensions: an extension's action button, in the pill. Up to
/// `ExtensionPins.cap` of them, in the order they were pinned, and in a private window only
/// the extensions that have been let into private browsing.
///
/// ponytail: no reserved slot. An unpinned browser's pill is exactly the pill it was, and
/// the width goes when the pin is made rather than being held empty against the chance of
/// one — the pill's own glyphs (the lock, the chip) are the stable chrome here.
private struct PinnedExtensions: View {
    /// The window, not the tab, decides which extensions are pinned here: the pill keeps its
    /// glyphs with no tab open, the way the back and forward buttons keep theirs.
    let store: TabStore
    let tab: Tab?
    /// A badge is not on the tab: the extension sets it, and `ExtensionHost`'s
    /// `didUpdate` delegate bumps this. No timer.
    @ObservedObject private var changes = SiteChanges.shared

    var body: some View {
        let host = ExtensionHost.host(for: store.profileID)
        ForEach(host.pinned(private: store.isPrivate), id: \.uniqueIdentifier) { context in
            ExtensionGlyph(host: host, tab: tab, context: context)
        }
    }
}

/// One pinned extension's action, as a glyph in the pill: its icon, its badge, and a click
/// that runs it — opening its popup against this pill, so a Little Vane and a private
/// window each get their own.
private struct ExtensionGlyph: View {
    let host: ExtensionHost
    let tab: Tab?
    let context: WKWebExtensionContext
    @StateObject private var anchor = ActionAnchor()

    var body: some View {
        // Every string built before the chain: a modifier chain this long with the work
        // inline is what the type checker gives up on.
        let now = state
        let live: Bool = now.note == nil
        let help: String = now.note.map { "\(name) — \($0)" } ?? name
        let value: String = [now.badge, now.note].compactMap { $0 }.joined(separator: ", ")
        let hint: String = live ? "Runs this extension on this page." : ""
        glyph(badge: now.badge, live: live)
            .actionAnchor(anchor)
            .contextMenu { Button("Unpin from Address Bar") { host.togglePin(context) } }
            .help(help)
            // One element: the badge drawn on the icon is a `Text`, and without this it is
            // published as a second button of its own beside the glyph.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(value)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction { press() }
            .accessibilityAction(named: "Unpin from Address Bar") { host.togglePin(context) }
    }

    /// A `Button`, which consumes its own click the way the pill's Copy Link glyph does —
    /// but never `.disabled`, because a disabled button stops hit-testing altogether and the
    /// click falls through to the pill, which opens the search bar. A glyph that looks
    /// unpressable must not quietly do something else instead, so it stays live, swallows
    /// the click and does nothing with it.
    private func glyph(badge: String?, live: Bool) -> some View {
        Button(action: press) {
            ActionIcon(host: host, context: context, tab: tab, badge: badge).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(live ? 1 : Look.dimmed)
    }

    /// What the action says about itself right now. `note` is why it is not pressable, and
    /// nil when it is: a pinned glyph is drawn whatever the window holds — the pill's chrome
    /// does not come and go — but it only runs on a page, and only while its extension
    /// leaves the action enabled.
    private var state: (badge: String?, note: String?) {
        let action = host.action(context, for: tab)
        let badge = action.flatMap { ExtensionPins.badge($0.badgeText) }
        if tab == nil { return (badge, "No page open") }
        if action?.isEnabled == false { return (badge, "Not available on this page") }
        return (badge, nil)
    }

    private func press() {
        guard let tab, state.note == nil else { return }
        host.run(context, for: tab, from: anchor.view)
    }

    private var name: String { context.webExtension.displayName ?? "Extension" }
}

/// "125%" in the pill while the page is zoomed. A click is Actual Size.
private struct ZoomChip: View {
    let label: String
    let tab: Tab
    var body: some View {
        Button { Zoom.reset(tab) } label: {
            Text(label)
                .font(Look.caption)
                .padding(.horizontal, 5)
                .frame(height: Look.chip - 6)
                .background(Look.selected, in: .rect(cornerRadius: Look.chipRadius))
        }
        .help("Zoomed to \(label). Click for actual size (\(Keybindings.binding(for: .actualSize).display)).")
        .accessibilityLabel("Zoom \(label)")
        .accessibilityHint("Resets the page to actual size.")
    }
}

// MARK: - Favourites

/// Arc's Favourites: a grid of tiles at the very top, above the space's name. A place, not
/// a page. A tile stays put when its page is closed (`TabStore.close` parks it), it never
/// auto-archives, and only Unfavourite — or a drag down into one of the lists — takes it
/// out. Columns follow the count (`TabStore.favouriteColumns`), so one favourite is one wide
/// tile and seven are a 4-wide grid, never two fixed slots.
/// Empty, it is nothing at all — Arc's fresh space is the pill and then the space's name,
/// no placeholder — and the first favourite is made by dropping a tab on the address pill.
private struct Favorites: View {
    @EnvironmentObject var store: TabStore
    /// A narrow sidebar drops a column instead of shrinking every tile to a sliver.
    @ObservedObject private var sidebar = SidebarWidth.shared

    var body: some View {
        let pinned = store.tabs.filter { $0.kind == .favourite }
        if !pinned.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.inset),
                                     count: SidebarWidth.favouriteColumns(pinned.count,
                                                                          width: sidebar.width)),
                      spacing: Look.inset) {
                ForEach(pinned) { FavoriteTile(tab: $0).transition(.tileGrow) }
            }
            // The grid sits an `inset` above the space row, not a row gap.
            .padding(.bottom, Look.inset - Look.rowGap)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Favourites")
            .accessibilityValue("\(pinned.count) pinned")
        }
    }
}

private struct FavoriteTile: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var hovering = false
    @State private var side: Landing.Band?
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.strip) private var strip

    var body: some View {
        let selected = store.current == tab.id
        Group {
            if store.renamingTab == tab.id {
                // A tile has no title to edit in place, so the field takes the tile: the
                // icon comes back with the name it was given.
                RenameField(store: store, tab: tab, font: Look.text)
                    .padding(.horizontal, Look.rowInset)
            } else {
                TabIcon(tab: tab, size: Look.tileIcon)
            }
        }
            .frame(maxWidth: .infinity, minHeight: Look.tileHeight)
            // Hover steps the tile up to the selected fill, the way the address pill does:
            // a tile is a button, and a button that does not react reads as a label.
            .background(selected || hovering ? Look.selected : Look.pillFill,
                        in: .rect(cornerRadius: Look.pillRadius))
            .overlay(alignment: side == .after ? .trailing : .leading) {
                DropLine(on: side != nil, axis: .horizontal)
            }
            .animation(reduceMotion ? nil : Look.quick, value: hovering)
            .inStrip(tab.id, strip)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { store.current = tab.id }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .help(tab.title)
            .onDrag { dragPayload(tab) } preview: { TabIcon(tab: tab, size: Look.tileIcon).padding(6) }
            .onDrop(of: [.plainText],
                    delegate: TabDrop(store: store, target: tab, into: .favourite,
                                      axis: .horizontal, extent: width, side: $side))
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingTab = tab.id })
            .contextMenu { TabMenu(store: store, tab: tab) }
            // One element per favourite, the way a tab reads: the title is the label, the
            // state is the value, and unpin/close are actions rather than hidden gestures.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TidyTitles.title(for: tab))
            .accessibilityValue(tabState(tab, in: store))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Shows this tab.")
            .accessibilityAction(named: "Rename Tab") { store.renamingTab = tab.id }
            .accessibilityAction(named: "Unfavourite Tab") { store.toggleFavourite(tab.id) }
            .accessibilityAction(named: "Pin Tab") { store.move(tab.id, to: .pinned) }
            .accessibilityAction(named: "Close Tab") { store.close(tab.id) }
    }
}

/// Everything a tab row says with a picture, a position or a colour instead of words.
@MainActor private func tabState(_ tab: Tab, in store: TabStore) -> String {
    var bits: [String] = []
    if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) {
        bits.append("tab \(i + 1) of \(store.tabs.count)")
    }
    switch tab.kind {
    case .favourite: bits.append("favourite")
    case .pinned:
        bits.append("pinned")
        // The indent is the only thing on screen that says a tab is inside a folder, and an
        // indent is not something VoiceOver can read out.
        if let folder = store.pins.folder(holding: tab.id.uuidString) {
            bits.append("in \(folder.name)")
            // The state glyph is drawn but hidden from VoiceOver: a row reads as one
            // element, so what it means belongs here rather than as a second thing to find.
            if folder.live != nil, let url = store.rowURL(tab.id.uuidString),
               let pr = LiveFolders.shared(for: store.profileID).state(of: url, in: folder) {
                bits.append(pr.says.lowercased())
            }
        }
    case .today:
        // The same indent, saying the same thing, in the section a tidy's folders live in.
        if let folder = store.todayShape.folder(holding: tab.id.uuidString) {
            bits.append("in \(folder.name)")
        }
    }
    if TabAudio.isMuted(tab) { bits.append("muted") } else if tab.audible { bits.append("playing audio") }
    bits.append(tab.loading ? "loading" : "loaded")
    return bits.joined(separator: ", ")
}

// MARK: Drag and drop

/// Which side of its target a drop will land on.
/// The tab being dragged, for the whole app. A drag never leaves the process, so a drop
/// reads it straight back rather than round-tripping the item provider — which is
/// asynchronous, and would leave `dropUpdated` unable to say whether this is one of ours.
/// Observable so every drop line goes out the moment the drop lands: SwiftUI does not send
/// `dropExited` to the target that performed the drop, and a line left behind read as a
/// second, phantom favourite.
/// Not private: `SidebarDrop` in TabActions.swift has to stand aside while one of these
/// is in flight, and a footer dot in SpacesUI.swift has to know a tab is what is being
/// dropped on it.
@MainActor final class Dragging: ObservableObject {
    static let shared = Dragging()
    @Published var tab: Tab.ID? { didSet { watch() } }
    /// A folder row being dragged among the pinned rows. Never both at once — a drag is one
    /// thing — but two fields rather than an enum keeps every existing `dragging.tab` read
    /// meaning exactly what it did.
    @Published var folder: Folder.ID? { didSet { watch() } }
    /// Dragging one row of a multi-select drags the whole selection. Empty for an ordinary
    /// one-tab drag, so `tab` — the row actually grabbed, and the one the drag preview and
    /// every existing reader is about — keeps meaning exactly what it did.
    @Published var tabs: [Tab.ID] = []
    /// Where the dragged row sits *now* — it moves as the pointer crosses its neighbours,
    /// so this follows it. `Landing` treats it as no move at all, which is what stops the
    /// live reorder oscillating around the row's own slot. Not published: only the drop
    /// delegates read it, and publishing it would redraw every row on every pointer move.
    var at: Landing.Spot?
    /// Where in the row it was picked up, so the row stays under the same part of itself
    /// for the length of the drag, and where the pointer was on screen when it was — see
    /// `TabDrop.lift`. Not published, for the same reason `at` is not.
    var grab: CGFloat?
    var grabbedAt: CGFloat?
    /// Whether the list has been keeping this row's slot under the pointer. A run and a
    /// split's row are not live-moved (see `TabDrop.track`), so their slot is wherever the
    /// drop puts them and there is nothing for the held row to glide into: it simply lands.
    var live = false
    /// The row still gliding into its slot after the drag ended, so the list does not draw
    /// it twice on the way. Published — but it changes twice a drag, not twice a frame,
    /// which is the whole reason it is here and not on `Held`.
    /// Puts the row back where the drag found it. A live reorder has already moved it by the
    /// time anything is dropped, so a drag that ends with no drop — Escape, or the button
    /// coming up over nothing — has a real change to undo rather than nothing to do.
    @Published var settling: Tab.ID?
    var undo: (@MainActor () -> Void)?
    /// Whether one of ours is in flight at all, which is what the drop lines and the
    /// sidebar's catch-all delegate care about.
    var active: Bool { tab != nil || folder != nil }

    /// Whether this row is the one in the air, and so is not drawn where it sits.
    /// ponytail: one row only. A dragged *run* keeps every row of it on screen — taking five
    /// out at once leaves a hole the size of the selection and says nothing useful about
    /// where they are going. Upgrade path: lift the run and stack its previews.
    /// True through the settle as well, when the drag is over but the row is still in the
    /// air on its way to the slot — the list must not draw the same row twice.
    func lifted(_ id: Tab.ID) -> Bool {
        (tab == id && tabs.count <= 1) || settling == id
    }

    /// What is being dragged, and the end of the drag in the same breath. Every
    /// `performDrop` calls this first: a delegate that reads the flag and then *refuses*
    /// the drop leaves the drag running forever, and a drag that never ends makes
    /// `SidebarDrop` stand aside from every later url and file drop.
    ///
    /// `landed` is opt-*in*, and every caller but one leaves it alone: a target that moves
    /// the tab somewhere of its own — a folder, a Space's dot, the page's split well — has
    /// made the slot the list was holding meaningless, and the row in the air has to land
    /// rather than glide into it. Only the sidebar's own no-op drop says otherwise.
    func take(landed: Bool = false) -> (tab: Tab.ID?, folder: Folder.ID?) {
        defer { end(landed: landed) }
        return (tab, folder)
    }

    /// The same, for a target that can take a whole selection: the dragged tabs in the order
    /// their rows were drawn, which is the order they should land in.
    func takeAll(landed: Bool = false) -> (tabs: [Tab.ID], folder: Folder.ID?) {
        defer { end(landed: landed) }
        return (tabs.isEmpty ? [tab].compactMap { $0 } : tabs, folder)
    }

    /// The end of the drag, and the start of the settle. The row is in the air wherever the
    /// pointer left it, and the list has been holding a slot for it up to a row or so away;
    /// it glides there, and only when it lands does the real row come back. Handing the row
    /// over the moment the button comes up shows it twice — once scaled, once not — across
    /// whatever gap is left.
    func end(landed: Bool = false) {
        // Back to full before anything else: a row that glides into its slot at half size
        // and then grows once it has arrived reads as two endings rather than one.
        Held.shared.rest()
        let glide = Landing.settles(live: live, landed: landed,
                                    air: Held.shared.air?.kind, at: at?.kind)
        // Where it glides to, or nil for "it lands": nothing waiting, the drop moved it
        // again, or the user asked for less motion.
        let home = glide && !Motion.reduced ? at.flatMap { spot in
            Held.shared.air.map {
                Held.Air(tab: $0.tab, kind: $0.kind,
                         y: Landing.slot(row: spot.index,
                                         height: Look.rowHeight, gap: Look.rowGap))
            }
        } : nil
        grab = nil; grabbedAt = nil; live = false
        settling = home?.tab
        Motion.list {
            tab = nil; folder = nil; tabs = []; at = nil; undo = nil
            Held.shared.show(home)      // nil fades the row out where it is, and it lands
        }
        guard let home else { return }
        Task { @MainActor [weak self] in
            // A spring is not at rest at its nominal duration, so the glide is given a
            // little longer than the list animation before the two are crossfaded: the row
            // in the air goes as the row in the slot comes back to full, rather than the
            // one being cut and the other appearing.
            try? await Task.sleep(for: .seconds(Look.listSeconds + Look.appearDuration))
            guard let self, settling == home.tab, Held.shared.air == home else { return }
            withAnimation(Look.appear) { Held.shared.show(nil); settling = nil }
        }
    }

    /// The end of a drag that no `performDrop` ever saw. The row has been moving as the
    /// pointer went, so "nothing happened" has to be made true rather than assumed.
    func cancel() {
        // `end` without `landed`, so nothing glides: `undo` puts the row back where the drag
        // found it, which is not the slot the list has been holding.
        if tab != nil, let undo { Motion.list(undo) }
        end()
    }

    /// The other end of a drag that no `performDrop` ever sees: released on the desktop, on
    /// the sidebar's bare ground, or in the middle of the page card, where the answer is "not
    /// here" rather than a drop. The flag it leaves behind is not cosmetic — `SplitDropWell`
    /// mounts a real dragging destination over the whole page while it is set.
    ///
    /// ponytail: a mouse-up monitor rather than an `NSDraggingSource` conformance, which
    /// would mean owning the drag session instead of `.onDrag`. Cleared on the *next* turn of
    /// the run loop, because the drop AppKit is about to deliver still has to be able to read
    /// what is being dragged. Ceiling: a drag ended by anything but the button coming up — a
    /// Space switch, say — still waits for the next mouse-up.
    private var monitors: [Any] = []

    private func watch() {
        guard active else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            return
        }
        guard monitors.isEmpty else { return }
        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.cancel() } }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.cancel() } }
        }
        monitors = [local, global].compactMap { $0 }
    }
}

/// Where the row in the air is drawn. On its own object, not on `Dragging`: this changes on
/// every pointer move, and `Dragging` is observed by every row in the sidebar, every drop
/// line and every favourite's tile — publishing it there would invalidate all of them a
/// hundred times a drag, which is the same reason `Dragging.at` is not published either.
/// `HeldRow` is the only thing that observes this.
@MainActor final class Held: ObservableObject {
    static let shared = Held()
    /// Which tab is in the air, which section's overlay draws it, and how far down that
    /// section it sits.
    struct Air: Equatable { var tab: Tab.ID; var kind: TabKind; var y: CGFloat }
    @Published private(set) var air: Air?

    /// `@Published` fires on equal values too, and a pointer wandering inside one row
    /// reports the same place over and over, so the write is filtered rather than the read.
    func show(_ next: Air?) {
        guard next != air else { return }
        air = next
    }

    /// Whether the row in the air is out of its own way — `Look.heldCompact` of itself, so
    /// the row it is resting on can be seen along with the half of it that will take the
    /// dragged pane. `HeldRow` reads it; nothing else needs to know a drag has paused.
    @Published private(set) var compact = false
    /// Which row the pointer is resting over and since when. `Landing` decides what that
    /// means; this only remembers it.
    private var dwell: Landing.Dwell?

    /// The pointer is over `spot`, a row offering a split — or over nothing worth seeing
    /// through, which puts the row back to full at once.
    ///
    /// ponytail: a `Task.sleep` per rest rather than a timer or a periodic drag update.
    /// SwiftUI does not promise a `dropUpdated` for a pointer that has *stopped*, which is
    /// the only case this is about, so the wait has to be ours; the reading afterwards still
    /// goes through `Landing.compact`, so the rule stays provable offline.
    func resting(over spot: Landing.Spot?) {
        let next = Landing.dwell(dwell, over: spot, now: ProcessInfo.processInfo.systemUptime)
        // The same row still under the pointer: the clock it started is already running, and
        // re-arming it on every reported move would mean it never came due.
        guard next != dwell else { return }
        dwell = next
        set(compact: false)
        guard let next else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Look.heldDwell))
            guard let self, dwell == next,
                  Landing.compact(next, now: ProcessInfo.processInfo.systemUptime,
                                  after: Look.heldDwell) else { return }
            set(compact: true)
        }
    }

    /// The pointer has left `spot`. Only the row the clock is running on can stop it:
    /// SwiftUI does not promise that the `dropExited` of the row you left arrives before the
    /// `dropEntered` of the one you reached, and the wrong order would cancel the rest you
    /// have only just begun.
    func left(_ spot: Landing.Spot) {
        guard dwell?.over == spot else { return }
        resting(over: nil)
    }

    /// Back to full, whatever the pointer was doing — the drag is over. Not `resting(over:)`,
    /// which returns early when there is no clock running: a row left compact with the dwell
    /// already cleared would stay shrunk after the drag it belonged to had gone.
    func rest() {
        dwell = nil
        set(compact: false)
    }

    /// Reduce Motion still shrinks the row: what it is for is seeing what is underneath, and
    /// that is not decoration. Only the growing and shrinking of it goes.
    private func set(compact next: Bool) {
        guard next != compact else { return }
        if Motion.reduced { compact = next } else { withAnimation(Look.quick) { compact = next } }
    }
}

/// ponytail: `.onDrag`/`.onDrop` with a delegate rather than `.draggable`/`.dropDestination`.
/// The Transferable pair cannot say which side of the target the pointer is on, so it can
/// only ever drop *onto* a tab, never before or after it; this one gets the location.
/// `at` is the row's own place in its section — the one place a drop cannot move it to, and
/// the slot the live reorder keeps under the pointer. The favourites grid passes none: a
/// tile is not a row in a section's list.
@MainActor private func dragPayload(_ tab: Tab, in store: TabStore? = nil,
                                    at spot: Landing.Spot? = nil) -> NSItemProvider {
    // Published on the next turn, not now: a state change inside the drag's own start
    // re-renders the row under the pointer, and SwiftUI drops the drag with it.
    let id = tab.id
    // Read *now*, while the pointer is still where the button went down. The drag reports
    // its first location a flick later, and on a fast one that is two rows on — see
    // `TabDrop.lift`.
    let from = NSEvent.mouseLocation.y
    // Grabbing a row that is part of a selection drags the selection, in the order it is
    // drawn; grabbing any other row drags that row alone and leaves the selection be —
    // which is how Finder behaves, and what stops a drag quietly moving tabs off screen.
    let set = store?.selection.contains(id) == true ? store?.selectedTabs.map(\.id) ?? [] : []
    let undo = store.map { restore(tab, in: $0) }
    // All of it set, so a flag left behind by a drag that ended outside any of our targets —
    // dropped on the desktop, say, where no `performDrop` ever runs — is cleared by the
    // next drag rather than outliving the session.
    DispatchQueue.main.async {
        Motion.list {
            Dragging.shared.tab = id
            Dragging.shared.folder = nil
            Dragging.shared.tabs = set
            Dragging.shared.at = spot
            Dragging.shared.undo = undo
            Dragging.shared.grab = nil
            Dragging.shared.grabbedAt = from
            Dragging.shared.live = false
            Dragging.shared.settling = nil
            // The row lifts where it stands. Waiting for the drag's first location would
            // leave the list with a dimmed slot and nothing in the air until the pointer
            // reached a row, which reads as the row having been deleted.
            Held.shared.show(spot.map {
                Held.Air(tab: id, kind: $0.kind,
                         y: Landing.slot(row: $0.index,
                                         height: Look.rowHeight, gap: Look.rowGap))
            })
        }
    }
    return NSItemProvider(object: id.uuidString as NSString)
}

/// Putting a row back where a drag found it. Captured as its neighbour rather than as an
/// index: the live reorder moves only the dragged row, so every other row keeps its place
/// and "after the tab that was above me" still names the same gap however far the drag has
/// wandered. `drop` restores the section too, since it takes its target's kind.
///
/// ponytail: no snapshot of the whole order. One row moved is one row to move back, and a
/// saved order would have to be reconciled with every tab opened or closed mid-drag.
@MainActor private func restore(_ tab: Tab, in store: TabStore) -> @MainActor () -> Void {
    let id = tab.id, kind = tab.kind
    let section = store.tabs.filter { $0.kind == kind }
    let here = section.firstIndex { $0.id == id }
    let anchor: (Tab.ID, Bool)? = here.flatMap { i in
        if i > 0 { return (section[i - 1].id, true) }
        return section.count > 1 ? (section[i + 1].id, false) : nil
    }
    return { [weak store] in
        guard let store else { return }
        // The only row in its section has no neighbour to be put back beside; all it can
        // have lost is which section it is in.
        if let anchor {
            store.drop(id, onto: anchor.0, after: anchor.1)
        } else {
            store.move(id, to: kind)
        }
        // The row is back in the section it started in, so the selection has to be told the
        // same thing a drop tells it — a cancelled drag must leave nothing behind.
        store.selectionLanded([id], in: kind)
    }
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
            .opacity(on && dragging.active ? 1 : 0)
    }
}

/// The slot a lifted row came from, dimmed so the list still reads as having somewhere to
/// put it back. The row itself is drawn over the list by `HeldRow`, under the pointer. The
/// slot keeps its height and its drop target on purpose: the live reorder brings it to the
/// pointer, and the pointer has to land on something that says "nothing to do".
///
/// ponytail: opacity, not height. A slot that closed would slide the list out from under the
/// pointer, which is the oscillation the live reorder was written to avoid.
private struct Lifted: ViewModifier {
    let id: Tab.ID
    @ObservedObject private var dragging = Dragging.shared

    func body(content: Content) -> some View {
        content.opacity(dragging.lifted(id) ? Look.lifted : 1)
    }
}

/// The row in your hand. Arc moves the row itself rather than a picture of it, so this is
/// the real row — drawn in an *overlay* of the section, a sibling of the stack rather than a
/// child of it. That is the whole trick: a row in the stack sits inside its own
/// `.rowCollapse` transition, and a transition owns the geometry of what it is
/// transitioning, so offsetting the row there stops it being drawn at all.
///
/// It follows the pointer through `Dragging.air`, whose y comes from the drag's own reported
/// locations (`TabDrop.lift`) — there is no view geometry to read, because the rows are laid
/// out on one pitch and `Landing` can do the arithmetic. Where no drop target sees the
/// pointer — over a folder row, the page card, a Space dot — the row stays where it last
/// was, which reads as the list waiting rather than the row vanishing.
private struct HeldRow: View {
    @EnvironmentObject var store: TabStore
    /// Which section's overlay this is: the row is only drawn over the list it is in.
    let kind: TabKind
    @ObservedObject private var held = Held.shared

    var body: some View {
        if let air = held.air, air.kind == kind,
           let tab = store.tabs.first(where: { $0.id == air.tab }) {
            row(tab)
                .frame(height: Look.rowHeight)
                // Off the ground, so it covers the row it is passing over rather than
                // reading as two titles printed on top of each other. A floating surface is
                // `barFill` over `barMaterial` everywhere else in the app, and a row is not
                // the place to invent a second recipe — the fill is what makes it opaque,
                // the blur only softens what is under it.
                .background(Look.barFill, in: .rect(cornerRadius: Look.pillRadius))
                .background(Look.barMaterial, in: .rect(cornerRadius: Look.pillRadius))
                .padding(.leading, indent(air.tab))
                .liftedPreview()
                // Rest it over a row and it gets out of its own way, so the ring and the lit
                // half underneath — which is the whole answer to "which side does the split
                // open on?" — are not hidden by the thing asking the question. Scale, not a
                // smaller row: the row keeps its layout, so nothing reflows on the way down
                // and nothing has to be built twice.
                //
                // ponytail: about the row's own centre rather than the pointer's exact place
                // in it. The pointer is holding the row somewhere along 36pt and the centre
                // is 18 of them, so the two are under a finger's width apart — and anchoring
                // on the grab point would mean publishing it on every reported move, which
                // is the one thing `Held` exists to avoid.
                .scaleEffect(held.compact ? Look.heldCompact : 1)
                // Nothing in the air is a target. The slot it left is one, and the live
                // reorder keeps that slot under the pointer wherever the row has got to.
                .allowsHitTesting(false)
                // Nor is it a second row for VoiceOver: the slot it came from is still in
                // the list, and a drag is a pointer gesture with a menu behind it.
                .accessibilityHidden(true)
                // The slot already stands for this tab in the strip's geometry group, and
                // one source per id is the most it can have.
                .environment(\.strip, nil)
                .offset(y: air.y)
                // It leaves by fading, crossing with the slot coming back to full — see
                // `Dragging.end`. Cutting it instead shows the row jump out of its own
                // shadow at the end of every drag.
                .transition(.opacity)
        }
    }

    @ViewBuilder private func row(_ tab: Tab) -> some View {
        if let split = store.split(containing: tab.id) {
            SplitRow(split: split, lead: tab)
        } else {
            TabRow(tab: tab)
        }
    }

    /// How far in a row sits, so a tab held out of a folder keeps the indent its slot has.
    /// Both sections that have folders; a favourite's tile has none.
    private func indent(_ id: Tab.ID) -> CGFloat {
        guard let shape = TabStore.shape(of: kind) else { return 0 }
        let depth = store[keyPath: shape].visible.first { $0.entry.tab == id.uuidString }?.depth ?? 0
        return CGFloat(depth) * Look.folderIndent
    }
}

/// A split's row: the panes as pills in one row-height container, sharing its width. The
/// pane you are in is the lighter pill, and clicking any of them shows the split with that
/// pane focused — which is the only reason the row has more than one thing in it.
///
/// ponytail: equal widths rather than widths from the titles. A row whose columns move as
/// pages load their titles is a row you cannot aim at, and four panes have to fit a sidebar
/// either way, so the truncation is the answer at every count.
private struct PaneStrip: View {
    /// Passed in rather than read from the environment, as `SpaceMenu`'s is: this is also
    /// built for the drag preview, which AppKit renders outside the view hierarchy, and a
    /// missing `@EnvironmentObject` there is a crash rather than a blank row.
    let store: TabStore
    let split: Split
    let panes: [Tab]
    let selected: Bool
    let ticked: Bool
    /// The preview is a picture of the row, not the row: nothing in it is pressable, and the
    /// close button would be a lie.
    var live = true
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Look.paneGap) {
            ForEach(Array(panes.enumerated()), id: \.element.id) { i, pane in
                PanePill(store: store, tab: pane, active: pane.id == split.activeTab,
                         index: i, of: panes.count)
            }
            // A split's row is still a row: the pane making the noise says so and can be
            // muted from here, and the × closes the pane the row is showing.
            if live, let voice {
                TabRowTrailing(store: store, tab: voice, selected: selected,
                               pane: true, closes: panes.first { $0.id == split.activeTab })
            }
        }
        .padding(Look.paneInset)
        .frame(height: Look.rowHeight)
        .background(fill, in: .rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius, ticked && selected ? Look.selectedEdge : .clear)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { store.focusPane(split.activeTab) }
        .environment(\.rowHovering, hovering)
    }

    /// Which pane the row's trailing glyphs are about. Whichever one is making the noise —
    /// that is the pane you are looking for when a sidebar starts talking — and otherwise
    /// the one on screen, whose × is the one a split's row has always closed.
    /// ponytail: worked out here rather than in the body. The same expression inside a
    /// `ViewBuilder` took the type checker minutes.
    private var voice: Tab? {
        panes.first { $0.audible || TabAudio.isMuted($0) }
            ?? panes.first { $0.id == split.activeTab }
    }

    /// The container wears the row's own states, exactly as `SidebarRow` does.
    private var fill: Color {
        selected || ticked ? Look.selected : (hovering ? Look.hovered : .clear)
    }
}

/// One pane of a split, in the strip. Its own element for VoiceOver, because a pane is a
/// page you can go to and a row with four of them is four places, not one.
private struct PanePill: View {
    /// See `PaneStrip`: handed in, because this is drawn in the drag preview too.
    let store: TabStore
    @ObservedObject var tab: Tab
    let active: Bool
    let index: Int
    let of: Int

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            TabIcon(tab: tab, size: Look.rowIcon)
            Text(TidyTitles.title(for: tab))
                .font(Look.rowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Look.inkPrimary)
        }
        .padding(.horizontal, Look.paneInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Look.rowHeight - Look.paneInset * 2)
        // The pane being looked at is the lighter one; the rest are a step quieter, so the
        // row says which page the card is showing without a second mark to read.
        .background(active ? Look.selected : Look.hovered,
                    in: .rect(cornerRadius: Look.panePillRadius))
        .contentShape(.rect)
        .onTapGesture { store.focusPane(tab.id) }
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TidyTitles.title(for: tab))
        .accessibilityValue("Pane \(index + 1) of \(of)" + (active ? ", showing" : ""))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this pane of the split view.")
    }
}

extension View {
    /// A row that lifts out of the list while it is being dragged.
    func lifted(_ id: Tab.ID) -> some View { modifier(Lifted(id: id)) }
    /// The drag preview: the row held a shade above the sidebar. AppKit renders this into
    /// the image that follows the pointer, so the shadow has to be inside it.
    func liftedPreview() -> some View {
        scaleEffect(Look.liftScale)
            .shadow(color: Look.liftShadow, radius: Look.liftShadowRadius, y: Look.liftShadowY)
    }
}

/// One drop target for a tile, a row and the empty grid. `target` nil is the placeholder,
/// which simply moves the tab into `into`. The side is the part of the target the pointer is
/// in — left/right across `extent` for a tile, one of `Landing`'s three bands of
/// `Look.rowHeight` for a row — and is published through `side` so the target can draw its
/// line before the button is released. A row's middle band publishes `half` as well: which
/// side of it the split will open on.
private struct TabDrop: DropDelegate {
    let store: TabStore
    let target: Tab?
    /// Which section this target is in. With a `target` it is the target's own kind and is
    /// unused; with none it is the empty section's, and is what the drop moves the tab into.
    let into: TabKind
    let axis: Axis
    /// How wide the target is across: a tile's width, and a row's — which is what says which
    /// half of the row a split was dropped on. Zero for the placeholders, which have no
    /// halves at all.
    let extent: CGFloat
    @Binding var side: Landing.Band?
    /// This row's place in its section, and how many rows the section draws — what turns the
    /// pointer inside one row into a place in the whole list. Nil for a tile in the
    /// favourites grid and for the two placeholder targets, which stand for a section rather
    /// than a row in one.
    var row: Int?
    var rows = 0
    /// Which half of the row the pointer is in while it is offering a split, so the row can
    /// show the side the dragged tab will take before the button comes up. A plain
    /// `Binding` rather than a `@Binding` property: only a strip row has a half to draw, and
    /// every other target of this delegate would have to pass `.constant(nil)` by hand.
    var half: Binding<Landing.Side?> = .constant(nil)
    /// Whether the window reads right to left, in which case the leading pane is drawn on
    /// the right and the two halves of the row mean the opposite sides. See `Landing.side`.
    var rtl = false

    func validateDrop(info: DropInfo) -> Bool {
        // A folder lands among the rows of either section that has folders — its own, which
        // is a reorder, or the other one, which pins it or un-pins it whole. The favourites
        // grid has nowhere to draw a folder row, and refuses rather than dropping one where
        // it cannot be seen.
        if let dragged = Dragging.shared.folder {
            guard let shape = TabStore.shape(of: target?.kind ?? into) else { return false }
            return store.canDrag(folder: dragged, into: shape)
        }
        // The dragged row's own slot takes the drop too, and answers "nothing to do".
        // Refusing it would hand the pointer to whatever is under the list the moment the
        // live reorder brings the row back beneath it.
        return Dragging.shared.tab != nil
    }
    func dropEntered(info: DropInfo) { track(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard Dragging.shared.active else { return DropProposal(operation: .cancel) }
        track(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        side = nil
        half.wrappedValue = nil
        if let spot { Held.shared.left(spot) }
    }

    /// This target as a place in a list — what the rest the pointer may be taking is *on*.
    /// Nil for everything that is not a row: a favourite's tile and the two placeholders.
    private var spot: Landing.Spot? { row.map { Landing.Spot(kind: into, index: $0) } }

    func performDrop(info: DropInfo) -> Bool {
        let offer = place(info)
        let where_ = offer?.band
        let after = where_ == .after
        side = nil
        half.wrappedValue = nil
        // Read once and cleared *before* anything can refuse the drop. A drag left set here
        // outlives the gesture, and `SidebarDrop` then stands aside from every url and file
        // dropped on the sidebar for the rest of the session.
        //
        // `landed` only when there is nothing left to do — the live reorder has already put
        // the row where it belongs, so the slot the list is holding is where it ends up and
        // the row in the air can glide into it. Anything else moves it again.
        let (dragged, folder) = Dragging.shared.takeAll(landed: where_ == nil)
        if let folder {
            guard let shape = TabStore.shape(of: target?.kind ?? into),
                  store.canDrag(folder: folder, into: shape) else { return false }
            // A row to be beside, or — on the space's name, the divider and the New Tab row —
            // the section itself, which takes the folder at the end of Pinned or the head of
            // Today, where a tab crossing the same divider lands.
            if let target {
                store.move(folder: folder, next: target.id.uuidString, after: after, in: shape)
            } else {
                store.move(folder: folder, to: shape)
            }
            return true
        }
        guard !dragged.isEmpty else { return false }
        // Whatever the drop turns out to mean, these tabs have landed in this section — the
        // live reorder may have carried them here rows ago — and the selection has to be
        // told, or every bulk action on it becomes a silent no-op. See `selectionLanded`. A
        // `defer`, because the quietest landing of all is the one that returns first.
        defer { store.selectionLanded(dragged, in: target?.kind ?? into) }
        // Let go where the row already is — including wherever the live reorder has already
        // put it — and the drop is over: taken, so the drag ends, and answered, so nothing
        // else is offered it. The list is already right.
        guard let where_ else { return true }
        // Arc's "drop a tab on a tab": the two go side by side. `addPane` is the same door
        // ⌃⇧= and a drop on the page card use, so the four-pane ceiling and the thing it
        // says when you reach it are written down once.
        if where_ == .onto, let target {
            // Back to front on the trailing side: every tab of a run joins immediately after
            // the anchor, so the first one placed ends up last. On the leading side each in
            // turn joins in front of the anchor and so behind the one before it, which is
            // already the order they were drawn in.
            for id in offer?.half == .leading ? dragged : dragged.reversed() {
                // A split draws one row, at its lead pane's place, so a pane from the other
                // section would be a row in two lists. It joins the target's section first.
                if store.tabs.first(where: { $0.id == id })?.kind != target.kind {
                    store.drop(id, onto: target.id, after: true)
                }
                // Which half of the row it was let go on says which side of the target the
                // pane opens on.
                store.addPane(id, beside: target.id, side: offer?.half ?? .trailing)
            }
            return true
        }
        // A dropped selection lands as a run in the order its rows were drawn. Dropping
        // *before* the target means each next tab goes after the one just placed, so the run
        // keeps its order instead of arriving inside out.
        var anchor = target
        for id in dragged {
            guard let here = anchor else { store.move(id, to: into); continue }
            // A tab dropped onto itself — the target's own row was in the selection — is
            // already where it belongs; it still becomes the anchor for the rest of the run.
            if id != here.id { store.drop(id, onto: here.id, after: after || id != dragged.first) }
            anchor = store.tabs.first { $0.id == id } ?? here
        }
        return true
    }

    /// What a row is offering: which of its three bands the pointer is in and, for the two
    /// edges, the index the dragged row would end up at. Worked out once, because `track`
    /// moves the row there and `performDrop` reads the band, and the two must not be able to
    /// disagree about the same pointer.
    private struct Offer {
        var band: Landing.Band
        var to: Int?
        /// Which side of the target a split would open on — only ever set for `.onto`.
        var half: Landing.Side?
    }

    /// What this row is offering the pointer, or nil for nothing at all. A tile in the
    /// favourites grid has two halves and no middle — a row of icons has nothing to split.
    private func place(_ info: DropInfo) -> Offer? {
        // The thing being dragged, over itself: nothing to offer, whichever way the target is
        // laid out. On a row this is what makes the live reorder settle; on a favourite's
        // tile it is what stops the grid drawing a drop line on the tile in your hand.
        if let id = Dragging.shared.tab, id == target?.id { return nil }
        guard axis == .vertical, let target else {
            // A placeholder stands for a whole section rather than for a row in one, and
            // `move(_:to:)` refuses a tab that is already in that section — so offering the
            // drop would be a target that lights up and then does nothing. Nil is the same
            // answer the dragged row's own slot gives: there is nothing to do, and the row
            // in the air glides back into the slot the list is holding for it.
            if target == nil, let id = Dragging.shared.tab,
               store.tabs.first(where: { $0.id == id })?.kind == into { return nil }
            return Offer(band: info.location.x > extent / 2 ? .after : .before, to: nil)
        }
        let band = Landing.band(y: info.location.y, height: Look.rowHeight)
        if band == .onto {
            // Arc opens the split on the side you dropped on: the left half of the row puts
            // the dragged tab left (or on top, stacked), the right half puts it right.
            guard canSplit(with: target) else { return nil }
            return Offer(band: .onto, to: nil,
                         half: Landing.side(x: info.location.x, width: extent, rtl: rtl))
        }
        // The source is only a source in its own section: dragged into the other one it is a
        // new row, and every boundary there is a real move.
        let at = Dragging.shared.at
        let source = at?.kind == into ? at?.index : nil
        guard let to = Landing.move(row: row ?? 0, band: band, source: source) else { return nil }
        return Offer(band: band, to: to)
    }

    /// Whether dropping onto this row would make a split anyone wants. A full one has no
    /// room; a pane of the dragged tab's own split is already beside it.
    private func canSplit(with target: Tab) -> Bool {
        guard Dragging.shared.folder == nil, let id = Dragging.shared.tab else { return false }
        if store.split(containing: id)?.contains(target.id) == true { return false }
        let panes = store.split(containing: target.id)?.tabs.count ?? 1
        let coming = max(Dragging.shared.tabs.count, 1)
        return Landing.roomToSplit(panes: panes) >= coming
    }

    /// Arc reorders while you drag, not when you let go: crossing into a neighbour's edge
    /// moves the row there and then, and the list settles into its new shape under the
    /// pointer. What keeps it still afterwards is `Landing.move` — the move puts the row's
    /// own slot under the pointer, and its own slot is not a place to land.
    ///
    /// ponytail: `store.drop` once per crossing, the same call a released drop makes. In
    /// Pinned that writes `pins.json` each time, so dragging the length of a long list is one
    /// small write per row passed — the debounce for that belongs in `savePins`, not here,
    /// where it would have to know what a drag is.
    ///
    /// A dragged *run* keeps the drop line and lands on release: moving five rows on every pointer crossing is five reorders a frame, and the
    /// run's own rows would be crossing each other as it went. Upgrade path: move the run as
    /// a block once `store.drop` can take one.
    private func track(_ info: DropInfo) {
        let offer = place(info)
        side = offer?.band
        half.wrappedValue = offer?.half
        // Rest over the middle of a row and the row in your hand shrinks out of the way: the
        // middle is where the split is offered, and the ring and the lit half that say so are
        // exactly what the held row is covering. Every other place the pointer can be — an
        // edge band, the dragged row's own slot, a tile, a placeholder — has nothing behind
        // the row worth uncovering, and hands back nil, which puts it straight back to full.
        Held.shared.resting(over: offer?.band == .onto ? spot : nil)
        lift(info)
        guard axis == .vertical, let offer, let to = offer.to, let target,
              let id = Dragging.shared.tab,
              // A run keeps the line and lands on release: moving five rows on every pointer
              // crossing is five reorders a frame, with the run's own rows crossing each
              // other as they go. So does a split's row — `store.drop` moves one tab and a
              // split is several, so walking its lead past a sibling would swap which pane
              // the row stands for and leave it looking as though nothing had happened.
              Dragging.shared.tabs.count <= 1, store.split(containing: id) == nil
        else { return }
        store.drop(id, onto: target.id, after: offer.band == .after)
        Dragging.shared.at = Landing.Spot(kind: into, index: to)
        // The list is now holding this row's slot, so letting go is a glide into it rather
        // than a landing — see `Dragging.end`.
        Dragging.shared.live = true
        // The row is where the line would have pointed, so there is no line to draw.
        side = nil
    }

    /// Puts the row itself under the pointer — Arc moves the row, not a picture of it. The
    /// pointer's place in the whole section is its place in this row plus this row's own,
    /// and the row hangs from it by wherever it was picked up, which the first location the
    /// drag reports says: a drag begins inside the row it grabbed.
    ///
    /// Only for a row that was dragged out of a section's list (`at`) and is in the air on
    /// its own (`lifted`): a favourite's tile has no row to lift, and a run keeps every one
    /// of its rows on screen and AppKit's picture under the pointer.
    private func lift(_ info: DropInfo) {
        let drag = Dragging.shared
        guard axis == .vertical, let row, rows > 0, let at = drag.at,
              let id = drag.tab, drag.lifted(id) else { return }
        let pointer = Landing.pointer(row: row, y: info.location.y,
                                      height: Look.rowHeight, gap: Look.rowGap)
        // Worked out once, from the first location the drag reports. That location is a
        // flick after the button went down — two rows on, if the flick was quick — so the
        // row-local y there is not where the row was grabbed; the pointer's travel since,
        // taken back off, is. Screen y counts up and a section's counts down, hence the
        // subtraction either way round.
        let now = NSEvent.mouseLocation.y
        let grab = drag.grab ?? Landing.grab(
            pointer: pointer,
            travelled: (drag.grabbedAt ?? now) - now,
            source: at.kind == into
                ? Landing.slot(row: at.index, height: Look.rowHeight, gap: Look.rowGap)
                : pointer - info.location.y,      // dragged in from the other section
            height: Look.rowHeight)
        drag.grab = grab
        // Crossing into the other section makes the slot the list is holding the wrong one
        // to glide into; `Landing.settles` refuses it, and this is where the two diverge.
        Held.shared.show(Held.Air(tab: id, kind: into,
                                  y: Landing.held(pointer: pointer, grab: grab, rows: rows,
                                                  height: Look.rowHeight, gap: Look.rowGap)))
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
    @State private var live = false

    var body: some View {
        if let space = store.currentSpace {
            row(space.icon ?? "cloud", space, space.name)
            .onTapGesture(count: 2) { store.renamingSpace = space.id }
            .onTapGesture { showSpaceList(store) }
            .contextMenu {
                SpaceMenu(store: store, space: space, icons: $icons, theme: $theme, live: $live)
            }
            .popover(isPresented: $icons) { SpaceIcons(store: store, space: space) }
            .popover(isPresented: $theme) { ThemeEditor(store: store, space: space) }
            .sheet(isPresented: $live) {
                LiveFolderSheet(store: store, live: LiveFolders.shared(for: store.profileID))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space")
            .accessibilityValue(space.name)
            .accessibilityHint("Click for the list of spaces, double-click to rename this one.")
            .accessibilityAction(named: "Rename Space") { renameSpace(space, in: store) }
            .accessibilityAction(named: "Change Space Icon") { icons = true }
            .accessibilityAction(named: "Edit Theme Color") { theme = true }
        } else if store.isPrivate {
            // A private window is in no Space by design, and the list below it still needs
            // its heading. No click, no rename, no context menu — there is nothing to act on.
            row("eyeglasses", nil, store.profile.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Private window")
            .accessibilityValue(store.profile.name)
            .accessibilityHint("A private window is in no space and keeps nothing.")
        } else {
            // An ordinary window pointing at a Space that is no longer there: deleted from
            // another window, from Settings or from the Library. It has one frame of the
            // profile's name and then falls into a surviving Space — see `resolveStaleSpace`.
            row("cloud", nil, store.profile.name)
            .task { store.resolveStaleSpace() }
            .accessibilityHidden(true)
        }
    }

    private func row(_ icon: String, _ space: Space?, _ name: String) -> some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: icon).font(Look.spaceIcon).frame(width: Look.tileIcon)
            SpaceName(store: store, space: space, fallback: name)
            Spacer(minLength: 0)
        }
        // Arc's quietest ink on the sidebar (152 on 66): a heading, not a row.
        .foregroundStyle(Look.inkTertiary)
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.rowHeight)
        .contentShape(.rect)
        // Dropping a tab on the space's name pins it — the way into an empty Pinned section
        // now that there is no placeholder slot to drop on.
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: nil, into: .pinned,
                                  axis: .horizontal, extent: 0, side: .constant(nil)))
    }
}

/// Exactly the items Arc offers, minus the ones Vane has nothing behind.
/// ponytail: no Share Space and no Export — those are whole features, not menu items, and an
/// entry that opens an apology is worse than no entry. They belong beside `New Folder` on the
/// day they exist.
/// ponytail: `store` is passed in rather than read from the environment. A context menu is
/// hosted in its own window, and an `@EnvironmentObject` that fails to reach it is a crash,
/// not a blank menu — not a risk worth taking for a shorter initialiser.
private struct SpaceMenu: View {
    let store: TabStore
    let space: Space
    @Binding var icons: Bool
    @Binding var theme: Bool
    /// The one way into a Live Folder when the Pinned section is empty: with no rows there
    /// is no Pinned context menu to right-click.
    @Binding var live: Bool

    var body: some View {
        Button("Change Space Icon…") { open($icons) }
        Button("Rename Space…") { renameSpace(space, in: store) }
        Button("Edit Theme Color…") { open($theme) }
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
        // Moving a Space out is a delete on this side, so the last one is as un-movable as
        // it is un-deletable: a profile always has a Space.
        .disabled(store.spaces.count < 2)
        Divider()
        Button("New Folder") { store.newFolder() }
        // Arc asks nothing: signed in, the folder is there on the click. Signed out, the
        // click is the sign-in, and the folder follows it. The sheet is the fallback for a
        // build that cannot do the web flow — see `TabStore.askForLiveFolder`.
        Button("New Live Folder…") { store.askForLiveFolder { open($live) } }
        Divider()
        // Arc's "Manage Spaces…" opens the Library's Spaces view — every Space's pages side
        // by side, draggable between columns — rather than a settings pane.
        Button("Manage Spaces…") { Library.open(.spaces, in: store) }
        Divider()
        Button("Delete Space") { deleteSpace(space, in: store) }
            .disabled(store.spaces.count < 2)
    }
}

/// Opens a panel a menu item asked for, one turn of the run loop later.
///
/// A menu item's action runs while the menu is still on its way out, and a popover asked for
/// there is asked for against a view AppKit has not given the pointer back to yet: SwiftUI
/// takes the flag and drops the presentation. The panel then only turns up when something
/// else happens to redraw the row it hangs off — which is why "Edit Theme Color…" showed
/// nothing until the space's name was pressed again. By the next turn the menu has gone and
/// the popover opens where it was asked for.
@MainActor private func open(_ flag: Binding<Bool>) {
    DispatchQueue.main.async { MainActor.assumeIsolated { flag.wrappedValue = true } }
}

/// Arc renames a Space in the sidebar, not in a dialog: this only arms the field, and
/// `SpaceName` is what commits it.
@MainActor private func renameSpace(_ space: Space, in store: TabStore) {
    store.renamingSpace = space.id
}

@MainActor private func deleteSpace(_ space: Space, in store: TabStore) {
    guard store.spaces.count > 1 else { return }
    let a = NSAlert()
    a.messageText = "Delete the space “\(space.name)”?"
    a.informativeText = "Its tabs and pinned tabs go to the Archive, where the Library can "
        + "still find them. Nothing in your history, bookmarks or saved passwords is affected."
    a.alertStyle = .critical
    a.addButton(withTitle: "Cancel")
    a.addButton(withTitle: "Delete")
    a.buttons.last?.hasDestructiveAction = true
    guard a.runModal() == .alertSecondButtonReturn else { return }
    let survivor = store.spaces.first { $0.id != space.id }
    guard Spaces.delete(space.id, in: space.profileID) else { return }
    if let survivor { store.switchTo(space: survivor) }
    rebuild()
}

/// ponytail: a window's profile is fixed for its lifetime — the data store, the cookie jar
/// and the extension host are all built from it in `TabStore.init`. So moving a space to
/// another profile opens it in a window there and closes this one, rather than trying to
/// re-home a live WKWebsiteDataStore. Ceiling: the window's position is not carried over.
@MainActor private func moveSpace(_ space: Space, to profile: Profile, from store: TabStore) {
    // The source profile is losing a Space, so the same rule as Delete applies: never its
    // last one. Without this the profile is left with none, this window's close writes its
    // tabs into that profile's session, and the next window there invents a Space holding a
    // second copy of every page that just moved out.
    guard profile.id != space.profileID, store.spaces.count > 1 else { return }
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

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.rowHeight), spacing: 6), count: 6),
                  spacing: 6) {
            ForEach(Spaces.icons, id: \.self) { name in
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

/// One dot per space, the current one wearing the space's own icon. There is no "no spaces"
/// case any more: an ordinary window is always in a Space, so exactly one dot is always the
/// current one. Only a private window has none, and it does not draw this at all.
private struct SpaceDots: View {
    @EnvironmentObject var store: TabStore
    /// *Which* dot's panel is open, not merely whether one is. Every dot draws its own
    /// `.popover`, so on one shared flag all of them asked to present at once and SwiftUI
    /// gave the panel to the last dot in the row: right-clicking any other dot opened the
    /// editor on the *last* Space's colours, hanging off the last Space's dot.
    @State private var icons: UUID?
    @State private var theme: UUID?
    @State private var live: UUID?
    /// Which dot a drag is over, so only that one lights up.
    @State private var dropTarget: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Once per body, not once per dot: `store.spaces` re-reads and decodes `spaces.json`
        // every time it is touched, and a live swipe redraws this row every frame.
        let list = store.spaces
        let lit = weights(list)
        HStack(spacing: 8) {
            ForEach(list) { dot($0, lit: lit[$0.id] ?? 0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    /// Both shapes are always in the tree, cross-fading on one number, so a live swipe can
    /// hand the icon over a fraction at a time. A transition can only be all or nothing, and
    /// mid-swipe the answer to "which Space are you in" genuinely is "between two".
    @ViewBuilder private func dot(_ space: Space, lit: Double) -> some View {
        let here = store.currentSpaceID == space.id
        let over = Binding(get: { dropTarget == space.id },
                           set: { dropTarget = $0 ? space.id : nil })
        let showIcons = Binding(get: { icons == space.id },
                                set: { icons = $0 ? space.id : nil })
        let showTheme = Binding(get: { theme == space.id },
                                set: { theme = $0 ? space.id : nil })
        let showLive = Binding(get: { live == space.id },
                               set: { live = $0 ? space.id : nil })
        ZStack {
            Circle().fill(Look.dotFill).frame(width: Look.dot, height: Look.dot)
                .opacity(1 - lit)
                .scaleEffect(Look.tileAppearScale + (1 - Look.tileAppearScale) * (1 - lit))
            Image(systemName: space.icon ?? "cloud").font(Look.small)
                .foregroundStyle(Look.inkPrimary)
                .opacity(lit)
                .scaleEffect(Look.tileAppearScale + (1 - Look.tileAppearScale) * lit)
        }
        .animation(reduceMotion ? nil : Look.quick, value: here)
        .frame(width: Look.spaceDotHit, height: Look.spaceDotHit)
        .background(dropTarget == space.id ? Look.selected : .clear, in: .circle)
        .contentShape(.rect)
        .onTapGesture { store.switchTo(space: space) }
        .onDrag { spaceDragPayload(space) }
        .onDrop(of: [.plainText], delegate: SpaceDrop(store: store, space: space, over: over))
        .help(space.name)
        .contextMenu {
            SpaceMenu(store: store, space: space, icons: showIcons, theme: showTheme,
                      live: showLive)
        }
        .popover(isPresented: showIcons) { SpaceIcons(store: store, space: space) }
        .popover(isPresented: showTheme) { ThemeEditor(store: store, space: space) }
        // In the Space the window is showing, like "New Folder" beside it in the same menu:
        // a folder belongs to a Pinned section, and this window draws exactly one.
        .sheet(isPresented: showLive) {
            LiveFolderSheet(store: store, live: LiveFolders.shared(for: store.profileID))
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(here ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Switches to this space.")
        .accessibilityAction { store.switchTo(space: space) }
    }

    /// How lit each dot is, 0…1. Idle that is 1 for the current Space and 0 for the rest;
    /// while a swipe is live the current dot hands its icon to the neighbour the fingers are
    /// heading for, in step with them, so the footer says where the gesture will land before
    /// it lands. At the ends nothing is handed over — the strip is only rubber-banding.
    private func weights(_ list: [Space]) -> [UUID: Double] {
        guard let i = list.firstIndex(where: { $0.id == store.currentSpaceID }) else { return [:] }
        let width = SidebarWidth.shared.width
        guard store.spaceDrag != 0, width > 0 else { return [list[i].id: 1] }
        let f = Double(max(-1, min(1, store.spaceDrag / width)))
        let towards = f < 0 ? i + 1 : i - 1
        guard list.indices.contains(towards) else { return [list[i].id: 1] }
        return [list[i].id: 1 - abs(f), list[towards].id: abs(f)]
    }
}

// MARK: - Pinned

/// Arc's Pinned section: the tabs that stay, drawn as ordinary rows between the space's name
/// and the New Tab divider. Deliberately the same row as a Today tab — in Arc the two are
/// indistinguishable to look at, and the divider below is the only thing that says which is
/// which. What differs is behaviour: a pinned tab never auto-archives, and ⌘W leaves it
/// exactly where it is.
private struct PinnedTabs: View {
    @EnvironmentObject var store: TabStore

    /// One observer of `LiveFolders` for the whole section, rather than one per row: the
    /// glyphs all come out of the same object, and a hundred pinned rows each watching it
    /// is a hundred redraws for one refresh.
    var body: some View {
        PinnedSection(live: LiveFolders.shared(for: store.profileID))
    }
}

private struct PinnedSection: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var live: LiveFolders
    @State private var sheet = false

    var body: some View {
        // Drawn from `store.pins`, not from the strip: a folder is not a tab, and the order
        // the rows are in is the folders’, which is what `Pins` is for. Only the entries that
        // actually draw a row are counted — a pinned pane that is not its split's lead, and
        // an entry whose tab has gone, draw nothing, and a place in the list counted in
        // entries rather than rows lands beside the wrong one. See `OpenTabs`.
        let rows = store.pins.visible.filter { row in
            if row.entry.folder != nil { return true }
            guard let tab = store.tabs.first(where: { $0.id.uuidString == row.entry.tab })
            else { return false }
            guard let split = store.split(containing: tab.id) else { return true }
            return store.leadPane(split) == tab.id
        }
        // Empty is nothing, as in Arc: the divider follows the space’s name, and this
        // section draws no row at all — not even an empty one while a drag is in flight,
        // which would push the whole strip down a pitch under the pointer and take
        // `Landing`'s arithmetic with it. The way in is the divider below, which is the end
        // of this list and takes a drop as one; the space row above; ⌘⇧D; or New Folder.
        if !rows.isEmpty {
            VStack(spacing: Look.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ShapeRow(row: row, index: index, rows: rows.count,
                             shape: \.pins, pr: state(of: row))
                        .transition(.rowCollapse)
                }
            }
            .overlay(alignment: .topLeading) { HeldRow(kind: .pinned) }
            .contextMenu {
                Button("New Folder") { store.newFolder() }
                Button("New Live Folder…") { store.askForLiveFolder { open($sheet) } }
            }
            .sheet(isPresented: $sheet) {
                LiveFolderSheet(store: store, live: LiveFolders.shared(for: store.profileID))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned Tabs")
            .accessibilityValue("\(store.pins.tabs.count) pinned")
        }
    }

    /// The pull request a row stands for — only for a row a live folder actually owns, so a
    /// page dragged into one, and every row elsewhere in the sidebar that happens to be on
    /// the same page, wears no mark.
    private func state(of row: Pins.Visible) -> GitHub.State? {
        guard let id = row.entry.tab, let folder = store.pins.folder(holding: id),
              folder.live != nil, let url = store.rowURL(id) else { return nil }
        return live.state(of: url, in: folder)
    }
}

/// One line of a section that has folders — a folder or one of the tabs in it — stepped in
/// by how deep it sits. The indent is the only thing that says a tab is inside a folder,
/// which is exactly how Arc says it. Pinned draws these and so does Today; `shape` is which
/// of the two, and the only thing that differs between them.
private struct ShapeRow: View {
    @EnvironmentObject var store: TabStore
    let row: Pins.Visible
    /// Its place among the section's rows, and how many there are — see `TabDrop.row`.
    let index: Int
    let rows: Int
    let shape: ReferenceWritableKeyPath<TabStore, Pins>
    /// The pull request this row stands for, when a live folder owns it. Through the
    /// environment rather than through `StripRow` and `TabRow`'s signatures: only the Pinned
    /// section can know it, only the row's trailing edge draws it, and every other row in
    /// the app — Today, a pane strip, the Library — correctly gets the default of nil.
    var pr: GitHub.State?

    var body: some View {
        Group {
            if let folder = row.entry.folder {
                FolderRow(folder: folder, shape: shape)
            } else if let tab = store.tabs.first(where: { $0.id.uuidString == row.entry.tab }) {
                // StripRow, not TabRow: a tab that is a pane of a split is drawn as the
                // split's one row, at its lead pane's place.
                StripRow(tab: tab, index: index, rows: rows)
            }
        }
        .padding(.leading, CGFloat(row.depth) * Look.folderIndent)
        .environment(\.livePR, pr)
    }
}

/// Which part of a folder row a drop is over: its edges reorder, its middle puts the thing
/// inside. A tab row has the same three (`Landing.Band`): its middle is the tab itself.
private enum FolderZone { case before, inside, after }

/// A folder in the Pinned section: its glyph, its name and a chevron that says whether it is
/// folded. Clicking anywhere on it folds or unfolds; everything else it can be is in its
/// right-click menu, which is the only route the keyboard and VoiceOver have.
private struct FolderRow: View {
    @EnvironmentObject var store: TabStore
    let folder: Folder
    /// Which section's shape this folder is in — `\.pins` or `\.todayShape`.
    let shape: ReferenceWritableKeyPath<TabStore, Pins>
    @State private var zone: FolderZone?
    @State private var icons = false
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SidebarRow(selected: false, action: { store.toggleFolder(folder.id, in: shape) }) {
            FolderGlyph(folder: folder, live: LiveFolders.shared(for: store.profileID))
        } label: {
            if store.renamingFolder == folder.id {
                FolderNameField(store: store, folder: folder, shape: shape)
            } else {
                Text(folder.name)
            }
        } trailing: {
            Image(systemName: "chevron.down")
                .font(Look.rowGlyph)
                .foregroundStyle(Look.inkSecondary)
                .rotationEffect(.degrees(folder.collapsed ? -90 : 0))
                .animation(reduceMotion ? nil : Look.quick, value: folder.collapsed)
                .accessibilityHidden(true)      // the row’s value already says which it is
        }
        // A drop *into* the folder fills the whole row; a drop beside it draws a line at the
        // edge it will land on. Behind `SidebarRow`, whose own fill is clear at rest.
        .background(zone == .inside ? Look.selected : .clear,
                    in: .rect(cornerRadius: Look.pillRadius))
        .overlay(alignment: zone == .after ? .bottom : .top) {
            DropLine(on: zone == .before || zone == .after, axis: .vertical)
        }
        .help(folder.name)
        .onDrag { folderDragPayload(folder) } preview: {
            HStack(spacing: Look.rowSpacing) {
                FolderGlyph(folder: folder)
                Text(folder.name).lineLimit(1).font(Look.rowTitle)
            }
            .padding(.horizontal, Look.rowInset).padding(.vertical, 4)
        }
        .onDrop(of: [.plainText],
                delegate: FolderDrop(store: store, folder: folder, shape: shape, zone: $zone))
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingFolder = folder.id })
        .contextMenu {
            FolderMenu(store: store, folder: folder, shape: shape,
                       icons: $icons, editing: $editing)
        }
        .popover(isPresented: $icons) { FolderIcons(store: store, folder: folder, shape: shape) }
        .sheet(isPresented: $editing) {
            LiveFolderSheet(store: store, editing: folder,
                            live: LiveFolders.shared(for: store.profileID))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue(state)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Folds this folder open or shut.")
        .accessibilityAction(named: "Rename Folder") { store.renamingFolder = folder.id }
        .accessibilityAction(named: "Change Icon") { icons = true }
        .accessibilityAction(named: "Archive All Tabs in Folder") {
            store.archiveFolder(folder.id, in: shape)
        }
        .accessibilityAction(named: "Delete Folder") { store.deleteFolder(folder.id, in: shape) }
        // The live commands reach the keyboard and VoiceOver the same way every other folder
        // command does — and only on a live folder, as in the menu above.
        .modifier(LiveFolderActions(store: store, folder: folder, editing: $editing))
        // "Live Folder Created", hanging off the folder the click just made. Also out of the
        // chain above, and for the same reason.
        .modifier(LiveFolderCallout(store: store, folder: folder))
    }

    /// Out of the chain because the chain is already at the type-checker's ceiling, and one
    /// more concatenation in it stops the file compiling.
    private var state: String {
        let failed = folder.live != nil
            && LiveFolders.shared(for: store.profileID).failing.contains(folder.id)
        return (folder.live == nil ? "Folder, " : "Live folder, ")
            + "\(store[keyPath: shape].tabs(in: folder.id).count) tabs, "
            + (folder.collapsed ? "collapsed" : "expanded")
            + (failed ? ", last refresh failed" : "")
    }
}

/// A folder’s glyph in a favicon’s box, so its name lines up with the tab titles around it.
/// An emoji is text and an SF Symbol is an image; `Folder.iconIsEmoji` is what tells them
/// apart, and it does so by looking at the string rather than by a second stored field.
private struct FolderGlyph: View {
    let folder: Folder
    /// nil where the badge would be noise rather than news — the drag preview.
    var live: LiveFolders? = nil
    var body: some View {
        Group {
            if folder.iconIsEmoji {
                Text(folder.icon).font(Look.small)
            } else {
                Image(systemName: folder.icon)
            }
        }
        .frame(width: Look.tileIcon)
        // A live folder wears its source in the corner of its own glyph, so a folded folder
        // still says it fills itself.
        .overlay(alignment: .bottomTrailing) {
            if folder.live != nil, let live {
                LiveBadge(live: live, folder: folder.id)
                    .offset(x: Look.sourceBadgeOffset, y: Look.sourceBadgeOffset)
            }
        }
    }
}

/// Right-clicking a folder, in Arc’s order: what it is called, whether it is open, and the
/// two ways to be rid of it. Deleting keeps the tabs; archiving keeps the folder.
private struct FolderMenu: View {
    let store: TabStore
    let folder: Folder
    let shape: ReferenceWritableKeyPath<TabStore, Pins>
    @Binding var icons: Bool
    @Binding var editing: Bool

    var body: some View {
        Button("Rename…") { store.renamingFolder = folder.id }
        Button("Change Icon…") { icons = true }
        Button(folder.collapsed ? "Unfold" : "Collapse") { store.toggleFolder(folder.id, in: shape) }
        // Only on a folder that has something to refresh: an ordinary folder is filled by
        // hand and there is nothing for these to do.
        if folder.live != nil {
            Divider()
            Button("Refresh Now") {
                LiveFolders.shared(for: store.profileID).refreshNow(folder.id)
            }
            Button("Edit Live Folder…") { open($editing) }
            // Nothing is closed: the folder keeps exactly the rows it has and simply stops
            // being told what to hold.
            Button("Stop Keeping Filled") {
                LiveFolders.shared(for: store.profileID).stopKeepingFilled(folder.id)
            }
        }
        Divider()
        // ponytail: not in Today, where a folder with nothing in it is removed the moment it
        // is made — see `Pins.removeEmptyFolders`. A menu item that leaves nothing behind is
        // worse than one that is not there.
        if shape == \TabStore.pins {
            Button("New Folder") { store.newFolder(beside: folder.id, in: shape) }
        }
        Button("Archive All Tabs in Folder") { store.archiveFolder(folder.id, in: shape) }
            .disabled(store[keyPath: shape].tabs(in: folder.id).isEmpty)
        Divider()
        Button("Delete Folder") { store.deleteFolder(folder.id, in: shape) }
    }
}

/// See `dragPayload`: published on the next turn so starting the drag does not re-render the
/// row out from under it.
@MainActor private func folderDragPayload(_ folder: Folder) -> NSItemProvider {
    let id = folder.id
    // All four set, for the reason `dragPayload` sets all of its: a flag left behind by a
    // drag that ended outside every target outlives the gesture otherwise.
    DispatchQueue.main.async {
        Motion.list {
            Dragging.shared.folder = id
            Dragging.shared.tab = nil
            Dragging.shared.tabs = []
            Dragging.shared.at = nil
            Dragging.shared.undo = nil
        }
    }
    return NSItemProvider(object: id.uuidString as NSString)
}

/// The drop target a tab row does not need: three zones instead of two, because a folder has
/// an inside. The middle half takes the thing in; the quarter at each edge reorders beside
/// it, the way `TabDrop` does.
private struct FolderDrop: DropDelegate {
    let store: TabStore
    let folder: Folder
    let shape: ReferenceWritableKeyPath<TabStore, Pins>
    @Binding var zone: FolderZone?

    func validateDrop(info: DropInfo) -> Bool {
        // A folder from either section, in or beside this one — except a live folder from
        // the other, which stays where its source can keep filling it. See `TabStore.canDrag`.
        if let dragged = Dragging.shared.folder {
            return dragged != folder.id && store.canDrag(folder: dragged, into: shape)
        }
        return Dragging.shared.tab != nil
    }
    func dropEntered(info: DropInfo) { zone = which(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard Dragging.shared.active else { return DropProposal(operation: .cancel) }
        zone = which(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = which(info)
        zone = nil
        let (tabs, dragged) = Dragging.shared.takeAll()      // see `TabDrop.performDrop`
        if let dragged {
            guard dragged != folder.id, store.canDrag(folder: dragged, into: shape)
            else { return false }
            switch where_ {
            case .inside: store.move(folder: dragged, into: folder.id, in: shape)
            default: store.move(folder: dragged, next: folder.id.uuidString,
                                after: where_ == .after, in: shape)
            }
            return true
        }
        guard !tabs.isEmpty else { return false }
        // Every row lands next to the *folder*, not next to the one before it, so a run
        // dropped below one has to be laid down bottom-first to come out in the order it
        // was drawn. Into the folder, and above it, in-order is already right.
        switch where_ {
        case .inside: tabs.forEach { store.move($0, into: folder.id, in: shape) }
        case .before: tabs.forEach { store.drop($0, beside: folder.id, after: false, in: shape) }
        case .after:  tabs.reversed().forEach {
            store.drop($0, beside: folder.id, after: true, in: shape)
        }
        }
        // A tab takes the folder's own section, in it or beside it. See `TabDrop.performDrop`.
        store.selectionLanded(tabs, in: shape == \TabStore.todayShape ? .today : .pinned)
        return true
    }

    private func which(_ info: DropInfo) -> FolderZone {
        switch info.location.y / Look.rowHeight {
        case ..<0.25: .before
        case 0.75...: .after
        default: .inside
        }
    }
}

// MARK: - Rows

/// Every clickable line in the sidebar: an icon, a title, and whatever the row wants on the
/// trailing edge. One shape so the list reads as one list.
private struct SidebarRow<Leading: View, Label: View, Trailing: View>: View {
    let selected: Bool
    /// In a multi-select. It wears the same fill as `selected` — a selection is a selection —
    /// and the row that is *also* `selected` is picked out by an accent hairline, so the
    /// list still says which of the ticked tabs is the one on screen.
    var ticked = false
    /// Secondary rather than primary type: "New Tab" is an action among places, and Arc
    /// sets it a step quieter than the tabs around it.
    var dimmed = false
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let label: () -> Label
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            leading()
            // Every tab title in the same ink, selected or not — Arc's list is one grey on
            // dark all the way down, and the selection is the fill, not a change of ink.
            label().font(Look.rowTitle).lineLimit(1)
                .foregroundStyle(dimmed ? Look.inkTertiary : Look.inkPrimary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, Look.rowInset)
        .padding(.trailing, Look.rowTrailingInset)
        .frame(height: Look.rowHeight)
        .background(fill, in: .rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius, ticked && selected ? Look.selectedEdge : .clear)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .environment(\.rowHovering, hovering)
    }

    private var fill: Color {
        selected || ticked ? Look.selected : (hovering ? Look.hovered : .clear)
    }
}

/// A symbol in a favicon's box, so a row led by a glyph lines its title up with the tab
/// titles around it.
private struct GlyphBox: View {
    let name: String
    var body: some View { Image(systemName: name).frame(width: Look.tileIcon) }
}

extension SidebarRow where Leading == GlyphBox, Label == Text, Trailing == EmptyView {
    init(icon: String, title: String, selected: Bool, dimmed: Bool = false,
         action: @escaping () -> Void) {
        self.init(selected: selected, dimmed: dimmed, action: action,
                  leading: { GlyphBox(name: icon) },
                  label: { Text(title) },
                  trailing: { EmptyView() })
    }
}

/// Whether the row a view sits in is hovered, so a close button can appear without every
/// row needing its own hover plumbing.
private struct RowHoveringKey: EnvironmentKey { static let defaultValue = false }
/// The pull request a pinned row stands for, set by `PinnedRow` on the rows a live folder
/// owns. nil everywhere else, which is every other row in the app.
private struct LivePRKey: EnvironmentKey { static let defaultValue: GitHub.State? = nil }
/// The sidebar's geometry group (see `Sidebar.strip`). nil outside the sidebar — the
/// Library's rows are not in it.
private struct StripKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    fileprivate var rowHovering: Bool {
        get { self[RowHoveringKey.self] }
        set { self[RowHoveringKey.self] = newValue }
    }
    fileprivate var livePR: GitHub.State? {
        get { self[LivePRKey.self] }
        set { self[LivePRKey.self] = newValue }
    }
    fileprivate var strip: Namespace.ID? {
        get { self[StripKey.self] }
        set { self[StripKey.self] = newValue }
    }
}

extension View {
    /// A tab's place in the strip's geometry group, when it is in one.
    @ViewBuilder fileprivate func inStrip(_ id: Tab.ID, _ ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: id, in: ns) } else { self }
    }
}

/// A hairline, then the two housekeeping actions Arc puts here — once there is housekeeping
/// to do. Under `Look.tidyThreshold` Today tabs the line is on its own: five tabs are not a
/// pile, and two actions offering to sort them out are two things to read past on every new
/// Space and in every new window.
///
/// The hairline stays either way — it is the end of the pinned section, not a decoration on
/// the buttons — and until the actions arrive it runs the full width, across the room they
/// will take. Then it shortens to make way for them, with the one animation the list
/// already uses, so the sixth tab reads as the words fading in over the end of the line.
///
/// Below the threshold the actions are out of the layout altogether, so the sidebar offers
/// exactly what it shows. Neither is *lost* there: Tidy Tabs and Clear Tabs keep their menu
/// items and their shortcuts at any number of tabs, which is the route a keyboard or a
/// screen reader would take to them anyway.
///
/// **Nothing here is ever drawn and disabled.** Tidy used to be: it appeared at six Today
/// tabs and only started working at nine, because two different counts answered "show it"
/// and "let them press it". One count answers both now (`TidyTabs.control`), and a Tidy that
/// has been switched off in preferences is not drawn at all rather than greyed out. The one
/// state where the row does not answer a click is while a tidy is actually running, and it
/// says so with a spinner in the label's own place.
private struct TidyRow: View {
    @EnvironmentObject var store: TabStore
    /// The one thing that says a tidy is in flight, for this window. See `TidyProgress`.
    @ObservedObject private var progress = TidyProgress.shared
    /// Set while a tab that this would actually move is over the divider. See below.
    @State private var lit: Landing.Band?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let offering = TidyTabs.offersHousekeeping(store)
        let tidy = TidyTabs.control(store)
        HStack(spacing: 8) {
            Hairline()
            // Two questions, one count: Clear is offered as soon as the section is a pile,
            // Tidy the same — unless it has been switched off, in which case it is not drawn
            // at all rather than drawn and refusing to work. See `TidyTabs.control`.
            switch tidy {
            case .hidden:
                EmptyView()
            case .tidy:
                // The menu item owns the tidy's cancellation and its "undo" bookkeeping —
                // this is the same closure, not a second copy of it.
                Button("Tidy") { Keybindings.actions[.tidyTabs]?() }
                    .help("Group tabs into folders (\(Keybindings.binding(for: .tidyTabs).display))")
                    .accessibilityLabel("Tidy Tabs")
            case .tidying:
                // The word "Tidy", replaced in place by a spinner — the row keeps its height
                // and the hairline beside it simply grows back into the room the word gave
                // up, with the list's own animation. It does not take a press: a second Tidy
                // cancels, and the routes to that are the menu item, its shortcut and the
                // command bar, which is where the run lives.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Look.tidySpinnerScale)
                    .frame(height: Look.tidyRow)
                    .help("Tidying tabs…")
                    .accessibilityLabel("Tidying tabs")
            }
            if offering {
                if tidy != .hidden { Text("|").foregroundStyle(Look.inkQuiet) }
                Button("Clear") { clear() }
                    .help("Archive today's tabs (\(Keybindings.binding(for: .clearTabs).display))")
                    .accessibilityLabel("Clear Tabs")
            }
        }
        .animation(reduceMotion ? nil : Look.list, value: offering)
        .animation(reduceMotion ? nil : Look.list, value: tidy)
        .buttonStyle(.plain)
        .font(Look.sectionCaption)
        .foregroundStyle(Look.inkTertiary)
        .padding(.horizontal, Look.rowInset)
        // Arc butts this label to the last pinned row and leaves the room *below* it, so
        // the divider reads as the end of one section rather than the start of the next.
        .frame(height: Look.tidyRow)
        .padding(.top, -Look.rowGap)
        .padding(.bottom, Look.sectionGap - Look.rowGap)
        // The divider is the end of the Pinned list, so a tab let go on it pins, at the end
        // — otherwise the band between the last pinned row and the New Tab row is a hole a
        // drag can be released into and have nothing happen. It is also the whole of an
        // empty Pinned section's drop target: the section itself draws nothing, and a well
        // conjured into the stack mid-drag would shift every row below it by a pitch.
        //
        // The line goes at the top, where the last pinned row ends and the drop will land.
        // Its own state, per row and per window: `Dragging` is process-wide, and a drag in
        // one window must not light the divider in another.
        .contentShape(.rect)
        .overlay(alignment: .top) { DropLine(on: lit != nil, axis: .vertical) }
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: nil, into: .pinned,
                                  axis: .horizontal, extent: 0, side: $lit))
    }

    /// The menu item owns this too, so both routes archive rather than destroy.
    private func clear() { Keybindings.actions[.clearTabs]?() }
}

private struct NewTabRow: View {
    @EnvironmentObject var store: TabStore
    /// Set while a pinned tab is over this row — the only drag it has anything to do with.
    @State private var lit: Landing.Band?

    var body: some View {
        SidebarRow(icon: "plus", title: "New Tab", selected: false, dimmed: true) { store.newTab(nil) }
            // The other side of the same hole: this row heads the Today list, and a pinned
            // tab let go on it comes back down to the top of it — where `move(_:to:)` puts a
            // tab it un-pins, which is directly under this row. So the line goes at the
            // bottom, on the gap the tab will land in.
            .overlay(alignment: .bottom) { DropLine(on: lit != nil, axis: .vertical) }
            .onDrop(of: [.plainText],
                    delegate: TabDrop(store: store, target: nil, into: .today,
                                      axis: .horizontal, extent: 0, side: $lit))
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
        let open = store.tabs.filter { $0.kind == .today }
        // Drawn from `store.todayShape`, exactly as Pinned is drawn from `store.pins`: a
        // tidy's folders live here now, and a folder is not a tab. Only the entries that
        // actually draw a row are counted — a pane that is not its split's lead, and an
        // entry whose tab has gone, draw nothing. See `PinnedSection`.
        let rows = store.todayShape.visible.filter { row in
            if row.entry.folder != nil { return true }
            guard let tab = store.tabs.first(where: { $0.id.uuidString == row.entry.tab })
            else { return false }
            guard let split = store.split(containing: tab.id) else { return true }
            return store.leadPane(split) == tab.id
        }
        VStack(spacing: Look.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ShapeRow(row: row, index: index, rows: rows.count, shape: \.todayShape)
                    .transition(.rowCollapse)
            }
        }
        // The row being dragged, over the list rather than in it — see `HeldRow`.
        .overlay(alignment: .topLeading) { HeldRow(kind: .today) }
        // A container of rows, so VoiceOver reads this as a tab list and steps through the
        // tabs instead of announcing an anonymous stack.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today")
        .accessibilityValue("\(open.count) open")
        .accessibilityHint("Command 1 through 8 selects a tab, Command 9 the last one.")
        .accessibilityAction(named: "Search Tabs") { store.palette = .tabs }
        .accessibilityAction(named: "New Tab") { store.newTab(nil) }
    }
}

/// One line of the strip: a tab's row — unless the tab is a pane of a split, in which case
/// the split owns one row between all of its panes and draws it where its first pane sits.
private struct StripRow: View {
    @EnvironmentObject var store: TabStore
    let tab: Tab
    /// Its place in the section it is drawn in, and how many rows that section draws — see
    /// `TabDrop.row`.
    var index: Int?
    var rows = 0
    private var spot: Landing.Spot? { index.map { Landing.Spot(kind: tab.kind, index: $0) } }
    @State private var side: Landing.Band?
    /// Which half of the row a split would open on, while the pointer is over its middle.
    @State private var half: Landing.Side?
    /// The row's own width, so the drop can say which half of it the pointer is in. Measured
    /// rather than worked out from `SidebarWidth`: a pinned row inside a folder is stepped
    /// in, and its middle is not the sidebar's.
    @State private var width = Look.sidebarWidth
    /// Which way the window reads. A right-to-left one draws the leading pane on the right,
    /// so the answer mirrors — `DropInfo.location` is in the row's own coordinate space,
    /// which counts up to the right whichever way the window reads, while the alignment the
    /// half is drawn with mirrors itself. See `Landing.drawsLeft`.
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Group {
            if let split = store.split(containing: tab.id) {
                // The transition stays on the row, not on the Group: a pane that is not the
                // lead draws nothing, and a height pinned around nothing is a phantom row.
                if store.leadPane(split) == tab.id {
                    SplitRow(split: split, lead: tab, spot: spot).transition(.rowCollapse)
                }
            } else {
                TabRow(tab: tab, spot: spot).transition(.rowCollapse)
            }
        }
        .lifted(tab.id)
        // One drop target for the row, whichever of the two draws it: a split is one item in
        // the strip, so it reorders and takes drops exactly as a tab does.
        //
        // The line is only for the drops that have not already happened — a run, and the
        // favourites grid. A single row has moved by the time the pointer gets here, so
        // there is nothing left to point at.
        .overlay(alignment: side == .after ? .bottom : .top) {
            DropLine(on: side == .before || side == .after, axis: .vertical)
        }
        // "Drop it on this one and the two go side by side." A ring rather than a fill: a
        // selected row is already filled, and a row that changed size under the pointer
        // would move the thing being aimed at. Inside the ring, the half the dragged tab
        // will take is filled — the row is a small picture of the split it is offering, so
        // which side it opens on is answered before the button comes up rather than after.
        //
        // Opacity, not an `if`: the ring fades in and out where it stands rather than being
        // cut into and out of the tree, and the half under it slides across as the pointer
        // crosses the middle instead of blinking. `.leading`/`.trailing` are the window's,
        // not the screen's — SwiftUI mirrors them under a right-to-left layout, which is
        // exactly the mirror `Landing.side` puts into the answer. See `Landing.drawsLeft`.
        .overlay {
            Color.clear
                .overlay(alignment: half == .trailing ? .trailing : .leading) {
                    Rectangle().fill(Look.dropHalf).frame(width: width / 2)
                }
                .clipShape(.rect(cornerRadius: Look.pillRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Look.pillRadius)
                        .strokeBorder(.tint, lineWidth: Look.dropLine)
                }
                .opacity(side == .onto ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: tab, into: tab.kind,
                                  axis: .vertical, extent: width, side: $side,
                                  row: index, rows: rows, half: $half,
                                  rtl: direction == .rightToLeft))
    }
}

/// A split as one sidebar row, in Arc's shape: the panes' favicons overlapping where a
/// favicon goes, and the active pane's title.
///
/// ponytail: no rename and no pin. Arc lets you name a split and pin it; Vane's row is a way
/// back into the split and nothing more — the panes keep their own names, and closing the
/// last-but-one pane hands the row back to the tab it was. Upgrade path: give `Split` a title
/// and a `TabKind` of its own and it becomes a fourth kind of strip item.
private struct SplitRow: View {
    @EnvironmentObject var store: TabStore
    let split: Split
    /// The pane whose place in the strip this row stands in — what a drag of the row moves
    /// and what a drop beside it lands next to.
    let lead: Tab
    /// Its place in the strip, so a drag can say where it started — see `Landing`.
    var spot: Landing.Spot?
    @Environment(\.strip) private var strip

    var body: some View {
        let panes = split.tabs.compactMap { id in store.tabs.first { $0.id == id } }
        let selected = split.tabs.contains { $0 == store.current }
        // The split's one row stands for its lead pane in the strip, so that is the id the
        // selection holds — the other panes have no row to tick.
        let ticked = store.selection.contains(lead.id)
        let active = panes.first { $0.id == split.activeTab } ?? panes.first
        let title = active.map { TidyTitles.title(for: $0) } ?? "Split View"
        // Arc's split row: one row-height container with a pill per pane in it, side by
        // side and sharing the width. Not `SidebarRow` — a row with one title is the wrong
        // shape for a split, which has as many titles as it has panes.
        PaneStrip(store: store, split: split, panes: panes, selected: selected, ticked: ticked)
        // Everything a tab's row does with a drag, keyed on the pane whose place this is: a
        // split is one item in the strip, so it reorders and takes drops like one.
        .inStrip(lead.id, strip)
        .help("Split view of \(panes.count) tabs")
        .onDrag {
            dragPayload(lead, in: store, at: spot)
        } preview: {
            // As a tab's row: the row itself moves, so there is nothing for AppKit to float.
            // A run of several still needs a picture — see `TabRow`.
            if ticked, store.selection.count > 1 {
                PaneStrip(store: store, split: split, panes: panes,
                          selected: true, ticked: false, live: false)
                    .frame(width: Look.sidebarWidth - Look.inset * 2)
                    .liftedPreview()
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        // A ticked split row is one of several selected rows, and is about all of them —
        // exactly as `TabRow` is.
        .contextMenu {
            if ticked, store.selection.count > 1 {
                BulkMenu(store: store, count: store.selection.count, kind: lead.kind)
            } else {
                SplitMenu(store: store, split: split)
            }
        }
        // A container of panes, not one flattened row: each pill is a page you can go to,
        // and VoiceOver should be able to step through them and say which is showing. What
        // belongs to the split rather than to any one pane — how many panes there are, and
        // the things that rearrange or end them — stays here, on the container.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
        .accessibilityValue(axValue(panes.count, title, ticked))
        .accessibilityAddTraits(selected || ticked ? .isSelected : [])
        .accessibilityAction(named: "Next Pane") { store.focusNextPane() }
        .accessibilityAction(named: "Swap") { store.swapPanes(split) }
        .accessibilityAction(named: "Separate All Tabs") { store.separateSplit(split) }
        .accessibilityAction(named: "Close Pane") {
            if let active { store.close(active.id) }
        }
    }
}

extension SplitRow {
    /// Split out because the body stopped type-checking in reasonable time with one more
    /// string term in it.
    fileprivate func axValue(_ panes: Int, _ title: String, _ ticked: Bool) -> String {
        "\(panes) panes, showing \(title)" + selectionSuffix(ticked, store.selection.count)
    }
}

/// The right-click menu on a split's row: what can be done to the split as a whole. What can
/// be done to one pane is on that pane's own tab menu, which is where it was before it
/// became a pane.
private struct SplitMenu: View {
    let store: TabStore
    let split: Split

    var body: some View {
        Button("Swap") { store.swapPanes(split) }
        Button("Separate All Tabs") { store.separateSplit(split) }
        Divider()
        Button("Close Split View") { store.closeSplit(split) }
    }
}

private struct TabRow: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    /// Its place in the strip, so a drag can say where it started — see `Landing`.
    var spot: Landing.Spot?
    @Environment(\.strip) private var strip

    var body: some View {
        let selected = store.current == tab.id
        let ticked = store.selection.contains(tab.id)
        SidebarRow(selected: selected, ticked: ticked, action: select) {
            TabIcon(tab: tab)
        } label: {
            // Arc's in-row rename: the title becomes a field and the row keeps its shape.
            if store.renamingTab == tab.id {
                RenameField(store: store, tab: tab)
            } else {
                ShimmerTitle(title: TidyTitles.title(for: tab), reveal: tab.titleReveal)
            }
        } trailing: {
            TabRowTrailing(store: store, tab: tab, selected: selected)
        }
        .inStrip(tab.id, strip)
        .help(tab.title)
        .onDrag {
            dragPayload(tab, in: store, at: spot)
        } preview: {
            // One row is moved by moving the row: `HeldRow` draws it under the pointer, so
            // AppKit is given a point of nothing to make its floating preview out of —
            // there must be a view, but there must not be a second copy of the row.
            //
            // A run keeps the picture. Its rows all stay in the list (`Dragging.lifted`),
            // because taking five out at once leaves a hole the size of the selection and
            // says nothing about where they are going, so the count under the pointer is
            // the only thing saying what is being carried.
            if ticked, store.selection.count > 1 {
                HStack(spacing: Look.rowSpacing) {
                    TabIcon(tab: tab)
                    Text("\(store.selection.count) tabs").lineLimit(1).font(Look.rowTitle)
                }
                .padding(.horizontal, Look.rowInset).padding(.vertical, 4)
                .liftedPreview()
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        // Arc's double-click-to-rename. Simultaneous, so the row's own single tap still
        // selects the tab first — which is what Arc does too, and what makes the rename
        // apply to the tab you are looking at.
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingTab = tab.id })
        // Right-clicking one of several ticked rows is about all of them; anywhere else it
        // is about the one tab, exactly as before.
        .contextMenu {
            if ticked, store.selection.count > 1 {
                BulkMenu(store: store, count: store.selection.count, kind: tab.kind)
            } else {
                TabMenu(store: store, tab: tab)
            }
        }
        // One element per tab, the way a tab in Safari reads: the title is the label, the
        // state is the value, and the close button becomes an action rather than a second
        // element the user has to find and then guess the meaning of.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TidyTitles.title(for: tab))
        .accessibilityValue(tabState(tab, in: store)
                            + selectionSuffix(ticked, store.selection.count))
        .accessibilityAddTraits(selected || ticked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this tab.")
        // The same words the row's own glyph is showing — a pinned row's ⌘W unloads before
        // it unpins, and an action named "Close Tab" that does neither is a lie.
        .accessibilityAction(named: tab.kind == .today ? "Archive Tab" : closeVerb) {
            store.archive(tab.id)
        }
        .accessibilityAction(named: tab.kind == .pinned ? "Unpin Tab" : "Pin Tab") {
            store.togglePinned(tab.id)
        }
        .accessibilityAction(named: "Rename Tab") { store.renamingTab = tab.id }
        .accessibilityAction(named: "Duplicate Tab") { TabActions.duplicate(tab, in: store) }
        .accessibilityAction(named: "Favourite Tab") { store.move(tab.id, to: .favourite) }
        .accessibilityAction(named: "Close Other Tabs") { closeOthers() }
        .accessibilityAction(named: TabAudio.isMuted(tab) ? "Unmute Tab" : "Mute Tab") {
            TabAudio.toggleMute(tab)
        }
    }

    /// What ⌘W will actually do to this row, in words. See `TabRowGlyph`.
    private var closeVerb: String {
        TabRowGlyph.decide(kind: tab.kind, suspended: tab.suspended,
                           pane: store.split(containing: tab.id) != nil).verb
    }

    /// What a click on a row means, by what is held down: ⌘ ticks it into the selection, ⇧
    /// takes the run from the last row clicked, ⌥ opens it *beside* the one you are reading
    /// in a split, ⌥⌘ floats it off into a Little Arc leaving the row where it is, and a
    /// plain click drops the selection and shows the tab. `TabActions.rowClick` is the
    /// table, proved offline — one place the meaning of a click is decided.
    /// ponytail: `NSEvent.modifierFlags` read at the moment of the tap rather than a
    /// modifier-aware gesture. SwiftUI's tap carries no flags, and the only alternative is a
    /// second hit-testing layer over every row. Ceiling: it reads the *current* state of the
    /// keyboard, so a modifier released inside the same click's few milliseconds is missed.
    private func select() {
        let mods = NSEvent.modifierFlags
        switch TabActions.rowClick(option: mods.contains(.option),
                                   command: mods.contains(.command),
                                   shift: mods.contains(.shift),
                                   isCurrent: store.current == tab.id) {
        // Showing a tab is the one click that is about *this* row and no other, so it is
        // also what ends a selection.
        case .show:
            store.selection.clear()
            store.current = tab.id
        case .split:  store.addPane(tab.id)
        case .tick:   store.toggleSelection(tab.id)
        case .range:  store.extendSelection(to: tab.id)
        // A row with no page yet — a parked favourite that has never loaded — has nothing to
        // hand over, so it is shown instead of opening an empty window.
        case .little:
            // A Private Window's row must not float out into a window that keeps cookies
            // and writes history — the Little Arc inherits the window's privacy.
            if let url = tab.currentURL {
                LittleArc.open(url, isPrivate: store.isPrivate)
            } else {
                store.current = tab.id
            }
        }
    }

    private func closeOthers() {
        // Favourites and pinned tabs are not "other tabs" — they stay whatever happens.
        for t in store.tabs where t.id != tab.id && t.kind == .today { store.archive(t.id) }
    }
}

/// The right-click menu on any tab in the sidebar, in Arc's shape: what this tab is, where
/// it can go, and how to be rid of it. `Move To` names the other two sections, so a tab can
/// be moved without a drag — which is the only route VoiceOver and the keyboard have.
///
/// ponytail: `store` is passed in rather than read from the environment, as `SpaceMenu`
/// does — a context menu is hosted in its own window, and a missing `@EnvironmentObject`
/// there is a crash rather than a blank menu.
/// The names are Arc's, in the repo's spelling: Arc writes "Favorite", Vane writes
/// "Favourite" everywhere else and one menu is not the place to start spelling it two ways.
struct TabMenu: View {
    let store: TabStore
    @ObservedObject var tab: Tab

    var body: some View {
        Button("Copy Link") { copyLink() }
            .disabled(tab.currentURL == nil)
        // Arc's own two, in Arc's order. Rename is also a double-click on the row; Duplicate
        // has no gesture at all, which is exactly why it has to be here.
        Button("Rename…") { store.renamingTab = tab.id }
        if TabActions.rename(tab) != nil {
            Button("Use the Page’s Own Title") { TidyTitles.rename(tab, to: nil) }
        }
        Button("Duplicate") { TabActions.duplicate(tab, in: store) }
            .disabled(tab.currentURL == nil)
        Button("Reload") { tab.reload() }
            .disabled(tab.currentURL == nil)
        Button(TabAudio.isMuted(tab) ? "Unmute" : "Mute") { TabAudio.toggleMute(tab) }
        Divider()
        SplitItems(store: store, tab: tab)
        Divider()
        switch tab.kind {
        case .favourite:
            Button("Unfavourite Tab") { store.toggleFavourite(tab.id) }
        case .pinned:
            Button("Unpin Tab") { store.togglePinned(tab.id) }
        case .today:
            Button("Favourite Tab") { store.move(tab.id, to: .favourite) }
            Button("Pin Tab") { store.togglePinned(tab.id) }
        }
        Menu("Move To") {
            ForEach(TabKind.allCases.filter { $0 != tab.kind }, id: \.self) { kind in
                Button(TabMenu.name(kind)) { store.move(tab.id, to: kind) }
            }
        }
        // Arc’s "New Folder" on a tab makes the folder *around* that tab. "Move to Folder"
        // is the same move without a drag, which is the only route the keyboard and
        // VoiceOver have. Both are about the tab's *own* section: a Today tab gets a Today
        // folder round it and stays in Today, a pinned one a pinned folder. A favourite has
        // no shape of its own — there is nowhere in a grid for a folder row — so it is
        // pinned on the way in, exactly as it always was.
        let shape = TabStore.shape(of: tab.kind) ?? \.pins
        Button("New Folder") { store.newFolder(from: tab.id, in: shape) }
        let folders = store[keyPath: shape].entries.compactMap(\.folder)
        if !folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(folders) { folder in
                    Button(folder.name) { store.move(tab.id, into: folder.id, in: shape) }
                }
            }
        }
        MoveToSpaceMenu(store: store, tab: tab)
        Divider()
        // A favourite or a pinned tab has no "archive": closing it parks it in place, which
        // is what the section means, so the item says what will actually happen — and on a
        // pinned row that is Unload first, Unpin after. See `TabRowGlyph`.
        Button(tab.kind == .today
               ? "Archive Tab"
               : TabRowGlyph.decide(kind: tab.kind, suspended: tab.suspended,
                                    pane: store.split(containing: tab.id) != nil).verb) {
            store.archive(tab.id)
        }
        if tab.kind == .today {
            Button("Archive Tabs Below") { archiveBelow() }
        }
    }

    /// What a section is called in a menu. The sidebar's own headings are the same words.
    static func name(_ kind: TabKind) -> String {
        switch kind {
        case .favourite: "Favourites"
        case .pinned:    "Pinned"
        case .today:     "Today"
        }
    }

    private func copyLink() {
        guard let u = tab.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        axAnnounce("Link copied.")
    }

    /// Arc's "Archive Tabs Below": everything after this one in Today, and nothing above it.
    private func archiveBelow() {
        guard let i = store.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let below = store.tabs[(i + 1)...].filter { $0.kind == .today }
        below.forEach { store.archive($0.id) }
        axAnnounce("Archived \(below.count) tab\(below.count == 1 ? "" : "s").")
    }
}

/// The split-view corner of a tab's menu, in Arc's words: "Add Split View" when there is no
/// split to join, "Add to Split" when there is. Its own view because it is the one part of
/// the menu that has to ask the window what is split at the moment it opens.
private struct SplitItems: View {
    let store: TabStore
    @ObservedObject var tab: Tab

    var body: some View {
        if let split = store.split(containing: tab.id) {
            Button("Swap") { store.swapPanes(split) }
            Button("Separate All Tabs") { store.separateSplit(split) }
            Button(Command.removeSplit.title) { store.archive(tab.id) }
        } else if let active = store.activeSplit {
            Button("Add to Split") { store.addPane(tab.id, beside: active.activeTab) }
                .disabled(active.isFull)
        } else {
            // On the tab you are already looking at there is nothing to split it *with*, so
            // this is the same thing ⌃⇧= does: a new pane, with the bar up over it.
            Button(Command.addSplit.title) {
                if store.current == tab.id { store.addSplit() } else { store.addPane(tab.id) }
            }
        }
    }
}

extension View {
    /// A row's trailing glyph, given something to aim at. The button *is* the square; the
    /// glyph is only what you can see of it — see `Look.rowTarget` for why a bare glyph is
    /// not a target on a row that answers a click of its own.
    fileprivate func rowTarget() -> some View {
        frame(width: Look.rowTarget, height: Look.rowTarget).contentShape(.rect)
    }
}

/// A tab title that says so when the on-device model has just renamed the row: the old name
/// fades out from underneath while the new one is wiped in from the left with a spark riding
/// the edge. Arc's shimmer.
///
/// Only ever for a *model* answer — `Tab.titleReveal` is bumped by nothing else — because
/// the point is to explain a name that changed while nobody touched the tab. A page
/// navigating retitles the row silently, exactly as it always has.
///
/// The old name is drawn *behind* the new one rather than over it, so what shows through the
/// part the wipe has not reached yet is the name the row had a moment ago. That is the whole
/// trick, and it is why this is a mask rather than two crossfading labels.
///
/// ponytail: three bits of `@State` and no timer. `withAnimation`'s completion handler is
/// what puts the spark away and drops the old name, so nothing here has to be cancelled when
/// the row goes — and a row that has never been renamed runs no animation at all, because
/// `onChange` never fires.
private struct ShimmerTitle: View {
    let title: String
    let reveal: TitleReveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the wipe has got, in fractions of the title's width. It rests one soft edge
    /// *past* the end so the mask is solid black at rest — the resting state of this view is
    /// a plain `Text` with nothing done to it.
    private static let full: CGFloat = 1 + Look.shimmerEdge
    @State private var wipe: CGFloat = ShimmerTitle.full
    /// The name being replaced, while it is still on its way out.
    @State private var leaving: String?
    @State private var leavingOpacity: Double = 0
    @State private var sparking = false
    /// Whether a wipe is actually in flight. The three layers below exist for a fifth of a
    /// second, a handful of times ever; without this flag every title in the sidebar is
    /// drawn through a gradient mask, with a ghost behind it and a `GeometryReader` over it,
    /// for the life of the window. A row at rest is a plain `Text` with nothing done to it.
    ///
    /// Its own flag rather than a test on `wipe`: `withAnimation` sets the state to its
    /// final value at once and animates the *rendering*, so `wipe` is already at rest while
    /// the sweep is still on screen. The animation's completion handler is what knows.
    @State private var wiping = false

    var body: some View {
        Group {
            if wiping || leaving != nil {
                Text(title)
                    .mask { wipeMask }
                    .background(alignment: .leading) { ghost }
                    .overlay { spark }
            } else {
                Text(title)
            }
        }
        .onChange(of: reveal) { _, new in start(new) }
    }

    /// Opaque up to the wipe's edge, clear past it, with `shimmerEdge` of gradient between
    /// the two so the edge reads as light moving across the words rather than as a crop.
    private var wipeMask: some View {
        let lit = min(max(wipe - Look.shimmerEdge, 0), 1)
        let edge = min(max(wipe, 0), 1)
        return LinearGradient(stops: [.init(color: .black, location: 0),
                                      .init(color: .black, location: lit),
                                      .init(color: .clear, location: edge),
                                      .init(color: .clear, location: 1)],
                              startPoint: .leading, endPoint: .trailing)
    }

    /// The old name, showing through whatever the wipe has not covered yet. Bounded by the
    /// new title's width on purpose: a longer old name is truncated rather than allowed to
    /// draw out over the row's trailing glyphs for the fifth of a second it is alive.
    @ViewBuilder private var ghost: some View {
        if let leaving {
            Text(leaving)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(leavingOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// One glyph riding the wipe's edge. Drawn in a `GeometryReader` so it can be placed by
    /// the title's own width, which is the only measurement this view needs and the only
    /// place it can be taken.
    private var spark: some View {
        GeometryReader { geometry in
            Image(systemName: Look.shimmerSparkle)
                .font(Look.rowGlyph)
                .foregroundStyle(Color.accentColor)
                .opacity(sparking ? Look.shimmerSparkleOpacity : 0)
                .animation(reduceMotion ? nil : Look.shimmerFade, value: sparking)
                .position(x: min(wipe, 1) * geometry.size.width, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func start(_ reveal: TitleReveal) {
        guard reveal.count > 0 else { return }
        leaving = reveal.from.isEmpty ? nil : reveal.from
        leavingOpacity = 1
        wiping = true
        // Reduced motion still gets the *event* — a name that changed by itself has to be
        // visible — it simply gets it as a crossfade with no travel and no spark.
        guard !reduceMotion else {
            wipe = ShimmerTitle.full
            sparking = false
            withAnimation(Look.quick) { leavingOpacity = 0 } completion: {
                leaving = nil
                wiping = false
            }
            return
        }
        wipe = 0
        sparking = true
        withAnimation(Look.shimmerFade) { leavingOpacity = 0 } completion: { leaving = nil }
        // The sweep is the longer of the two, so its completion is where the row goes back
        // to being a plain label.
        withAnimation(Look.shimmerSweep) { wipe = ShimmerTitle.full } completion: {
            sparking = false
            wiping = false
        }
    }
}

/// What a row's trailing glyph does, decided by which section the tab is in, whether it is a
/// pane of the split on screen, and whether it still holds a page. Arc's rule: the × on a
/// pinned row unloads the *page* first, and only a second press — on a row that now has
/// nothing to unload — takes the pin off and drops the tab into Today. Nothing here ever
/// deletes a pinned tab, and the press that takes the pin off says so with an Undo (see
/// `TabStore.unpin`), because a pinned tab comes up from disk parked and so meets that press
/// in its commonest state, on a glyph that looks like every other × in the app.
/// `TabStore.close` reads the same table, so ⌘W agrees with the glyph the row is showing.
///
/// A pane is asked about first, and a pane is never a two-step: a pinned tab shown as a pane
/// closes as a *pane*, because a pane is not a pin. Without that the split row's ×, its
/// "Close Pane" action, ⌃⇧− and Remove Split all unloaded or unpinned the pane and left it
/// on screen — a split there was no way out of.
///
/// Pure, and deliberately: it is a small table, it is what the tooltip, the symbol, the
/// VoiceOver label and `close` all read, and one of those drifting is exactly the bug this
/// replaces. `selfcheck --pure` drives every row of it with no window and no tab.
enum TabRowGlyph: Equatable, Sendable, CaseIterable {
    /// The tab goes: Today's ×, a favourite's — which parks the tile in place — and any
    /// pane's, which takes the pane out of the split.
    case close
    /// The page goes, the row stays exactly where it is. A loaded pinned tab.
    case unload
    /// The pin goes and the tab drops into Today. A pinned tab with no page left to unload.
    case unpin

    /// `suspended` means "has no live page". Read straight off `Tab.suspended` and nothing
    /// else: "or it has no url" looks like the same question and is not, because `resume`
    /// hands the web view a load and clears `parkedURL` before `WKWebView.url` has caught up
    /// with it — so a × pressed right after clicking a parked pinned row met a tab that was
    /// very much alive with no url to show, and unpinned it in one click.
    ///
    /// `pane` is "this row is one pane of the split on screen", which wins over everything:
    /// what a pane's × closes is the pane.
    static func decide(kind: TabKind, suspended: Bool, pane: Bool) -> TabRowGlyph {
        guard !pane, kind == .pinned else { return .close }
        return suspended ? .unpin : .unload
    }

    /// Whether this close is a pane close. `inSplit` is what `splits` says right now;
    /// `forced` is a caller that knows better, and there is one — "Close Split View" takes a
    /// split down one tab at a time, and a split shrinks back to a plain tab at two panes, so
    /// by the time the last id is asked for, `splits` has already forgotten it was ever a
    /// pane. A pinned last pane read that as an ordinary pinned row and unloaded — or, if it
    /// was parked, unpinned itself with a toast — instead of leaving the split the way the
    /// two before it did. See `TabStore.closeSplit`.
    static func isPane(inSplit: Bool, forced: Bool) -> Bool { inSplit || forced }

    /// The second half of the unload step. `suspend` parks a *page*, so it declines a tab
    /// whose web view has no url — and that is two different tabs wearing one face. A pinned
    /// row that has never been given a page has nothing to unload, and the press may as well
    /// be the step that takes the pin off; a row whose page is on its way in — the gap
    /// between `resume` handing the view a load and `WKWebView.url` catching up with it — has
    /// very much got one, and unpinning *that* loses a row the user had only just clicked
    /// awake to a press that asked to unload. `Tab.hasEverLoaded` tells the two apart.
    static func unpinsWithNothingParked(hasEverLoaded: Bool) -> Bool { !hasEverLoaded }

    var symbol: String {
        switch self {
        case .close, .unpin: "xmark"
        // Not "xmark": the × on a pinned row would be promising to close something, and a
        // minus is what every unload control in this app draws.
        case .unload: "minus"
        }
    }

    /// The tooltip and the menu wording, in Arc's words.
    var verb: String {
        switch self {
        case .close:  "Close Tab"
        case .unload: "Unload Tab"
        case .unpin:  "Unpin Tab"
        }
    }

    /// What VoiceOver says, in front of the tab's name.
    var spoken: String {
        switch self {
        case .close:  "Close "
        case .unload: "Unload "
        case .unpin:  "Unpin "
        }
    }

    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        assert("a Today tab's × closes it, loaded or not",
               decide(kind: .today, suspended: false, pane: false) == .close
                   && decide(kind: .today, suspended: true, pane: false) == .close)
        assert("a favourite keeps the tile behaviour it had",
               decide(kind: .favourite, suspended: false, pane: false) == .close
                   && decide(kind: .favourite, suspended: true, pane: false) == .close)
        assert("a loaded pinned tab unloads rather than closing",
               decide(kind: .pinned, suspended: false, pane: false) == .unload)
        assert("a pinned tab with nothing loaded unpins",
               decide(kind: .pinned, suspended: true, pane: false) == .unpin)
        assert("no state of a pinned row closes it",
               ![true, false].map { decide(kind: .pinned, suspended: $0, pane: false) }
                   .contains(.close))
        assert("only a pinned tab is ever unloaded or unpinned",
               TabKind.allCases.filter { $0 != .pinned }.allSatisfy { k in
                   [true, false].allSatisfy { decide(kind: k, suspended: $0, pane: false) == .close }
               })
        assert("unloading is offered exactly once, and only while there is a page",
               decide(kind: .pinned, suspended: false, pane: false) == .unload
                   && decide(kind: .pinned, suspended: true, pane: false) != .unload)

        // --- A pane closes as a pane, whatever it is a pane of ---
        assert("a pinned tab used as a pane closes, rather than unloading",
               decide(kind: .pinned, suspended: false, pane: true) == .close)
        assert("…and a parked one closes rather than unpinning",
               decide(kind: .pinned, suspended: true, pane: true) == .close)
        assert("no pane of any kind, in any state, is a two-step",
               TabKind.allCases.allSatisfy { k in
                   [true, false].allSatisfy { decide(kind: k, suspended: $0, pane: true) == .close }
               })

        // --- The state a × meets right after a parked pinned row is clicked ---
        // `resume` clears `parkedURL` before `WKWebView.url` has caught up with the load it
        // was just handed, so for the width of that gap the tab has no url at all. It is not
        // suspended, so it is a page being loaded and the press unloads it — the old input,
        // "suspended *or* it has no url", read the same instant as "nothing left to unload"
        // and took the pin off in one click.
        assert("a pinned tab that has just resumed and has no url yet still unloads",
               decide(kind: .pinned, suspended: false, pane: false) == .unload)
        // …and the unload it asked for finds nothing to park, because `WKWebView.url` has
        // not caught up. That must not fall through to taking the pin off.
        assert("an unload with a page on its way in does not go on to unpin",
               !unpinsWithNothingParked(hasEverLoaded: true))
        assert("an unload on a pinned row that never held a page takes the pin off instead",
               unpinsWithNothingParked(hasEverLoaded: false))

        // --- The last pane of a split being dissolved is still a pane ---
        // "Close Split View" archives the split's tabs one at a time, and `dropPane` folds a
        // split back into a plain tab at two panes — so `splits` says the last id is no pane
        // at all by the time it is closed. Both halves have to read as a pane, or that last
        // one unloads, or unpins itself, instead of leaving the split.
        assert("a pane the splits still know about is a pane", isPane(inSplit: true, forced: false))
        assert("…and so is one a dissolving split has already let go of",
               isPane(inSplit: false, forced: true))
        assert("an ordinary close is no pane close", !isPane(inSplit: false, forced: false))
        assert("the last pane of a dissolving split closes, parked or not",
               [true, false].allSatisfy { parked in
                   decide(kind: .pinned, suspended: parked,
                          pane: isPane(inSplit: false, forced: true)) == .close
               })
        assert("…while the same pinned row closed on its own is still the two-step",
               decide(kind: .pinned, suspended: true,
                      pane: isPane(inSplit: false, forced: false)) == .unpin)
        assert("the minus is only ever the unload glyph",
               TabRowGlyph.allCases.filter { $0.symbol == "minus" } == [.unload])
        assert("every state says out loud what it will do",
               TabRowGlyph.allCases.allSatisfy {
                   !$0.verb.isEmpty && !$0.spoken.isEmpty && $0.verb.hasSuffix("Tab")
               })
        return out
    }
}

/// The speaker and the close button. Split out only because one expression with both of
/// them plus the row's own modifiers stopped type-checking in reasonable time.
///
/// ponytail: `store` is handed in rather than read from the environment. It used to be an
/// `@EnvironmentObject`, which made every trailing view in the sidebar a dependent of every
/// `@Published` on the store — so one `current` write invalidated two views per row instead
/// of one. Nothing here reads the store except the click.
private struct TabRowTrailing: View {
    let store: TabStore
    @ObservedObject var tab: Tab
    let selected: Bool
    /// On a split's row the × closes the pane the row is showing, not a whole tab's worth of
    /// row — so it says so, in the tooltip and to VoiceOver.
    var pane = false
    /// The tab the × closes. On a split's row the speaker follows whichever pane is making
    /// the noise, but the × — like ⌘W and the row's "Close Pane" action — closes the pane
    /// the row is showing, which may be a different one.
    var closes: Tab? = nil
    @Environment(\.rowHovering) private var hovering
    @Environment(\.livePR) private var pr

    var body: some View {
        let closing = closes ?? tab
        // No gap: each glyph now carries its own `Look.rowTarget` square, and two squares
        // side by side already leave the glyphs inside them a control's worth of air apart.
        // A gap on top of that would be a strip of bare row between two buttons, which
        // belongs to the row's own tap and so *shows* the tab from between its two glyphs.
        HStack(spacing: 0) {
            // A live folder's row says which pull request it is. Always drawn, not only
            // under the pointer: it is state, not an action. Hidden from VoiceOver because
            // the row's own value already says it — see `tabState`.
            if let pr {
                Image(systemName: pr.symbol)
                    .font(Look.rowGlyph)
                    .foregroundStyle(pr == .closed ? Look.inkTertiary : Look.inkSecondary)
                    // A button's square of width, so it sits in line with the two beside it
                    // — but not `rowTarget()`, which also lays down a hit shape. There is
                    // nothing here to press: this is what the row *is*, not something to do
                    // to it, and a target over it would only swallow part of the row's click.
                    .frame(width: Look.rowTarget)
                    .help(pr.says)
                    .accessibilityHidden(true)
            }
            if tab.audible || TabAudio.isMuted(tab) {
                Button { TabAudio.toggleMute(tab) } label: {
                    Image(systemName: TabAudio.isMuted(tab) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(Look.rowGlyph)
                        .rowTarget()
                }
                .help(TabAudio.isMuted(tab) ? "Unmute Tab" : "Mute Tab")
                .accessibilityLabel(TabAudio.isMuted(tab) ? "Unmute \(tab.title)" : "Mute \(tab.title)")
            }
            if hovering || selected {
                // On a split's row the glyph is about the *pane*, which is closed whatever
                // section its tab is in — a pane is not a pin. The table knows that; it is
                // an input to it rather than a special case around it, so `TabStore.close`
                // reaches the same answer for the same row.
                let glyph = TabRowGlyph.decide(kind: closing.kind, suspended: closing.suspended,
                                               pane: pane)
                Button { store.close(closing.id) } label: {
                    Image(systemName: glyph.symbol).font(Look.rowGlyph).rowTarget()
                }
                .help((pane ? "Close Pane" : glyph.verb) + " (⌘W)")
                .accessibilityLabel((pane ? "Close pane " : glyph.spoken)
                                    + TidyTitles.title(for: closing))
                // A pinned row's glyph changes under the pointer the moment its page is
                // unloaded, so the swap is the same fade the rest of the row uses rather
                // than a cut from − to ×.
                .contentTransition(.symbolEffect(.replace))
                // Grows in under the pointer rather than popping: the row's own hover
                // animation carries it.
                .transition(.scale(scale: Look.tileAppearScale).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Look.inkSecondary)
    }
}

/// A site's own icon, with a fallback symbol standing in until it arrives (or forever, for
/// a page that has none).
struct SiteIcon: View {
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
/// favicon lands, and because what it draws while none has is the whole of the rule below.
///
/// **Never a spinner.** This slot used to spin while `tab.loading`, and a row that turns
/// into a spinning wheel on every reload is a row you cannot point at: the mark you aim for
/// is gone for exactly as long as the page takes. Arc keeps the icon the tab had until the
/// next one has actually been decoded and then swaps it — which is free here, because
/// `Favicons.load` only ever writes on `didFinish`, so a tab holds its old icon for the
/// whole of a navigation. A tab that has never had one shows the site's letter instead.
///
/// Loading is still said, twice: the pill's 2pt progress line, and the row's accessibility
/// value, which reads "loading" in words. In words and in a line, not in motion.
private struct TabIcon: View {
    @ObservedObject var tab: Tab
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set only on the rows a live folder owns — see `PinnedRow`. Every other row in the app
    /// gets nil, which is the branch below doing nothing.
    @Environment(\.livePR) private var pr

    var body: some View {
        Group {
            if let icon = tab.favicon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if pr != nil {
                // A live folder's rows are parked until they are clicked, so github.com's
                // own icon has not been fetched for most of them and a bare "G" is what the
                // folder would otherwise be full of. The mark is what Arc draws there, and
                // here it is only ever drawn on a row a GitHub folder owns.
                GitHubMark().fill(Look.inkSecondary)
            } else if let letter = Favicons.letter(for: tab.currentURL) {
                // Flat, no box: a tile and a pane pill already have a fill under this, and a
                // second one inside it would read as an icon with a badge.
                Text(letter)
                    .font(Look.letterFont(box: size))
                    .foregroundStyle(Look.inkSecondary)
            } else {
                // Nothing to take a letter from: a blank tab, or a file with no icon yet.
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        // The swap, when it comes, is a fade rather than a cut — the same 0.15s the rest of
        // the sidebar's hovers use.
        .animation(reduceMotion ? nil : Look.quick, value: tab.favicon)
        .accessibilityHidden(true)          // the row's own label and value say all of this
    }
}

// MARK: - Sidebar footer

private struct BottomRow: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 8) {
            LibraryButton(archive: Archive.shared(for: store.profileID),
                          downloads: Downloads.manager(for: store.profileID))
            Spacer(minLength: 0)
            // A private window has no Spaces — Arc's incognito has none either — so there
            // is nothing to draw dots for and nothing a `+` could make. The row keeps its
            // height regardless: nothing in the sidebar's chrome may come and go.
            if !store.isPrivate {
                SpaceDots()
                Spacer(minLength: 0)
                NewSpaceButton()
            }
        }
        .font(Look.icon)
        .frame(height: Look.footer)
        .padding(.horizontal, Look.inset)
    }
}

// MARK: - Overlays

/// Arc's Library, at the bottom-left corner of the sidebar: the button that slides the
/// Library panel out over the sidebar. The panel itself is LibraryWindow.swift.
private struct LibraryButton: View {
    @EnvironmentObject var store: TabStore
    /// Passed in from the window's own store, not read from a `shared`. That resolves to
    /// whichever profile is active at the moment the view is built, so a background window
    /// of another profile would show — and act on — the wrong lists.
    @ObservedObject var archive: Archive
    @ObservedObject var downloads: Downloads

    var body: some View {
        // Never disabled any more: the panel has this profile's Spaces and its history in
        // it as well as the two lists, so there is always something behind the glyph.
        Button { Library.toggle(Library.shared.section, in: store) } label: {
            Image(systemName: "archivebox")
        }
            // A ring around the glyph while anything is downloading, so progress is visible
            // without opening the Library to look for it.
            .overlay { DownloadRing(downloads: downloads) }
            .buttonStyle(.plain)
            // Always the footer's own ink: the Library stands where this whole row is, so
            // there is no state in which the glyph is on screen *and* the Library is open.
            .foregroundStyle(Look.inkSecondary)
            .help("Library (\(Keybindings.binding(for: .showLibrary).display))")
            .accessibilityLabel("Library")
            .accessibilityValue("\(archive.entries.count) archived, \(downloads.items.count) download\(downloads.items.count == 1 ? "" : "s")")
            .accessibilityHint("Shows archived tabs, downloads, Spaces and history.")
    }
}
