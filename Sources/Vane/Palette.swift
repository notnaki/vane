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

/// ⌘⇧P opens everything; ⌘⇧A opens the same overlay restricted to open tabs, which is the
/// "search tabs" gesture Arc and Safari both use. One view, two starting filters — a second
/// overlay for tab search would be the same 100 lines with one line deleted.
enum PaletteMode {
    case all, tabs, address

    var title: String {
        switch self {
        case .tabs: "Search Tabs"
        case .address: "Search or Enter URL"
        case .all: "Command Palette"
        }
    }
    var prompt: String {
        switch self {
        case .tabs: "Search open tabs"
        case .address: "Search or Enter URL…"
        case .all: "Search tabs, history, bookmarks and commands"
        }
    }
}

private struct PaletteRow: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    /// What VoiceOver calls this row, since the icon says it to everyone else.
    let kind: String
    let run: @MainActor () -> Void
}

@MainActor struct PaletteView: View {
    @EnvironmentObject var store: TabStore
    let mode: PaletteMode
    let dismiss: () -> Void

    @State private var query = ""
    @State private var index = 0
    /// Recomputed on each keystroke rather than per render: `Store.shared.suggest` is a
    /// LIKE over history, and the body runs far more often than the query changes.
    @State private var rows: [PaletteRow] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Click-off to dismiss. Decoration only — Esc is the accessible route out, and
            // VoiceOver should never land on a full-screen unlabelled rectangle.
            Color.black.opacity(0.12)
                .contentShape(.rect)
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                TextField(mode.prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .focused($focused)
                    .accessibilityLabel(mode.title)
                    .accessibilityHint("Type to filter. Up and down arrows choose a result, Return opens it, Escape closes.")
                    .onSubmit { activate() }
                    // onKeyPress, not onMoveCommand: the field editor of a focused
                    // TextField swallows the arrows to move its own insertion point, so
                    // onMoveCommand never fires. onKeyPress runs first and .handled stops
                    // the field seeing them at all.
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: query) { refresh() }

                if !rows.isEmpty {
                    Divider()
                    list
                }
            }
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .shadow(radius: 14, y: 6)
            .padding(.top, 60)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(mode.title)
            // The palette owns the window while it is up, so everything behind it is noise.
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { dismiss() }
        .onAppear {
            refresh()
            focused = true
        }
    }

    private var list: some View {
        // Matches the address bar's suggestion list on purpose — same row shape, same
        // selection fill. The UI is being redesigned; two different lists would be two
        // things to redo.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        HStack(spacing: 8) {
                            Image(systemName: row.icon)
                                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            Text(row.title).lineLimit(1).font(.system(size: 12))
                            Text(row.detail).lineLimit(1).font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(i == index ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                        .contentShape(.rect)
                        .id(i)
                        .onTapGesture { index = i; activate() }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.title)
                        .accessibilityValue("\(row.kind), \(row.detail), \(i + 1) of \(rows.count)")
                        .accessibilityAddTraits(i == index ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { index = i; activate() }
                    }
                }
            }
            // ponytail: rows are a known 27pt (12pt text plus 6pt padding either side), so
            // the card sizes itself with arithmetic instead of a preference-key measuring
            // dance. Ceiling: change the row's font or padding and this has to follow.
            .frame(height: min(CGFloat(rows.count) * 27, 324))
            .onChange(of: index) { proxy.scrollTo(index) }
        }
    }

    // MARK: Behaviour

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
        dismiss()
        row.run()
    }

    private func refresh() {
        let pool = candidates()
        rows = Array(Palette.rank(query, pool, key: { $0.title + " " + $0.detail }).prefix(24))
        // Inserted after ranking: asking an assistant is always a valid thing to do with
        // whatever was typed, so the fuzzy matcher must never be able to rank it away.
        if let ai = aiRow() { rows.insert(ai, at: 0) }
        index = 0
        axAnnounce(rows.isEmpty ? "No results" : "\(rows.count) result\(rows.count == 1 ? "" : "s")")
    }

    private func aiRow() -> PaletteRow? {
        guard mode == .all, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let (assistant, question) = AIChat.match(query) ?? (AIChat.preferred, query)
        guard let url = AIChat.url(for: question, using: assistant) else { return nil }
        return PaletteRow(id: "ai", icon: "sparkles", title: "Ask \(assistant.name)",
                          detail: question, kind: "AI Chat") {
            (Windows.current ?? Windows.open()).newTab(url)
        }
    }

    private func candidates() -> [PaletteRow] {
        var out: [PaletteRow] = []
        var seen = Set<String>()

        if mode == .all {
            out += PaletteCommand.all.map { c in
                PaletteRow(id: "cmd:" + c.id, icon: c.icon, title: c.title,
                           detail: "Command", kind: "Command", run: c.run)
            }
        }

        // Every window, not just this one — a tab you are looking for is as likely to be
        // behind another window as in front of you.
        let manyWindows = TabStore.all.count > 1
        for (w, other) in TabStore.all.enumerated() where !other.isPrivate || other === store {
            for tab in other.tabs {
                let place = manyWindows ? "Window \(w + 1)" : ""
                let detail = [tab.address, place].filter { !$0.isEmpty }.joined(separator: " — ")
                seen.insert(tab.address)
                out.append(PaletteRow(id: "tab:" + tab.id.uuidString, icon: "square.on.square",
                                      title: tab.title, detail: detail, kind: "Open tab") {
                    other.current = tab.id
                    other.window?.makeKeyAndOrderFront(nil)
                })
            }
        }

        // A private window keeps its palette out of history and bookmarks, the same way its
        // address bar already refuses to suggest from them.
        if mode == .all && !store.isPrivate {
            for s in Store.shared.suggest(query, limit: 12) where seen.insert(s.url).inserted {
                let title = s.title.isEmpty ? s.url : s.title
                out.append(PaletteRow(id: "url:" + s.url,
                                      icon: s.bookmarked ? "star.fill" : "clock",
                                      title: title, detail: s.url,
                                      kind: s.bookmarked ? "Bookmark" : "History") {
                    guard let u = URL(string: s.url) else { return }
                    (Windows.current ?? Windows.open()).newTab(u)
                })
            }
        }
        return out
    }
}
