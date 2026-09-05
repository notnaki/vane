import AppKit
import Combine
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

    /// The bar's row order, in one place so it can be proved without a window. With nothing
    /// typed the bar is the list of open tabs (ref 2). With a query, the tabs that match lead
    /// — at most `leadingTabs`, so the typed row is never pushed under the fold — then what
    /// was typed, what it completes to, the assistant two rows under the typed one (ref 3),
    /// the rest of the matching tabs, the other places that match, and commands as a tail.
    ///
    /// `rest` is the places that are neither open tabs nor completions: an archived tab to
    /// restore, a Space to switch to. They sit above the commands because they are somewhere
    /// to go, and below the tabs because a tab you already have open is the better answer.
    static func arrange<T>(tabs: [T], typed: T?, suggestions: [T], ai: T?, rest: [T] = [],
                           commands: [T], leadingTabs: Int = 3) -> [T] {
        guard let typed else { return tabs + rest + commands }
        var out = Array(tabs.prefix(leadingTabs))
        let lead = out.count
        out.append(typed)
        out += suggestions
        if let ai { out.insert(ai, at: min(lead + 2, out.count)) }
        out += tabs.dropFirst(leadingTabs)
        out += rest
        out += commands
        return out
    }

    /// ⌘T, ⌘L and ⌘⇧P over a bar that is already up close it (Arc v0.107): the same key that
    /// opened it is the fastest way out, and reopening a bar that never went away is what
    /// makes a browser feel stuck.
    static func toggled(current: PaletteMode?, pressed: PaletteMode) -> PaletteMode? {
        current == nil ? pressed : nil
    }

    /// Where Return loads, as Arc decides it. ⌘T's bar always makes a tab; ⌘L's replaces
    /// the page it was opened on; ⌘Return makes a tab whichever opened it. With nothing open
    /// there is nothing to replace, so a tab is made either way.
    static func opensInNewTab(mode: PaletteMode, commandHeld: Bool, hasActiveTab: Bool) -> Bool {
        commandHeld || mode == .newTab || !hasActiveTab
    }

    static func check() -> [(String, Bool)] {
        // Force-unwrapped inside the assertions on purpose: a nil here is the failure the
        // line above it already checks for, so it can only fire if the checks disagree.
        let words = ["GitHub", "Gitlab", "git", "Hacker News"]
        let none: [String] = []
        let watched = MainActor.assumeIsolated { ChangeWatch.check() }
        return [
            // Where Return loads (§4 of the Arc spec): ⌘T makes a tab, ⌘L replaces the page.
            ("⌘T's bar always opens in a new tab",
             opensInNewTab(mode: .newTab, commandHeld: false, hasActiveTab: true)),
            ("⌘L's bar replaces the page it was opened on",
             !opensInNewTab(mode: .address, commandHeld: false, hasActiveTab: true)),
            ("⌘Return opens in a new tab whichever way the bar was opened",
             opensInNewTab(mode: .address, commandHeld: true, hasActiveTab: true)
                && opensInNewTab(mode: .all, commandHeld: true, hasActiveTab: true)),
            ("with nothing open there is nothing to replace, so a tab is made",
             opensInNewTab(mode: .address, commandHeld: false, hasActiveTab: false)),
            ("⌘⇧P's bar replaces the page too — it is the same bar",
             !opensInNewTab(mode: .all, commandHeld: false, hasActiveTab: true)),
            ("with nothing typed the bar lists the open tabs",
             arrange(tabs: ["t1", "t2"], typed: nil, suggestions: none, ai: nil, commands: none) == ["t1", "t2"]),
            ("a matching tab comes before what was typed",
             arrange(tabs: ["t1"], typed: "q", suggestions: ["s1"], ai: nil, commands: none) == ["t1", "q", "s1"]),
            ("at most three tabs lead; the rest follow the completions",
             arrange(tabs: ["t1", "t2", "t3", "t4"], typed: "q", suggestions: ["s1"], ai: nil, commands: none)
                == ["t1", "t2", "t3", "q", "s1", "t4"]),
            ("the assistant sits two rows under what was typed",
             arrange(tabs: ["t1"], typed: "q", suggestions: ["s1", "s2"], ai: "ai", commands: none)
                == ["t1", "q", "s1", "ai", "s2"]),
            ("…or right after it when there is nothing to complete to",
             arrange(tabs: none, typed: "q", suggestions: none, ai: "ai", commands: none) == ["q", "ai"]),
            ("commands are the tail",
             arrange(tabs: ["t1"], typed: "q", suggestions: none, ai: nil, commands: ["c"]) == ["t1", "q", "c"]),
            ("an archived tab or a Space follows the open tabs",
             arrange(tabs: ["t1"], typed: "q", suggestions: none, ai: nil, rest: ["archived"],
                     commands: none) == ["t1", "q", "archived"]),
            ("…and still comes before the commands",
             arrange(tabs: none, typed: "q", suggestions: none, ai: nil, rest: ["space"],
                     commands: ["c"]) == ["q", "space", "c"]),
            ("…and after every matching tab, not just the leading three",
             arrange(tabs: ["t1", "t2", "t3", "t4"], typed: "q", suggestions: none, ai: nil,
                     rest: ["archived"], commands: ["c"])
                == ["t1", "t2", "t3", "q", "t4", "archived", "c"]),
            ("…and under the completions and the assistant, which answer what was typed",
             arrange(tabs: none, typed: "q", suggestions: ["s1"], ai: "ai", rest: ["space"],
                     commands: none) == ["q", "s1", "ai", "space"]),
            ("with nothing typed the bar is still just the tabs",
             arrange(tabs: ["t1"], typed: nil, suggestions: none, ai: nil, rest: none,
                     commands: none) == ["t1"]),

            ("⌘T over a closed bar opens it", toggled(current: nil, pressed: .newTab) == .newTab),
            ("⌘T over an open bar closes it",
             toggled(current: .newTab, pressed: .newTab) == nil),
            ("⌘L over a bar ⌘T opened closes it too — it is the same bar",
             toggled(current: .newTab, pressed: .address) == nil),
        ] + watched + [
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

/// Re-runs the bar's list when a tab it is showing changes under it — a title arriving, a
/// favicon landing, a page finishing. `TabStore` publishes its *list* of tabs and nothing
/// about the tabs themselves, so a bar that only snapshotted on open kept drawing "New Tab"
/// and a globe for a page that had long since said who it was.
///
/// The bump happens inside `objectWillChange`, before the tab's own value changes; that is
/// fine, because SwiftUI runs `onChange` on its next pass, after the write has landed.
/// ponytail: one revision counter, not per-field subscriptions. A tab's progress fires this
/// too, and the refresh it triggers is a rank over a few dozen titles — nothing to save.
@MainActor final class ChangeWatch: ObservableObject {
    @Published private(set) var revision = 0
    private var subscriptions: [AnyCancellable] = []

    /// Replace what is being watched. Anything watched before is dropped.
    func watch<O: ObservableObject>(_ objects: [O])
    where O.ObjectWillChangePublisher == ObservableObjectPublisher {
        subscriptions = objects.map { o in
            o.objectWillChange.sink { [weak self] _ in self?.revision += 1 }
        }
    }

    /// A stand-in for a Tab, which needs WebKit: the same shape as far as the watch can see.
    private final class Probe: ObservableObject { @Published var value = 0 }

    static func check() -> [(String, Bool)] {
        let watch = ChangeWatch()
        let a = Probe(), b = Probe()
        watch.watch([a])
        a.value = 1
        let bumped = watch.revision == 1
        b.value = 1
        let unwatchedIgnored = watch.revision == 1
        watch.watch([b])
        a.value = 2
        let dropped = watch.revision == 1
        b.value = 2
        let rewatched = watch.revision == 2
        return [
            ("a change on a watched tab bumps the revision", bumped),
            ("a tab that is not watched does not", unwatchedIgnored),
            ("watching a new set drops the old one", dropped),
            ("…and follows the new one", rewatched),
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
        PaletteCommand("Open Library", icon: "archivebox") { Windows.current?.libraryOpen = true },
        PaletteCommand("View Archive", icon: "tray.full") { Windows.current?.libraryOpen = true },
        PaletteCommand("View History", icon: "clock.arrow.circlepath") { HistoryWindow.show() },
        PaletteCommand("Open Settings", icon: "gearshape") { SettingsWindow.show() },
        PaletteCommand("Keyboard Shortcuts", icon: "keyboard") { SettingsWindow.show(tab: "shortcuts") },
    ]

    /// The rows that only make sense against what is in front of you right now: pinning the
    /// tab you are on, favouriting it, moving it to one of *your* Spaces. They cannot live in
    /// `all` — a static list cannot know whether this tab is already pinned, and Arc's bar
    /// says "Unpin Tab" when it is.
    @MainActor static func contextual() -> [PaletteCommand] {
        guard let store = Windows.current, let tab = store.active else { return [] }
        var out: [PaletteCommand] = [
            PaletteCommand(tab.kind == .pinned ? "Unpin Tab" : "Pin Tab",
                           icon: tab.kind == .pinned ? "pin.slash" : "pin") {
                store.togglePinned(tab.id)
            },
            PaletteCommand(tab.kind == .favourite ? "Remove from Favourites" : "Add to Favourites",
                           icon: tab.kind == .favourite ? "star.slash" : "star") {
                store.toggleFavourite(tab.id)
            },
        ]
        // Arc's "Move to Space ▸" is a submenu; a search bar has no submenus, so it is one
        // row per Space — which is also the row you can type the Space's name at.
        guard tab.currentURL?.scheme?.hasPrefix("http") == true else { return out }
        for space in store.spaces where space.id != store.currentSpaceID {
            out.append(PaletteCommand("Move to \(space.name)",
                                      icon: space.icon ?? "square.on.square") {
                Spaces.move(tab.id, to: space.id, as: .today, from: store)
            })
        }
        return out
    }
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
///
/// `detail` is matched against and spoken, but never drawn: Arc's rows are a title and a
/// verb, and a url after every tab title is what made the list read as a log. `subtitle`
/// is the part of it worth drawing when there is one — "Window 2", a history item's host.
private struct PaletteRow: Identifiable {
    let id: String
    let icon: String
    var image: NSImage? = nil
    let title: String
    var detail: String = ""
    var subtitle: String = ""
    var trailing: String = ""
    /// What VoiceOver calls this row, since the icon says it to everyone else.
    let kind: String
    /// `target` makes — or finds — the tab this row should load into, and is only called by
    /// the rows that load something. Passed in rather than captured so ⌘Return can hand the
    /// same row a fresh tab: a row's closure is built when the list is, which is before the
    /// user has pressed anything.
    let run: @MainActor (_ target: () -> Tab) -> Void
}

/// The command bar's text field.
///
/// ponytail: AppKit rather than SwiftUI's `TextField`, for the two things this field has to
/// do that SwiftUI has no API for. It opens with the current address *selected*, so typing
/// replaces it and ⌘L behaves like every other browser's location bar; and it sees Return,
/// Shift-Return, Tab and the arrows before the field editor decides what they mean, rather
/// than racing `onKeyPress` against it. Ceiling: a plain single-line NSTextField — no
/// attributed text, no inline completion, no emoji picker.
///
/// Internal, not private: the find bar needs the same three things (selected on open, Return
/// and Shift-Return seen first, focus that stays put), only smaller.
struct CommandField: NSViewRepresentable {
    enum Key { case up, down, enter, shiftEnter, commandEnter, tab, escape }

    @Binding var text: String
    let prompt: String
    /// Select everything once the field takes focus, rather than parking the caret at the end.
    let selectAll: Bool
    let label: String
    let hint: String
    /// The bar's size by default; the find bar asks for its own, smaller one.
    var font: NSFont = .systemFont(ofSize: Look.barFontSize)
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
        f.font = font
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
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let shift = flags.contains(.shift)
            // ⌘Return arrives as insertNewlineIgnoringFieldEditor:, ⇧Return as an ordinary
            // insertNewline:, so both modifiers have to be read off the event that caused it.
            let command = flags.contains(.command)
            switch selector {
            case #selector(NSResponder.moveUp(_:)):          return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):        return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):       return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return parent.onKey(command ? .commandEnter : (shift ? .shiftEnter : .enter))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// False for the first frame, so the bar can scale and fade in from `appearScale`.
    @State private var shown = false
    /// Every open tab, in every window: a title or favicon arriving redraws the row for it.
    @StateObject private var tabs = ChangeWatch()

    /// At most eight rows are visible; the rest are a scroll away. Arithmetic rather than a
    /// preference-key measuring dance, which the fixed row height makes exact.
    private var listHeight: CGFloat {
        let n = CGFloat(min(rows.count, 8))
        return n * Look.barRowHeight + max(0, n - 1) * Look.barRowGap
    }
    /// Above and below the rows: a row gap's less at the top, where the divider already
    /// separates, than at the bottom, where the bar's edge has to.
    private var listPadding: CGFloat { Look.barInset - Look.barRowGap + Look.barInset }
    private var barHeight: CGFloat {
        Look.barFieldHeight + (rows.isEmpty ? 0 : 1 + listHeight + listPadding)
    }

    /// Nil under Reduce Motion, which SwiftUI reads as "just change".
    private func motion(_ a: Animation) -> Animation? { reduceMotion ? nil : a }

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
                    .frame(width: min(Look.barWidth, geo.size.width - Look.inset * 2))
                    .scaleEffect(shown ? 1 : Look.appearScale)
                    .opacity(shown ? 1 : 0)
                    // Centred on the window, the way Arc's is, growing about its middle as
                    // the list does — but never so far down that a tall list runs off the
                    // bottom of a short window.
                    .padding(.top, max(Look.inset,
                                       min((geo.size.height - barHeight) / 2,
                                           geo.size.height - barHeight - Look.inset)))
                    .animation(motion(Look.quick), value: rows.count)
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
            tabs.watch(allTabs)
            withAnimation(motion(Look.appear)) { shown = true }
        }
        .onChange(of: query) {
            if mode != .tabs { store.suggest(query) }
            refresh()
        }
        // Completions land later than the keystroke that asked for them; the list has to
        // grow under the user without moving what they had already arrowed onto. The same
        // goes for a tab that renames itself or gets its favicon while the bar is up.
        .onChange(of: store.suggestions) { refresh(reset: false) }
        .onChange(of: tabs.revision) { refresh(reset: false) }
        // Tabs opened or closed while the bar is up: watch the new set, and list it.
        .onChange(of: allTabs.map(\.id)) { tabs.watch(allTabs); refresh(reset: false) }
    }

    private var allTabs: [Tab] { TabStore.all.flatMap(\.tabs) }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Look.barRowInset) {
                Image(systemName: "magnifyingglass")
                    .font(Look.fieldIcon)
                    .foregroundStyle(Look.barPlaceholder)
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
            // The same two insets a row has, so the field's icon sits over the rows' icons.
            .padding(.horizontal, Look.barInset + Look.barRowInset)
            .frame(height: Look.barFieldHeight)

            if !rows.isEmpty {
                Hairline().padding(.horizontal, Look.barInset)
                list
            }
        }
        // Arc's bar is one flat surface, not glass: a blur of whatever is behind it,
        // darkened almost to opaque, and a single hairline. No specular edge, no
        // refraction — the shadow is what lifts it off the page.
        .background(Look.barFill, in: .rect(cornerRadius: Look.barRadius))
        .background(Look.barMaterial, in: .rect(cornerRadius: Look.barRadius))
        .hairline(radius: Look.barRadius, Look.barStroke)
        .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
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
                VStack(spacing: Look.barRowGap) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        line(i, row)
                    }
                }
                .padding(.top, Look.barInset - Look.barRowGap)
                .padding(.bottom, Look.barInset)
            }
            .frame(height: listHeight + listPadding)
            .scrollIndicators(.never)
            .onChange(of: index) { proxy.scrollTo(index) }
        }
    }

    private func line(_ i: Int, _ row: PaletteRow) -> some View {
        let on = i == index
        let lit = hover == row.id
        return HStack(spacing: Look.barRowSpacing) {
            if let image = row.image {
                Image(nsImage: image).resizable()
                    .frame(width: Look.rowIcon, height: Look.rowIcon)
            } else {
                Image(systemName: row.icon)
                    .font(Look.symbol)
                    .foregroundStyle(Look.barGlyph)
                    .frame(width: Look.rowIcon, height: Look.rowIcon)
            }
            // Arc's title is a light grey until the row is the one Return will press,
            // when it goes to full white — the fill alone is not the whole selection here.
            Text(row.title).font(Look.rowText).lineLimit(1)
                .foregroundStyle(on ? Look.barSelectedText : Look.barText)
            if !row.subtitle.isEmpty {
                Text(row.subtitle).font(Look.text).foregroundStyle(Look.barTrailing).lineLimit(1)
            }
            Spacer(minLength: Look.inset)
            // The verb and its chip travel together, on every row that has one; the
            // selected row's are the bright pair, because that is the one Return presses.
            if !row.trailing.isEmpty {
                Text(row.trailing).font(Look.rowText)
                    .foregroundStyle(on ? Look.barSelectedText : Look.barTrailing)
                    .lineLimit(1).layoutPriority(1)
                Image(systemName: "arrow.right")
                    .font(Look.chipGlyph)
                    .foregroundStyle(on ? Look.barSelectedText : Look.barGlyph)
                    .frame(width: Look.chip, height: Look.chip)
                    .background(Look.chipFill, in: .rect(cornerRadius: Look.chipRadius))
            }
        }
        .padding(.horizontal, Look.barRowInset)
        .frame(height: Look.barRowHeight)
        .background(on ? Look.barSelected : (lit ? Look.barHovered : .clear),
                    in: .rect(cornerRadius: Look.pillRadius))
        .animation(motion(Look.quick), value: on)
        .animation(motion(Look.quick), value: lit)
        .padding(.horizontal, Look.barInset)
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
        case .enter:        activate()
        case .commandEnter: activate(inNewTab: true)
        case .escape:       close()
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

    /// Where Return loads: a fresh tab when the bar was opened by ⌘T or ⌘Return was held,
    /// else the tab it was opened on. Made only now, so a dismissed bar never leaves an
    /// empty tab behind.
    private func target(inNewTab: Bool = false) -> Tab {
        Palette.opensInNewTab(mode: mode, commandHeld: inNewTab, hasActiveTab: store.active != nil)
            ? store.newBlankTab() : (store.active ?? store.newBlankTab())
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        index = max(0, min(rows.count - 1, index + delta))
        let row = rows[index]
        axAnnounce("\(row.title), \(row.kind), \(index + 1) of \(rows.count)")
    }

    private func activate(inNewTab: Bool = false) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        // Dismiss first: a command may close this very window.
        close()
        // The tab is made lazily, inside the row: a command row opens nothing, and eagerly
        // making a tab for it would leave a blank one behind.
        row.run { target(inNewTab: inNewTab) }
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
        let tabs = Palette.rank(query, tabRows(), key: { $0.title + " " + $0.detail })
        if mode == .tabs {
            out = tabs
        } else {
            // Arc's order (refs 2, 3): a tab you already have open that matches is the
            // best answer there is, so it leads — "Switch to Tab" is what Return does. Then
            // what you typed, what the engine and your own history complete it to, the
            // assistant, the rest of the tabs. Sections rather than one ranked pool: the
            // order *is* the ranking, and a fuzzy score must never be able to move "what
            // you actually typed" around. Commands are a tail, never a headline — someone
            // typing two letters means a search far more often than "Close Tab", and three
            // characters is the floor at which a fuzzy match stops being a coincidence.
            // Archived tabs and Spaces are places, so they are searched the moment there is
            // something to search with; commands are verbs, and three characters is the floor
            // at which a fuzzy match on one stops being a coincidence.
            let places = typed.isEmpty ? []
                : Palette.rank(typed, archiveRows() + spaceRows(), key: { $0.title + " " + $0.detail })
            out = Palette.arrange(
                tabs: tabs, typed: typedRow(), suggestions: suggestionRows(), ai: aiRow(),
                rest: places,
                commands: typed.count >= 3 ? Palette.rank(typed, commandRows(), key: { $0.title }) : [])
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
                          kind: trailing) { target in
            // go() resolves bangs, assistants, urls and searches — all of it, in that order.
            target().go(text)
        }
    }

    /// History, bookmarks and engine completions, in the order `TabStore.suggest` merged
    /// them. A completion is a search that has not happened yet, so it gets no url and no
    /// "Open" label; the others are places, shown with their host so two pages with the
    /// same title can be told apart.
    private func suggestionRows() -> [PaletteRow] {
        store.suggestions.map { s in
            let title = s.title.isEmpty ? s.url : s.title
            let icon = s.completion ? "magnifyingglass" : (s.bookmarked ? "star.fill" : "clock")
            let host = URL(string: s.url)?.host ?? s.url
            return PaletteRow(
                id: "url:" + s.url, icon: icon,
                image: s.completion ? nil : URL(string: s.url).flatMap(store.favicons.icon),
                title: title,
                detail: s.completion ? "" : s.url,
                subtitle: s.completion || s.title.isEmpty ? "" : host,
                trailing: s.completion ? "" : "Open",
                kind: s.completion ? "Search suggestion" : (s.bookmarked ? "Bookmark" : "History")
            ) { target in
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
                                      subtitle: place,
                                      trailing: "Switch to Tab", kind: "Open tab") { _ in
                    other.current = tab.id
                    other.window?.makeKeyAndOrderFront(nil)
                })
            }
        }
        return out
    }

    /// Tabs that have left the sidebar but not the browser. Return puts one back where it
    /// was, which is what the Library's rows do — this is the same list, searchable.
    private func archiveRows() -> [PaletteRow] {
        guard !store.isPrivate else { return [] }
        let archive = Archive.shared(for: store.profileID)
        return archive.entries.map { entry in
            PaletteRow(id: "archived:" + entry.url, icon: "archivebox",
                       image: URL(string: entry.url).flatMap(store.favicons.icon),
                       title: entry.title.isEmpty ? entry.url : entry.title,
                       detail: entry.url,
                       trailing: "Restore Tab", kind: "Archived tab") { _ in
                Windows.current?.unarchive(entry)
            }
        }
    }

    /// The profile's Spaces, by name. Arc switches Space from the bar, and typing the name
    /// of the Space you want is faster than counting ⌃1…⌃9.
    private func spaceRows() -> [PaletteRow] {
        guard !store.isPrivate else { return [] }
        return store.spaces.filter { $0.id != store.currentSpaceID }.map { space in
            PaletteRow(id: "space:" + space.id.uuidString, icon: space.icon ?? "square.stack",
                       title: space.name, detail: "Space",
                       trailing: "Switch to Space", kind: "Space") { _ in
                Windows.current?.switchTo(space: space)
            }
        }
    }

    private func commandRows() -> [PaletteRow] {
        (PaletteCommand.all + PaletteCommand.contextual()).map { c in
            PaletteRow(id: "cmd:" + c.id, icon: c.icon, title: c.title,
                       trailing: "Command", kind: "Command") { _ in c.run() }
        }
    }

    private func aiRow() -> PaletteRow? {
        guard mode != .tabs, !typed.isEmpty else { return nil }
        let (assistant, question) = AIChat.match(query) ?? (AIChat.preferred, query)
        guard let url = AIChat.url(for: question, using: assistant) else { return nil }
        return PaletteRow(id: "ai", icon: "sparkles", title: question,
                          trailing: "Ask \(assistant.name)", kind: "AI Chat") { _ in
            (Windows.current ?? Windows.open()).newTab(url)
        }
    }
}
