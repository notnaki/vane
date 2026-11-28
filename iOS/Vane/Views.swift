import SwiftUI
import LocalAuthentication

/// Laid out like Arc Search: the page takes the screen, a short bar at its foot holds the tab
/// stack, + and the page menu; + (and coming back to Vane) opens search with the keyboard up.
/// With no page open, the Space's tabs sit side by side on its colours.
struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(\.scenePhase) private var phase
    @State private var settings = false
    @State private var noArticle = false
    @State private var mac = false
    @State private var archive = false
    @State private var themeDemo = false
    @State private var switcherDemo = false
    @State private var menu = false
    @State private var away: Date?
    @AppStorage("onboarded") private var onboarded = false

    private var space: SpaceRow? { library.space(browser.spaceID) }
    /// How far the keyboard reaches above the bottom safe area.
    @State private var keyboard: CGFloat = 0
    /// The keyboard on screen is for a field in the page, not the search sheet.
    @State private var pageKeyboard = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let tab = browser.selected {
                // The Space's colours behind everything; the page sits on them as a card.
                Wash(space: space, full: true)
                // The page is a card on the Space's colours, as on the Mac: it ends above the bar with
                // rounded corners (so its own fixed bars stay in view), and runs to the foot while reading.
                WebContainer(tab: tab).id(tab.id)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: tab.collapsed ? 0 : Look.pageRadius,
                                                      bottomTrailingRadius: tab.collapsed ? 0 : Look.pageRadius, style: .continuous))
                    .padding(.bottom, tab.collapsed ? 0 : Look.barRoom)
                    .ignoresSafeArea(edges: tab.collapsed ? [.top, .bottom] : .top)
                    .animation(.smooth(duration: 0.3), value: tab.collapsed)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                // Loading: a short rounded pill at the top of the screen, filling as the page loads.
                if tab.progress > 0, tab.progress < 1 {
                    LoadPill(progress: tab.progress)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }
                if let pull = tab.pull {
                    PullActions(pull: pull, color: tab.pageColor).frame(maxHeight: .infinity, alignment: .top)
                }
                // Reader is a mode of the tab: the article takes the page's place, under the same bar.
                if let article = tab.reading {
                    ReaderView(article: article).padding(.bottom, Look.barRoom).transition(.opacity)
                }
            } else {
                ZStack {
                    Wash(space: space, full: true)
                    TabSwitcher(openArchive: { archive = true })
                        .padding(.bottom, Look.barRoom)
                        .modifier(OnWash(space: space))
                }
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
            if menu, let tab = browser.selected, let space = space ?? library.spaces.first {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { menu = false }
                    .transition(.opacity)
                PageMenu(tab: tab, space: space, close: { menu = false }, noArticle: $noArticle)
                    .padding(.horizontal, 10).padding(.bottom, Look.barRoom + 6)
                    .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }
            BottomBar(space: space, menu: $menu, openSettings: { settings = true }, openMac: { mac = true })
                .modifier(OnWash(space: space))
                // Out of the way while typing into a page; the keyboard's own bar takes its place.
                .opacity(pageKeyboard ? 0 : 1)
            if browser.editing != nil {
                // The page or Space stays in view above the sheet, dimmed; a tap there cancels.
                Color.black.opacity(browser.selected == nil ? 0.08 : 0.3).ignoresSafeArea()
                    .onTapGesture { browser.editing = nil }
                    .transition(.opacity)
                SearchSheet(space: space)
                    .padding(.bottom, keyboard)
                    .transition(.move(edge: .bottom))
            }
        }
        // A page's keyboard covers the bar, as in Safari, instead of lifting the bar and squeezing
        // the page; WebKit scrolls the focused field into view itself. Only the search sheet rides it.
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let screen = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            // The frame is in screen space; an iPad window in Stage Manager or Split View isn't at its origin.
            let frame = window.convert(screen, from: window.screen.coordinateSpace)
            let cover = window.bounds.intersection(frame)
            // Only a keyboard along the bottom counts (iOS 27 insets its bar a little); a floating iPad one covers nothing here.
            let docked = !cover.isNull && cover.maxY >= window.bounds.maxY - 48 && cover.width >= window.bounds.width * 0.8
            let height = docked ? max(0, cover.height - window.safeAreaInsets.bottom) : 0
            // A keyboard that comes up while no search sheet is open belongs to the page.
            pageKeyboard = height > 0 && (browser.editing == nil || pageKeyboard)
            withAnimation(.smooth(duration: 0.25)) { keyboard = height }
        }
        .animation(.smooth(duration: 0.32), value: browser.editing)
        .animation(.smooth(duration: 0.3), value: browser.selectedID)
        .animation(.smooth(duration: 0.25), value: menu)
        .animation(.easeInOut(duration: 0.25), value: browser.selected?.reading)
        .onChange(of: browser.selectedID) { menu = false }
        .onChange(of: browser.editing) {
            // The card's picture is taken now, before the keyboard covers part of the page.
            if browser.editing != nil { menu = false; browser.selected?.takeSnapshot() }
        }
        .blur(radius: Frost.shared.sheets > 0 ? 18 : 0)
        .animation(.easeOut(duration: 0.3), value: Frost.shared.sheets > 0)
        .sheet(isPresented: $settings) { SettingsView().frostsBehind() }
        .sheet(isPresented: $mac) { MacView().frostsBehind() }
        .sheet(isPresented: $archive) { ArchiveView().frostsBehind() }
        .sheet(isPresented: $themeDemo) { if let space { ThemeEditor(space: space) } }
        .sheet(isPresented: $switcherDemo) { SpaceSwitcher() }
        .alert("Reader isn't available for this page", isPresented: $noArticle) {}
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) { Onboarding { onboarded = true } }
        .preferredColorScheme(space?.appearance == "dark" ? .dark : space?.appearance == "light" ? .light : nil)
        .tint(.primary)
        // Arc Search opens on a new search: at launch, and when you come back after a while.
        .onChange(of: phase) { _, phase in
            if phase == .background { away = .now }
            if phase == .active, let away, Date.now.timeIntervalSince(away) > 5 * 60, onboarded { search() }
        }
        .task { if onboarded { search() }; demo() }
    }

    private func search() {
        // Not over a link that just came in from another app, an open menu, or any sheet or dialog.
        let presenting = UIApplication.shared.connectedScenes.contains {
            ($0 as? UIWindowScene)?.keyWindow?.rootViewController?.presentedViewController != nil
        }
        guard browser.editing == nil, !menu, !presenting,
              Date.now.timeIntervalSince(browser.externalOpen ?? .distantPast) > 3 else { return }
        browser.editing = .newTab
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
        if let raw = defaults.string(forKey: "demoOpen"), let url = URL(string: raw) { browser.editing = nil; browser.open(url) }
        if let dx = defaults.object(forKey: "demoPull") as? String, let value = Double(dx) {
            Task { try? await Task.sleep(for: .seconds(5)); browser.selected?.pull = .init(progress: 1, choice: value < -45 ? .newTab : value > 45 ? .close : .reload, dx: value) }
        }
        if defaults.bool(forKey: "demoCollapsed") {
            Task { try? await Task.sleep(for: .seconds(5)); withAnimation { browser.selected?.collapsed = true } }
        }
        switch defaults.string(forKey: "demoPanel") {
        case "spaces": browser.editing = nil; browser.select(nil)
        case "tabs": browser.editing = nil; Task { try? await Task.sleep(for: .seconds(8)); browser.select(nil) }
        case "settings": settings = true
        case "address": browser.editing = .current
        case "search": browser.editing = .newTab
        case "menu": browser.editing = nil; Task { try? await Task.sleep(for: .seconds(3)); menu = true }
        case "archive": browser.editing = nil; archive = true
        case "theme": themeDemo = true
        case "switcher": browser.select(nil); switcherDemo = true
        default: break
        }
        #endif
    }
}

/// The page's load progress as a short capsule: a faint track and a brighter fill.
struct LoadPill: View {
    let progress: Double
    var body: some View {
        Capsule().fill(Color(white: 0.5).opacity(0.3))
            .frame(width: 120, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Color(white: 0.55)).frame(width: max(4, 120 * progress))
            }
            .padding(.top, 4)
            .animation(.easeOut(duration: 0.2), value: progress)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A round or capsule control on the bar: a soft white over the Space's colours.
struct BarFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        (environment.colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.5)).resolve(in: environment)
    }
}

/// Arc Search's bar: the last two tabs as a little stack on the left, + in the middle, the
/// page menu's chevron on the right, on the Space's colours. While reading it shrinks to the
/// site's name. With no page open: your Mac's tabs, + and Settings.
struct BottomBar: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let space: SpaceRow?
    @Binding var menu: Bool
    let openSettings: () -> Void
    let openMac: () -> Void
    @State private var sharing = false

    var body: some View {
        Group {
            if let tab = browser.selected, tab.collapsed, !menu {
                reading(tab)
            } else {
                bar.transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .sheet(isPresented: $sharing) { if let url = browser.selected?.url { ShareSheet(items: [url]).presentationDetents([.medium, .large]) } }
    }

    /// Reading: just the site, small, down in the home-indicator strip. A tap brings the bar back.
    private func reading(_ tab: Tab) -> some View {
        Button { withAnimation(.smooth(duration: 0.3)) { tab.collapsed = false } } label: {
            HStack(spacing: 6) {
                SiteIcon(url: tab.url, size: 12)
                Text(tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? "").font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, -18)
        .accessibilityLabel("Show controls, \(tab.url.host() ?? "")")
        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
    }

    private var bar: some View {
        let tab = browser.selected
        return HStack {
            Group {
                if let tab { TabStack(tab: tab, previous: browser.previous) } else {
                    round("desktopcomputer", label: "Your Mac", action: openMac)
                        .disabled(library.remoteTabs.isEmpty && library.bookmarks(profile: space?.profileID ?? Local.profile).isEmpty)
                }
            }
            .frame(width: 52, alignment: .leading)
            Spacer()
            Button { browser.editing = .newTab } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .regular))
                    .frame(width: 72, height: 32).background(BarFill(), in: Capsule()).contentShape(Capsule())
            }
            .accessibilityLabel("New Search")
            Spacer()
            Group {
                if tab != nil {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(menu ? 180 : 0))
                        .frame(width: 32, height: 32)
                        .background(menu ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(BarFill()), in: Circle())
                        .contentShape(Circle())
                        .onTapGesture { menu.toggle() }
                        // Holding the chevron goes straight to Share, as in Arc Search.
                        .onLongPressGesture { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); menu = false; sharing = true }
                        .accessibilityElement().accessibilityLabel("Page Menu").accessibilityAddTraits(.isButton)
                        .accessibilityAction { menu.toggle() }
                        .accessibilityAction(named: "Share") { sharing = true }
                } else {
                    round("gearshape", label: "Settings", action: openSettings)
                }
            }
            .frame(width: 52, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 26)
        .frame(height: Look.barHeight)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -Look.barSink)
        // The bar sits straight on the Space's colours, drawn behind the page and the tab view.
    }

    private func round(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32).background(BarFill(), in: Circle()).contentShape(Circle())
        }
        .accessibilityLabel(label)
    }
}

/// The bar's tab button: this tab and the one before it as two small cards. A tap opens the
/// tab switcher; a flick up swaps to the previous tab.
struct TabStack: View {
    @Environment(Browser.self) private var browser
    let tab: Tab
    let previous: Tab?
    @State private var lift: CGFloat = 0

    var body: some View {
        ZStack {
            if let previous { card(previous).rotationEffect(.degrees(-12)).offset(x: -6, y: 2) }
            card(tab).rotationEffect(.degrees(6)).offset(x: 5, y: lift)
        }
        .frame(width: 44, height: Look.barHeight)
        .contentShape(Rectangle())
        .onTapGesture { tab.takeSnapshot(); browser.select(nil) }
        .gesture(DragGesture(minimumDistance: 8).onChanged { value in
            lift = max(-14, min(0, value.translation.height * 0.4))
        }.onEnded { value in
            if value.translation.height < -24 || value.predictedEndTranslation.height < -60, let previous {
                UISelectionFeedbackGenerator().selectionChanged()
                browser.select(previous)
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { lift = 0 }
        })
        .accessibilityElement()
        .accessibilityLabel("Tabs, \(browser.spaceTabs.count) open")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tab.takeSnapshot(); browser.select(nil) }
        .accessibilityAction(named: "Previous Tab") { if let previous { browser.select(previous) } }
    }

    private func card(_ tab: Tab) -> some View {
        Group {
            if let snapshot = tab.snapshot {
                Image(uiImage: snapshot).resizable().scaledToFill().frame(width: 19, height: 26, alignment: .top)
            } else {
                SiteIcon(url: tab.url, size: 11).frame(width: 19, height: 26)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// The chevron's menu, above the bar: the address (tap to edit, or copy it), Back, Forward,
/// Reload and Share as tiles, then the page's own actions.
struct PageMenu: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let tab: Tab
    let space: SpaceRow
    let close: () -> Void
    @Binding var noArticle: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { close(); browser.editing = .current } label: {
                    HStack(spacing: 8) {
                        SiteIcon(url: tab.url, size: 16)
                        Text(tab.url.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: ""))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Edit Address, \(tab.url.host() ?? "")")
                Button { UIPasteboard.general.url = tab.url; UINotificationFeedbackGenerator().notificationOccurred(.success); close() } label: {
                    Image(systemName: "doc.on.doc").font(.subheadline)
                }
                .accessibilityLabel("Copy Address")
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).frame(height: 40)
            .background(GroundFill(strength: 1.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 8) {
                tile("Back", "chevron.backward") { tab.webView.goBack() }.disabled(!tab.canGoBack)
                tile("Forward", "chevron.forward") { tab.webView.goForward() }.disabled(!tab.canGoForward)
                tile("Reload", "arrow.clockwise") { tab.webView.reload(); close() }
                ShareLink(item: tab.url) { tileLabel("Share", "square.and.arrow.up") }
            }
            VStack(spacing: 0) {
                if !space.isIncognito {
                    // Each way to keep the page, filled when it already is one; tapping again undoes it.
                    let favourite = library.favourites(profile: space.profileID).first { $0.url == tab.url }
                    let pin = library.pinned(space: space.id).first { $0.url == tab.url }
                    item(favourite == nil ? "Add to Favourites" : "Remove from Favourites", favourite == nil ? "star" : "star.fill") {
                        if let favourite { library.remove(favourite.id) } else { library.addFavourite(tab.url, profile: space.profileID) }
                    }
                    item(pin == nil ? "Pin to \(space.name)" : "Unpin", pin == nil ? "pin" : "pin.fill") {
                        if let pin { library.remove(pin.id) } else { library.addPinned(tab.url, title: tab.title, space: space) }
                    }
                }
                item(tab.reading == nil ? "Reader" : "Close Reader", tab.reading == nil ? "doc.plaintext" : "doc.plaintext.fill") {
                    if tab.reading != nil { tab.reading = nil } else { Task { tab.reading = await tab.article(); noArticle = tab.reading == nil } }
                }
                item("Find on Page", "text.magnifyingglass") {
                    tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
                }
                item("Close Tab", "xmark", role: .destructive) { withAnimation(.smooth(duration: 0.3)) { browser.close(tab) } }
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, symbol) }
    }
    private func tileLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(GroundFill(strength: 1.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
    private func item(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role) { action(); close() } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol).frame(width: 22)
            }
            .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12).frame(height: 44)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 12) }
    }
}

/// The system share sheet, for a long press on the chevron.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Arc Search's tab view: the Space's tabs as cards side by side on its colours, oldest on
/// the left. Swipe a card up to close it. The Space's name and dots sit on top, its favourites
/// under them, and the archive past the oldest card.
struct TabSwitcher: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let openArchive: () -> Void
    @State private var switching = false
    @State private var theming = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var creating = false
    @State private var name = ""
    @State private var naming: LinkRow?

    var body: some View {
        let space = library.space(browser.spaceID)
        let tabs = browser.spaceTabs
        VStack(spacing: 0) {
            header(space)
            if let space, !space.isIncognito { favourites(space) }
            if tabs.isEmpty {
                empty(space).frame(maxHeight: .infinity)
            } else {
                carousel(tabs)
            }
        }
        .sheet(isPresented: $switching) { SpaceSwitcher() }
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
        .alert("New Space", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") {
                guard !name.isEmpty else { return }
                browser.switchSpace(library.addSpace(name, profile: space.flatMap { $0.isIncognito ? nil : $0.profileID } ?? Local.profile))
            }
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

    /// The Space's name (tap to pick another) with its options, and a dot per Space.
    private func header(_ space: SpaceRow?) -> some View {
        let pages = library.spaces + [.incognito]
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { switching = true } label: {
                    HStack(spacing: 7) {
                        if let space { SpaceMark(space: space, size: 15) }
                        Text(space?.name ?? "Vane").font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 36).contentShape(Capsule())
                }
                .accessibilityLabel("Space, \(space?.name ?? ""). Switch Space")
                if let space, !space.isIncognito {
                    Menu {
                        Button("Edit Theme and Icon", systemImage: "paintpalette") { theming = true }
                        Button("Rename", systemImage: "pencil") { name = space.name; renaming = true }
                        Button("New Space", systemImage: "plus") { name = ""; creating = true }
                        Button("Delete Space", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                            .background(BarFill(), in: Circle())
                    }
                    .accessibilityLabel("Space options")
                }
            }
            HStack(spacing: 0) {
                ForEach(pages) { page in
                    let here = page.id == browser.spaceID
                    Button { withAnimation(.smooth) { browser.switchSpace(page.id) } } label: {
                        Circle().fill(.primary.opacity(here ? 0.85 : 0.25)).frame(width: 6, height: 6).frame(width: 24, height: 30).contentShape(Rectangle())
                    }
                    .accessibilityLabel(page.name)
                    .accessibilityAddTraits(here ? .isSelected : [])
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        // Swipe sideways on the name to move between Spaces.
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            let ids = pages.map(\.id)
            guard abs(value.translation.width) > 50, let index = ids.firstIndex(of: browser.spaceID) else { return }
            let next = index + (value.translation.width < 0 ? 1 : -1)
            guard ids.indices.contains(next) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.smooth) { browser.switchSpace(ids[next]) }
        })
    }

    private func favourites(_ space: SpaceRow) -> some View {
        let links = library.favourites(profile: space.profileID)
        // One row, scrolling sideways when there are more, so the tab cards keep the room.
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(links) { link in
                    Button { browser.open(link.url, home: link.url) } label: {
                        SiteIcon(url: link.url, size: 20)
                            .frame(width: 58, height: 44)
                            .background(BarFill(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressFill())
                    .accessibilityLabel(link.title)
                    .contextMenu {
                        Text(link.title)
                        Button("Rename", systemImage: "pencil") { name = link.title; naming = link }
                        Button("Remove Favourite", systemImage: "star.slash", role: .destructive) { library.remove(link.id) }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.top, 14)
        .frame(maxWidth: 520)
    }

    private func carousel(_ tabs: [Tab]) -> some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.6, 300)
            let height = min(geo.size.height - 70, width * 1.85)
            let archived = browser.archived.contains { $0.spaceID == browser.spaceID }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .center, spacing: 14) {
                    if archived {
                        Button(action: openArchive) {
                            VStack(spacing: 6) {
                                Image(systemName: "archivebox").font(.system(size: 18, weight: .medium))
                                Text("Archive").font(.caption2.weight(.medium))
                            }
                            .frame(width: 64, height: 88).background(BarFill(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(tabs) { tab in
                        TabCard(tab: tab, width: width, height: height)
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .scrollTargetLayout()
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, (geo.size.width - width) / 2, for: .scrollContent)
            .defaultScrollAnchor(.trailing)
            .scrollClipDisabled()
        }
        .padding(.top, 8)
    }

    private func empty(_ space: SpaceRow?) -> some View {
        VStack(spacing: 10) {
            Text(space?.isIncognito == true ? "You're browsing Incognito" : "No open tabs").font(.headline)
            Text(space?.isIncognito == true ? "Nothing here is saved or synced. Close the last tab and it's gone." : "Tap + to search or open a page.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if browser.archived.contains(where: { $0.spaceID == browser.spaceID }) {
                Button("Archived Tabs", systemImage: "archivebox", action: openArchive).font(.subheadline.weight(.medium)).padding(.top, 6)
            }
        }
        .padding(.horizontal, 40)
    }
}

/// An open tab in the switcher: its site and title above, the page as it last looked below.
/// Swipe it up to close it.
struct TabCard: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let tab: Tab
    let width: CGFloat
    let height: CGFloat
    @State private var lift: CGFloat = 0

    var body: some View {
        let space = library.space(tab.spaceID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SiteIcon(url: tab.url, size: 14)
                Text(tab.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .padding(.leading, 4)
            .opacity(1 - Double(min(1, -lift / 120)))
            Group {
                if let snapshot = tab.snapshot {
                    Image(uiImage: snapshot).resizable().scaledToFill()
                        .frame(width: width, height: height, alignment: .top)
                } else {
                    // Not seen since launch: the site's icon, not a blank page.
                    SiteIcon(url: tab.url, size: 36).frame(width: width, height: height)
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { browser.select(tab) }
            .contextMenu {
                if let space, !space.isIncognito {
                    Button("Add to Favourites", systemImage: "star") { library.addFavourite(tab.url, profile: space.profileID) }
                    Button("Pin to \(space.name)", systemImage: "pin") { library.addPinned(tab.url, title: tab.title, space: space) }
                }
                Button("Close Tab", systemImage: "xmark", role: .destructive) { close() }
            }
        }
        .frame(width: width)
        .offset(y: lift)
        .opacity(1 - Double(min(0.6, -lift / 400)))
        // Up closes, like the app switcher. A UIKit pan that only starts on an upward drag, so
        // sideways drags always reach the carousel's scroll (a SwiftUI drag here swallows some).
        .gesture(UpwardPan { pan in
            let dy = pan.translation(in: pan.view).y
            switch pan.state {
            case .began, .changed: lift = min(0, dy)
            default:
                if pan.state == .ended, lift < -120 || (lift < -20 && pan.velocity(in: pan.view).y < -600) {
                    withAnimation(.easeOut(duration: 0.2)) { lift = -height } completion: { close() }
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { lift = 0 }
                }
            }
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { browser.select(tab) }
        .accessibilityAction(named: "Close Tab") { close() }
    }

    private func close() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.3)) { browser.close(tab) }
    }
}

/// Searching, as Arc Search does it: a sheet up from the bottom with the field on top and the
/// keyboard already up; the Space's favourites and pinned tabs wait between them.
struct SearchSheet: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let space: SpaceRow?
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool
    private var text: String { browser.query }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.subheadline.weight(.medium)).opacity(0.5)
                    TextField("Search…", text: Binding(get: { browser.query }, set: { browser.query = $0 }), selection: $selection)
                        .focused($focused).keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { browser.go(browser.destination(for: browser.query)) }
                    if !text.isEmpty {
                        Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.4) }
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 12).frame(height: 44)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if text.isEmpty, browser.editing == .newTab {
                    // Arc Search's Incognito switch, beside the field.
                    let on = space?.isIncognito == true
                    Button {
                        let back = browser.beforeIncognito.flatMap { id in library.spaces.first { $0.id == id }?.id }
                        browser.switchSpace(on ? back ?? library.spaces.first?.id ?? Local.space : SpaceRow.incognito.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text("Incognito").font(.subheadline.weight(.medium))
                            Image(systemName: on ? "eyeglasses.slash" : "eyeglasses")
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(on ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(Color(.systemBackground)),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(on ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
            .animation(.smooth(duration: 0.2), value: text.isEmpty)
            ScrollView {
                Group { if idle { start } else { matches } }
                    .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: 600)
        .background(Color(.secondarySystemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous))
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom).padding(.top, 26))
        .padding(.top, browser.selected == nil ? 110 : 70)
        .onAppear(perform: begin)
        .onChange(of: browser.editing) { begin() }
    }

    private func begin() {
        guard let editing = browser.editing else { return }
        // Editing the page you're on starts from its address, all selected so typing replaces it.
        let query = editing == .newTab ? "" : browser.selected?.url.absoluteString ?? ""
        browser.query = query
        selection = TextSelection(range: query.startIndex..<query.endIndex)
        focused = true
    }

    /// Nothing typed yet (or only the page's own address).
    private var idle: Bool { text.isEmpty || text == browser.selected?.url.absoluteString }

    /// Before typing: the Space's favourites and pinned tabs, then where you've been lately.
    @ViewBuilder private var start: some View {
        let keeps = space.map { !$0.isIncognito } ?? false
        let favourites = keeps ? library.favourites(profile: space!.profileID) : []
        let pinned = keeps ? library.pinned(space: space!.id) : []
        let folders = keeps ? library.folders(space: space!.id) : []
        var seen = Set<URL>()
        let recent = space?.isIncognito == true ? [] : Array(browser.allHistory.filter { seen.insert($0.url).inserted }.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            if UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs {
                // The system's paste button reads the clipboard without the paste prompt; it goes straight there.
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in browser.go(browser.destination(for: strings.first ?? "")) }
                }
                .buttonBorderShape(.capsule).labelStyle(.titleAndIcon).tint(.secondary)
                .padding(.top, 6)
            }
            if !favourites.isEmpty {
                section("Favourites")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                    ForEach(favourites.prefix(12)) { link in
                        Button { browser.editing = nil; browser.open(link.url, home: link.url) } label: {
                            VStack(spacing: 5) {
                                SiteIcon(url: link.url, size: 24)
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(link.title).font(.caption2).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !pinned.isEmpty || !folders.isEmpty, let space {
                section("Pinned · \(space.name)")
                VStack(spacing: 2) { PinnedRows(space: space.id) { link in browser.editing = nil; browser.open(link.url, home: link.url) } }
            }
            if !recent.isEmpty {
                section("Recently Visited")
                VStack(spacing: 2) {
                    ForEach(recent, id: \.self) { visit in
                        Row(title: visit.title, icon: AnyView(SiteIcon(url: visit.url, size: 18))) { browser.go(visit.url) } trailing: {
                            Text(host(visit.url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if space?.isIncognito == true {
                Text("You're browsing Incognito").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 14)
    }

    /// While typing: the search (or address) first, then history matches.
    private var matches: some View {
        VStack(spacing: 2) {
            if let destination = browser.destination(for: text) {
                let search = destination.absoluteString.contains("?q=")
                Row(title: search ? "Search for \u{201C}\(text)\u{201D}" : destination.absoluteString,
                    icon: AnyView(Image(systemName: search ? "magnifyingglass" : "arrow.up.right"))) { browser.go(destination) }
            }
            ForEach(browser.suggestions(for: text), id: \.self) { visit in
                Row(title: visit.title, icon: AnyView(SiteIcon(url: visit.url, size: 18))) { browser.go(visit.url) } trailing: {
                    Text(host(visit.url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.top, 4)
    }

    private func host(_ url: URL) -> String { url.host()?.replacingOccurrences(of: "www.", with: "") ?? "" }
}

/// Your Mac: its open tabs (and other devices'), and the bookmarks synced from it.
struct MacView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let profile = library.space(browser.spaceID).flatMap { $0.isIncognito ? nil : $0.profileID } ?? Local.profile
        NavigationStack {
            List {
                if !library.bookmarks(profile: profile).isEmpty {
                    NavigationLink { BookmarksView(onOpen: { dismiss() }) } label: { Label("Bookmarks", systemImage: "book") }
                }
                ForEach(library.remoteTabs, id: \.device) { group in
                    Section(group.device) {
                        ForEach(group.tabs) { tab in
                            Button { browser.open(tab.url); dismiss() } label: {
                                HStack(spacing: 12) {
                                    SiteIcon(url: tab.url, size: 20)
                                    VStack(alignment: .leading) {
                                        Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title).lineLimit(1)
                                        Text(tab.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if library.remoteTabs.isEmpty && library.bookmarks(profile: profile).isEmpty { ContentUnavailableView("Nothing from your Mac yet", systemImage: "desktopcomputer", description: Text("Turn on iCloud sync in Settings on both devices.")) } }
            .navigationTitle("Your Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Tabs archived after sitting unopened, newest first, with how long tabs may sit.
struct ArchiveView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        @Bindable var browser = browser
        let items = browser.archived.filter {
            $0.spaceID == browser.spaceID && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query))
        }
        let calendar = Calendar.current
        let groups: [(String, [Archived])] = [
            ("Today", items.filter { calendar.isDateInToday($0.at) }),
            ("Yesterday", items.filter { calendar.isDateInYesterday($0.at) }),
            ("Earlier", items.filter { !calendar.isDateInToday($0.at) && !calendar.isDateInYesterday($0.at) }),
        ].filter { !$0.1.isEmpty }
        NavigationStack {
            List {
                ForEach(groups, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { item in
                            Button { browser.unarchive(item); dismiss() } label: {
                                HStack(spacing: 12) {
                                    SiteIcon(url: item.url, size: 20)
                                    VStack(alignment: .leading) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    ArchivePicker(value: $browser.archiveAfter)
                } footer: { Text("Tabs you haven't opened in this long move here. Tabs opened from a favourite or pinned tab stay.") }
            }
            .searchable(text: $query, prompt: "Search archive")
            .overlay { if items.isEmpty && query.isEmpty { ContentUnavailableView("No archived tabs", systemImage: "archivebox") } }
            .navigationTitle("Archived Tabs").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct ArchivePicker: View {
    @Binding var value: Double
    var body: some View {
        Picker("Archive tabs", selection: $value) {
            Text("After 12 hours").tag(43_200.0)
            Text("After 1 day").tag(86_400.0)
            Text("After 7 days").tag(604_800.0)
            Text("After 30 days").tag(2_592_000.0)
            Text("Never").tag(0.0)
        }
    }
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
                    if folder.today && folder.links.isEmpty && folder.folders.isEmpty {
                        Text("A Today folder: its tabs stay on your Mac.").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                    }
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
    let onOpen: () -> Void
    var body: some View {
        let profile = library.spaces.first { $0.id == browser.spaceID }?.profileID ?? Local.profile
        let groups = library.bookmarks(profile: profile)
            List {
                ForEach(groups, id: \.folder) { group in
                    Section(group.folder ?? "Bookmarks") {
                        ForEach(group.links) { link in
                            Button { browser.open(link.url); onOpen() } label: {
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

            .overlay { if groups.isEmpty { ContentUnavailableView("No Bookmarks", systemImage: "book", description: Text("Bookmarks you save in Vane on your Mac show up here.")) } }
            .navigationTitle("Bookmarks").navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// Imports the Mac backup at `file` once it is set, asking for its password when it has one.
    func macBackupImport(_ file: Binding<URL?>) -> some View { modifier(MacBackupImport(file: file)) }
}

private struct MacBackupImport: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var file: URL?
    @State private var data: Data?
    @State private var asking = false
    @State private var password = ""
    @State private var wrong = false
    @State private var message: String?
    func body(content: Content) -> some View {
        content
            .onChange(of: file, initial: true) {
                guard let url = file else { return }
                file = nil
                do { data = try MacBackup.read(url); run(nil) } catch { message = error.localizedDescription }
            }
            .alert("Backup Password", isPresented: $asking) {
                SecureField("Password", text: $password)
                Button("Import") { run(password) }
                Button("Cancel", role: .cancel) { data = nil }
            } message: { Text(wrong ? BackupError.unlockFailed.localizedDescription : "Enter the password this backup was exported with.") }
            .alert("Import from Mac Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
    }
    private func run(_ password: String?) {
        guard let data else { return }
        self.password = ""; wrong = false
        Task {
            do {
                // Unlocking runs 600,000 PBKDF2 rounds; keep it off the main thread.
                let records = try await Task.detached { try MacBackup.records(data, password: password) }.value
                try await library.importBackup(records)
                self.data = nil
                let spaces = records.filter { $0.category == .spaces }.count
                message = "Imported \(spaces) \(spaces == 1 ? "Space" : "Spaces") with their pinned tabs and folders, and your favourites."
            } catch BackupError.passwordRequired {
                asking = true
            } catch BackupError.unlockFailed {
                wrong = true; asking = true
            } catch {
                self.data = nil
                message = error.localizedDescription
            }
        }
    }
}

struct SettingsView: View {
    @Environment(Sync.self) private var sync
    @Environment(Browser.self) private var browser
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var styleChanged = false
    @State private var choosing = false
    @State private var backup: URL?
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
                    Button("Import from Mac Backup…") { choosing = true }
                } footer: {
                    Text("Brings in the Spaces, favourites, pinned tabs and folders from a backup exported in Vane on your Mac. Importing again updates them.")
                }
                Section {
                    AppIconPicker()
                    Toggle("Streamlined", isOn: Binding(
                        get: { UserDefaults.standard.string(forKey: "interfaceStyle") == "streamlined" },
                        set: { UserDefaults.standard.set($0 ? "streamlined" : nil, forKey: "interfaceStyle"); styleChanged = true }))
                } header: { Text("Look") } footer: {
                    Text(styleChanged ? "Streamlined applies the next time Vane opens." : "Streamlined uses denser rows and tiles, as on the Mac. Each Space's colours and icon are set from its ••• menu.")
                }
                if Look.canBeDefaultBrowser {
                    Section {
                        Button("Make Vane Your Default Browser") {
                            if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Section {
                    ArchivePicker(value: $browser.archiveAfter)
                } header: { Text("Tabs") } footer: { Text("Like Arc, tabs you haven't opened in a while move to the archive at the start of the tab view.") }
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
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.vaneBackup]) { backup = try? $0.get() }
            .macBackupImport($backup)
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
            Capsule().fill(.primary.opacity(0.26))
                .frame(width: 52 + abs(lean), height: 52 - abs(lean) * 0.12)
                .offset(x: snapped + lean / 2)
                // Shows the choice from early in the pull, faint until it's armed.
                .opacity(armed ? 1 : Double(pull.progress) * 0.45)
                .scaleEffect(armed ? 1 : 0.6 + 0.3 * pull.progress)
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
                    .opacity(on ? 1 : 0.4)
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

/// Every Space, grouped under its profile as on the Mac, with Incognito and New Space below.
struct SpaceSwitcher: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        let groups = Dictionary(grouping: library.spaces, by: \.profileID)
        let order = library.spaces.map(\.profileID).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(order, id: \.self) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile == Local.profile ? "On This iPhone" : library.profileName(profile) ?? "Profile")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                            ForEach(groups[profile] ?? []) { space in row(space) }
                        }
                    }
                    VStack(spacing: 2) {
                        row(.incognito)
                        Row(title: "New Space", icon: AnyView(Image(systemName: "plus").fontWeight(.medium))) { name = ""; creating = true }
                    }
                }
                .padding(Look.inset)
            }
            .navigationTitle("Spaces").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
        .presentationDetents([.medium, .large])
        .frostsBehind()
        .alert("New Space", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") {
                guard !name.isEmpty else { return }
                let profile = library.space(browser.spaceID).flatMap { $0.isIncognito ? nil : $0.profileID } ?? Local.profile
                browser.switchSpace(library.addSpace(name, profile: profile)); dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func row(_ space: SpaceRow) -> some View {
        Row(title: space.name, selected: space.id == browser.spaceID, icon: AnyView(SpaceMark(space: space, size: 17))) {
            withAnimation(.smooth) { browser.switchSpace(space.id) }
            dismiss()
        } trailing: {
            if space.id == browser.spaceID { Image(systemName: "checkmark").font(.footnote.weight(.semibold)) }
        }
    }
}

/// A pan that begins only when the drag starts out upward, leaving every other drag to the scroll view.
struct UpwardPan: UIGestureRecognizerRepresentable {
    let changed: (UIPanGestureRecognizer) -> Void
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }
    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) { changed(pan) }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return v.y < 0 && abs(v.y) > abs(v.x) * 1.5
        }
    }
}
