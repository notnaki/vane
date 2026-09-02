import AppKit
import SwiftUI

// MARK: - Matching

/// The command palette's matcher, and the offline checks that prove it.
///
/// Everything in this enum is a pure function of its arguments — no window server, no
/// database, no network — so `vane selfcheck --pure` can assert the ranking on a headless
/// box. The view below is the only part that touches the app.
enum Palette {
    /// Score `target` against `query`, or nil when `query` is not a subsequence of it.
    /// Higher is better. Case-insensitive. An empty query matches everything, flatly, so
    /// the palette can open showing its whole list.
    ///
    /// ponytail: a greedy leftmost subsequence walk, not an optimal alignment. Ceiling: a
    /// target that repeats the query's leading letters can be scored on a worse alignment
    /// than the best one available. That is invisible at the length of a tab title or a
    /// url; the day it isn't, the fix is Smith-Waterman, not more bonus terms.
    static func score(_ query: String, _ target: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(target.lowercased())
        var qi = 0, structural = 0, previous = -2
        for (i, c) in t.enumerated() {
            guard qi < q.count else { break }
            guard c == q[qi] else { continue }
            structural += 1
            if i == 0 {
                structural += 12                                  // matched at the very start
            } else if !t[i - 1].isLetter && !t[i - 1].isNumber {
                structural += 6                                   // matched at the start of a word
            }
            if i == previous + 1 { structural += 8 }              // extends a contiguous run
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Target length is scaled into the last two digits: a shorter target breaks a tie
        // and can never outrank a structurally better match.
        return structural * 100 - min(t.count, 99)
    }

    /// Filter to what matches, best first. Stable — equal scores keep their input order,
    /// which is what makes the list predictable between keystrokes (and testable).
    static func rank<T>(_ query: String, _ items: [T], key: (T) -> String) -> [T] {
        var hits: [(score: Int, order: Int, item: T)] = []
        for (i, item) in items.enumerated() {
            if let s = score(query, key(item)) { hits.append((s, i, item)) }
        }
        hits.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return hits.map(\.item)
    }

    static func check() -> [(String, Bool)] {
        // Force-unwrapped inside the assertions on purpose: a nil here is the failure the
        // line above it already checks for, so it can only fire if the checks disagree.
        let words = ["GitHub", "Gitlab", "git", "Hacker News"]
        return [
            ("query characters match in order", score("gh", "GitHub") != nil),
            ("the same characters out of order do not match", score("hg", "GitHub") == nil),
            ("matched characters may be scattered", score("gtb", "GitHub") != nil),
            ("a query longer than the target never matches", score("github!", "GitHub") == nil),
            ("no match returns nothing, not a zero score", score("zzz", "GitHub") == nil),
            ("a partly-matching query still returns nothing", score("gitx", "GitHub") == nil),

            ("matching is case-insensitive", score("GH", "github") == score("gh", "GitHub")),
            ("case does not change the ranking",
             score("git", "Git") == score("GIT", "git")),

            ("a prefix match beats the same match mid-word",
             score("doc", "docs.rs")! > score("doc", "mydocs.rs")!),
            ("a word-start match beats the same match mid-word",
             score("doc", "my-docs")! > score("doc", "mydocs")!),
            ("contiguous characters beat scattered ones",
             score("abc", "abcxx")! > score("abc", "axbxc")!),
            ("on a tie the shorter target wins",
             score("ab", "ab")! > score("ab", "abab")!),

            ("an empty query matches everything", score("", "anything") == 0),
            ("an empty query scores every target the same",
             score("", "a") == score("", "a much longer target")),
            ("an empty query keeps the input order",
             rank("", words, key: { $0 }) == words),

            ("rank drops the targets that do not match",
             rank("git", words, key: { $0 }) == ["git", "GitHub", "Gitlab"]),
            ("rank on no match returns an empty list",
             rank("zzz", words, key: { $0 }).isEmpty),
            ("rank puts the best match first",
             rank("hn", words, key: { $0 }).first == "Hacker News"),
        ]
    }
}

// MARK: - Commands

/// A palette entry that is an action rather than a place to go.
struct PaletteCommand: Identifiable {
    let id: String
    let icon: String
    let title: String
    let run: @MainActor () -> Void

    init(_ title: String, icon: String, run: @escaping @MainActor () -> Void) {
        self.id = title
        self.icon = icon
        self.title = title
        self.run = run
    }

    /// A `var`, not a `let`: features that land later append themselves here, so the
    /// palette never grows a compile-time dependency on code that does not exist yet — and
    /// never lists a row that does nothing when activated.
    @MainActor static var all: [PaletteCommand] = [
        PaletteCommand("New Tab", icon: "plus") { Windows.current?.newTab(nil) },
        PaletteCommand("Close Tab", icon: "xmark") {
            if let s = Windows.current, let c = s.current { s.close(c) }
        },
        PaletteCommand("Reload Page", icon: "arrow.clockwise") { Windows.current?.active?.reload() },
        PaletteCommand("Reopen Closed Tab", icon: "arrow.uturn.left") {
            if let u = ClosedTabs.pop() { (Windows.current ?? Windows.open()).newTab(u) }
        },
        PaletteCommand("Toggle Reader", icon: "doc.plaintext") {
            Windows.current?.active.map(Reader.toggle)
        },
        PaletteCommand("Open Settings", icon: "gearshape") { SettingsWindow.show() },
    ]
}

// MARK: - Overlay

/// There is one bar, not three. ⌘L, ⌘T and the address pill open `.address`, ⌘⇧P opens
/// `.all` and ⌘⇧A `.tabs` — and all of them are the same search bar with the same prompt.
/// The mode is only a starting filter: `.tabs` lists open tabs and nothing else, which is
/// the "search tabs" gesture Arc and Safari both have. A separate overlay for that would be
/// the same hundred lines with one line deleted.
enum PaletteMode {
    case all, tabs, address, newTab

    /// What VoiceOver calls the bar. Never drawn — the prompt below is what is drawn.
    var title: String {
        switch self {
        case .tabs: "Search Tabs"
        case .all, .address, .newTab: "Search or Enter URL"
        }
    }
    /// One prompt for every entry point: whatever opened this, it searches or navigates.
    var prompt: String { "Search or Enter URL…" }
}


// MARK: - The bar

/// One line of the command bar. `icon` is drawn only when `image` (a favicon) is missing,
/// and `trailing` is the "what Return does here" label on the right — "Switch to Tab",
/// "Ask Claude", "Open". Both are what make a row readable without reading it.
private struct PaletteRow: Identifiable {
    let id: String
    let icon: String
    var image: NSImage? = nil
    let title: String
    var detail: String = ""
    var trailing: String = ""
    /// What VoiceOver calls this row, since the icon says it to everyone else.
    let kind: String
    let run: @MainActor () -> Void
}

/// The command bar's text field.
///
/// ponytail: AppKit rather than SwiftUI's `TextField`, for the two things this field has to
/// do that SwiftUI has no API for. It opens with the current address *selected*, so typing
/// replaces it and ⌘L behaves like every other browser's location bar; and it sees Return,
/// Shift-Return, Tab and the arrows before the field editor decides what they mean, rather
/// than racing `onKeyPress` against it. Ceiling: a plain single-line NSTextField — no
/// attributed text, no inline completion, no emoji picker.
private struct CommandField: NSViewRepresentable {
    enum Key { case up, down, enter, shiftEnter, tab, escape }

    @Binding var text: String
    let prompt: String
    /// Select everything once the field takes focus, rather than parking the caret at the end.
    let selectAll: Bool
    let label: String
    let hint: String
    /// Return true to swallow the key; false lets the field editor have it.
    let onKey: (Key) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.delegate = context.coordinator
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.font = .systemFont(ofSize: 17)
        f.placeholderString = prompt
        f.setAccessibilityLabel(label)
        f.setAccessibilityHelp(hint)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        // The coordinator holds a copy of this struct, so refresh it or the callbacks below
        // keep calling into the state the view had when it was first made.
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        // Once only — otherwise every keystroke would reselect what was just typed.
        guard !context.coordinator.focused else { return }
        context.coordinator.focused = true
        context.coordinator.take(f, selectAll: selectAll)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        var focused = false
        init(_ parent: CommandField) { self.parent = parent }

        /// First responder can only be taken once the field is in a window, and SwiftUI
        /// adds it to one *after* the update that created it — so this waits a turn, and
        /// keeps waiting rather than silently leaving the bar unfocused.
        func take(_ f: NSTextField, selectAll: Bool, tries: Int = 20) {
            guard let window = f.window else {
                guard tries > 0 else { return }
                DispatchQueue.main.async { self.take(f, selectAll: selectAll, tries: tries - 1) }
                return
            }
            window.makeFirstResponder(f)
            let end = (f.stringValue as NSString).length
            f.currentEditor()?.selectedRange =
                selectAll ? NSRange(location: 0, length: end) : NSRange(location: end, length: 0)
        }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            // Shift-Return arrives as an ordinary insertNewline:, so the modifier has to be
            // read off the event that caused it.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch selector {
            case #selector(NSResponder.moveUp(_:)):          return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):        return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):       return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return parent.onKey(shift ? .shiftEnter : .enter)
            default: return false
            }
        }
    }
}

/// The search bar: one centred sheet over the page for typing a url, a search, a question
/// for an assistant, or the name of a tab.
///
/// It is a *search* bar, not a command palette, and the row order is the whole design:
/// what you typed first, so Return always does the obvious thing; then what the engine and
/// your own history complete it to; then the assistant; then the tabs you already have
/// open. Commands are a tail that only shows up once the query is long enough to mean one.
/// Every entry point — ⌘L, ⌘T, the address pill, ⌘⇧P, ⌘⇧A — lands here, looking the same.
@MainActor struct PaletteView: View {
    @EnvironmentObject var store: TabStore
    let mode: PaletteMode
    let dismiss: () -> Void

    @State private var query = ""
    @State private var index = 0
    /// Recomputed on each keystroke rather than per render: `Store.suggest` is a LIKE over
    /// history, and the body runs far more often than the query changes.
    @State private var rows: [PaletteRow] = []
    @State private var hover: String?
    /// The field is held back one frame so it is created with the prefilled address already
    /// in it — an NSTextField can only select text it has.
    @State private var ready = false

    /// At most eight rows are visible; the rest are a scroll away. Arithmetic rather than a
    /// preference-key measuring dance, which the fixed row height makes exact.
    private var listHeight: CGFloat { min(CGFloat(rows.count), 8) * Look.barRowHeight }
    private var barHeight: CGFloat {
        Look.barFieldHeight + (rows.isEmpty ? 0 : listHeight + Look.inset + 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Click-off to dismiss. Decoration only — Esc is the accessible route out,
                // and VoiceOver should never land on a full-screen unlabelled rectangle.
                Look.scrim
                    .contentShape(.rect)
                    .onTapGesture { close() }
                    .accessibilityHidden(true)

                bar
                    .frame(width: Look.barWidth)
                    // A third of the way down, the way Arc and Spotlight sit — but never so
                    // far that a tall list runs off the bottom of a short window.
                    .padding(.top, max(Look.inset,
                                       min(geo.size.height / 3,
                                           geo.size.height - barHeight - Look.inset)))
            }
        }
        .onExitCommand { close() }
        .onAppear {
            // ⌘L over a page opens with that page's address, selected.
            if mode == .address, let address = store.active?.address, !address.isEmpty {
                query = address
            }
            ready = true
            refresh()
        }
        .onChange(of: query) {
            if mode != .tabs { store.suggest(query) }
            refresh()
        }
        // Completions land later than the keystroke that asked for them; the list has to
        // grow under the user without moving what they had already arrowed onto.
        .onChange(of: store.suggestions) { refresh(reset: false) }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: Look.rowIcon)
                if ready {
                    CommandField(text: $query, prompt: mode.prompt,
                                 selectAll: mode == .address,
                                 label: mode.title,
                                 hint: "Type to filter. Up and down arrows choose a result, "
                                     + "Return opens it, Escape closes.",
                                 onKey: key)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Look.barFieldHeight)

            if !rows.isEmpty {
                Divider()
                list
            }
        }
        .glass(radius: Look.cardRadius)
        .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        // The bar is dark over anything, including a white page, so the semantic colours
        // inside it have to resolve dark too — otherwise light mode paints black on black.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode.title)
        // The bar owns the window while it is up, so everything behind it is noise.
        .accessibilityAddTraits(.isModal)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        line(i, row)
                    }
                }
                .padding(.vertical, Look.inset / 2)
            }
            .frame(height: listHeight + Look.inset)
            .scrollIndicators(.never)
            .onChange(of: index) { proxy.scrollTo(index) }
        }
    }

    private func line(_ i: Int, _ row: PaletteRow) -> some View {
        let on = i == index
        return HStack(spacing: 10) {
            if let image = row.image {
                Image(nsImage: image).resizable()
                    .frame(width: Look.rowIcon, height: Look.rowIcon)
            } else {
                Image(systemName: row.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: Look.rowIcon, height: Look.rowIcon)
            }
            Text(row.title).font(Look.text).lineLimit(1)
            if !row.detail.isEmpty {
                Text(row.detail).font(Look.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Look.inset)
            if !row.trailing.isEmpty {
                Text(row.trailing).font(Look.text.weight(.medium))
                    .foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
            // Only on the selected row: the chip is what Return will press.
            if on {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Look.barRowHeight)
        .background(on ? Look.selected : (hover == row.id ? Look.hovered : .clear),
                    in: .rect(cornerRadius: Look.pillRadius))
        .padding(.horizontal, Look.inset)
        .contentShape(.rect)
        .id(i)
        .onHover { hover = $0 ? row.id : (hover == row.id ? nil : hover) }
        .onTapGesture { index = i; activate() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue("\(row.kind), \(row.detail), \(i + 1) of \(rows.count)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { index = i; activate() }
    }

    // MARK: Behaviour

    private func key(_ k: CommandField.Key) -> Bool {
        switch k {
        case .up:         move(-1)
        case .down:       move(1)
        case .enter:      activate()
        case .escape:     close()
        case .shiftEnter:
            // Instant Links: skip the results page and open what it would have led to.
            guard mode == .address || mode == .newTab, !typed.isEmpty else { return false }
            let tab = target()
            close()
            store.goInstant(typed, from: tab)
        case .tab:
            // Same gesture the address bar had: hand what was typed to the assistant.
            guard mode != .tabs, !typed.isEmpty else { return false }
            let tab = target()
            close()
            tab.ask(typed)
        }
        return true
    }

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }

    /// Where Return loads: a fresh tab when the bar was opened by ⌘T, else the current one.
    /// Made only now, so a dismissed bar never leaves an empty tab behind.
    private func target() -> Tab {
        mode == .newTab ? store.newBlankTab() : (store.active ?? store.newBlankTab())
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        index = max(0, min(rows.count - 1, index + delta))
        let row = rows[index]
        axAnnounce("\(row.title), \(row.kind), \(index + 1) of \(rows.count)")
    }

    private func activate() {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        // Dismiss first: a command may close this very window.
        close()
        row.run()
    }

    /// The suggestion list belongs to the window, not to this view, so it has to be handed
    /// back — otherwise the address bar's own overlay inherits a stale list.
    private func close() {
        store.clearSuggestions()
        dismiss()
    }

    // MARK: The list

    private func refresh(reset: Bool = true) {
        var out: [PaletteRow] = []
        if mode == .tabs {
            out = Palette.rank(query, tabRows(), key: { $0.title + " " + $0.detail })
        } else {
            // Search first, in the order Arc puts them: what you typed (so Return always
            // does the obvious thing), what the engine and your own history complete it to,
            // the assistant, then the tabs you already have open. Appended rather than
            // ranked as one pool — the ranking *is* this order, and a fuzzy score must
            // never be able to push "what you actually typed" below a tab title.
            if let row = typedRow() { out.append(row) }
            out += suggestionRows()
            // Third row, where Arc puts it (ref 3) — not appended after the completions,
            // which would push it under the fold on any query the engine has eight guesses
            // for. Asking an assistant is always a valid thing to do with what was typed,
            // so it has to be on screen, and it must never be something the matcher can
            // rank away.
            if let row = aiRow() { out.insert(row, at: min(2, out.count)) }
            out += Palette.rank(query, tabRows(), key: { $0.title + " " + $0.detail })
            // Commands are a tail, never a headline: this is a search bar, and someone
            // typing two letters means a search far more often than "Close Tab". Three
            // characters is the floor at which a fuzzy match stops being a coincidence.
            if typed.count >= 3 {
                out += Palette.rank(typed, commandRows(), key: { $0.title })
            }
        }
        rows = Array(out.prefix(24))
        index = reset ? 0 : min(index, max(0, rows.count - 1))
        guard reset else { return }
        axAnnounce(rows.isEmpty ? "No results" : "\(rows.count) result\(rows.count == 1 ? "" : "s")")
    }

    /// Row one: what Return does with exactly what is in the field. Which of the three it is
    /// is decided by asking the same functions that will run — `Bangs` then `Search.url`,
    /// the address bar's own decision table — rather than by a second copy of the heuristic.
    private func typedRow() -> PaletteRow? {
        guard !typed.isEmpty else { return nil }
        let icon: String, trailing: String
        if let bang = Bangs.split(typed).flatMap({ Bangs.lookup($0.keyword) }) {
            (icon, trailing) = ("magnifyingglass", "Search \(bang.name)")
        } else if !typed.hasPrefix("?"), Search.url(for: typed) != Search.search(typed) {
            (icon, trailing) = ("globe", "Open")
        } else {
            (icon, trailing) = ("magnifyingglass", "Search \(Search.current.name)")
        }
        let text = typed
        return PaletteRow(id: "typed", icon: icon, title: text, trailing: trailing,
                          kind: trailing) {
            // go() resolves bangs, assistants, urls and searches — all of it, in that order.
            target().go(text)
        }
    }

    /// History, bookmarks and engine completions, in the order `TabStore.suggest` merged
    /// them. A completion is a search that has not happened yet, so it gets no url and no
    /// "Open" label; the others are places.
    private func suggestionRows() -> [PaletteRow] {
        store.suggestions.map { s in
            let title = s.title.isEmpty ? s.url : s.title
            let icon = s.completion ? "magnifyingglass" : (s.bookmarked ? "star.fill" : "clock")
            return PaletteRow(
                id: "url:" + s.url, icon: icon,
                image: s.completion ? nil : URL(string: s.url).flatMap(store.favicons.icon),
                title: title,
                detail: s.completion ? "" : s.url,
                trailing: s.completion ? "" : "Open",
                kind: s.completion ? "Search suggestion" : (s.bookmarked ? "Bookmark" : "History")
            ) {
                guard let u = URL(string: s.url) else { return }
                let tab = target()
                tab.editing = false
                tab.web.load(URLRequest(url: u))
            }
        }
    }

    /// Every window, not just this one — a tab you are looking for is as likely to be
    /// behind another window as in front of you.
    private func tabRows() -> [PaletteRow] {
        var out: [PaletteRow] = []
        let manyWindows = TabStore.all.count > 1
        for (w, other) in TabStore.all.enumerated() where !other.isPrivate || other === store {
            for tab in other.tabs {
                let place = manyWindows ? "Window \(w + 1)" : ""
                let detail = [tab.address, place].filter { !$0.isEmpty }.joined(separator: " — ")
                out.append(PaletteRow(id: "tab:" + tab.id.uuidString, icon: "square.on.square",
                                      image: tab.favicon, title: tab.title, detail: detail,
                                      trailing: "Switch to Tab", kind: "Open tab") {
                    other.current = tab.id
                    other.window?.makeKeyAndOrderFront(nil)
                })
            }
        }
        return out
    }

    private func commandRows() -> [PaletteRow] {
        PaletteCommand.all.map { c in
            PaletteRow(id: "cmd:" + c.id, icon: c.icon, title: c.title,
                       trailing: "Command", kind: "Command", run: c.run)
        }
    }

    private func aiRow() -> PaletteRow? {
        guard mode != .tabs, !typed.isEmpty else { return nil }
        let (assistant, question) = AIChat.match(query) ?? (AIChat.preferred, query)
        guard let url = AIChat.url(for: question, using: assistant) else { return nil }
        return PaletteRow(id: "ai", icon: "sparkles", title: question,
                          trailing: "Ask \(assistant.name)", kind: "AI Chat") {
            (Windows.current ?? Windows.open()).newTab(url)
        }
    }
}
