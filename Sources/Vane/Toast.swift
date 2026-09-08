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
        /// Settable so a toast that changes its mind — "Downloading… 42%", then "…43%" —
        /// keeps one identity and rewrites the pill in place instead of sliding a new one
        /// up from the sidebar's edge on every tick.
        var id = UUID()
        let text: String
        let action: (title: String, run: @MainActor () -> Void)?
        /// A sticky toast is up because something is still true, not because something just
        /// happened: no clock, and an × of its own. The updater is the only thing with one.
        var sticky = false
        /// The window it happened in, so only that window's sidebar draws it. On the toast
        /// rather than the store: a toast from a second window must not drag the one
        /// already showing into the wrong sidebar. `nil` means every window, which is what a
        /// toast about the app itself rather than about a page wants.
        var owner: ObjectIdentifier? = nil
    }

    /// The pure part: what is showing and what is waiting, so `check()` can prove the
    /// one-at-a-time rule without a run loop.
    struct Queue {
        private(set) var items: [Toast] = []
        /// Underneath the queue rather than in it. A sticky toast can sit there for an hour,
        /// and a queue that has to be *drained* past it would hold "Archived …" behind an
        /// update notice for exactly as long. So the ordinary toasts keep the pill while
        /// they have anything to say, and the sticky one is what is left when they stop —
        /// which is also the smaller change: `push`, `jump` and `dismiss` are untouched.
        private(set) var sticky: Toast?
        var current: Toast? { items.first ?? sticky }
        /// Two waiting toasts would be stale by the time the second one showed.
        static let waiting = 1

        mutating func push(_ toast: Toast) {
            items.append(toast)
            if items.count > 1 + Queue.waiting { items.remove(at: 1) }
        }

        /// In front of whatever is showing rather than behind it: for a toast that answers
        /// a keystroke made a moment ago, waiting its turn behind "Archived …" would put it
        /// on screen after the moment it is describing has gone.
        mutating func jump(_ toast: Toast) {
            items.insert(toast, at: 0)
            if items.count > 1 + Queue.waiting { items.removeLast() }
        }

        mutating func dismiss() {
            if !items.isEmpty { items.removeFirst() }
        }

        /// One sticky toast at a time: the second is the same update saying something newer,
        /// never a second thing to read.
        mutating func stick(_ toast: Toast) { sticky = toast }
        mutating func unstick() { sticky = nil }
    }

    static let shared = Toasts()

    @Published private(set) var queue = Queue()
    /// The pointer is on the pill: hold it. Set by the host's `onHover`.
    var hovering = false { didSet { if !hovering { schedule() } } }
    private var timer: Task<Void, Never>?

    var current: Toast? { queue.current }

    /// `store` is the window the event happened in; the menus pass nothing and get the key
    /// window, which is where the shortcut was pressed.
    static func show(_ text: String, action: (title: String, run: @MainActor () -> Void)? = nil,
                     in store: TabStore? = Windows.current) {
        let wasEmpty = shared.queue.current == nil
        shared.queue.push(Toast(text: text, action: action, owner: store.map(ObjectIdentifier.init)))
        if wasEmpty { shared.schedule() }
    }

    /// `show`, for the one toast that cannot wait: it goes in front of whatever is up and
    /// its own clock starts now. The ⌘Q warning is the only caller — it is the answer to a
    /// keystroke, and an answer that arrives after the hold it asks for is not one.
    static func showNow(_ text: String, in store: TabStore?) {
        shared.queue.jump(Toast(text: text, action: nil, owner: store.map(ObjectIdentifier.init)))
        shared.schedule()
    }

    /// A toast with no clock, showing under the ordinary ones until its × or its verb takes
    /// it away. `id` is the caller's, so the same pill can be rewritten as its news changes.
    static func stick(_ text: String, id: UUID,
                      action: (title: String, run: @MainActor () -> Void)? = nil) {
        shared.queue.stick(Toast(id: id, text: text, action: action, sticky: true))
        shared.schedule()
    }

    /// Only the toast that put it there can take it back, by id — a stale caller must not
    /// clear a notice that has since been replaced.
    static func unstick(_ id: UUID) {
        guard shared.queue.sticky?.id == id else { return }
        shared.queue.unstick()
        shared.schedule()
    }

    /// A toast's text as it is read out: the same sentence with its emphasis markers gone,
    /// so VoiceOver never says "star star v zero point two star star".
    nonisolated static func spoken(_ text: String) -> String {
        (try? AttributedString(markdown: text)).map { String($0.characters) } ?? text
    }

    /// The pill was pressed: take the toast away, then run the verb — "Undo" twice is not a
    /// thing, and the toast is what stops it being one. Away first, because a verb that
    /// puts a new toast up (the updater's "Update" does) would otherwise have it removed
    /// out from under it a line later.
    func act(_ toast: Toast) {
        dismiss(toast)
        toast.action?.run()
    }

    func dismiss(_ toast: Toast) {
        guard queue.current?.id == toast.id else { return }
        // The pill under the pointer is going; whatever comes next is not being hovered,
        // and `onHover(false)` never fires for a view that was removed.
        hovering = false
        if toast.sticky { queue.unstick() } else { queue.dismiss() }
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        // A sticky toast has no clock: it is there until the × or the verb, and a timer that
        // took it away would be the one bug this kind of toast exists to not have.
        guard let showing = queue.current, !showing.sticky else { return }
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
            if let toast = toasts.current,
               toast.owner == nil || toast.owner == ObjectIdentifier(store) {
                HStack(spacing: Look.inset) {
                    // An ordinary toast names a page, and a page's title truncates
                    // gracefully — a long one was never going to fit and the verb beside it
                    // is the point. A sticky one names a version, and a truncated version
                    // number is the one thing on the pill nobody can afford to lose. So it
                    // takes the sidebar's whole width and wraps rather than cutting, and
                    // the version itself is the bold half of the sentence.
                    Text(toast.sticky ? emphasised(toast.text) : AttributedString(toast.text))
                        // No `.font` for the sticky kind: a font on the view replaces the
                        // one the bold run carries, and the version stops being the bold
                        // half of the sentence. `emphasised` sets both weights itself.
                        .font(toast.sticky ? nil : Look.rowText)
                        .lineLimit(toast.sticky ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: toast.sticky ? .infinity : nil, alignment: .leading)
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
                    // Only the sticky kind. An ordinary toast is gone in three seconds, and
                    // an × on it would be a target that moves away while you aim at it.
                    if toast.sticky {
                        Button { toasts.dismiss(toast) } label: {
                            Image(systemName: "xmark")
                                .font(Look.rowGlyph)
                                .frame(width: Look.rowTarget, height: Look.rowTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Look.barText)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss \(Toasts.spoken(toast.text))")
                    }
                }
                .padding(.leading, Look.pillInset)
                .padding(.trailing, toast.action == nil && !toast.sticky
                                    ? Look.pillInset : Look.inset / 2)
                .padding(.vertical, toast.sticky ? Look.inset / 2 : 0)
                .frame(minHeight: Look.toastHeight)
                .background(Look.barFill, in: .capsule)
                .background(tint.opacity(Look.toastTint), in: .capsule)
                .background(Look.barMaterial, in: .capsule)
                .hairline(radius: Look.toastHeight / 2, Look.barStroke)
                .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
                .onHover { toasts.hovering = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Toasts.spoken(toast.text))
            }
        }
        // Never wider than the rows above it: a long title truncates rather than pushing the
        // pill past the sidebar's edges.
        .padding(.horizontal, Look.inset)
        .animation(reduceMotion ? nil : Look.list, value: toasts.current?.id)
        // Below the footer's edge is where the slide comes from; the sidebar itself clips it.
        .clipped()
    }

    /// The one piece of markup a toast is allowed: `**bold**`, and only on the sticky kind,
    /// where it is the version number. Parsed here rather than carried as two strings so a
    /// `Toast` stays one plain sentence — which is also what VoiceOver reads, see `spoken`.
    private func emphasised(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        out.font = Look.rowText
        for run in out.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            out[run.range].font = Look.rowText.bold()
        }
        return out
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
        let urgent = Toast(text: "urgent", action: nil)
        q.jump(urgent)
        out.append(("a toast that cannot wait goes in front of the one showing",
                    q.current?.id == urgent.id))
        q.dismiss()
        q.dismiss()
        out.append(("dismissing past empty is harmless", q.current == nil))

        // The sticky kind: an update notice that stays until it is answered.
        let update = Toast(text: "Vane v0.2.0 is available", action: nil, sticky: true)
        q.stick(update)
        out.append(("a sticky toast shows when nothing else is up", q.current?.id == update.id))
        out.append(("the clock never runs on it", q.current?.sticky == true))
        q.dismiss()
        out.append(("...so the timer's dismiss cannot take it away", q.current?.id == update.id))
        q.push(a)
        out.append(("an ordinary toast shows over it rather than queueing behind it",
                    q.current?.id == a.id))
        q.dismiss()
        out.append(("...and the sticky one comes back when that toast is done",
                    q.current?.id == update.id))
        let progress = Toast(id: update.id, text: "Downloading… 42%", action: nil, sticky: true)
        q.stick(progress)
        out.append(("the same update rewrites its own pill rather than stacking a second",
                    q.current?.text == "Downloading… 42%" && q.sticky?.id == update.id))
        q.unstick()
        out.append(("the × is the only thing that takes it away", q.current == nil))

        // The updater's wording, which is what the pill actually says.
        out.append(("the offer names the release, with the version as the bold half",
                    Updater.text(for: .available("v0.2.0")) == "Vane **v0.2.0** is available"))
        out.append(("...and VoiceOver reads the sentence, not the markers",
                    spoken(Updater.text(for: .available("v0.2.0"))) == "Vane v0.2.0 is available"))
        out.append(("a toast with no markup is read exactly as written",
                    spoken("Archived Swift Forums") == "Archived Swift Forums"))
        out.append(("progress is a whole percentage",
                    Updater.text(for: .downloading(0.4249)) == "Downloading… 42%"))
        out.append(("a finished download says what is left to do",
                    Updater.text(for: .ready) == "Drag Vane to Applications to finish"))
        out.append(("a failure says so", Updater.text(for: .failed) == "Update failed"))
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
