import SwiftUI
import LocalAuthentication

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @State private var settings = false
    @State private var noArticle = false
    @State private var bookmarks = false
    @State private var themeDemo = false
    @AppStorage("onboarded") private var onboarded = false

    private var space: SpaceRow? { library.space(browser.spaceID) }

    var body: some View {
        // The page takes the whole screen; the controls float over its foot in the Space's
        // colour, down in the home-indicator strip, and shrink away while you read.
        ZStack(alignment: .bottom) {
            Wash(space: space)
            if let tab = browser.selected {
                WebContainer(tab: tab).id(tab.id)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                if let pull = tab.pull {
                    PullActions(pull: pull, color: tab.pageColor).frame(maxHeight: .infinity, alignment: .top)
                }
                // Reader is a mode of the tab: the article takes the page's place, under the same bar.
                if let article = tab.reading {
                    ReaderView(article: article)
                        .transition(.opacity)
                }
            } else {
                // Home: every Space, full screen, swiped between like Arc on iPhone.
                SpacesHome(openSettings: { settings = true })
                    .transition(.opacity)
            }
            if browser.editing != nil {
                // The page or Space stays in view, dimmed; a tap outside cancels.
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { browser.editing = nil }
                    .transition(.opacity)
                Suggestions(space: space)
                    .padding(.horizontal, 14).padding(.bottom, Look.barHeight + 12)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            }
            BottomBar(space: space, menu: menu)
        }
        .animation(.smooth(duration: 0.28), value: browser.editing)
        .animation(.smooth(duration: 0.3), value: browser.selectedID)
        .animation(.easeInOut(duration: 0.25), value: browser.selected?.reading)
        .blur(radius: Frost.shared.sheets > 0 ? 18 : 0)
        .animation(.easeOut(duration: 0.3), value: Frost.shared.sheets > 0)
        .sheet(isPresented: $settings) { SettingsView().frostsBehind() }
        .sheet(isPresented: $themeDemo) { if let space { ThemeEditor(space: space) } }
        .sheet(isPresented: $bookmarks) { BookmarksView().frostsBehind() }
        .alert("Reader isn't available for this page", isPresented: $noArticle) {}
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) { Onboarding { onboarded = true } }
        .preferredColorScheme(space?.appearance == "dark" ? .dark : space?.appearance == "light" ? .light : nil)
        .tint(.primary)
        .task { demo() }
    }

    /// Short enough to open whole on any iPhone: actions sit in two rows of icons, and the
    /// ways to keep a page share one submenu.
    @ViewBuilder private var menu: some View {
        if let tab = browser.selected, let space {
            ControlGroup {
                Button("Back", systemImage: "chevron.backward") { tab.webView.goBack() }.disabled(!tab.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { tab.webView.goForward() }.disabled(!tab.canGoForward)
                Button("Reload", systemImage: "arrow.clockwise") { tab.webView.reload() }
            }
            ControlGroup {
                ShareLink(item: tab.url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Find", systemImage: "text.magnifyingglass") { tab.webView.findInteraction?.presentFindNavigator(showingReplace: false) }
                // One short label either way; the filled icon says Reader is on.
                Button("Reader", systemImage: tab.reading == nil ? "doc.plaintext" : "doc.plaintext.fill") {
                    if tab.reading != nil { tab.reading = nil } else { Task { tab.reading = await tab.article(); noArticle = tab.reading == nil } }
                }
            }
            if !space.isIncognito {
                // Each way to keep the page, named plainly, filled when the page already is one;
                // tapping again undoes it.
                let favourite = library.favourites(profile: space.profileID).first { $0.url == tab.url }
                let pin = library.pinned(space: space.id).first { $0.url == tab.url }
                ControlGroup {
                    Button("Favourite", systemImage: favourite == nil ? "star" : "star.fill") {
                        if let favourite { library.remove(favourite.id) } else { library.addFavourite(tab.url, profile: space.profileID) }
                    }
                    Button("Pin Tab", systemImage: pin == nil ? "pin" : "pin.fill") {
                        if let pin { library.remove(pin.id) } else { library.addPinned(tab.url, title: tab.title, space: space) }
                    }
                }
            }
            Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
        }
        Section {
            Button("New Tab", systemImage: "plus") { browser.editing = .newTab }
            if space?.isIncognito == true {
                Button("Leave Incognito", systemImage: "eyeglasses") { leaveIncognito() }
            } else {
                Button("New Incognito Tab", systemImage: "eyeglasses") { browser.select(nil); browser.switchSpace(SpaceRow.incognito.id); browser.editing = .newTab }
            }
        }
        Section {
            // The bookmarks library synced from Vane on the Mac; only there when it has some.
            if let space, !library.bookmarks(profile: space.profileID).isEmpty {
                Button("Mac Bookmarks", systemImage: "book") { bookmarks = true }
            }
            Button("Settings", systemImage: "gearshape") { settings = true }
        }
    }

    private func leaveIncognito() {
        browser.switchSpace(library.spaces.first?.id ?? Local.space)
    }

    /// Debug-only launch arguments for screenshots, e.g. `-demoPanel spaces -demoOpen https://…`.
    private func demo() {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "demoSeed"), let space = library.spaces.first {
            for site in ["https://www.apple.com", "https://github.com", "https://en.wikipedia.org", "https://developer.mozilla.org", "https://www.youtube.com", "https://news.ycombinator.com"] {
                library.addFavourite(URL(string: site)!, profile: space.profileID)
            }
            library.addPinned(URL(string: "https://developer.apple.com")!, title: "Apple Developer", space: space)
            library.addPinned(URL(string: "https://www.swift.org")!, title: "Swift.org", space: space)
            var themed = space; themed.colors = ["#6CBAD9", "#C5C6E5", "#F29BBB"]; themed.icon = "sparkles"; themed.grain = 0.4
            library.setTheme(themed)
            library.addSpace("Work", profile: space.profileID)
            browser.open(URL(string: "https://en.wikipedia.org/wiki/Weather_vane")!)
            browser.open(URL(string: "https://www.swift.org/about/")!)
            browser.select(nil)
        }
        if defaults.bool(forKey: "demoIncognito") { browser.switchSpace(SpaceRow.incognito.id) }
        if let raw = defaults.string(forKey: "demoOpen"), let url = URL(string: raw) { browser.open(url) }
        if let dx = defaults.object(forKey: "demoPull") as? String, let value = Double(dx) {
            Task { try? await Task.sleep(for: .seconds(5)); browser.selected?.pull = .init(progress: 1, choice: value < -45 ? .newTab : value > 45 ? .close : .reload, dx: value) }
        }
        if defaults.bool(forKey: "demoCollapsed") {
            Task { try? await Task.sleep(for: .seconds(5)); withAnimation { browser.selected?.collapsed = true } }
        }
        switch defaults.string(forKey: "demoPanel") {
        case "spaces": browser.select(nil)
        case "settings": settings = true
        case "address": browser.editing = .current
        case "theme": themeDemo = true
        default: break
        }
        #endif
    }
}

/// The controls under the page, on the Space's ground. Sliding along the bar moves to the
/// next or previous Space, the way a two-finger swipe does on the Mac sidebar.
struct BottomBar<Menu: View>: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let space: SpaceRow?
    let menu: Menu
    @State private var nudge: CGFloat = 0
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool
    private var editing: Bool { browser.editing != nil }

    var body: some View {
        Group { content }
            .onChange(of: browser.editing) { _, editing in
                guard let editing else { focused = false; return }
                // Editing the page you're on starts from its address, all selected so typing replaces it.
                let query = editing == .newTab ? "" : browser.selected?.url.absoluteString ?? ""
                browser.query = query
                selection = TextSelection(range: query.startIndex..<query.endIndex)
                focused = true
            }
    }

    @ViewBuilder private var content: some View {
        if let tab = browser.selected, tab.collapsed, !editing {
            // Reading: just the site, small, out of the way. A tap brings the bar back.
            Button { withAnimation(.smooth(duration: 0.3)) { tab.collapsed = false } } label: {
                HStack(spacing: 6) {
                    SiteIcon(url: tab.url, size: 12)
                    Text(tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .accessibilityLabel("Show controls, \(tab.url.host() ?? "")")
            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        } else {
            bar.transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
        }
    }

    private var bar: some View {
        let tab = browser.selected
        let last = browser.spaceTabs.last
        // A capsule inside a capsule, so both ends sit concentric with the screen's corners.
        return HStack(spacing: 4) {
            if !editing { tabsButton(tab: tab, last: last).transition(.scale(scale: 0.5).combined(with: .opacity)) }
            pill(tab: tab)
            if editing {
                Button("Cancel") { browser.editing = nil }.fontWeight(.medium).padding(.horizontal, 10).frame(height: 44)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                SwiftUI.Menu { menu } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).contentShape(Circle())
                }
                .accessibilityLabel("More")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        .frame(maxWidth: 560)
        .padding(.horizontal, 14).padding(.bottom, 2)
        .offset(x: nudge)
        .simultaneousGesture(editing ? nil : DragGesture(minimumDistance: 24).onChanged { value in
            nudge = value.translation.width * 0.12
        }.onEnded { value in
            let ids = library.spaces.map(\.id)
            if abs(value.translation.width) > 80, let index = ids.firstIndex(of: browser.spaceID) {
                let next = index + (value.translation.width < 0 ? 1 : -1)
                if ids.indices.contains(next) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    browser.switchSpace(ids[next])
                }
            }
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { nudge = 0 }
        })
    }

    private func tabsButton(tab: Tab?, last: Tab?) -> some View {
            // On a page: the Space and its tabs. On the Space itself (which already shows them):
            // back to the last tab, or nothing to do when there isn't one.
            Button { if tab == nil, let last { browser.select(last) } else { tab?.takeSnapshot(); browser.select(nil) } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary, lineWidth: 1.6).frame(width: 21, height: 21)
                    Text("\(browser.spaceTabs.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 44, height: 44).contentShape(Circle())
            }
            .disabled(tab == nil && last == nil)
            .opacity(tab == nil && last == nil ? 0.35 : 1)
            .accessibilityLabel(tab == nil ? "Back to \(last?.title ?? "tab")" : "Spaces and tabs, \(browser.spaceTabs.count) open")
    }

    /// The address pill; while editing, the same capsule holds the text field.
    private func pill(tab: Tab?) -> some View {
        ZStack {
            if editing {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium)).opacity(0.6)
                    TextField("Search or enter address", text: Binding(get: { browser.query }, set: { browser.query = $0 }), selection: $selection)
                        .focused($focused).keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { browser.go(browser.destination(for: browser.query)) }
                    if !browser.query.isEmpty {
                        Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.45) }
                            .accessibilityLabel("Clear")
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
            } else {
                Button { browser.editing = .current } label: {
                HStack(spacing: 8) {
                    if let tab {
                        if tab.reading != nil {
                            Image(systemName: "doc.plaintext.fill").font(.subheadline).accessibilityLabel("Reader")
                        }
                        SiteIcon(url: tab.url, size: 16)
                        Text(tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? tab.title).lineLimit(1)
                    } else {
                        Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium))
                        Text("Search or enter address").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
                }
                .accessibilityLabel(tab.map { "Address, \($0.url.host() ?? "")" } ?? "Search or enter address")
            }
        }
        .frame(maxWidth: .infinity).frame(height: 40)
                .background {
                    // Loading fills the pill from the left, then fades.
                    GeometryReader { geo in
                        let loading = (tab?.progress ?? 1) < 1
                        Capsule().fill(.primary.opacity(0.08))
                            .frame(width: geo.size.width * (tab?.progress ?? 0))
                            .opacity(loading ? 1 : 0)
                            .animation(.easeOut(duration: loading ? 0.2 : 0.4), value: tab?.progress)
                    }
                }
                .background(GroundFill(strength: editing ? 1.8 : 1.4), in: Capsule())
                .clipShape(Capsule())
    }
}

/// Home: every Space side by side, full screen, swiped between like Arc on iPhone. The
/// Space marks under them work as page dots, as at the foot of the Mac sidebar.
struct SpacesHome: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let openSettings: () -> Void
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        let current = library.space(browser.spaceID)
        let pages = library.spaces + [.incognito]
        ZStack(alignment: .bottom) {
            TabView(selection: Binding(get: { browser.spaceID }, set: { browser.switchSpace($0) })) {
                ForEach(pages) { space in
                    SpaceColumn(space: space, close: {}, openSettings: openSettings).tag(space.id)
                        // Room to scroll the last card clear of the marks and the bar.
                        .safeAreaPadding(.bottom, Look.barHeight + 46)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .bottom)
            .mask {
                // Content fades out under the marks and bar rather than being cut off.
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 120)
                    Color.clear.frame(height: 40)
                }
                .ignoresSafeArea()
            }
            HStack(spacing: 0) {
                ForEach(pages) { space in
                    let here = space.id == browser.spaceID
                    Button { withAnimation(.smooth) { browser.switchSpace(space.id) } } label: {
                        SpaceMark(space: space, size: 14).opacity(here ? 1 : 0.4).frame(width: 34, height: 34)
                    }
                    .accessibilityLabel(space.name)
                    .accessibilityAddTraits(here ? .isSelected : [])
                }
                Button { name = ""; creating = true } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).opacity(0.5).frame(width: 34, height: 34)
                }
                .accessibilityLabel("New Space")
            }
            .buttonStyle(.plain)
            .padding(.bottom, Look.barHeight + 6)
        }
        .alert("New Space", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") {
                guard !name.isEmpty else { return }
                browser.switchSpace(library.addSpace(name, profile: current.flatMap { $0.isIncognito ? nil : $0.profileID } ?? Local.profile))
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// One Space, laid out like the Mac sidebar: favourites as tiles, pinned tabs and folders,
/// a hairline, New Tab, then the Space's open tabs. Other devices' tabs follow.
struct SpaceColumn: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(Sync.self) private var sync
    let space: SpaceRow?
    let close: () -> Void
    let openSettings: () -> Void
    @State private var renaming = false
    @State private var deleting = false
    @State private var theming = false
    @State private var name = ""
    @State private var naming: LinkRow?

    var body: some View {
        let favourites = space.map { library.favourites(profile: $0.profileID) } ?? []
        let tabs = browser.tabs.filter { $0.spaceID == space?.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !favourites.isEmpty || (canKeep && !tabs.isEmpty) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(favourites) { link in
                            Button { open(link) } label: {
                                SiteIcon(url: link.url, size: 24)
                                    .frame(maxWidth: .infinity).frame(height: Look.tileHeight)
                                    .background(GroundFill(strength: browser.selected?.home == link.url ? 2.2 : 1),
                                                in: RoundedRectangle(cornerRadius: Look.pillRadius, style: .continuous))
                            }
                            .buttonStyle(PressFill())
                            .accessibilityLabel(link.title)
                            .contextMenu {
                                Text(link.title)
                                Button("Rename", systemImage: "pencil") { name = link.title; naming = link }
                                Button("Remove Favourite", systemImage: "star.slash", role: .destructive) { library.remove(link.id) }
                            }
                        }
                        if favourites.isEmpty {
                            // Somewhere to drop the first one.
                            Image(systemName: "star").font(.system(size: 16, weight: .medium)).opacity(0.4)
                                .frame(maxWidth: .infinity).frame(height: Look.tileHeight)
                                .overlay(RoundedRectangle(cornerRadius: Look.pillRadius, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])))
                                .accessibilityLabel("Drag a tab here to make it a favourite")
                        }
                    }
                    // Drag a tab up here to make it a favourite, as on the Mac.
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let space, canKeep else { return false }
                        urls.forEach { library.addFavourite($0, profile: space.profileID) }
                        return !urls.isEmpty
                    }
                }
                if let space {
                    VStack(spacing: 2) { PinnedRows(space: space.id, open: open) }
                        .frame(minHeight: 12)
                        .contentShape(Rectangle())
                        .dropDestination(for: URL.self) { urls, _ in
                            guard canKeep else { return false }
                            for url in urls { library.addPinned(url, title: browser.tabs.first { $0.url == url }?.title ?? url.host() ?? "", space: space) }
                            return !urls.isEmpty
                        }
                }
                Rectangle().fill(.primary.opacity(0.14)).frame(height: 1).padding(.horizontal, 12)
                VStack(spacing: 2) {
                    Row(title: "New Tab", icon: AnyView(Image(systemName: "plus").fontWeight(.medium))) {
                        browser.editing = .newTab; close()
                    }
                }
                // Open tabs as cards, newest first, like Arc on iPhone.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(tabs.reversed()) { tab in
                        TabCard(tab: tab, selected: tab.id == browser.selectedID) {
                            browser.select(tab); close()
                        } close: {
                            withAnimation(.smooth(duration: 0.25)) { browser.close(tab) }
                        }
                        .draggable(tab.url) { SiteIcon(url: tab.url, size: 28).padding(10).background(GroundFill(strength: 2), in: RoundedRectangle(cornerRadius: Look.pillRadius, style: .continuous)) }
                        .contextMenu {
                            if let space, canKeep {
                                Button("Add to Favourites", systemImage: "star") { library.addFavourite(tab.url, profile: space.profileID) }
                                Button("Pin to \(space.name)", systemImage: "pin") { library.addPinned(tab.url, title: tab.title, space: space) }
                            }
                            Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
                        }
                    }
                }
                ForEach(space?.isIncognito == true ? [] : library.remoteTabs, id: \.device) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(group.device, systemImage: "laptopcomputer")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                        ForEach(group.tabs) { tab in
                            Row(title: tab.title.isEmpty ? tab.url.absoluteString : tab.title, icon: AnyView(SiteIcon(url: tab.url, size: 18))) {
                                browser.open(tab.url); close()
                            }
                        }
                    }
                }
                if space?.isIncognito == true {
                    Text("Nothing here is saved or synced. Close the last tab and it's gone.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                } else if favourites.isEmpty && tabs.isEmpty && library.pinned(space: space?.id ?? Local.space).isEmpty {
                    emptyHint
                }
            }
            .padding(.horizontal, Look.inset).padding(.vertical, 12)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await sync.run() }
        .sheet(isPresented: $theming) { if let space { ThemeEditor(space: space) } }
        .alert("Rename", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(naming?.url.host() ?? "Name", text: $name)
            Button("Rename") { if let naming { library.setCustomName(naming.id, to: name) } }
            Button("Use Page Title") { if let naming { library.setCustomName(naming.id, to: nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Space", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { if let space, !name.isEmpty { library.renameSpace(space, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(space?.name ?? "this Space")?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Space", role: .destructive) {
                guard let space else { return }
                browser.closeTabs(in: space.id)
                library.deleteSpace(space)
                if let first = library.spaces.first { browser.switchSpace(first.id) }
            }
        } message: {
            Text(space?.isLocal == true ? "Its tabs and pinned tabs are removed." : "Its pinned tabs are also removed from your other synced devices.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Tap the Space's icon or name to jump to another Space.
            Menu {
                Picker("Space", selection: Binding(get: { browser.spaceID }, set: { id in withAnimation(.smooth) { browser.switchSpace(id) } })) {
                    ForEach(library.spaces + [.incognito]) { other in
                        Label(other.name, systemImage: other.icon.flatMap { UIImage(systemName: $0) == nil ? nil : $0 } ?? "circle.fill").tag(other.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if let space {
                        SpaceMark(space: space, size: 17).frame(width: 36, height: 36).background(GroundFill(), in: Circle())
                    }
                    Text(space?.name ?? "Vane").font(.title2.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Space, \(space?.name ?? "")")
            if let space, !space.isLocal, !space.isIncognito, let profile = library.profileName(space.profileID) {
                Text(profile).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if let space, !space.isIncognito {
                Menu {
                    Button("Edit Theme and Icon", systemImage: "paintpalette") { theming = true }
                    Button("Rename", systemImage: "pencil") { name = space.name; renaming = true }
                    Button("Delete Space", systemImage: "trash", role: .destructive) { deleting = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                        .background(GroundFill(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Space options")
            }
        }
        .padding(.top, 12)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag tabs here to keep them.")
            if !sync.enabled {
                Button("Sync with your Mac", action: openSettings).fontWeight(.medium)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 6)
    }

    /// Incognito keeps nothing, so nothing can be favourited or pinned from it.
    private var canKeep: Bool { space.map { !$0.isIncognito } ?? false }

    private func open(_ link: LinkRow) { browser.open(link.url, home: link.url); close() }
}

/// Pinned tabs and their folders. Folders locked on the Mac open only after Face ID or the passcode.
struct PinnedRows: View {
    @Environment(Library.self) private var library
    let space: UUID
    let open: (LinkRow) -> Void
    var body: some View {
        ForEach(library.folders(space: space)) { FolderView(folder: $0, open: open) }
        ForEach(library.pinned(space: space)) { LinkButton(link: $0, open: open) }
    }
}

struct LinkButton: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let link: LinkRow
    let open: (LinkRow) -> Void
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        Row(title: link.title, selected: browser.selected?.home == link.url, icon: AnyView(SiteIcon(url: link.url, size: 18))) { open(link) }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { name = link.title; renaming = true }
                Button("Unpin", systemImage: "pin.slash", role: .destructive) { library.remove(link.id) }
            }
            .alert("Rename", isPresented: $renaming) {
                TextField(link.url.host() ?? "Name", text: $name)
                Button("Rename") { library.setCustomName(link.id, to: name) }
                Button("Use Page Title") { library.setCustomName(link.id, to: nil) }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct FolderView: View {
    let folder: FolderRow
    let open: (LinkRow) -> Void
    @State private var expanded = false
    @State private var unlocked = false
    var body: some View {
        VStack(spacing: 2) {
            Row(title: folder.name, icon: AnyView(Image(systemName: folder.locked && !unlocked ? "lock.fill" : expanded ? "folder.fill" : "folder"))) { toggle() } trailing: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).opacity(0.5)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            if expanded {
                VStack(spacing: 2) {
                    ForEach(folder.folders) { FolderView(folder: $0, open: open) }
                    ForEach(folder.links) { LinkButton(link: $0, open: open) }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
    private func toggle() {
        guard !expanded, folder.locked, !unlocked else { return withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } }
        Task {
            let context = LAContext()
            if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open \(folder.name)")) == true {
                unlocked = true
                withAnimation(.smooth(duration: 0.25)) { expanded = true }
            }
        }
    }
}


struct ReaderView: View {
    let article: Article
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.site).font(.subheadline).foregroundStyle(.secondary)
                Text(article.title).font(.system(.largeTitle, design: .serif).bold())
                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    Text(block.text)
                        .font(block.heading ? .system(.title2, design: .serif).bold() : .system(.body, design: .serif))
                        .lineSpacing(5).textSelection(.enabled)
                        .padding(.top, block.heading ? 10 : 0)
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, Look.barHeight + 40)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

struct BookmarksView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let profile = library.spaces.first { $0.id == browser.spaceID }?.profileID ?? Local.profile
        let groups = library.bookmarks(profile: profile)
        NavigationStack {
            List {
                ForEach(groups, id: \.folder) { group in
                    Section(group.folder ?? "Bookmarks") {
                        ForEach(group.links) { link in
                            Button { browser.open(link.url); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    Text(link.title).lineLimit(1)
                                    Text(link.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { library.remove(link.id) } }
                        }
                    }
                }
            }
            
            .overlay { if groups.isEmpty { ContentUnavailableView("No Bookmarks", systemImage: "book", description: Text("Use Bookmark in the ••• menu to save a page.")) } }
            .navigationTitle("Bookmarks").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct SpaceChip: View {
    let row: SpaceRow
    let selected: Bool
    let action: () -> Void
    var body: some View {
        let color = Color(hex: row.colorHex) ?? .accentColor
        Button(action: action) {
            Label(row.name, systemImage: row.isLocal ? "iphone" : "square.stack")
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? color.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The address field and what it finds, on the Space's colour.
/// Typing an address, Safari-style: the field stays at the foot of the screen with the
/// keyboard straight up under it, and suggestions stack upward from it, nearest first.
struct Suggestions: View {
    @Environment(Browser.self) private var browser
    @Environment(Library.self) private var library
    let space: SpaceRow?
    private var text: String { browser.query }
    var body: some View {
        // As tall as what it holds, scrolling only once that's more than the room above the bar.
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.never)
        }
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.top, 60)
    }

    @ViewBuilder private var list: some View {
        Group { if idle { start } else { matches } }
            .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Nothing typed yet (or only the page's own address).
    private var idle: Bool { text.isEmpty || text == browser.selected?.url.absoluteString }

    /// Before typing: the Space's favourites as icons, then where you've been lately.
    private var start: some View {
        let favourites = space.flatMap { $0.isIncognito ? nil : library.favourites(profile: $0.profileID) } ?? []
        var seen = Set<URL>()
        let recent = browser.allHistory.filter { seen.insert($0.url).inserted }.prefix(8)
        return VStack(alignment: .leading, spacing: 22) {
                if !favourites.isEmpty {
                    section("Favourites")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                        ForEach(favourites.prefix(12)) { link in
                            Button { go(link.url) } label: {
                                VStack(spacing: 6) {
                                    SiteIcon(url: link.url, size: 28)
                                        .frame(width: 60, height: 60)
                                        .background(GroundFill(strength: 1.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    Text(link.title).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !recent.isEmpty {
                    section("Recently Visited")
                    VStack(spacing: 2) {
                        ForEach(Array(recent), id: \.self) { visit in
                            Row(title: visit.title, icon: AnyView(SiteIcon(url: visit.url, size: 18))) { go(visit.url) } trailing: {
                                Text(visit.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                if favourites.isEmpty && recent.isEmpty {
                    Text("Search the web or type an address.").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            .padding(.vertical, 6)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    /// While typing: matches stacked up from the field, nearest first.
    private var matches: some View {
                VStack(spacing: 2) {
                    ForEach(browser.suggestions(for: text).reversed(), id: \.self) { visit in
                        Row(title: visit.title, icon: AnyView(SiteIcon(url: visit.url, size: 18))) { go(visit.url) } trailing: {
                            Text(visit.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let destination = browser.destination(for: text), !text.isEmpty {
                        let search = destination.absoluteString.contains("?q=")
                        Row(title: search ? "Search for \u{201C}\(text)\u{201D}" : destination.absoluteString,
                            icon: AnyView(Image(systemName: search ? "magnifyingglass" : "arrow.up.right"))) { go(destination) }
                    }
                }
    }

    private func go(_ url: URL?) { browser.go(url) }
}

struct SettingsView: View {
    @Environment(Sync.self) private var sync
    @Environment(Browser.self) private var browser
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var styleChanged = false
    var body: some View {
        @Bindable var sync = sync
        @Bindable var browser = browser
        @Bindable var library = library
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync with iCloud", isOn: $sync.enabled).disabled(!sync.available)
                    LabeledContent("Status", value: sync.busy ? "Syncing…" : sync.status)
                    if let last = sync.lastSuccess { LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened)) }
                    Toggle("Include browsing history", isOn: $library.syncHistory).disabled(!sync.enabled)
                    Button("Sync Now") { Task { await sync.run() } }.disabled(!sync.enabled || sync.busy)
                } header: { Text("iCloud") } footer: {
                    Text("Spaces, favourites, pinned tabs and folders, bookmarks and open tabs sync with Vane on your Mac through your private iCloud database. Nothing is sent to Vane.")
                }
                Section {
                    AppIconPicker()
                    Toggle("Streamlined", isOn: Binding(
                        get: { UserDefaults.standard.string(forKey: "interfaceStyle") == "streamlined" },
                        set: { UserDefaults.standard.set($0 ? "streamlined" : nil, forKey: "interfaceStyle"); styleChanged = true }))
                } header: { Text("Look") } footer: {
                    Text(styleChanged ? "Streamlined applies the next time Vane opens." : "Streamlined uses denser rows and tiles, as on the Mac. Each Space's colours and icon are set from its ••• menu.")
                }
                Section {
                    Button("Make Vane Your Default Browser") {
                        if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("Search") {
                    Picker("Search engine", selection: $browser.engine) { ForEach(SearchEngine.allCases) { Text($0.name).tag($0) } }
                }
                Section("History") {
                    NavigationLink("History") { HistoryView() }
                    Button("Clear History and Website Data", role: .destructive) { confirmClear = true }
                }
                Section {
                    Link("Privacy Policy", destination: URL(string: "https://github.com/notnaki/vane/blob/main/PRIVACY.md")!)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Clear history, cookies and website data on this device?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    browser.clearHistory()
                    if library.syncHistory { library.clearSyncedHistory() }
                }
            } message: {
                if library.syncHistory { Text("Synced history is also cleared on your other devices.") }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        List(query.isEmpty ? Array(browser.allHistory.prefix(500)) : browser.suggestions(for: query), id: \.self) { visit in
            Button { browser.open(visit.url); dismiss() } label: {
                VStack(alignment: .leading) {
                    Text(visit.title).lineLimit(1)
                    Text(visit.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        
        .searchable(text: $query)
        .overlay { if browser.allHistory.isEmpty { ContentUnavailableView("No History", systemImage: "clock") } }
        .navigationTitle("History")
    }
}

/// An open tab as Arc shows it on iPhone: the page as it last looked, its site and title
/// above, and a close button in the corner.
struct TabCard: View {
    let tab: Tab
    let selected: Bool
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SiteIcon(url: tab.url, size: 14)
                    Text(tab.title).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 22)
                }
                .padding(.horizontal, 4)
                Group {
                    if let snapshot = tab.snapshot {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(Color(.systemBackground))
                    } else {
                        // Not seen since launch: the site's icon on the Space's own fill, not a blank page.
                        SiteIcon(url: tab.url, size: 30).frame(maxWidth: .infinity, maxHeight: .infinity).background(GroundFill(strength: 1.3))
                    }
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Color.primary : .primary.opacity(0.08), lineWidth: selected ? 2 : 1))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                    .background(GroundFill(strength: 1.6), in: Circle())
                    .frame(width: 36, height: 36, alignment: .topTrailing).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(x: 4, y: -6)
            .accessibilityLabel("Close \(tab.title)")
        }
        .accessibilityLabel(tab.title)
    }
}

/// Chrome's pull-down actions over the top of the page: three icons in a row; a filled circle
/// follows the finger sideways, stretching toward it like a drop, and snaps to the nearest
/// action with its name underneath. Let go to do it.
struct PullActions: View {
    let pull: Tab.Pull
    /// The page's colour; the strip continues it, with icons that read on it.
    let color: UIColor?
    @Environment(\.colorScheme) private var scheme
    private let spacing: CGFloat = 96
    /// Dark when the colour is, so the icons flip to white on it.
    static func dark(_ color: UIColor?) -> ColorScheme? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0.5 else { return nil }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 ? .dark : .light
    }
    private let choices: [(Tab.PullChoice, String, String)] = [
        (.newTab, "plus", "New Tab"), (.reload, "arrow.clockwise", "Reload"), (.close, "xmark", "Close Tab"),
    ]
    var body: some View {
        let armed = pull.progress >= 1
        let snapped = CGFloat(pull.choice.rawValue) * spacing
        // The drop leans from its action toward the finger, a little, then lets go.
        let lean = max(-36, min(36, (max(-spacing, min(spacing, pull.dx)) - snapped) * 0.5))
        ZStack(alignment: .top) {
            Capsule().fill(.regularMaterial)
                .frame(width: 52 + abs(lean), height: 52 - abs(lean) * 0.12)
                .offset(x: snapped + lean / 2)
                .opacity(armed ? 1 : 0)
                .scaleEffect(armed ? 1 : 0.5)
            HStack(spacing: 0) {
                ForEach(choices, id: \.0) { choice, symbol, title in
                    let on = pull.choice == choice
                    VStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .rotationEffect(.degrees(choice == .reload ? Double(pull.progress) * 200 : 0))
                            .frame(width: 52, height: 52)
                        Text(title).font(.caption2.weight(.medium))
                            .opacity(on && armed ? 1 : 0)
                    }
                    .frame(width: spacing)
                    .opacity(on && armed ? 1 : 0.6)
                    .accessibilityLabel(title)
                }
            }
        }
        .padding(.top, 4)
        .opacity(Double(min(1, pull.progress * 1.6)))
        .offset(y: -20 * (1 - pull.progress))
        // The browser's own strip over the gap the page leaves as it's pulled down.
        // Exactly the gap: it never reaches over the page itself.
        .frame(maxWidth: .infinity)
        .frame(height: max(0, pull.depth), alignment: .center)
        .clipped()
        // The page's own colour, so the gap reads as more of the page rather than a black bar.
        .background(Color(color ?? .systemBackground).ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, Self.dark(color) ?? scheme)
        .animation(.spring(duration: 0.3, bounce: 0.35), value: pull.choice)
        .animation(.spring(duration: 0.3, bounce: 0.35), value: armed)
        .allowsHitTesting(false)
    }
}
