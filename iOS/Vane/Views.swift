import SwiftUI

extension Color {
    init?(hex: String?) {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @State private var sidebar = false
    @State private var address = false
    @State private var settings = false

    private var space: SpaceRow? { library.spaces.first { $0.id == browser.spaceID } }

    var body: some View {
        Group {
            if let tab = browser.selected {
                WebContainer(tab: tab).ignoresSafeArea(edges: .bottom).id(tab.id)
            } else {
                StartPage(open: { sidebar = false; browser.open($0.url, home: $0.url) })
            }
        }
        .safeAreaInset(edge: .bottom) { toolbar }
        .tint(Color(hex: space?.colorHex) ?? .accentColor)
        .sheet(isPresented: $sidebar) { Sidebar(settings: $settings, dismiss: { sidebar = false }).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $address) { AddressSheet(dismiss: { address = false }) }
        .sheet(isPresented: $settings) { SettingsView() }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { browser.selected?.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(browser.selected?.canGoBack != true).accessibilityLabel("Back")
            Button { browser.selected?.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(browser.selected?.canGoForward != true).accessibilityLabel("Forward")
            Button { address = true } label: {
                HStack {
                    Image(systemName: browser.selected?.url.scheme == "https" ? "lock.fill" : "magnifyingglass").font(.caption)
                    Text(browser.selected?.url.host() ?? "Search or enter address").lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(.primary).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(.quaternary, in: Capsule())
                .overlay(alignment: .bottom) {
                    if let tab = browser.selected, tab.progress < 1 {
                        ProgressView(value: tab.progress).progressViewStyle(.linear).padding(.horizontal, 12)
                    }
                }
            }
            .buttonStyle(.plain)
            Button { sidebar = true } label: {
                Image(systemName: "square.on.square").overlay { Text("\(browser.spaceTabs.count)").font(.system(size: 9, weight: .bold)) }
            }.accessibilityLabel("Tabs and Spaces")
            PageMenu(settings: $settings)
        }
        .font(.title3).padding(.horizontal).padding(.vertical, 8).background(.bar)
    }
}

struct PageMenu: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Binding var settings: Bool
    var body: some View {
        Menu {
            if let tab = browser.selected, let space = library.spaces.first(where: { $0.id == browser.spaceID }) {
                ShareLink(item: tab.url)
                Button("Reload", systemImage: "arrow.clockwise") { tab.webView.reload() }
                Button("Find on Page", systemImage: "doc.text.magnifyingglass") { tab.webView.findInteraction?.presentFindNavigator(showingReplace: false) }
                Button("Add to Favourites", systemImage: "star") { library.addFavourite(tab.url, profile: space.profileID) }
                Button("Pin to \(space.name)", systemImage: "pin") { library.addPinned(tab.url, title: tab.title, space: space) }
                Button("Close Tab", systemImage: "xmark", role: .destructive) { browser.close(tab) }
            }
            Button("Settings", systemImage: "gear") { settings = true }
        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
    }
}

struct Monogram: View {
    let link: LinkRow
    var body: some View {
        Text(String((link.url.host() ?? link.title).replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
            .font(.headline).frame(width: 44, height: 44)
            .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.tint)
    }
}

struct FavouritesGrid: View {
    @Environment(Library.self) private var library
    let profile: UUID
    let open: (LinkRow) -> Void
    var body: some View {
        let links = library.favourites(profile: profile)
        if !links.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 14) {
                ForEach(links) { link in
                    Button { open(link) } label: {
                        VStack(spacing: 6) { Monogram(link: link); Text(link.title).font(.caption2).lineLimit(1).foregroundStyle(.secondary) }
                    }
                    .contextMenu { Button("Remove Favourite", systemImage: "star.slash", role: .destructive) { library.remove(link.id) } }
                }
            }
        }
    }
}

struct StartPage: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    let open: (LinkRow) -> Void
    var body: some View {
        let space = library.spaces.first { $0.id == browser.spaceID }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(space?.name ?? "Vane").font(.largeTitle.bold())
                if let space {
                    FavouritesGrid(profile: space.profileID, open: open)
                    let pinned = library.pinned(space: space.id)
                    if !pinned.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pinned").font(.headline)
                            ForEach(pinned) { link in
                                Button { open(link) } label: { Label(link.title, systemImage: "pin").lineLimit(1) }
                            }
                        }
                    }
                }
                if library.favourites(profile: space?.profileID ?? Local.profile).isEmpty && library.pinned(space: browser.spaceID).isEmpty {
                    Text("Open a page and use the ••• menu to add it to Favourites or pin it to this Space.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Sidebar: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(Sync.self) private var sync
    @Binding var settings: Bool
    let dismiss: () -> Void
    @State private var naming: SpaceRow?
    @State private var creating = false
    @State private var name = ""
    @State private var deleting: SpaceRow?

    var body: some View {
        let space = library.spaces.first { $0.id == browser.spaceID }
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(library.spaces) { row in
                                SpaceChip(row: row, selected: row.id == browser.spaceID) { browser.switchSpace(row.id) }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") { name = row.name; naming = row }
                                        Button("Delete Space", systemImage: "trash", role: .destructive) { deleting = row }
                                    }
                            }
                            Button { name = ""; creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New Space")
                        }
                    }
                }
                if let space {
                    Section { FavouritesGrid(profile: space.profileID, open: open).padding(.vertical, 4) }
                    let pinned = library.pinned(space: space.id)
                    if !pinned.isEmpty {
                        Section("Pinned") {
                            ForEach(pinned) { link in
                                Button { open(link) } label: { Label(link.title, systemImage: "pin").lineLimit(1) }
                                    .swipeActions { Button("Unpin", role: .destructive) { library.remove(link.id) } }
                            }
                        }
                    }
                }
                Section("Tabs") {
                    Button { browser.select(nil); dismiss() } label: { Label("New Tab", systemImage: "plus") }
                    ForEach(browser.spaceTabs.reversed()) { tab in
                        Button { browser.select(tab); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Text(tab.title).lineLimit(1).fontWeight(tab.id == browser.selectedID ? .semibold : .regular)
                                Text(tab.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("Close", role: .destructive) { browser.close(tab) } }
                    }
                }
                ForEach(library.remoteTabs, id: \.device) { group in
                    Section("On \(group.device)") {
                        ForEach(group.tabs) { tab in
                            Button { browser.open(tab.url); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title).lineLimit(1)
                                    Text(tab.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !sync.enabled {
                    Section { Button("Turn on iCloud sync to see your Mac's Spaces") { settings = true } }
                }
            }
            .refreshable { await sync.run() }
            .navigationTitle(space?.name ?? "Spaces").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", action: dismiss) }
        }
        .alert("New Space", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") {
                guard !name.isEmpty else { return }
                let profile = space.map(\.profileID) ?? Local.profile
                browser.switchSpace(library.addSpace(name, profile: profile))
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Space", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") { if let naming, !name.isEmpty { library.renameSpace(naming, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this Space?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Space", role: .destructive) {
                guard let row = deleting else { return }
                browser.closeTabs(in: row.id)
                library.deleteSpace(row)
                if browser.spaceID == row.id, let first = library.spaces.first { browser.switchSpace(first.id) }
            }
        } message: {
            Text(deleting?.isLocal == true ? "Its tabs and pinned links will be removed." : "Its pinned tabs will also be removed from your other synced devices.")
        }
    }

    private func open(_ link: LinkRow) { browser.open(link.url, home: link.url); dismiss() }
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

struct AddressSheet: View {
    @Environment(Browser.self) private var browser
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            List {
                TextField("Search or enter address", text: $text)
                    .focused($focused).keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).onSubmit { go(browser.destination(for: text)) }
                ForEach(browser.suggestions(for: text), id: \.self) { visit in
                    Button { go(visit.url) } label: {
                        VStack(alignment: .leading) { Text(visit.title).lineLimit(1); Text(visit.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            .navigationTitle("Go to").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel", action: dismiss) }
        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    var body: some View {
        @Bindable var sync = sync
        @Bindable var browser = browser
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync with iCloud", isOn: $sync.enabled).disabled(!sync.available)
                    LabeledContent("Status", value: sync.busy ? "Syncing…" : sync.status)
                    if let last = sync.lastSuccess { LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened)) }
                    Button("Sync Now") { Task { await sync.run() } }.disabled(!sync.enabled || sync.busy)
                } header: { Text("iCloud") } footer: {
                    Text("Spaces, favourites, pinned tabs and open tabs sync with Vane on your Mac through your private iCloud database. Nothing is sent to Vane.")
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
                Button("Clear", role: .destructive) { browser.clearHistory() }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        List(query.isEmpty ? Array(browser.history.prefix(500)) : browser.suggestions(for: query), id: \.self) { visit in
            Button { browser.open(visit.url); dismiss() } label: {
                VStack(alignment: .leading) {
                    Text(visit.title).lineLimit(1)
                    Text(visit.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query)
        .overlay { if browser.history.isEmpty { ContentUnavailableView("No History", systemImage: "clock") } }
        .navigationTitle("History")
    }
}
