import AppKit
import SwiftUI

/// Arc's toasts: a small pill that slides up from the bottom of the sidebar to say what just
/// happened — "Archived Swift Forums", "Copied URL" — sometimes with one verb beside it,
/// usually Undo. It goes on its own after `Look.toastDuration`; a pointer resting on it holds
/// it there, because the verb is the point and a moving target is not a button.
///
/// One store app-wide rather than one per window: there is one pointer, one keyboard and so
/// one event at a time worth telling the user about. `owner` remembers which window it
/// happened in, and only that window's sidebar draws it.
/// ponytail: no toast history, no stacking — a second toast waits behind the first, and a
/// third replaces the one waiting. Ceiling: a Notification-Center-style drawer of past
/// toasts, which Arc does not have either.
@MainActor final class Toasts: ObservableObject {
    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        let action: (title: String, run: @MainActor () -> Void)?
    }

    /// The pure part: what is showing and what is waiting, so `check()` can prove the
    /// one-at-a-time rule without a run loop.
    struct Queue {
        private(set) var items: [Toast] = []
        var current: Toast? { items.first }
        /// Two waiting toasts would be stale by the time the second one showed.
        static let waiting = 1

        mutating func push(_ toast: Toast) {
            items.append(toast)
            if items.count > 1 + Queue.waiting { items.remove(at: 1) }
        }

        mutating func dismiss() {
            if !items.isEmpty { items.removeFirst() }
        }
    }

    static let shared = Toasts()

    @Published private(set) var queue = Queue()
    private(set) weak var owner: TabStore?
    /// The pointer is on the pill: hold it. Set by the host's `onHover`.
    var hovering = false { didSet { if !hovering { schedule() } } }
    private var timer: Task<Void, Never>?

    var current: Toast? { queue.current }

    /// `store` is the window the event happened in; the menus pass nothing and get the key
    /// window, which is where the shortcut was pressed.
    static func show(_ text: String, action: (title: String, run: @MainActor () -> Void)? = nil,
                     in store: TabStore? = Windows.current) {
        shared.owner = store
        let wasEmpty = shared.queue.current == nil
        shared.queue.push(Toast(text: text, action: action))
        if wasEmpty { shared.schedule() }
    }

    /// The pill was pressed: run the verb, then take the toast away — "Undo" twice is not a
    /// thing, and the toast is what stops it being one.
    func act(_ toast: Toast) {
        toast.action?.run()
        dismiss(toast)
    }

    func dismiss(_ toast: Toast) {
        guard queue.current?.id == toast.id else { return }
        queue.dismiss()
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        guard let showing = queue.current else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Look.toastDuration))
            guard let self, !Task.isCancelled, !hovering else { return }
            dismiss(showing)
        }
    }
}

/// The pill. Lives in the sidebar's overlay just above the footer, and only in the window
/// the toast belongs to. Dark whatever the appearance, like the command bar, with the
/// space's colour washed over it: that is what makes it read as *this* space's toast.
struct ToastHost: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var toasts = Toasts.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if toasts.owner === store, let toast = toasts.current {
                HStack(spacing: Look.inset) {
                    Text(toast.text)
                        .font(Look.rowText)
                        .lineLimit(1)
                        .foregroundStyle(Look.barSelectedText)
                    if let action = toast.action {
                        Button(action.title) { toasts.act(toast) }
                            .buttonStyle(.plain)
                            .font(Look.rowText)
                            .foregroundStyle(Look.barText)
                            .padding(.horizontal, Look.inset)
                            .frame(height: Look.control)
                            .background(Look.barSelected, in: .capsule)
                    }
                }
                .padding(.leading, Look.pillInset)
                .padding(.trailing, toast.action == nil ? Look.pillInset : Look.inset / 2)
                .frame(height: Look.toastHeight)
                .background(Look.barFill, in: .capsule)
                .background(Look.barMaterial, in: .capsule)
                .overlay { tint.opacity(Look.toastTint).clipShape(.capsule).allowsHitTesting(false) }
                .hairline(radius: Look.toastHeight / 2, Look.barStroke)
                .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
                .onHover { toasts.hovering = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(toast.text)
            }
        }
        .animation(reduceMotion ? nil : Look.list, value: toasts.current?.id)
        // Below the footer's edge is where the slide comes from; the sidebar itself clips it.
        .clipped()
    }

    /// The space's colour, or the profile's outside any space.
    private var tint: Color {
        Color(hex: store.currentSpace?.colorHex ?? ProfileManager.shared.active.colorHex) ?? .clear
    }
}

// MARK: - check

extension Toasts {
    static func check() -> [(String, Bool)] {
        var q = Queue()
        let a = Toast(text: "a", action: nil), b = Toast(text: "b", action: nil), c = Toast(text: "c", action: nil)
        var out: [(String, Bool)] = [("nothing shows before anything happened", q.current == nil)]
        q.push(a)
        out.append(("the first toast shows at once", q.current?.id == a.id))
        q.push(b)
        out.append(("a second waits behind it rather than replacing it", q.current?.id == a.id))
        q.push(c)
        out.append(("a third replaces the one waiting: two stale toasts are worse than one",
                    q.items.map(\.id) == [a.id, c.id]))
        q.dismiss()
        out.append(("dismissing shows what was waiting", q.current?.id == c.id))
        q.dismiss()
        q.dismiss()
        out.append(("dismissing past empty is harmless", q.current == nil))
        return out
    }
}

// MARK: - ⌘W

extension TabStore {
    /// ⌘W with its toast: "Archived <title>", and Undo brings the page back out of the
    /// archive. A favourite or a pinned tab is only parked by ⌘W — nothing has left the
    /// sidebar, so there is nothing to say and nothing to undo.
    /// ponytail: Undo reopens the page as a new Today tab at the end of the list, not in the
    /// slot it left. Ceiling: remembering the index, which `unarchive` does not either.
    func archiveWithToast() {
        guard let tab = active else { return }
        let title = TidyTitles.title(for: tab), url = tab.currentURL, leaving = tab.kind == .today
        archive(tab.id)
        guard leaving else { return }
        // Only what `archiveNow` actually wrote down can be brought back from the archive.
        let restorable = !isPrivate && url?.scheme?.hasPrefix("http") == true
        var undo: (title: String, run: @MainActor () -> Void)?
        if restorable {
            undo = ("Undo", { [weak self] in
                guard let self, let url else { return }
                if let entry = Archive.shared(for: profileID).entries
                    .first(where: { $0.url == url.absoluteString }) {
                    unarchive(entry)
                } else {
                    newTab(url)
                }
            })
        }
        Toasts.show("Archived \(title)", action: undo, in: self)
    }
}
