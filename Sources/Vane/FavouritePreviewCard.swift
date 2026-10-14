import SwiftUI
import AppKit

/// Two hover regions with a transfer grace period. Keyboard opening is latched until dismissed.
@MainActor final class FavouritePreviewHover: ObservableObject {
    enum Region: Hashable { case tile, card }
    @Published private(set) var visible = false
    @Published private(set) var preparing = false
    private var regions: Set<Region> = []
    private var pending: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void
    private(set) var keyboardOpened = false

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }
    func setHovered(_ hovered: Bool, over region: Region) {
        if hovered { regions.insert(region) } else { regions.remove(region) }
        pending?.cancel(); pending = nil
        guard !keyboardOpened else { return }
        let opening = !regions.isEmpty
        if !opening && !visible { preparing = false }
        guard opening != visible else { return }
        let sleep = sleep
        pending = Task { @MainActor [weak self] in
            do {
                if opening {
                    try await sleep(.milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.preparing = true
                    try await sleep(.milliseconds(80))
                } else { try await sleep(.milliseconds(180)) }
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            if !opening { self.preparing = false }
            Motion.animate(Look.quick) { self.visible = opening }
            self.pending = nil
        }
    }
    func openForKeyboard() {
        pending?.cancel(); pending = nil; keyboardOpened = true
        Motion.animate(Look.quick) { visible = true }
    }
    func dismiss() {
        pending?.cancel(); pending = nil; regions.removeAll(); keyboardOpened = false
        preparing = false
        Motion.animate(Look.quick) { visible = false }
    }
}

struct FavouritePreviewCard: View {
    static let width: CGFloat = 240
    static let maxContentHeight: CGFloat = 270
    private static let rowHeight: CGFloat = 83
    let context: FavouritePreviewContext
    let state: FavouritePreviewState
    let open: (URL) -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusRequested = false
    @State private var visibleItemCount = 10
    var keyboardOpened: Bool = false

    private var surface: Color {
        colorScheme == .dark ? Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255) : Color(nsColor: .windowBackgroundColor)
    }
    private var snapshot: FavouritePreviewSnapshot? {
        switch state { case .ready(let value), .stale(let value): value; default: nil }
    }
    private var freshnessLabel: String {
        if case .stale = state { return "Saved preview" }
        return ""
    }
    private enum FocusTarget: Hashable { case none, site, item }
    private var focusTarget: FocusTarget {
        guard keyboardOpened else { return .none }
        if case .loading = state { return .none }
        return snapshot?.items.isEmpty == false ? .item : .site
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            previewContent
                .frame(width: Self.width, height: Self.maxContentHeight, alignment: .topLeading)
                .clipped()
            if case .stale = state {
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(surface, in: Circle())
                    .help("Saved preview · waiting for a fresh result")
                    .accessibilityLabel("Saved preview")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(9)
            }
            floatingAction.padding(9)
        }
        .frame(width: Self.width, height: Self.maxContentHeight)
        .background(surface)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
        .vaneMotionPolicy()
        .onChange(of: context) { _, _ in visibleItemCount = 10 }
        .onExitCommand(perform: dismiss)
        .task(id: focusTarget) {
            if focusTarget != .none {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                focusRequested = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(context.service.title) favourite preview")
        .accessibilityValue(freshnessLabel)
    }

    @ViewBuilder private var previewContent: some View {
        switch state {
        case .loading:
            VStack(spacing: 0) {
                ForEach(0..<4) { _ in
                    skeletonRow
                    separator
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading \(context.service.title) preview")
        case .signedOut:
            notice("Sign in to \(context.service.title)", detail: "Open the site to sign in with this profile.")
        case .unavailable:
            notice("Preview unavailable", detail: "Open the site to view the latest items.")
        case .ready(let value), .stale(let value):
            if value.items.isEmpty {
                notice(context.service == .github ? "No open pull requests" : context.service == .gmail ? "Your inbox is empty" : "No upcoming events", detail: "Open the site to view more.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(value.items.prefix(visibleItemCount))) { item in
                            VStack(spacing: 0) {
                                itemRow(item, first: item.id == value.items.first?.id, last: item.id == value.items.last?.id)
                                if item.id != value.items.last?.id { separator }
                            }
                            .frame(height: Self.rowHeight + (item.id == value.items.last?.id ? 0 : 0.5))
                            .onAppear {
                                if item.id == value.items.prefix(visibleItemCount).last?.id,
                                   visibleItemCount < value.items.count {
                                    visibleItemCount = min(visibleItemCount + 10, value.items.count)
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var separator: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }

    private func itemRow(_ item: FavouritePreviewItem, first: Bool, last: Bool) -> some View {
        Button { open(item.url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(context.service == .calendar ? item.title : item.subtitle)
                        .font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let time = item.timeLabel {
                        Text(time).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                }
                Text(context.service == .calendar ? item.startsAt?.formatted(date: .abbreviated, time: .shortened) ?? "Upcoming event" : item.title)
                    .font(.system(size: 13)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail(item)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.trailing, last ? 40 : 0)
                    .padding(.leading, last && !freshnessLabel.isEmpty ? 20 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(height: Self.rowHeight, alignment: .topLeading).contentShape(.rect)
        }
        .buttonStyle(.plain).focusable(false)
        .vaneKeyboardAction(radius: 6, requestFocus: first ? $focusRequested : .constant(false)) { open(item.url) }
        .accessibilityValue(item.unread ? "Unread" : "")
        .accessibilityHint(context.service == .gmail ? "Opens this message in a new tab in this favourite’s profile" : "Opens in a new tab in this favourite’s profile")
        .contextMenu {
            if let meeting = item.meetingURL { Button("Join Meeting") { open(meeting) } }
        }
    }

    private func detail(_ item: FavouritePreviewItem) -> String {
        switch context.service {
        case .gmail: return item.snippet ?? ""
        case .github:
            let number = item.url.lastPathComponent
            let status = item.status.flatMap { $0.isEmpty ? nil : $0 } ?? "Open pull request"
            return "#\(number) · \(status)"
        case .calendar: return item.meetingURL?.host ?? item.subtitle
        }
    }

    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                placeholder(width: 128, height: 13)
                Spacer()
                placeholder(width: 22, height: 10)
            }
            placeholder(width: 200, height: 12)
            placeholder(width: 207, height: 11)
            placeholder(width: 166, height: 11)
        }
        .padding(.horizontal, 11).padding(.vertical, 12)
        .frame(height: Self.rowHeight, alignment: .topLeading)
    }
    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)).frame(width: width, height: height)
    }

    private func notice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Open Site") { open(context.siteURL) }.buttonStyle(.plain).focusable(false)
                .vaneKeyboardAction(radius: 6, requestFocus: $focusRequested) { open(context.siteURL) }
                .font(.system(size: 12, weight: .medium)).padding(.top, 4)
        }
        .padding(11)
    }

    private var floatingAction: some View {
        let compose = context.composeURL
        let destination = compose ?? context.entryURL
        return Button { open(destination) } label: {
            Image(systemName: compose == nil ? "arrow.up.right" : "plus")
                .font(.system(size: 18, weight: .medium)).frame(width: 32, height: 32)
                .background(surface, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain).focusable(false)
        .vaneKeyboardAction(radius: 16) { open(destination) }
        .accessibilityLabel(compose == nil ? "Open \(context.service.title)" : "Compose")
        .help(compose == nil ? "Open \(context.service.title)" : "Compose a new message")
    }
}

/// Hover must not steal page focus, so Escape is handled for the owning window even
/// when the page or a different favourite remains first responder.
@MainActor private final class FavouritePreviewEscape: ObservableObject {
    private var monitor: Any?
    func attach(window: NSWindow?, dismiss: @escaping @MainActor () -> Void) {
        detach()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let consumed = MainActor.assumeIsolated {
                guard event.keyCode == 53, let window,
                      event.window === window || event.window?.parent === window else { return false }
                dismiss()
                return true
            }
            return consumed ? nil : event
        }
    }
    func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

private struct FavouritePreviewModifier: ViewModifier {
    @ObservedObject var tab: Tab
    let store: TabStore
    let restoreFocus: () -> Void
    @ObservedObject var hover: FavouritePreviewHover
    @ObservedObject private var previews = FavouritePreviews.shared
    @ObservedObject private var dragging = Dragging.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var owner = UUID()
    @StateObject private var escape = FavouritePreviewEscape()
    private var keyboardOpened: Bool { hover.keyboardOpened }
    @AppStorage("favouritePreviews") private var enabled = true
    @AppStorage("favouritePreviews.github") private var github = true
    @AppStorage("favouritePreviews.gmail") private var gmail = true
    @AppStorage("favouritePreviews.calendar") private var calendar = true

    private var context: FavouritePreviewContext? {
        (tab.homeURL ?? tab.currentURL).flatMap { FavouritePreviewContext(profileID: tab.profileID, url: $0) }
    }
    private var allowed: Bool {
        guard let context, enabled, store.renamingTab != tab.id, !dragging.active else { return false }
        switch context.service { case .github: return github; case .gmail: return gmail; case .calendar: return calendar }
    }
    func body(content: Content) -> some View {
        content
            .onHover { if allowed { hover.setHovered($0, over: .tile) } }
            .onExitCommand { close(returnFocus: true) }
            .contextMenu {
                if allowed {
                    Button("Show Favourite Preview") { showForKeyboard() }
                    Divider()
                }
                TabMenu(store: store, tab: tab)
            }
            .accessibilityActions {
                if allowed { Button("Show Favourite Preview") { showForKeyboard() } }
            }
            .background {
                if let context {
                    FavouritePreviewPanel(visible: hover.visible && allowed, keyboard: keyboardOpened,
                        content: AnyView(FavouritePreviewCard(context: context,
                            state: previews.owner == owner ? previews.state : .loading,
                            open: { url in
                                guard store.profileID == context.profileID else { return }
                                close(returnFocus: false)
                                store.newTab(url)
                            }, dismiss: { close(returnFocus: true) }, keyboardOpened: keyboardOpened)
                            .onHover { hover.setHovered($0, over: .card) }
                            .environment(\.colorScheme, colorScheme)), dismiss: { close(returnFocus: false) })
                }
            }
            .onChange(of: hover.preparing) { _, preparing in
                if preparing, allowed, let context {
                    previews.prepare(context, owner: owner, source: tab.existingWeb, privateSession: store.isPrivate)
                } else if !hover.visible { previews.dismiss(owner: owner) }
            }
            .onChange(of: hover.visible) { _, visible in
                if visible, allowed, let context {
                    escape.attach(window: store.window) { close(returnFocus: true) }
                    previews.request(context, owner: owner, source: tab.existingWeb, privateSession: store.isPrivate)
                } else { escape.detach(); previews.dismiss(owner: owner) }
            }
            .onChange(of: allowed) { _, allowed in if !allowed { close(returnFocus: false) } }
            .onChange(of: context) { _, _ in close(returnFocus: false) }
            .onChange(of: previews.owner) { _, id in if hover.visible && id != owner { close(returnFocus: false) } }
            .onDisappear { close(returnFocus: false) }
    }
    private func showForKeyboard() { hover.openForKeyboard() }
    private func close(returnFocus: Bool) {
        escape.detach()
        let restore = returnFocus && keyboardOpened
        hover.dismiss(); previews.dismiss(owner: owner)
        if restore {
            let focus = restoreFocus
            let window = store.window
            DispatchQueue.main.async { window?.makeKey(); focus() }
        }
    }
}

extension View {
    func favouritePreview(tab: Tab, store: TabStore, hover: FavouritePreviewHover, restoreFocus: @escaping () -> Void) -> some View {
        modifier(FavouritePreviewModifier(tab: tab, store: store, restoreFocus: restoreFocus, hover: hover))
    }
}
