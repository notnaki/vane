import SwiftUI
import UniformTypeIdentifiers

/// Arc's Air Traffic Control: a list of rules that says where a link from *outside* the app
/// lands, before the blanket "Open links from other apps in" preference gets a say.
///
/// The point is that one answer is never right for every link. Figma links belong in the
/// Work Space with the rest of the design tabs; a GitHub notification belongs in a Little
/// Arc you read once and throw away; everything else can keep doing whatever the preference
/// says. Without this, "Little Arc" means the Figma link comes up in a window that has none
/// of your logins-in-context and has to be handed over by hand every single time.
///
/// Rules are ordered and the first match wins, so a specific rule sits above a general one
/// — exactly the way a firewall or a mail filter reads. There is no "otherwise" row: falling
/// off the end is the preference, which is a rule the user already wrote.
@MainActor enum AirTraffic {

    // MARK: - The rule

    /// Arc offers exactly these two. Deliberately not a regex: a rule you can get wrong in a
    /// way you cannot see is a rule that silently sends your bank link to the wrong Space.
    /// ponytail ceiling: no "starts with"/"ends with", no globs. Upgrade path is another
    /// case here and another row in the picker; `matches` is the only thing that changes.
    enum Match: String, Codable, Sendable, CaseIterable {
        case contains, isEqualTo

        var title: String {
            switch self {
            case .contains:  "contains"
            case .isEqualTo: "is equal to"
            }
        }
    }

    /// Where a matched link goes.
    ///
    /// ponytail: stored as a tag string rather than as an enum with an associated value, so
    /// `Rule` gets `Codable` for free and a rule pointing at a Space that has since been
    /// deleted decodes fine and is simply skipped at routing time — rather than failing to
    /// decode and taking every rule after it down with it.
    enum Destination: Equatable, Sendable {
        case littleArc
        case mostRecentSpace
        case space(UUID)

        static let littleTag = "little"
        static let recentTag = "recent"

        var tag: String {
            switch self {
            case .littleArc:       Self.littleTag
            case .mostRecentSpace: Self.recentTag
            case .space(let id):   id.uuidString
            }
        }

        init?(tag: String) {
            switch tag {
            case Self.littleTag:  self = .littleArc
            case Self.recentTag:  self = .mostRecentSpace
            default:
                guard let id = UUID(uuidString: tag) else { return nil }
                self = .space(id)
            }
        }
    }

    /// One row of the list. `id` is only ever the list's identity — it is never matched on,
    /// and it is what a drag carries.
    struct Rule: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var match: Match = .contains
        var pattern: String = ""
        var destination: String = Destination.littleTag
    }

    // MARK: - Routing

    /// Nil means "no rule had an opinion", which is what hands the link back to the
    /// preference. Pure, so `selfcheck --pure` can prove the order and the skips without a
    /// window server, a profile on disk or a UserDefaults suite.
    ///
    /// `spaces` is passed in rather than read, because the one thing that has to be provable
    /// here is that a rule aimed at a Space that no longer exists is *skipped* and the rules
    /// under it still get their turn — not that it silently opens a window in some other
    /// Space, and not that it swallows the link.
    nonisolated static func route(url: URL, rules: [Rule], spaces: [Space]) -> Destination? {
        for rule in rules {
            guard let destination = Destination(tag: rule.destination),
                  matches(url: url, rule: rule) else { continue }
            if case .space(let id) = destination,
               !spaces.contains(where: { $0.id == id }) { continue }
            return destination
        }
        return nil
    }

    /// Whether one rule speaks for one url.
    ///
    /// "Contains" is asked of the whole url, so a pattern names a host, a path or a query
    /// string with no syntax to learn — and case-insensitively, because a host is
    /// case-insensitive and nobody typing `GitHub.com` means something different by it.
    ///
    /// "Is equal to" is asked of the *host* as well as of the whole url: a user who types
    /// `github.com` and picks "is equal to" means the site, not the one url that happens to
    /// be exactly that string. The host comparison is case-insensitive; the full-url one is
    /// not, because a path genuinely is case-sensitive and `/A` is not `/a`.
    ///
    /// An empty pattern never matches. A blank row is what a half-finished rule looks like,
    /// and one that matched everything would route every link in the browser to whatever
    /// destination happened to be in the picker.
    nonisolated static func matches(url: URL, rule: Rule) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        let full = url.absoluteString
        switch rule.match {
        case .contains:
            return full.range(of: pattern, options: .caseInsensitive) != nil
        case .isEqualTo:
            let host = url.host() ?? ""
            return host.compare(pattern, options: .caseInsensitive) == .orderedSame
                || full == pattern
        }
    }

    // MARK: - Doing it

    /// `URLHandling.open`'s first question about every incoming link. True when a rule took
    /// it, so the caller leaves it alone.
    static func hand(_ url: URL) -> Bool {
        let profile = ProfileManager.shared.active
        let spaces = ProfileManager.shared.spaces(for: profile.id)
        guard let destination = route(url: url, rules: rules, spaces: spaces) else { return false }
        switch destination {
        case .littleArc:
            LittleArc.open(url)
        case .space(let id):
            open(url, in: spaces.first { $0.id == id })
        case .mostRecentSpace:
            // The same rule an ordinary new window follows, so "Most Recent Space" and
            // "wherever a window would have opened" cannot drift apart.
            open(url, in: Spaces.pick(asked: nil, last: TabStore.lastSpaceID(for: profile.id),
                                      from: spaces))
        }
        return true
    }

    /// A link into a named Space: a Today tab in a window showing that Space, switching one
    /// over if it is showing another, and opening one if the profile has none up. `nil`
    /// cannot happen through `route` — it filters deleted Spaces out — but "Most Recent
    /// Space" for a profile with no Spaces at all reaches here, and doing nothing would eat
    /// the link, so it falls back to a plain window.
    private static func open(_ url: URL, in space: Space?) {
        guard let space, let window = Windows.current(in: space.profileID) else {
            Windows.open(urls: [url], space: space)
            return
        }
        if window.currentSpaceID != space.id { window.switchTo(space: space) }
        window.newTab(url)
        window.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Storage

    /// JSON in `UserDefaults.vane`, not a file: this is a preference, it is small, and it
    /// belongs beside the "Open links from other apps in" setting it overrides — which is
    /// also what makes `VANE_DATA_DIR` isolate it for free.
    static let key = "airTrafficRules"

    static var rules: [Rule] {
        get {
            guard let data = UserDefaults.vane.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.vane.set(data, forKey: key)
        }
    }

    // MARK: - check

    nonisolated static func check() -> [(String, Bool)] {
        let work = Space(name: "Work", profileID: UUID())
        let gone = UUID()
        let spaces = [work]
        func rule(_ match: Match, _ pattern: String, _ to: Destination) -> Rule {
            Rule(match: match, pattern: pattern, destination: to.tag)
        }
        let gh = URL(string: "https://github.com/vane/pulls?q=is%3Aopen")!
        let ex = URL(string: "https://example.com/A")!

        return [
            ("a \u{201C}contains\u{201D} rule matches anywhere in the url",
             route(url: gh, rules: [rule(.contains, "pulls", .littleArc)], spaces: spaces)
                == .littleArc),
            ("\u{2026}including in the host",
             route(url: gh, rules: [rule(.contains, "github.com", .space(work.id))], spaces: spaces)
                == .space(work.id)),
            ("\u{201C}contains\u{201D} is case-insensitive",
             route(url: gh, rules: [rule(.contains, "GitHub.COM", .littleArc)], spaces: spaces)
                == .littleArc),
            ("a \u{201C}contains\u{201D} rule that is nowhere in the url does not match",
             route(url: gh, rules: [rule(.contains, "figma", .littleArc)], spaces: spaces) == nil),
            ("\u{201C}is equal to\u{201D} matches the host on its own",
             route(url: gh, rules: [rule(.isEqualTo, "github.com", .mostRecentSpace)], spaces: spaces)
                == .mostRecentSpace),
            ("\u{2026}case-insensitively",
             route(url: gh, rules: [rule(.isEqualTo, "GITHUB.COM", .littleArc)], spaces: spaces)
                == .littleArc),
            ("\u{201C}is equal to\u{201D} matches the whole url",
             route(url: gh, rules: [rule(.isEqualTo, gh.absoluteString, .littleArc)], spaces: spaces)
                == .littleArc),
            ("\u{201C}is equal to\u{201D} is not \u{201C}contains\u{201D}",
             route(url: gh, rules: [rule(.isEqualTo, "github", .littleArc)], spaces: spaces) == nil),
            ("a path is compared case-sensitively, unlike a host",
             route(url: ex, rules: [rule(.isEqualTo, "https://example.com/a", .littleArc)],
                   spaces: spaces) == nil),
            ("the first matching rule wins",
             route(url: gh, rules: [rule(.contains, "github", .littleArc),
                                    rule(.contains, "github", .mostRecentSpace)],
                   spaces: spaces) == .littleArc),
            ("\u{2026}and rules before it that do not match are stepped over",
             route(url: gh, rules: [rule(.contains, "figma", .mostRecentSpace),
                                    rule(.contains, "github", .littleArc)],
                   spaces: spaces) == .littleArc),
            ("a rule pointing at a deleted Space is skipped",
             route(url: gh, rules: [rule(.contains, "github", .space(gone))], spaces: spaces) == nil),
            ("\u{2026}and the rules under it still get their turn",
             route(url: gh, rules: [rule(.contains, "github", .space(gone)),
                                    rule(.contains, "github", .littleArc)],
                   spaces: spaces) == .littleArc),
            ("an empty pattern never matches",
             route(url: gh, rules: [rule(.contains, "", .littleArc)], spaces: spaces) == nil),
            ("\u{2026}nor does one that is only spaces",
             route(url: gh, rules: [rule(.isEqualTo, "   ", .littleArc)], spaces: spaces) == nil),
            ("no rules at all means the preference decides",
             route(url: gh, rules: [], spaces: spaces) == nil),
            ("a rule whose destination is not a tag we know is skipped",
             route(url: gh, rules: [Rule(match: .contains, pattern: "github", destination: "?")],
                   spaces: spaces) == nil),
            ("a destination survives the round-trip through its tag",
             Destination(tag: Destination.littleArc.tag) == .littleArc
                && Destination(tag: Destination.mostRecentSpace.tag) == .mostRecentSpace
                && Destination(tag: Destination.space(work.id).tag) == .space(work.id)),
            ("a rule round-trips through JSON, which is how it is stored", {
                let one = rule(.isEqualTo, "figma.com", .space(work.id))
                guard let data = try? JSONEncoder().encode([one]),
                      let back = try? JSONDecoder().decode([Rule].self, from: data)
                else { return false }
                return back == [one]
            }()),
        ]
    }
}

// MARK: - Settings › Links

/// Air Traffic Control's card in the Links pane: one row per rule, read as a sentence.
/// ponytail: the rules are `@State` mirroring `AirTraffic.rules` rather than a published
/// store — nothing else in the app watches them, and the only reader (`URLHandling.open`)
/// re-reads defaults on every link. Ceiling: two settings windows would not see each other's
/// edits, and there is only ever one.
struct AirTrafficCard: View {
    @State private var rules = AirTraffic.rules
    /// The Spaces the destination picker offers. Read once: adding a Space is done in
    /// another pane, and reopening Settings is what picks it up.
    private let spaces = ProfileManager.shared.spaces(for: ProfileManager.shared.active.id)

    var body: some View {
        SettingsCard {
            ForEach($rules) { $rule in
                RuleRow(rule: $rule, spaces: spaces) { remove(rule.id) }
                    // Drag to reorder, because "first match wins" is the whole model and a
                    // list you cannot reorder is one you have to delete and retype.
                    .draggable(rule.id.uuidString)
                    // macOS 26 favours the `(items, session) -> Void` overload, so the
                    // "was this one of ours" answer goes nowhere — `move` changing nothing
                    // is what makes a drag of anything else a no-op rather than an error.
                    .dropDestination(for: String.self) { items, _ in
                        _ = move(items, above: rule.id)
                    }
            }
            HStack(spacing: Look.inset) {
                Button {
                    rules.append(AirTraffic.Rule())
                    save()
                } label: {
                    Label("Add a Rule", systemImage: "plus")
                        .font(Look.text)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityHint("Adds a rule to the bottom of the list.")
                Spacer(minLength: Look.inset)
            }
            .padding(.horizontal, Look.cardInset)
            .frame(minHeight: Look.settingsRow)
            Footnote("Links from other apps are checked against these rules in order, and the "
                     + "first one that matches decides where the link opens. Drag a rule to "
                     + "move it up. A link that matches nothing follows the setting above.")
        }
        // Every edit writes straight through: a settings window has no Save button, and a
        // rule that only existed until the window closed would be a bug you cannot see.
        .onChange(of: rules) { save() }
    }

    private func save() { AirTraffic.rules = rules }

    private func remove(_ id: UUID) { rules.removeAll { $0.id == id } }

    /// Dropping rule A on rule B puts A where B was — the one gesture, and enough to build
    /// any order out of. Returns false when the drag was not one of ours, which is what
    /// makes a dragged link or a dragged file bounce back instead of scrambling the list.
    private func move(_ items: [String], above target: UUID) -> Bool {
        guard let dragged = items.first.flatMap(UUID.init(uuidString:)), dragged != target,
              let from = rules.firstIndex(where: { $0.id == dragged }),
              let to = rules.firstIndex(where: { $0.id == target }) else { return false }
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
        return true
    }
}

/// "When a link [contains ▾] [pattern] open in [destination ▾] −", laid out on the settings
/// row grid so it sits in the card like every other row.
private struct RuleRow: View {
    @Binding var rule: AirTraffic.Rule
    let spaces: [Space]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Look.inset) {
            Text("When a link").font(Look.text).foregroundStyle(Look.inkPrimary)
            Picker("", selection: $rule.match) {
                ForEach(AirTraffic.Match.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("How this rule matches")
            TextField("", text: $rule.pattern, prompt: Text("figma.com"))
                .settingsField().frame(minWidth: 100)
                .accessibilityLabel("What this rule matches")
            Text("open in").font(Look.text).foregroundStyle(Look.inkPrimary)
            Picker("", selection: $rule.destination) {
                Text("Little Arc").tag(AirTraffic.Destination.littleTag)
                Text("Most Recent Space").tag(AirTraffic.Destination.recentTag)
                // A Space is offered by name; the tag it carries is its id, so renaming one
                // keeps the rule pointing at it.
                ForEach(spaces) { Text($0.name).tag($0.id.uuidString) }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel("Where a matching link opens")
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Remove this rule")
        }
        .padding(.horizontal, Look.cardInset)
        .frame(minHeight: Look.settingsRow)
        .contentShape(.rect)          // the whole row is the drag handle, not just the text
    }
}

/// A text field that reads as a control rather than a hole in the card. The same shape
/// SettingsWindow's own fields have; duplicated rather than exported because one modifier
/// is not worth a shared file, and this is the only user outside that file.
private extension View {
    func settingsField() -> some View {
        textFieldStyle(.plain).font(Look.text)
            .padding(.horizontal, Look.inset)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
    }
}
