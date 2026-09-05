import SwiftUI

/// Renaming a tab where it sits. Arc turns the row's title into a field on double-click; the
/// tab stays visible, the page stays put, and Return, Escape or a click elsewhere ends it.
/// This is that field and the one rule behind it.
enum Rename {
    /// What committing a field's text means for the tab's name.
    enum Outcome: Equatable {
        /// Nothing changed — the field held what the row already showed.
        case keep
        /// Drop the user's name and show the page's own title again.
        case clear
        /// Name the tab this.
        case set(String)
    }

    /// `typed` is the field's contents, `current` the override in force (nil when the tab
    /// wears its page's title) and `pageTitle` the title the page gives itself.
    /// Trimmed. Nothing left means "give me the page's title back" — the only way out of a
    /// rename that does not go through a menu. Typing the page's own title back means the
    /// same thing, so an override never quietly equals the thing it overrides.
    nonisolated static func outcome(typed: String, current: String?, pageTitle: String) -> Outcome {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == pageTitle { return current == nil ? .keep : .clear }
        return name == current ? .keep : .set(name)
    }

    nonisolated static func check() -> [(String, Bool)] {
        [
            ("a typed name is trimmed", outcome(typed: "  Docs  ", current: nil, pageTitle: "GitHub") == .set("Docs")),
            ("a newline is whitespace too", outcome(typed: "\nDocs\n", current: nil, pageTitle: "GitHub") == .set("Docs")),
            ("spaces inside a name are kept", outcome(typed: "Pull Requests", current: nil, pageTitle: "GitHub") == .set("Pull Requests")),
            ("an empty field on an unnamed tab changes nothing",
             outcome(typed: "", current: nil, pageTitle: "GitHub") == .keep),
            ("an empty field on a named tab restores the page's title",
             outcome(typed: "   ", current: "Docs", pageTitle: "GitHub") == .clear),
            ("the same name again is not a change", outcome(typed: "Docs", current: "Docs", pageTitle: "GitHub") == .keep),
            ("…even with stray spaces around it", outcome(typed: " Docs ", current: "Docs", pageTitle: "GitHub") == .keep),
            ("typing the page's own title back clears the override",
             outcome(typed: "GitHub", current: "Docs", pageTitle: "GitHub") == .clear),
            ("typing the page's own title on an unnamed tab changes nothing",
             outcome(typed: "GitHub", current: nil, pageTitle: "GitHub") == .keep),
            ("a different name replaces the old one",
             outcome(typed: "PRs", current: "Docs", pageTitle: "GitHub") == .set("PRs")),
            ("case matters: a tab can be named in lower case on purpose",
             outcome(typed: "github", current: nil, pageTitle: "GitHub") == .set("github")),
        ]
    }
}

/// The row's title while it is being edited. Sized and inked like the title it replaces, so
/// the row does not change shape when the field appears.
struct RenameField: View {
    @ObservedObject var store: TabStore
    @ObservedObject var tab: Tab
    var font: Font = Look.rowTitle
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tab name", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Look.inkPrimary)
            .focused($focused)
            .onSubmit { commit() }
            // Escape reverts. `onExitCommand`, not a key monitor: the field is first
            // responder and Escape has to leave the field, not stop the page or close a bar.
            .onExitCommand { cancel() }
            // What the row showed, selected whole: focusing an NSTextField selects its text,
            // so the first keystroke replaces the name rather than appending to it.
            .onAppear { draft = TidyTitles.title(for: tab); focused = true }
            // Clicking away commits, the way the Finder does — the alternative is a field the
            // user has to press Return in to be rid of.
            .onChange(of: focused) { _, now in if !now { commit() } }
            // Another rename starting, or the tab leaving, takes the field with it: what was
            // typed still counts, unless Escape already said otherwise.
            .onDisappear { commit() }
            .accessibilityLabel("Tab name")
            .accessibilityHint("Return renames the tab, Escape keeps its current name, an empty name restores the page's title.")
    }

    private func commit() {
        guard !done else { return }
        done = true
        defer { if store.renamingTab == tab.id { store.renamingTab = nil } }
        switch Rename.outcome(typed: draft, current: TabActions.rename(tab), pageTitle: tab.title) {
        case .keep: return
        case .clear: TidyTitles.rename(tab, to: nil); axAnnounce("Using the page's own title.")
        case .set(let name): TidyTitles.rename(tab, to: name); axAnnounce("Renamed to \(name).")
        }
    }

    private func cancel() {
        done = true
        if store.renamingTab == tab.id { store.renamingTab = nil }
    }
}
