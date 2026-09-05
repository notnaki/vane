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
    /// App-wide, so every window's sidebar is the width the user last dragged one to.
    @ObservedObject private var sidebar = SidebarWidth.shared

    private var chrome: Bool { store.sidebarShown || peeking }

    var body: some View {
        ZStack(alignment: .leading) {
            WindowGlass()
            SpaceGround()
            HStack(spacing: 0) {
                if store.sidebarShown { Sidebar().frame(width: sidebar.width) }
                WebCard()
            }
            // On the seam, over the card: the sidebar's own trailing edge is what Arc's
            // resize handle is, and it has to be above the web view to see a drag at all.
            if store.sidebarShown {
                SidebarHandle().offset(x: sidebar.width - SidebarHandle.hitTestWidth / 2)
            }
            edgeStrip
            floatingSidebar
            // Arc's Library slides out of the window's leading edge over the sidebar. The
            // page card behind it does not move — nothing about the HStack changes.
            if store.libraryOpen {
                LibraryPanel().transition(.move(edge: .leading).combined(with: .opacity))
            }
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
        // One even wash, not a bottom-weighted gradient: the gradient's strongest band
        // landed in the 8pt gap under the card, where it read as a fat coloured bar
        // along the card's bottom edge rather than as the sidebar's tint.
        // Always in the tree, so switching space cross-fades one colour into the next
        // instead of cutting — the fade *is* what says the whole window changed space.
        Look.groundColor(hex: hex, dark: dark, strength: store.currentSpace?.tint ?? Look.defaultTint)
            .opacity(Look.groundOpacity(dark: dark))
            .animation(reduceMotion ? nil : Look.appear, value: store.currentSpaceID)
            .animation(reduceMotion ? nil : Look.appear, value: store.spaceRevision)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var hex: String { store.currentSpace?.colorHex ?? store.profile.colorHex }
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
        .clipShape(.rect(cornerRadius: Look.cardRadius))
        // No inset on the leading edge while the sidebar is docked: the sidebar's own
        // padding already leaves the gap, and doubling it reads as a misaligned card.
        .padding(.leading, store.sidebarShown ? 0 : Look.cardGap)
        .padding([.top, .trailing, .bottom], Look.cardGap)
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
        // Toasts slide up from under the footer and sit just above it, over the list.
        .overlay(alignment: .bottom) {
            ToastHost().padding(.bottom, Look.footer + Look.footerInset + Look.inset)
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
        HStack(spacing: 8) {
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
    @State private var side: DropSide?
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
        }
    case .today:     break
    }
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
    /// Whether one of ours is in flight at all, which is what the drop lines and the
    /// sidebar's catch-all delegate care about.
    var active: Bool { tab != nil || folder != nil }

    /// What is being dragged, and the end of the drag in the same breath. Every
    /// `performDrop` calls this first: a delegate that reads the flag and then *refuses*
    /// the drop leaves the drag running forever, and a drag that never ends makes
    /// `SidebarDrop` stand aside from every later url and file drop.
    func take() -> (tab: Tab.ID?, folder: Folder.ID?) {
        defer { end() }
        return (tab, folder)
    }

    func end() { tab = nil; folder = nil }

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
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.end() } }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.end() } }
        }
        monitors = [local, global].compactMap { $0 }
    }
}

/// ponytail: `.onDrag`/`.onDrop` with a delegate rather than `.draggable`/`.dropDestination`.
/// The Transferable pair cannot say which side of the target the pointer is on, so it can
/// only ever drop *onto* a tab, never before or after it; this one gets the location.
@MainActor private func dragPayload(_ tab: Tab) -> NSItemProvider {
    // Published on the next turn, not now: a state change inside the drag's own start
    // re-renders the row under the pointer, and SwiftUI drops the drag with it.
    let id = tab.id
    // Both set, so a flag left behind by a drag that ended outside any of our targets —
    // dropped on the desktop, say, where no `performDrop` ever runs — is cleared by the
    // next drag rather than outliving the session.
    DispatchQueue.main.async { Dragging.shared.tab = id; Dragging.shared.folder = nil }
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
            .opacity(on && dragging.active ? 1 : 0)
    }
}

/// One drop target for a tile, a row and the empty grid. `target` nil is the placeholder,
/// which simply pins. The side is the half of the target the pointer is in — left/right
/// across `extent` for a tile, top/bottom of `Look.rowHeight` for a row — and is published
/// through `side` so the target can draw its line before the button is released.
private struct TabDrop: DropDelegate {
    let store: TabStore
    let target: Tab?
    /// Which section this target is in. With a `target` it is the target's own kind and is
    /// unused; with none it is the empty section's, and is what the drop moves the tab into.
    let into: TabKind
    let axis: Axis
    let extent: CGFloat
    @Binding var side: DropSide?

    func validateDrop(info: DropInfo) -> Bool {
        // A folder only ever lands among the pinned rows, so every other target refuses it
        // rather than quietly dropping it somewhere it cannot be drawn.
        if Dragging.shared.folder != nil { return target?.kind == .pinned }
        guard let dragging = Dragging.shared.tab else { return false }
        return dragging != target?.id
    }
    func dropEntered(info: DropInfo) { side = which(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard Dragging.shared.active else { return DropProposal(operation: .cancel) }
        side = which(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = which(info) == .after
        side = nil
        // Read once and cleared *before* anything can refuse the drop. A drag left set here
        // outlives the gesture, and `SidebarDrop` then stands aside from every url and file
        // dropped on the sidebar for the rest of the session.
        let (dragged, folder) = Dragging.shared.take()
        if let folder {
            guard let target, target.kind == .pinned else { return false }
            store.move(folder: folder, next: target.id.uuidString, after: after)
            return true
        }
        guard let id = dragged else { return false }
        if let target { store.drop(id, onto: target.id, after: after) } else { store.move(id, to: into) }
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
            row(space.icon ?? "cloud", space, space.name)
            .onTapGesture(count: 2) { store.renamingSpace = space.id }
            .onTapGesture { showSpaceList(store) }
            .contextMenu { SpaceMenu(store: store, space: space, icons: $icons, theme: $theme) }
            .popover(isPresented: $icons) { SpaceIcons(store: store, space: space) }
            .popover(isPresented: $theme) { SpaceTheme(store: store, space: space) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space")
            .accessibilityValue(space.name)
            .accessibilityHint("Click for the list of spaces, double-click to rename this one.")
            .accessibilityAction(named: "Rename Space") { renameSpace(space, in: store) }
            .accessibilityAction(named: "Change Space Icon") { icons = true }
            .accessibilityAction(named: "Edit Theme Color") { theme = true }
        } else {
            // A window outside any space still has this row, wearing the profile's name:
            // the list below it needs its heading, and the sidebar its shape.
            row("cloud", nil, store.profile.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space")
            .accessibilityValue(store.profile.name)
            .accessibilityHint("This window is not in a space. The plus button below makes one.")
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
/// ponytail: no Live Folders, no Share Space and no Export — those are whole features, not
/// menu items, and an entry that opens an apology is worse than no entry. They belong beside
/// `New Folder` on the day they exist.
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
        Button("New Folder") { store.newFolder() }
        Divider()
        // Arc's "Manage Spaces…" opens the Library's Spaces view — every Space's pages side
        // by side, draggable between columns — rather than a settings pane.
        Button("Manage Spaces…") { Library.open(.spaces, in: store) }
        Divider()
        Button("Delete Space") { deleteSpace(space, in: store) }
            .disabled(store.spaces.count < 2)
    }
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
    // Arc archives a deleted Space's tabs rather than dropping them. Read the space back
    // first: what is on disk is what is about to be deleted, and it is newer than the copy
    // the menu was built from.
    Spaces.archiveContents(of: store.spaces.first { $0.id == space.id } ?? space)
    ProfileManager.shared.deleteSpace(space.id, in: space.profileID)
    TabStore.forgetShape(space: space.id, profileID: space.profileID)
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
            .onTapGesture { edit { $0.colorHex = hex; $0.tint = $0.tint ?? Look.defaultTint } }
            .accessibilityLabel("Theme colour \(hex)")
            .accessibilityAddTraits(space.colorHex == hex ? [.isButton, .isSelected] : .isButton)
    }

    private var strength: some View {
        HStack(spacing: Look.inset + 2) {
            Image(systemName: "circle.lefthalf.filled").font(Look.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { space.tint ?? Look.defaultTint },
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
    /// Which dot a drag is over, so only that one lights up.
    @State private var dropTarget: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if store.spaces.isEmpty {
                Circle().fill(.tint).frame(width: Look.dot, height: Look.dot)
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
        let over = Binding(get: { dropTarget == space.id },
                           set: { dropTarget = $0 ? space.id : nil })
        Group {
            // The dot grows into the icon and the old icon shrinks to a dot as the Space
            // changes — Arc's footer morph, as a scale-and-fade both ways.
            if here {
                Image(systemName: space.icon ?? "cloud").font(Look.small)
                    .foregroundStyle(Look.inkPrimary)
                    .transition(.scale(scale: Look.tileAppearScale).combined(with: .opacity))
            } else {
                Circle().fill(Look.dotFill).frame(width: Look.dot, height: Look.dot)
                    .transition(.scale(scale: Look.tileAppearScale).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Look.quick, value: here)
        .frame(width: Look.spaceDotHit, height: Look.spaceDotHit)
        .background(dropTarget == space.id ? Look.selected : .clear, in: .circle)
        .contentShape(.rect)
        .onTapGesture { store.switchTo(space: space) }
        .onDrag { spaceDragPayload(space) }
        .onDrop(of: [.plainText], delegate: SpaceDrop(store: store, space: space, over: over))
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

// MARK: - Pinned

/// Arc's Pinned section: the tabs that stay, drawn as ordinary rows between the space's name
/// and the New Tab divider. Deliberately the same row as a Today tab — in Arc the two are
/// indistinguishable to look at, and the divider below is the only thing that says which is
/// which. What differs is behaviour: a pinned tab never auto-archives, and ⌘W leaves it
/// exactly where it is.
private struct PinnedTabs: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        // Drawn from `store.pins`, not from the strip: a folder is not a tab, and the order
        // the rows are in is the folders’, which is what `Pins` is for.
        let rows = store.pins.visible
        // Empty is nothing, as in Arc: the divider follows the space’s name. The way in is
        // a drop on the space row, ⌘D, a tab’s own Pin action, or New Folder.
        if !rows.isEmpty {
            VStack(spacing: Look.rowGap) {
                ForEach(rows) { PinnedRow(row: $0).transition(.rowCollapse) }
            }
            .contextMenu { Button("New Folder") { store.newFolder() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned Tabs")
            .accessibilityValue("\(store.pins.tabs.count) pinned")
        }
    }
}

/// One line of the Pinned section — a folder or one of the tabs in it — stepped in by how
/// deep it sits. The indent is the only thing that says a tab is inside a folder, which is
/// exactly how Arc says it.
private struct PinnedRow: View {
    @EnvironmentObject var store: TabStore
    let row: Pins.Visible

    var body: some View {
        Group {
            if let folder = row.entry.folder {
                FolderRow(folder: folder)
            } else if let tab = store.tabs.first(where: { $0.id.uuidString == row.entry.tab }) {
                // StripRow, not TabRow: a pinned tab that is a pane of a split is drawn as
                // the split's one row, at its lead pane's place.
                StripRow(tab: tab)
            }
        }
        .padding(.leading, CGFloat(row.depth) * Look.folderIndent)
    }
}

/// Which part of a folder row a drop is over: its edges reorder, its middle puts the thing
/// inside. A tab row has only two halves (`DropSide`) because there is no inside to have.
private enum FolderZone { case before, inside, after }

/// A folder in the Pinned section: its glyph, its name and a chevron that says whether it is
/// folded. Clicking anywhere on it folds or unfolds; everything else it can be is in its
/// right-click menu, which is the only route the keyboard and VoiceOver have.
private struct FolderRow: View {
    @EnvironmentObject var store: TabStore
    let folder: Folder
    @State private var zone: FolderZone?
    @State private var icons = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SidebarRow(selected: false, action: { store.toggleFolder(folder.id) }) {
            FolderGlyph(folder: folder)
        } label: {
            if store.renamingFolder == folder.id {
                FolderNameField(store: store, folder: folder)
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
        .onDrop(of: [.plainText], delegate: FolderDrop(store: store, folder: folder, zone: $zone))
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingFolder = folder.id })
        .contextMenu { FolderMenu(store: store, folder: folder, icons: $icons) }
        .popover(isPresented: $icons) { FolderIcons(store: store, folder: folder) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue("Folder, \(store.pins.tabs(in: folder.id).count) tabs, "
                            + (folder.collapsed ? "collapsed" : "expanded"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Folds this folder open or shut.")
        .accessibilityAction(named: "Rename Folder") { store.renamingFolder = folder.id }
        .accessibilityAction(named: "Change Icon") { icons = true }
        .accessibilityAction(named: "Archive All Tabs in Folder") { store.archiveFolder(folder.id) }
        .accessibilityAction(named: "Delete Folder") { store.deleteFolder(folder.id) }
    }
}

/// A folder’s glyph in a favicon’s box, so its name lines up with the tab titles around it.
/// An emoji is text and an SF Symbol is an image; `Folder.iconIsEmoji` is what tells them
/// apart, and it does so by looking at the string rather than by a second stored field.
private struct FolderGlyph: View {
    let folder: Folder
    var body: some View {
        Group {
            if folder.iconIsEmoji {
                Text(folder.icon).font(Look.small)
            } else {
                Image(systemName: folder.icon)
            }
        }
        .frame(width: Look.tileIcon)
    }
}

/// Right-clicking a folder, in Arc’s order: what it is called, whether it is open, and the
/// two ways to be rid of it. Deleting keeps the tabs; archiving keeps the folder.
private struct FolderMenu: View {
    let store: TabStore
    let folder: Folder
    @Binding var icons: Bool

    var body: some View {
        Button("Rename…") { store.renamingFolder = folder.id }
        Button("Change Icon…") { icons = true }
        Button(folder.collapsed ? "Unfold" : "Collapse") { store.toggleFolder(folder.id) }
        Divider()
        Button("New Folder") { store.newFolder(beside: folder.id) }
        Button("Archive All Tabs in Folder") { store.archiveFolder(folder.id) }
            .disabled(store.pins.tabs(in: folder.id).isEmpty)
        Divider()
        Button("Delete Folder") { store.deleteFolder(folder.id) }
    }
}

/// See `dragPayload`: published on the next turn so starting the drag does not re-render the
/// row out from under it.
@MainActor private func folderDragPayload(_ folder: Folder) -> NSItemProvider {
    let id = folder.id
    DispatchQueue.main.async { Dragging.shared.folder = id; Dragging.shared.tab = nil }
    return NSItemProvider(object: id.uuidString as NSString)
}

/// The drop target a tab row does not need: three zones instead of two, because a folder has
/// an inside. The middle half takes the thing in; the quarter at each edge reorders beside
/// it, the way `TabDrop` does.
private struct FolderDrop: DropDelegate {
    let store: TabStore
    let folder: Folder
    @Binding var zone: FolderZone?

    func validateDrop(info: DropInfo) -> Bool {
        if let dragged = Dragging.shared.folder { return dragged != folder.id }
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
        let (tab, dragged) = Dragging.shared.take()      // see `TabDrop.performDrop`
        if let dragged {
            guard dragged != folder.id else { return false }
            switch where_ {
            case .inside: store.move(folder: dragged, into: folder.id)
            default: store.move(folder: dragged, next: folder.id.uuidString,
                                after: where_ == .after)
            }
            return true
        }
        guard let id = tab else { return false }
        switch where_ {
        case .inside: store.move(id, into: folder.id)
        default: store.drop(id, beside: folder.id, after: where_ == .after)
        }
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
/// The sidebar's geometry group (see `Sidebar.strip`). nil outside the sidebar — the
/// Library's rows are not in it.
private struct StripKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    fileprivate var rowHovering: Bool {
        get { self[RowHoveringKey.self] }
        set { self[RowHoveringKey.self] = newValue }
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
            Text("|").foregroundStyle(Look.inkQuiet)
            Button("Clear") { clear() }
                .help("Archive today's tabs (\(Keybindings.binding(for: .clearTabs).display))")
                .accessibilityLabel("Clear Tabs")
        }
        .buttonStyle(.plain)
        .font(Look.sectionCaption)
        .foregroundStyle(Look.inkTertiary)
        .padding(.horizontal, Look.rowInset)
        // Arc butts this label to the last pinned row and leaves the room *below* it, so
        // the divider reads as the end of one section rather than the start of the next.
        .frame(height: Look.tidyRow)
        .padding(.top, -Look.rowGap)
        .padding(.bottom, Look.sectionGap - Look.rowGap)
    }

    /// The menu item owns this too, so both routes archive rather than destroy.
    private func clear() { Keybindings.actions[.clearTabs]?() }
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
        let open = store.tabs.filter { $0.kind == .today }
        VStack(spacing: Look.rowGap) {
            ForEach(open) { StripRow(tab: $0) }
        }
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

    var body: some View {
        if let split = store.split(containing: tab.id) {
            if store.leadPane(split) == tab.id {
                SplitRow(split: split, lead: tab).transition(.rowCollapse)
            }
        } else {
            TabRow(tab: tab).transition(.rowCollapse)
        }
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
    @State private var side: DropSide?
    @Environment(\.strip) private var strip

    var body: some View {
        let panes = split.tabs.compactMap { id in store.tabs.first { $0.id == id } }
        let selected = split.tabs.contains { $0 == store.current }
        let active = panes.first { $0.id == split.activeTab } ?? panes.first
        let title = active.map { TidyTitles.title(for: $0) } ?? "Split View"
        SidebarRow(selected: selected, action: { store.focusPane(split.activeTab) }) {
            SplitIcons(panes: panes)
        } label: {
            Text(title)
        } trailing: {
            if let active { TabRowTrailing(tab: active, selected: selected, pane: true) }
        }
        // Everything a tab's row does with a drag, keyed on the pane whose place this is: a
        // split is one item in the strip, so it reorders and takes drops like one.
        .overlay(alignment: side == .after ? .bottom : .top) {
            DropLine(on: side != nil, axis: .vertical)
        }
        .inStrip(lead.id, strip)
        .help("Split view of \(panes.count) tabs")
        .onDrag { dragPayload(lead) } preview: {
            HStack(spacing: Look.rowSpacing) {
                SplitIcons(panes: panes)
                Text(title).lineLimit(1).font(Look.rowTitle)
            }
            .padding(.horizontal, Look.rowInset).padding(.vertical, 4)
        }
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: lead, into: lead.kind,
                                  axis: .vertical, extent: Look.rowHeight, side: $side))
        .contextMenu { SplitMenu(store: store, split: split) }
        // One element for the whole split, the way one row is one thing: how many panes and
        // which one is showing, with moving between them as an action rather than as a
        // second element to find.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Split View")
        .accessibilityValue("\(panes.count) panes, showing \(title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this split view.")
        .accessibilityAction(named: "Next Pane") { store.focusNextPane() }
        .accessibilityAction(named: "Swap") { store.swapPanes(split) }
        .accessibilityAction(named: "Separate All Tabs") { store.separateSplit(split) }
        .accessibilityAction(named: "Close Pane") {
            if let active { store.close(active.id) }
        }
    }
}

/// The panes' favicons, overlapping, so one row says how many pages it holds without a count.
///
/// ponytail: two icons at most, whatever the split holds. Four of them are 49pt of leading
/// slot against every other row's 16, and a title that starts a third of the way across the
/// sidebar is worse than one that does not say "four" out loud — the row's own value says how
/// many panes there are. The slot is clamped as well as capped, so even the two overlap
/// inside a tab icon's width.
private struct SplitIcons: View {
    let panes: [Tab]
    var body: some View {
        HStack(spacing: -Look.splitIconLap) {
            ForEach(panes.prefix(2)) { TabIcon(tab: $0) }
        }
        .frame(width: Look.tileIcon, alignment: .leading)
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
        Button("Close Split View") { split.tabs.forEach { store.archive($0) } }
    }
}

private struct TabRow: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    @State private var side: DropSide?
    @Environment(\.strip) private var strip

    var body: some View {
        let selected = store.current == tab.id
        SidebarRow(selected: selected, action: select) {
            TabIcon(tab: tab)
        } label: {
            // Arc's in-row rename: the title becomes a field and the row keeps its shape.
            if store.renamingTab == tab.id {
                RenameField(store: store, tab: tab)
            } else {
                Text(TidyTitles.title(for: tab))
            }
        } trailing: {
            TabRowTrailing(tab: tab, selected: selected)
        }
        // The drop target is the whole row, so the line shows which side it will land on.
        .overlay(alignment: side == .after ? .bottom : .top) {
            DropLine(on: side != nil, axis: .vertical)
        }
        .inStrip(tab.id, strip)
        .help(tab.title)
        .onDrag { dragPayload(tab) } preview: {
            // Drag preview: the row alone would drag the whole list's background with it.
            HStack(spacing: Look.rowSpacing) {
                TabIcon(tab: tab)
                Text(TidyTitles.title(for: tab)).lineLimit(1).font(Look.rowTitle)
            }
            .padding(.horizontal, Look.rowInset).padding(.vertical, 4)
        }
        .onDrop(of: [.plainText],
                delegate: TabDrop(store: store, target: tab, into: tab.kind,
                                  axis: .vertical, extent: Look.rowHeight, side: $side))
        // Arc's double-click-to-rename. Simultaneous, so the row's own single tap still
        // selects the tab first — which is what Arc does too, and what makes the rename
        // apply to the tab you are looking at.
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingTab = tab.id })
        .contextMenu { TabMenu(store: store, tab: tab) }
        // One element per tab, the way a tab in Safari reads: the title is the label, the
        // state is the value, and the close button becomes an action rather than a second
        // element the user has to find and then guess the meaning of.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TidyTitles.title(for: tab))
        .accessibilityValue(tabState(tab, in: store))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this tab.")
        .accessibilityAction(named: tab.kind == .today ? "Archive Tab" : "Close Tab") {
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

    /// Arc's ⌥-click: the tab opens *beside* the one you are looking at, in a split, instead
    /// of replacing it.
    /// ponytail: `NSEvent.modifierFlags` read at the moment of the tap rather than a
    /// modifier-aware gesture. SwiftUI's tap carries no flags, and the only alternative is a
    /// second hit-testing layer over every row. Ceiling: it reads the *current* state of the
    /// keyboard, so a modifier released inside the same click's few milliseconds is missed.
    private func select() {
        if NSEvent.modifierFlags.contains(.option), store.current != tab.id {
            store.addPane(tab.id)
        } else {
            store.current = tab.id
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
private struct TabMenu: View {
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
        // Arc’s "New Folder" on a tab makes the folder *around* that tab, so the tab is
        // pinned on the way in. "Move to Folder" is the same move without a drag, which is
        // the only route the keyboard and VoiceOver have.
        Button("New Folder") { store.newFolder(from: tab.id) }
        let folders = store.pins.entries.compactMap(\.folder)
        if !folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(folders) { folder in
                    Button(folder.name) { store.move(tab.id, into: folder.id) }
                }
            }
        }
        MoveToSpaceMenu(store: store, tab: tab)
        Divider()
        // A favourite or a pinned tab has no "archive": closing it parks it in place, which
        // is what the section means, so the item says what will actually happen.
        Button(tab.kind == .today ? "Archive Tab" : "Close Tab") { store.archive(tab.id) }
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

/// The speaker and the close button. Split out only because one expression with both of
/// them plus the row's own modifiers stopped type-checking in reasonable time.
private struct TabRowTrailing: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab
    let selected: Bool
    /// On a split's row the × closes the pane the row is showing, not a whole tab's worth of
    /// row — so it says so, in the tooltip and to VoiceOver.
    var pane = false
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
                .help(pane ? "Close Pane (⌘W)" : "Close Tab (⌘W)")
                .accessibilityLabel((pane ? "Close pane " : "Close ")
                                    + TidyTitles.title(for: tab))
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
/// favicon lands.
private struct TabIcon: View {
    @ObservedObject var tab: Tab
    var size: CGFloat = 16

    var body: some View {
        // Arc spins the row's favicon slot while its page is loading. The card's own 2pt bar
        // only says that *the tab you are looking at* is busy; a background tab had nothing.
        if tab.loading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(size / 24)
                .frame(width: size, height: size)
                .accessibilityHidden(true)      // the row's value already says "loading"
        } else {
            SiteIcon(icon: tab.favicon, size: size)
        }
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
            SpaceDots()
            Spacer(minLength: 0)
            NewSpaceButton()
        }
        .font(Look.icon)
        .frame(height: Look.footer)
        .padding(.horizontal, Look.inset)
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
            .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
            .background(Look.barMaterial, in: .rect(cornerRadius: Look.cardRadius))
            .hairline(radius: Look.cardRadius)
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
            .foregroundStyle(store.libraryOpen ? Look.inkPrimary : Look.inkSecondary)
            .help("Library (\(Keybindings.binding(for: .showLibrary).display))")
            .accessibilityLabel("Library")
            .accessibilityValue("\(archive.entries.count) archived, \(downloads.items.count) download\(downloads.items.count == 1 ? "" : "s")")
            .accessibilityHint("Shows archived tabs, downloads, Spaces and history.")
    }
}
