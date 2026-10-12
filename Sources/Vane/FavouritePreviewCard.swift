import SwiftUI
import AppKit

/// Two hover regions with a transfer grace period. Keyboard opening is latched until dismissed.
@MainActor final class FavouritePreviewHover: ObservableObject {
    enum Region: Hashable { case tile, card }
    @Published private(set) var visible = false
    private var regions: Set<Region> = []
    private var pending: Task<Void, Never>?
    private(set) var keyboardOpened = false
    func setHovered(_ hovered: Bool, over region: Region) {
        if hovered { regions.insert(region) } else { regions.remove(region) }
        pending?.cancel(); pending = nil
        guard !keyboardOpened else { return }
        let opening = !regions.isEmpty
        guard opening != visible else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(opening ? 250 : 180)) } catch { return }
            guard let self else { return }
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
        Motion.animate(Look.quick) { visible = false }
    }
}

struct FavouritePreviewCard: View {
    let context: FavouritePreviewContext
    let state: FavouritePreviewState
    let open: (URL) -> Void
    let dismiss: () -> Void
    @State private var siteFocusRequested = false
    var keyboardOpened: Bool = false

    private var populatedInbox: Bool {
        guard context.service == .gmail else { return false }
        switch state { case .ready(let snapshot), .stale(let snapshot): return !snapshot.items.isEmpty; default: return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(populatedInbox ? "Inbox" : context.service.title).font(populatedInbox ? .subheadline : .headline)
                    if !populatedInbox { Text(context.service.heading).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).focusable(false)
                    .vaneKeyboardAction(radius: 6, action: dismiss).accessibilityLabel("Close favourite preview")
                    .help("Close preview (Escape)")
            }
            Group {
                switch state {
                case .loading:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading preview…").foregroundStyle(.secondary) }
                        .accessibilityElement(children: .combine)
                case .signedOut:
                    notice("Sign in to \(context.service.title)", detail: "Open the site to sign in with this profile.")
                case .unavailable:
                    notice("Preview unavailable", detail: "Vane couldn’t reliably read this page. Open the site to view the latest items.")
                case .ready(let snapshot): content(snapshot)
                case .stale(let snapshot):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Saved preview · couldn’t refresh", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        content(snapshot)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Open Site") { open(context.siteURL) }
                    .focusable(false)
                    .vaneKeyboardAction(radius: 6, requestFocus: $siteFocusRequested) { open(context.siteURL) }
                    .accessibilityHint("Opens \(context.service.title) in a new tab in this favourite’s profile")
                if let compose = context.composeURL {
                    if populatedInbox {
                        Spacer(minLength: 0)
                        Button { open(compose) } label: {
                            Image(systemName: "plus").font(.title3).frame(width: 32, height: 32)
                                .background(.quaternary, in: Circle())
                        }
                        .buttonStyle(.plain).focusable(false)
                        .vaneKeyboardAction(radius: 16) { open(compose) }
                        .accessibilityLabel("Compose").help("Compose a new message")
                        .accessibilityHint("Opens Gmail’s compose page. Does not send a message.")
                    } else {
                        Button("Compose") { open(compose) }.focusable(false)
                            .vaneKeyboardAction(radius: 6) { open(compose) }
                            .accessibilityHint("Opens Gmail’s compose page. Does not send a message.")
                    }
                }
                if !populatedInbox { Spacer(minLength: 0) }
            }
        }
        .padding(16).frame(width: 370, alignment: .leading)
        .background(Look.panelFill)
        .vaneMotionPolicy()
        .onExitCommand(perform: dismiss)
        .task(id: keyboardOpened) {
            // The hosting window must be attached before SwiftUI can move native focus.
            if keyboardOpened {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                siteFocusRequested = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(context.service.title) favourite preview")
    }

    private func notice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private func content(_ snapshot: FavouritePreviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if snapshot.items.isEmpty {
                Text(context.service == .github ? "No open pull requests involving you." : context.service == .gmail ? "Your inbox is empty." : "No upcoming events.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if context.service == .gmail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.items) { item in
                            Button { open(item.url) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        HStack(spacing: 6) {
                                            if item.unread { Circle().fill(Color.accentColor).frame(width: 5, height: 5).accessibilityHidden(true) }
                                            Text(item.subtitle).font(.subheadline).fontWeight(item.unread ? .bold : .semibold).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        if let time = item.timeLabel { Text(time).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Text(item.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.vertical, 10).padding(.horizontal, 4).contentShape(.rect)
                            }
                            .buttonStyle(.plain).focusable(false)
                            .vaneKeyboardAction(radius: 6) { open(item.url) }
                            .accessibilityValue(item.unread ? "Unread" : "Read")
                            .accessibilityHint("Opens this message in a new tab in this favourite’s profile")
                            if item.id != snapshot.items.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(snapshot.items.count) * 56, 300))
            } else {
                ForEach(snapshot.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { open(item.url) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                if item.unread {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 5)
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline).fontWeight(item.unread ? .semibold : .regular)
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    if let start = item.startsAt {
                                        Text(start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let status = item.status, !status.isEmpty {
                                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                            }.padding(7).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .vaneKeyboardAction(radius: 6) { open(item.url) }
                        .accessibilityValue(item.unread ? "Unread" : "")
                        .accessibilityHint("Opens in a new tab in this favourite’s profile")
                        if let meeting = item.meetingURL {
                            Button("Join Meeting") { open(meeting) }.focusable(false)
                                .vaneKeyboardAction(radius: 6) { open(meeting) }.font(.caption).padding(.leading, 7)
                        }
                    }
                }
            }
        }
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
