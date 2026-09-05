import AppKit
import SwiftUI
import WebKit

// MARK: - The search

/// ⌘F, and everything it needs to say "3 of 12".
///
/// WebKit owns the search itself — `Tab.find` wraps `WKWebView.find`, which scrolls to a
/// match and selects it — but it answers only "was there a match". Arc's bar says which
/// match, out of how many, so the count is ours: one pass over the page's text nodes, and
/// a position we walk ourselves as the user goes next and previous.
///
/// ponytail: a counting script rather than a second find engine. Ceiling: it counts inside
/// the main frame's text nodes only, so text split across two elements ("<b>Git</b>Hub"),
/// text inside an iframe, and text inside a shadow root are not counted the way WebKit
/// finds them. Fixing that properly means reimplementing WebKit's own text iterator; the
/// day the count is wrong often enough to matter, the fix is `_countStringMatches` SPI.
@MainActor final class Find: ObservableObject {

    /// What is typed in the bar. Survives closing it, so ⌘G can pick the search back up.
    @Published var query = ""
    /// Total matches on the page, 0 when there are none (or nothing typed).
    @Published private(set) var count = 0
    /// Which match is showing, 1-based. 0 means "none" — nothing typed, or no match.
    @Published private(set) var index = 0

    // MARK: Sessions

    /// One session per window: two windows each searching for something different is the
    /// normal case, and a shared query would fight over the count.
    private static var sessions: [ObjectIdentifier: Find] = [:]

    static func session(for store: TabStore) -> Find {
        let key = ObjectIdentifier(store)
        if let hit = sessions[key] { return hit }
        let fresh = Find()
        sessions[key] = fresh
        return fresh
    }

    /// The session of the window the keys are going to.
    static var current: Find? { Windows.current.map(session(for:)) }

    // MARK: Pure

    /// The count, in the words the bar draws. Nothing typed says nothing — an empty field
    /// with "No results" under it reads as a failure the user did not cause.
    static func label(index: Int, count: Int, query: String) -> String {
        guard !query.isEmpty else { return "" }
        guard count > 0 else { return "No results" }
        return "\(max(1, index)) of \(count)"
    }

    /// The same thing said out loud, since a count nobody can see is not a count.
    static func spoken(index: Int, count: Int, query: String) -> String {
        guard !query.isEmpty else { return "" }
        guard count > 0 else { return "No results for \(query)" }
        return "Match \(max(1, index)) of \(count)"
    }

    /// Where next (or previous) lands, wrapping the way WebKit's own search wraps. 0 in,
    /// 0 out: with no matches there is nowhere to go.
    static func step(index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        guard index > 0 else { return forward ? 1 : count }
        let next = forward ? index + 1 : index - 1
        if next > count { return 1 }
        if next < 1 { return count }
        return next
    }

    /// The needle, as a JavaScript string literal. A page's find is the one place a user's
    /// own typing is handed to `evaluateJavaScript`, so quoting it is not optional.
    static func quote(_ text: String) -> String {
        var out = "\""
        for c in text.unicodeScalars {
            switch c {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:    out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    /// Counts occurrences the way the page reads, per text node, skipping the nodes that
    /// are markup rather than words.
    static func countScript(_ text: String) -> String {
        """
        (function (q) {
          if (!q || !document.body) { return 0; }
          var needle = q.toLowerCase();
          var walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
              var p = n.parentNode, tag = p ? p.nodeName : '';
              if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') {
                return NodeFilter.FILTER_REJECT;
              }
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          var node, total = 0;
          while ((node = walk.nextNode())) {
            var hay = node.nodeValue.toLowerCase(), at = 0;
            while ((at = hay.indexOf(needle, at)) !== -1) { total++; at += needle.length; }
          }
          return total;
        })(\(quote(text)));
        """
    }

    // MARK: Running a search

    /// A fresh search: the query changed, so recount and land on the first match after the
    /// caret. Anything else is a step through what was already counted.
    func run(_ text: String, in tab: Tab, forward: Bool = true, fresh: Bool = false) async {
        query = text
        guard !text.isEmpty else {
            count = 0
            index = 0
            clearHighlight(in: tab)
            return
        }
        if fresh { count = await matches(text, in: tab) }
        let hit = await tab.find(text, forward: forward)
        guard hit else {
            // WebKit found nothing, so whatever the counter said, there is nothing to be on.
            count = 0
            index = 0
            return
        }
        // A page whose text WebKit finds but the walker cannot see (a shadow root, an
        // iframe) would otherwise show "0 matches" over a highlighted match.
        if count == 0 { count = 1 }
        index = fresh ? 1 : Self.step(index: index, count: count, forward: forward)
    }

    private func matches(_ text: String, in tab: Tab) async -> Int {
        let value = try? await tab.web.evaluateJavaScript(Self.countScript(text))
        return (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
    }

    /// Esc leaves no highlight behind: WebKit's find *is* a selection, so dropping the
    /// selection drops the highlight with it.
    func clearHighlight(in tab: Tab?) {
        tab?.web.evaluateJavaScript(
            "if (window.getSelection) { window.getSelection().removeAllRanges(); }")
    }

    /// ⌘G and ⇧⌘G, from the menu or the key. With the bar closed but a query remembered
    /// they bring it back rather than doing nothing, which is what every other browser does.
    static func advance(forward: Bool) {
        guard let store = Windows.current, let tab = store.active else { return }
        let session = session(for: store)
        guard !session.query.isEmpty else {
            store.findOpen = true
            return
        }
        let text = session.query
        if !store.findOpen { store.findOpen = true }
        Task { await session.run(text, in: tab, forward: forward) }
    }

    /// Called once at launch so ⌘G works before the bar has ever been opened. Menu.swift
    /// registers the same two commands when it builds the Find submenu; last write wins and
    /// both run this.
    static func install() {
        Keybindings.actions[.findNext] = { advance(forward: true) }
        Keybindings.actions[.findPrevious] = { advance(forward: false) }
    }

    // MARK: Offline check

    static func check() -> [(String, Bool)] {
        let script = countScript("a\"b")
        return [
            ("nothing typed says nothing", label(index: 0, count: 0, query: "") == ""),
            ("a match reads as n of m", label(index: 3, count: 12, query: "q") == "3 of 12"),
            ("the first match reads as 1 of m", label(index: 1, count: 12, query: "q") == "1 of 12"),
            ("a single match still says one of one", label(index: 1, count: 1, query: "q") == "1 of 1"),
            ("no matches says so, in words", label(index: 0, count: 0, query: "q") == "No results"),
            ("a match with no position yet reads as the first one",
             label(index: 0, count: 4, query: "q") == "1 of 4"),
            ("the spoken count names the query when nothing matched",
             spoken(index: 0, count: 0, query: "zebra") == "No results for zebra"),
            ("the spoken count is the same count",
             spoken(index: 2, count: 9, query: "q") == "Match 2 of 9"),

            ("next moves forward", step(index: 1, count: 3, forward: true) == 2),
            ("previous moves back", step(index: 2, count: 3, forward: false) == 1),
            ("next off the end wraps to the first", step(index: 3, count: 3, forward: true) == 1),
            ("previous off the start wraps to the last",
             step(index: 1, count: 3, forward: false) == 3),
            ("with no matches there is nowhere to step",
             step(index: 0, count: 0, forward: true) == 0 && step(index: 0, count: 0, forward: false) == 0),
            ("stepping forward from nowhere lands on the first match",
             step(index: 0, count: 5, forward: true) == 1),
            ("stepping back from nowhere lands on the last",
             step(index: 0, count: 5, forward: false) == 5),
            ("one match wraps onto itself",
             step(index: 1, count: 1, forward: true) == 1 && step(index: 1, count: 1, forward: false) == 1),

            ("a plain query quotes as itself", quote("cat") == "\"cat\""),
            ("a quote in the query is escaped", quote("a\"b") == "\"a\\\"b\""),
            ("a backslash in the query is escaped", quote("a\\b") == "\"a\\\\b\""),
            ("a newline in the query is escaped", quote("a\nb") == "\"a\\nb\""),
            ("the counting script cannot be broken out of",
             !script.contains("(\"a\"b\")") && script.contains("\"a\\\"b\"")),
            ("the counting script skips markup nodes", script.contains("SCRIPT")),
        ]
    }
}

// MARK: - The bar

/// Arc's find bar: the field, the count beside it, previous and next, and a close button.
/// It floats at the top-right of the page card; `store.findOpen` is what puts it there.
///
/// The field is `CommandField` — the same AppKit field the command bar uses — because
/// Return, ⇧Return and Esc all have to be seen before the field editor decides what they
/// mean, and because focus has to stay in the field while the page scrolls under it.
struct FindBar: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var tab: Tab

    /// The session belongs to the window, not to this view: it has to outlive the bar so
    /// that ⌘F reopens on the same query and ⌘G works while the bar is closed. Resolving it
    /// here and observing it below is what redraws the count as matches are stepped through.
    var body: some View { FindBarBody(session: Find.session(for: store), tab: tab) }
}

private struct FindBarBody: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject var session: Find
    @ObservedObject var tab: Tab
    @State private var text = ""
    /// Held back one frame, exactly like the command bar's: an NSTextField can only take
    /// first responder once it is in a window.
    @State private var ready = false

    var body: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: "magnifyingglass").font(Look.caption).foregroundStyle(.secondary)
            if ready {
                CommandField(text: $text, prompt: "Find on page", selectAll: true,
                             label: "Find on Page",
                             hint: "Return finds the next match, Shift-Return the previous "
                                 + "one, Escape closes the bar.",
                             font: .systemFont(ofSize: Look.findFontSize),
                             onKey: key)
                    .frame(width: Look.findFieldWidth)
                    .foregroundStyle(miss ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            // "3 of 12". Fixed width so stepping through matches does not shuffle the
            // buttons beside it a pixel at a time.
            Text(Find.label(index: session.index, count: session.count, query: text))
                .font(Look.caption).monospacedDigit()
                .foregroundStyle(miss ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: Look.findCountWidth, alignment: .trailing)
                .accessibilityHidden(true)
            Button { search(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous Match (\(Keybindings.binding(for: .findPrevious).display))")
                .accessibilityLabel("Previous Match")
                .disabled(session.count == 0)
            Button { search(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next Match (\(Keybindings.binding(for: .findNext).display))")
                .accessibilityLabel("Next Match")
                .disabled(session.count == 0)
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Close Find Bar").accessibilityLabel("Close Find Bar")
        }
        .buttonStyle(.plain).font(Look.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Look.barFill, in: .rect(cornerRadius: Look.cardRadius))
        .background(Look.barMaterial, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        // ⌘F over a bar that is already up re-searches what is in it, so the query the
        // session remembers is what the field opens with — selected, ready to be replaced.
        .onAppear {
            text = session.query
            ready = true
            Find.install()
        }
        // Live, like every other find bar: each keystroke searches from the top again.
        .onChange(of: text) { search(forward: true, fresh: true) }
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on page")
        .accessibilityValue(Find.spoken(index: session.index, count: session.count, query: text))
        // Ahead of the page, behind a password prompt.
        .accessibilitySortPriority(1)
    }

    /// Red text is not an answer for anyone who cannot see it, but it is the fastest one
    /// for everybody else.
    private var miss: Bool { !text.isEmpty && session.count == 0 }

    private func key(_ k: CommandField.Key) -> Bool {
        switch k {
        case .enter:      search(forward: true)
        case .shiftEnter: search(forward: false)
        case .escape:     close()
        // Typing is what changes the query; the arrows and Tab belong to the field.
        case .up, .down, .tab, .commandEnter: return false
        }
        return true
    }

    /// Every keystroke starts the search again from the top of the page, which is what
    /// makes ⌘F feel live; Return and the chevrons step through what it found.
    private func search(forward: Bool, fresh: Bool = false) {
        let query = text
        Task {
            await session.run(query, in: tab, forward: forward, fresh: fresh)
            guard fresh else { return }
            axAnnounce(Find.spoken(index: session.index, count: session.count, query: query))
        }
    }

    /// Esc, and the × button: the bar goes, and so does the highlight it left on the page.
    private func close() {
        session.clearHighlight(in: tab)
        store.findOpen = false
    }
}
