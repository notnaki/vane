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

    /// The pure part: what is on screen and in what order, so `check()` can prove the
    /// stacking rules without a run loop.
    struct Queue {
        /// Oldest first. Every one of them is drawn — nothing waits behind anything.
        private(set) var items: [Toast] = []
        /// The sticky one, kept apart because it does not age out and must not be the thing
        /// a cap drops. It sits at the top of the pile: it has been there longest.
        private(set) var sticky: Toast?
        /// Three is what a sidebar has room for above its footer without the stack becoming
        /// the sidebar. Past that the oldest ordinary toast goes — never the sticky one.
        static let visible = 3

        /// Top to bottom as drawn: the stack grows *upward* from the footer, so the newest
        /// toast is the one nearest it and the older ones rise above.
        var showing: [Toast] { (sticky.map { [$0] } ?? []) + items }
        var current: Toast? { showing.last }

        private mutating func trim() {
            let room = Queue.visible - (sticky == nil ? 0 : 1)
            if items.count > room { items.removeFirst(items.count - room) }
        }

        mutating func push(_ toast: Toast) {
            items.append(toast)
            trim()
        }

        /// `push`, for a toast that answers a keystroke made a moment ago. Once every toast
        /// is drawn at once there is no queue to jump — the newest is already the one
        /// nearest the pointer's eye — so this is `push` with a name that says why.
        mutating func jump(_ toast: Toast) { push(toast) }

        mutating func dismiss(_ id: UUID) {
            items.removeAll { $0.id == id }
            if sticky?.id == id { sticky = nil }
        }

        /// One sticky toast at a time: the second is the same update saying something newer,
        /// never a second thing to read.
        mutating func stick(_ toast: Toast) {
            sticky = toast
            trim()
        }
        mutating func unstick() { sticky = nil }
    }

    static let shared = Toasts()

    @Published private(set) var queue = Queue()
    /// Which pills the pointer is resting on. Per toast rather than one flag: with a stack,
    /// holding the one you are reaching for must not freeze the two above it.
    @Published private(set) var hovering: Set<UUID> = []
    /// One clock per toast, because each has its own three seconds. Cancelled when it goes.
    private var timers: [UUID: Task<Void, Never>] = [:]

    var current: Toast? { queue.current }
    var showing: [Toast] { queue.showing }

    /// `store` is the window the event happened in; the menus pass nothing and get the key
    /// window, which is where the shortcut was pressed.
    static func show(_ text: String, action: (title: String, run: @MainActor () -> Void)? = nil,
                     in store: TabStore? = Windows.current) {
        let toast = Toast(text: text, action: action, owner: store.map(ObjectIdentifier.init))
        shared.queue.push(toast)
        shared.schedule(toast)
    }

    /// `show`, for the one toast that cannot wait. The ⌘Q warning is the only caller.
    static func showNow(_ text: String, in store: TabStore?) {
        let toast = Toast(text: text, action: nil, owner: store.map(ObjectIdentifier.init))
        shared.queue.jump(toast)
        shared.schedule(toast)
    }

    /// A toast with no clock, showing until its × or its verb takes it away. `id` is the
    /// caller's, so the same pill can be rewritten as its news changes.
    static func stick(_ text: String, id: UUID,
                      action: (title: String, run: @MainActor () -> Void)? = nil) {
        shared.queue.stick(Toast(id: id, text: text, action: action, sticky: true))
    }

    /// Only the toast that put it there can take it back, by id — a stale caller must not
    /// clear a notice that has since been replaced.
    static func unstick(_ id: UUID) {
        guard shared.queue.sticky?.id == id else { return }
        shared.queue.unstick()
    }

    /// A toast's text as it is read out: the same sentence with its emphasis markers gone,
    /// so VoiceOver never says "star star v zero point two star star".
    nonisolated static func spoken(_ text: String) -> String {
        (try? AttributedString(markdown: text)).map { String($0.characters) } ?? text
    }

    func hover(_ toast: Toast, _ inside: Bool) {
        if inside { hovering.insert(toast.id) } else { hovering.remove(toast.id); schedule(toast) }
    }

    /// The pill was pressed: take the toast away, then run the verb — "Undo" twice is not a
    /// thing, and the toast is what stops it being one. Away first, because a verb that puts
    /// a new toast up (the updater's "Update" does) would otherwise have it removed out from
    /// under it a line later.
    func act(_ toast: Toast) {
        dismiss(toast)
        toast.action?.run()
    }

    func dismiss(_ toast: Toast) {
        timers.removeValue(forKey: toast.id)?.cancel()
        hovering.remove(toast.id)
        queue.dismiss(toast.id)
    }

    /// A sticky toast has no clock: it is there until the × or the verb, and a timer that
    /// took it away would be the one bug this kind of toast exists to not have.
    private func schedule(_ toast: Toast) {
        guard !toast.sticky else { return }
        timers[toast.id]?.cancel()
        timers[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Look.toastDuration))
            guard let self, !Task.isCancelled, !hovering.contains(toast.id) else { return }
            dismiss(toast)
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
        // Grows upward from the footer: the newest toast is the one nearest it, older ones
        // rise above, and none of them is ever behind another. A ZStack put them in depth,
        // where the second one is simply invisible.
        VStack(alignment: .leading, spacing: Look.rowGap) {
            ForEach(mine) { toast in
                pill(toast)
            }
        }
        // Never wider than the rows above it. The pill takes this width and lays itself out
        // inside it; nothing here is a fixed height, so a two-line toast is taller and the
        // sidebar's overlay simply has more of it to draw.
        .padding(.horizontal, Look.inset)
        .animation(reduceMotion ? nil : Look.list, value: mine.map(\.id))
        // Below the footer's edge is where the slide comes from; the sidebar itself clips it.
        .clipped()
    }

    /// One rule for every toast: say the whole thing, or take another line and say the whole
    /// thing. `ViewThatFits` asks the one-row form whether it fits at the sidebar's width and
    /// takes the stacked form when it does not — so "Copied URL" keeps Arc's little pill and
    /// "Archived hello world - a very long page title" gets its own line to wrap in, with the
    /// verb and the × underneath it. Nothing is ever cut mid-word to make room for a button.
    @ViewBuilder private func pill(_ toast: Toasts.Toast) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Look.inset) {
                // `fixedSize` on this one: it is what makes the row's ideal width the width
                // of the whole sentence, which is the question ViewThatFits is asking.
                text(toast).fixedSize()
                controls(toast)
            }
            VStack(alignment: .leading, spacing: Look.inset / 2) {
                text(toast).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Look.inset) {
                    Spacer(minLength: 0)
                    controls(toast)
                }
            }
        }
        .padding(.leading, Look.pillInset)
        .padding(.trailing, toast.action == nil && !toast.sticky
                            ? Look.pillInset : Look.inset / 2)
        .padding(.vertical, Look.inset / 2)
        .frame(minHeight: Look.toastHeight)
        // A corner, not a capsule: a capsule on a two-line pill is a lozenge. At one line
        // this radius *is* the capsule, so the short toast is unchanged.
        .background(Look.barFill, in: .rect(cornerRadius: Look.toastHeight / 2))
        .background(tint.opacity(Look.toastTint), in: .rect(cornerRadius: Look.toastHeight / 2))
        .background(Look.barMaterial, in: .rect(cornerRadius: Look.toastHeight / 2))
        .hairline(radius: Look.toastHeight / 2, Look.barStroke)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .onHover { toasts.hover(toast, $0) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .id(toast.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Toasts.spoken(toast.text))
    }

    /// The toasts this window is the one to draw: its own, plus the ones about the app
    /// itself, which have no window of their own.
    private var mine: [Toasts.Toast] {
        toasts.showing.filter { $0.owner == nil || $0.owner == ObjectIdentifier(store) }
    }

    private func text(_ toast: Toasts.Toast) -> some View {
        // No `.font` modifier — a font on the view replaces the one a bold run carries, and
        // the version would stop being the bold half of "Vane v0.2.0 is available";
        // `styled` sets both weights itself. Two lines is the ceiling: past that a toast is
        // an essay, and the tail can go.
        Text(styled(toast.text, emphasis: toast.sticky))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Look.barSelectedText)
    }

    @ViewBuilder private func controls(_ toast: Toasts.Toast) -> some View {
        if let action = toast.action {
            Button(action.title) { toasts.act(toast) }
                .buttonStyle(.plain)
                .font(Look.rowText)
                .fixedSize()            // a verb is a word; it never truncates
                .foregroundStyle(Look.barText)
                .padding(.horizontal, Look.inset)
                .frame(height: Look.control)
                .background(Look.barSelected, in: .capsule)
        }
        // Only the sticky kind. An ordinary toast is gone in three seconds, and an × on it
        // would be a target that moves away while you aim at it.
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

    /// A toast's text, ready to draw. `emphasis` parses the one piece of markup a toast is
    /// allowed — `**bold**`, the version number on the updater's pill. Off for every other
    /// toast, because a page title is not markup and "5 * 3 * 2" is not an italic.
    private func styled(_ text: String, emphasis: Bool) -> AttributedString {
        var out = emphasis ? ((try? AttributedString(markdown: text)) ?? AttributedString(text))
                           : AttributedString(text)
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
        let a = Toast(text: "a", action: nil), b = Toast(text: "b", action: nil)
        let c = Toast(text: "c", action: nil), d = Toast(text: "d", action: nil)
        var out: [(String, Bool)] = [("nothing shows before anything happened", q.current == nil)]
        q.push(a)
        out.append(("the first toast shows at once", q.showing.map(\.id) == [a.id]))
        q.push(b)
        out.append(("a second stacks beside it rather than waiting behind it",
                    q.showing.map(\.id) == [a.id, b.id]))
        q.push(c)
        out.append(("...and so does a third", q.showing.map(\.id) == [a.id, b.id, c.id]))
        out.append(("the newest is the one nearest the footer", q.current?.id == c.id))
        q.push(d)
        out.append(("a fourth pushes the oldest off rather than covering anything",
                    q.showing.map(\.id) == [b.id, c.id, d.id]))
        q.dismiss(c.id)
        out.append(("a toast can go from the middle of the stack",
                    q.showing.map(\.id) == [b.id, d.id]))
        let urgent = Toast(text: "urgent", action: nil)
        q.jump(urgent)
        out.append(("a toast that cannot wait is simply the newest, since none of them wait",
                    q.current?.id == urgent.id))
        q.dismiss(b.id); q.dismiss(d.id); q.dismiss(urgent.id)
        out.append(("dismissing past empty is harmless", q.current == nil))

        // The sticky kind: an update notice that stays until it is answered.
        let update = Toast(text: "Vane **v0.2.0** is available", action: nil, sticky: true)
        q.stick(update)
        out.append(("a sticky toast shows on its own", q.showing.map(\.id) == [update.id]))
        out.append(("the clock never runs on it", q.current?.sticky == true))
        q.push(a)
        out.append(("an ordinary toast stacks under it, not over it",
                    q.showing.map(\.id) == [update.id, a.id]))
        q.push(b); q.push(c)
        out.append(("the cap counts the sticky one but never drops it",
                    q.showing.map(\.id) == [update.id, b.id, c.id]))
        q.dismiss(b.id); q.dismiss(c.id)
        out.append(("...and it is still there when they have gone",
                    q.showing.map(\.id) == [update.id]))
        let progress = Toast(id: update.id, text: "Downloading… 42%", action: nil, sticky: true)
        q.stick(progress)
        out.append(("the same update rewrites its own pill rather than stacking a second",
                    q.showing.count == 1 && q.current?.text == "Downloading… 42%"))
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
        out.append(("a finished install leaves only the relaunch",
                    Updater.text(for: .ready) == "Restart to update"))
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
