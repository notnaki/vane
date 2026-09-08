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
/// ponytail: no toast history and no stack — one ordinary toast at a time, replaced by
/// whatever happens next, because the verb on the newest is the only one anybody is
/// reaching for. Ceiling: a Notification-Center-style drawer of past toasts, which Arc
/// does not have either.
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
    /// replacement rules without a run loop.
    struct Queue {
        /// The ordinary toast on screen. There is only ever one: a second thing happening
        /// is not a pile to read, it is the news, and it takes the pill.
        private(set) var latest: Toast?
        /// The sticky one, kept apart because it does not age out and must not be the thing
        /// an ordinary toast replaces. It sits above: it has been there longest.
        private(set) var sticky: Toast?

        /// Top to bottom as drawn: the notice that is still true above, the thing that just
        /// happened below it and nearest the footer. Two pills is the most there can be.
        var showing: [Toast] { [sticky, latest].compactMap { $0 } }
        var current: Toast? { latest ?? sticky }

        /// Puts a toast up and hands back whichever one it pushed off, so the caller can
        /// stop that one's clock — a replaced toast must not come back to dismiss its
        /// successor three seconds later.
        @discardableResult mutating func push(_ toast: Toast) -> Toast? {
            defer { latest = toast }
            return latest
        }

        mutating func dismiss(_ id: UUID) {
            if latest?.id == id { latest = nil }
            if sticky?.id == id { sticky = nil }
        }

        /// One sticky toast at a time: the second is the same update saying something newer,
        /// never a second thing to read.
        mutating func stick(_ toast: Toast) { sticky = toast }
        mutating func unstick() { sticky = nil }
    }

    static let shared = Toasts()

    @Published private(set) var queue = Queue()
    /// Which pills the pointer is resting on. Per toast rather than one flag: holding the
    /// ordinary toast you are reaching for must not freeze the sticky notice above it.
    @Published private(set) var hovering: Set<UUID> = []
    /// One clock per toast, because each has its own `Prefs.toastSeconds`. Cancelled when
    /// it goes — including when a newer toast takes its place.
    private var timers: [UUID: Task<Void, Never>] = [:]

    var current: Toast? { queue.current }
    var showing: [Toast] { queue.showing }

    /// `store` is the window the event happened in; the menus pass nothing and get the key
    /// window, which is where the shortcut was pressed.
    static func show(_ text: String, action: (title: String, run: @MainActor () -> Void)? = nil,
                     in store: TabStore? = Windows.current) {
        shared.put(Toast(text: text, action: action, owner: store.map(ObjectIdentifier.init)))
    }

    /// `show`, for the one toast that cannot wait. The ⌘Q warning is the only caller — and
    /// since nothing queues any more, "now" is what every toast gets; this stays for the
    /// name at the call site.
    static func showNow(_ text: String, in store: TabStore?) {
        shared.put(Toast(text: text, action: nil, owner: store.map(ObjectIdentifier.init)))
    }

    /// Up it goes, and whatever was showing goes with it — clock, hover and all. Dropping
    /// the old one's timer here is the point: left running, it would wake up on the pill
    /// that replaced it and take *that* one away early.
    private func put(_ toast: Toast) {
        if let gone = queue.push(toast) {
            timers.removeValue(forKey: gone.id)?.cancel()
            hovering.remove(gone.id)
        }
        schedule(toast)
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
            try? await Task.sleep(for: .seconds(Prefs.toastSeconds))
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
        // Grows upward from the footer: the thing that just happened is the pill nearest
        // it, and the sticky notice — when there is one — rises above. A ZStack put them in
        // depth, where the second one is simply invisible.
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

    /// One row, always: the sentence on the left, its verb and its × on the right, centred
    /// on it. "Copied URL" hugs its words the way Arc's little pill does; "Archived <a very
    /// long page title>" wraps to a second line and the pill grows taller — it never becomes
    /// a paragraph with a button parked underneath it. The text takes whatever width the
    /// controls leave and gets two lines of it, so nothing is squeezed mid-word to make room
    /// for a button either.
    private func pill(_ toast: Toasts.Toast) -> some View {
        HStack(spacing: Look.inset) {
            text(toast)
            controls(toast)
        }
        .padding(.leading, Look.pillInset)
        // Every toast ends in an ×, and an × is a `rowTarget` square with its glyph small in
        // the middle of it: half an inset here is what leaves the glyph looking inset rather
        // than crowded against the pill's edge.
        .padding(.trailing, Look.inset / 2)
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
        // Every toast, not only the sticky one: the pointer resting on a pill already stops
        // its clock, so by the time you are anywhere near the × it has stopped moving away.
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
        let c = Toast(text: "c", action: nil)
        var out: [(String, Bool)] = [("nothing shows before anything happened", q.current == nil)]
        q.push(a)
        out.append(("the first toast shows at once", q.showing.map(\.id) == [a.id]))
        let gone = q.push(b)
        out.append(("a second replaces the first rather than stacking on it",
                    q.showing.map(\.id) == [b.id]))
        out.append(("...and the one it replaced is handed back, so its clock can be stopped",
                    gone?.id == a.id))
        q.push(c)
        out.append(("only ever the newest", q.current?.id == c.id))
        q.dismiss(a.id)
        out.append(("dismissing a toast that has already been replaced changes nothing",
                    q.showing.map(\.id) == [c.id]))
        q.dismiss(c.id)
        out.append(("the × empties the sidebar", q.current == nil))
        out.append(("dismissing past empty is harmless", { q.dismiss(c.id); return q.current == nil }()))

        // The sticky kind: an update notice that stays until it is answered.
        let update = Toast(text: "Vane **v0.2.0** is available", action: nil, sticky: true)
        q.stick(update)
        out.append(("a sticky toast shows on its own", q.showing.map(\.id) == [update.id]))
        out.append(("the clock never runs on it", q.current?.sticky == true))
        q.push(a)
        out.append(("an ordinary toast shows under it, not over it",
                    q.showing.map(\.id) == [update.id, a.id]))
        out.append(("...and it is the ordinary one the pointer's verb belongs to",
                    q.current?.id == a.id))
        q.push(b)
        out.append(("a newer one replaces the ordinary toast and leaves the notice alone",
                    q.showing.map(\.id) == [update.id, b.id]))
        out.append(("two pills is the most there can ever be", q.showing.count <= 2))
        q.dismiss(b.id)
        out.append(("...and the notice is still there when it has gone",
                    q.showing.map(\.id) == [update.id]))
        let progress = Toast(id: update.id, text: "Downloading… 42%", action: nil, sticky: true)
        q.stick(progress)
        out.append(("the same update rewrites its own pill rather than putting up a second",
                    q.showing.count == 1 && q.current?.text == "Downloading… 42%"))
        q.unstick()
        out.append(("the × is the only thing that takes it away", q.current == nil))

        // How long an ordinary toast stands, which is the user's to say now. The pref is
        // put back afterwards, so a check is never a preference change.
        out.append(("every offered duration is a real one",
                    Prefs.toastChoices.allSatisfy { $0.seconds > 0 }))
        out.append(("the default is one of the durations the setting offers",
                    Prefs.toastChoices.contains { $0.seconds == Look.toastDuration }))
        let held = UserDefaults.vane.object(forKey: "toastSeconds")
        defer { UserDefaults.vane.set(held, forKey: "toastSeconds") }
        UserDefaults.vane.removeObject(forKey: "toastSeconds")
        out.append(("with nothing chosen a toast stands for as long as it always did",
                    Prefs.toastSeconds == Look.toastDuration))
        Prefs.toastSeconds = Prefs.toastChoices.last!.seconds
        out.append(("...and a chosen one is what the clock reads",
                    Prefs.toastSeconds == Prefs.toastChoices.last!.seconds))

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
