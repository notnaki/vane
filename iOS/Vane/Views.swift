import SwiftUI
import LocalAuthentication

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @State private var spaces = false
    @State private var address = false
    @State private var settings = false
    @State private var reader: Article?
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
            } else {
                SpaceColumn(space: space, close: {}, openSettings: { settings = true })
                    .safeAreaPadding(.bottom, Look.barHeight)
                    .transition(.opacity)
            }
            BottomBar(space: space, spaces: $spaces, address: $address, menu: menu)
        }
        .animation(.smooth(duration: 0.3), value: browser.selectedID)
        .blur(radius: Frost.shared.sheets > 0 ? 18 : 0)
        .animation(.easeOut(duration: 0.3), value: Frost.shared.sheets > 0)
        .sheet(isPresented: $spaces) {
            SpacesPanel(close: { spaces = false }, openSettings: { spaces = false; settings = true })
        }
        .sheet(isPresented: $address) { AddressSheet(space: space, dismiss: { address = false }) }
        .sheet(isPresented: $settings) { SettingsView().frostsBehind().presentationBackground { Wash(space: space) } }
        .sheet(item: $reader) { ReaderView(article: $0) }
        .sheet(isPresented: $themeDemo) { if let space { ThemeEditor(space: space) } }
        .sheet(isPresented: $bookmarks) { BookmarksView().frostsBehind().presentationBackground { Wash(space: space) } }
        .alert("Reader isn't available for this page", isPresented: $noArticle) {}
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) { Onboarding { onboarded = true } }
        .preferredColorScheme(space?.appearance == "dark" ? .dark : space?.appearance == "light" ? .light : nil)
        .tint(.primary)
        .task { demo() }
    }

    @ViewBuilder private var menu: some View {
        if let tab = browser.selected, let space {
            ControlGroup {
                Button("Back", systemImage: "chevron.backward") { tab.webView.goBack() }.disabled(!tab.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { tab.webView.goForward() }.disabled(!tab.canGoForward)
                Button("Reload", systemImage: "arrow.clockwise") { tab.webView.reload() }
                ShareLink(item: tab.url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button("Reader", systemImage: "doc.plaintext") { Task { reader = await tab.article(); noArticle = reader == nil } }
            Button("Find on Page", systemImage: "text.magnifyingglass") { tab.webView.findInteraction?.presentFindNavigator(showingReplace: false) }
            if !space.isIncognito { Section {
                Button("Add to Favourites", systemImage: "star") { library.addFavourite(tab.url, profile: space.profileID) }
                Button("Pin to \(space.name)", systemImage: "pin") { library.addPinned(tab.url, title: tab.title, space: space) }
                if let key = library.bookmarked(tab.url, profile: space.profileID) {
                    Button("Remove Bookmark", systemImage: "bookmark.slash") { library.remove(key) }
                } else {
                    Button("Bookmark", systemImage: "bookmark") { library.addBookmark(tab.url, title: tab.title, profile: space.profileID) }
                }
            } }
            Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
        }
        Section {
            if space?.isIncognito == true {
                Button("Leave Incognito", systemImage: "eyeglasses") { leaveIncognito() }
            } else {
                Button("New Incognito Tab", systemImage: "eyeglasses") { browser.switchSpace(SpaceRow.incognito.id); browser.select(nil) }
            }
            Button("Bookmarks", systemImage: "book") { bookmarks = true }
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
        if defaults.bool(forKey: "demoCollapsed") {
            Task { try? await Task.sleep(for: .seconds(5)); withAnimation { browser.selected?.collapsed = true } }
        }
        switch defaults.string(forKey: "demoPanel") {
        case "spaces": spaces = true
        case "settings": settings = true
        case "address": address = true
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
    @Binding var spaces: Bool
    @Binding var address: Bool
    let menu: Menu
    @State private var nudge: CGFloat = 0

    var body: some View {
        if let tab = browser.selected, tab.collapsed {
            // Reading: just the site, small, out of the way. A tap brings the bar back.
            Button { withAnimation(.smooth(duration: 0.3)) { tab.collapsed = false } } label: {
                HStack(spacing: 6) {
                    SiteIcon(url: tab.url, size: 12)
                    Text(tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background { Wash(space: space).clipShape(Capsule()) }
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
            // On a page: the Space and its tabs. On the Space itself (which already shows them):
            // back to the last tab, or nothing to do when there isn't one.
            Button { if tab == nil, let last { browser.select(last) } else { tab?.takeSnapshot(); spaces = true } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary, lineWidth: 1.6).frame(width: 21, height: 21)
                    Text("\(browser.spaceTabs.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 44, height: 44).contentShape(Circle())
            }
            .disabled(tab == nil && last == nil)
            .opacity(tab == nil && last == nil ? 0.35 : 1)
            .accessibilityLabel(tab == nil ? "Back to \(last?.title ?? "tab")" : "Spaces and tabs, \(browser.spaceTabs.count) open")

            Button { address = true } label: {
                HStack(spacing: 8) {
                    if let tab {
                        SiteIcon(url: tab.url, size: 16)
                        Text(tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? tab.title).lineLimit(1)
                    } else {
                        Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium))
                        Text("Search or enter address").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
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
                .background(GroundFill(strength: 1.4), in: Capsule())
                .clipShape(Capsule())
            }
            .accessibilityLabel(tab.map { "Address, \($0.url.host() ?? "")" } ?? "Search or enter address")

            SwiftUI.Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).contentShape(Circle())
            }
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .padding(4)
        .background { Wash(space: space).clipShape(Capsule()) }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        .frame(maxWidth: 560)
        .padding(.horizontal, 14).padding(.bottom, 2)
        .offset(x: nudge)
        .simultaneousGesture(DragGesture(minimumDistance: 24).onChanged { value in
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
}

/// Every Space side by side, swiped between like the Mac sidebar, over the current Space's
/// colour. The footer holds the Space marks, as at the foot of the Mac sidebar.
struct SpacesPanel: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let close: () -> Void
    let openSettings: () -> Void
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        let current = library.space(browser.spaceID)
        let pages = library.spaces + [.incognito]
        VStack(spacing: 0) {
            TabView(selection: Binding(get: { browser.spaceID }, set: { browser.switchSpace($0) })) {
                ForEach(pages) { space in
                    SpaceColumn(space: space, close: close, openSettings: openSettings).tag(space.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The same capsule as the page bar, so the panel ends where the bar was.
            HStack(spacing: 2) {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(pages) { space in
                            let current = space.id == browser.spaceID
                            Button { withAnimation(.smooth) { browser.switchSpace(space.id) } } label: {
                                SpaceMark(space: space, size: 17)
                                    .opacity(current ? 1 : 0.5)
                                    .frame(width: 44, height: 44)
                                    .background(current ? AnyShapeStyle(GroundFill(strength: 2)) : AnyShapeStyle(.clear), in: Circle())
                            }
                            .accessibilityLabel(space.name)
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Button { name = ""; creating = true } label: { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Circle()) }
                    .accessibilityLabel("New Space")
                Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(Circle()) }
                    .accessibilityLabel("Settings")
            }
            .font(.system(size: 17, weight: .medium))
            .buttonStyle(.plain)
            .padding(4)
            .background(GroundFill(), in: Capsule())
            .padding(.horizontal, 14).padding(.bottom, -6)
        }
        .padding(.top, 8)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .frostsBehind()
        .presentationBackground { Wash(space: current) }
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
                        browser.select(nil); close()
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
            if let space {
                SpaceMark(space: space, size: 17).frame(width: 36, height: 36).background(GroundFill(), in: Circle())
            }
            Text(space?.name ?? "Vane").font(.title2.weight(.semibold)).lineLimit(1)
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(article.site).font(.subheadline).foregroundStyle(.secondary)
                    Text(article.title).font(.system(.largeTitle, design: .serif).bold())
                    ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                        Text(block.text)
                            .font(block.heading ? .system(.title2, design: .serif).bold() : .system(.body, design: .serif))
                            .lineSpacing(5).textSelection(.enabled)
                    }
                }
                .padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
            .toolbar { Button("Done") { dismiss() } }
        }
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
            .scrollContentBackground(.hidden)
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
struct AddressSheet: View {
    @Environment(Browser.self) private var browser
    let space: SpaceRow?
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.body.weight(.medium)).opacity(0.6)
                TextField("Search or enter address", text: $text)
                    .focused($focused).keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).onSubmit { go(browser.destination(for: text)) }
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.45) }
                        .buttonStyle(.plain).accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14).frame(height: 50)
            .background(GroundFill(strength: 1.6), in: RoundedRectangle(cornerRadius: Look.pillRadius, style: .continuous))
            ScrollView {
                VStack(spacing: 2) {
                    if let destination = browser.destination(for: text), !text.isEmpty {
                        Row(title: destination.host() == nil || destination.absoluteString.contains("?q=") ? "Search for \u{201C}\(text)\u{201D}" : destination.absoluteString,
                            icon: AnyView(Image(systemName: destination.absoluteString.contains("?q=") ? "magnifyingglass" : "arrow.up.right"))) { go(destination) }
                    }
                    ForEach(browser.suggestions(for: text), id: \.self) { visit in
                        Row(title: visit.title, icon: AnyView(SiteIcon(url: visit.url, size: 18))) { go(visit.url) } trailing: {
                            Text(visit.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, Look.inset).padding(.top, 18)
        .presentationDetents([.large])
        .frostsBehind()
        .presentationBackground { Wash(space: space) }
        .onAppear { text = browser.selected?.url.absoluteString ?? ""; focused = true }
    }
    private func go(_ url: URL?) {
        guard let url else { return }
        browser.open(url, newTab: browser.selected == nil)
        dismiss()
    }
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
            .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
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
                    } else {
                        SiteIcon(url: tab.url, size: 34).frame(maxWidth: .infinity, maxHeight: .infinity).background(GroundFill(strength: 1.2))
                    }
                }
                .frame(height: 190)
                .background(Color(.systemBackground))
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
