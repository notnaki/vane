import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

struct BrowserWindow: View {
    @EnvironmentObject var store: TabStore
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
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
            }
        }
        .onChange(of: store.focusAddress) { addressFocused = true }
    }
}

/// ponytail: a rectangle, not ProgressView(.linear) — that style draws its own track and
/// rounded caps, which at 2pt reads as a stray dash sitting under the toolbar.
private struct LoadingBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.tint)
                .frame(width: geo.size.width * tab.progress)
                .animation(.easeOut(duration: 0.25), value: tab.progress)
        }
        .frame(height: 2)
        // Fades out on finish instead of vanishing, and never sweeps backwards when the
        // next navigation resets progress to zero behind the fade.
        .opacity(tab.loading ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: tab.loading)
        .allowsHitTesting(false)
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 72)          // traffic lights
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { TabChip(tab: $0) }
                }
            }
            Button { store.newTab(nil) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 6).help("New Tab (⌘T)")
            Spacer(minLength: 0)
            if store.isPrivate {
                Label("Private", systemImage: "eyeglasses")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                Text(tab.title).lineLimit(1).font(.system(size: 12))
                    .foregroundStyle(selected ? .primary : .secondary)
                // A pinned tab is a permanent fixture — no close button to fat-finger.
                if hovering || selected {
                    Button { store.close(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
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
            HStack(spacing: 6) { TabIcon(tab: tab); Text(tab.title).lineLimit(1).font(.system(size: 12)) }
                .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .dropDestination(for: String.self) { ids, _ in drop(ids) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
            Divider()
            Button("Close Tab") { store.close(tab.id) }
            Button("Close Other Tabs") {
                // Pinned tabs are not "other tabs" — closing them would undo the pin.
                for t in store.tabs where t.id != tab.id && !t.pinned { store.close(t.id) }
            }
        }
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
                Button { tab.toggleBookmark() } label: {
                    Image(systemName: tab.bookmarked ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.bookmarked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Bookmark This Page (⌘D)")
                DownloadsButton()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
    }
}

private struct NavButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Group {
            Button { tab.back() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button { tab.forward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button { tab.loading ? tab.stop() : tab.reload() } label: {
                Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
            }
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
        TextField("Search or enter address", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .focused($focused)
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
            .onMoveCommand { direction in
                switch direction {
                case .down: store.moveSuggestion(1)
                case .up:   store.moveSuggestion(-1)
                default:    break
                }
            }
            .onExitCommand { store.clearSuggestions(); focused = false }
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
                .onTapGesture {
                    if let u = URL(string: s.url) { store.active?.web.load(URLRequest(url: u)) }
                    store.clearSuggestions()
                }
            }
        }
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 14, y: 6)
        .padding(.top, 4)
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
            Button { search(forward: false) } label: { Image(systemName: "chevron.up") }
            Button { search(forward: true) }  label: { Image(systemName: "chevron.down") }
            Button { store.findOpen = false } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 10, y: 4)
        .onAppear { focused = true }
        .onExitCommand { store.findOpen = false }
    }

    private func search(forward: Bool) {
        Task { miss = !(await tab.find(text, forward: forward)) }
    }
}

private struct DownloadsButton: View {
    @ObservedObject var downloads = Downloads.shared
    @State private var open = false

    var body: some View {
        if !downloads.items.isEmpty {
            Button { open.toggle() } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                    .padding(14).frame(width: 320)
                }
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: Downloads.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name).lineLimit(1).font(.system(size: 12))
                Spacer(minLength: 8)
                if item.state == .done {
                    Button("Show") { Downloads.shared.reveal(item) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
                }
            }
            switch item.state {
            case .running: ProgressView(value: item.fraction).progressViewStyle(.linear)
            case .done:    EmptyView()
            case .failed(let why):
                Text(why).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
