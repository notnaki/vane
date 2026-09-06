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
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        let full = matchable(url)
        switch rule.match {
        case .contains:
            return full.range(of: pattern, options: .caseInsensitive) != nil
        case .isEqualTo:
            let host = url.host() ?? ""
            return host.compare(pattern, options: .caseInsensitive) == .orderedSame
                || full == pattern
        }
    }

    /// The url a rule is read against: the real one, with any `user:password@` in front of
    /// the host taken out.
    ///
    /// This is a routing decision, and routing decisions are attacker-reachable — the url
    /// arrives from another app. `https://github.com@evil.com/` is a page served by
    /// evil.com, but its `absoluteString` contains the text "github.com", so a rule reading
    /// the raw string would file an attacker's page under the Space you keep your work in
    /// and trust. Userinfo is the one part of a url that says nothing about where the page
    /// came from, so it is the one part a rule never sees.
    ///
    /// ponytail: `URLComponents` with the two fields nil'd, not a parser. Ceiling: a url
    /// `URLComponents` cannot parse is matched as it arrived, which is the behaviour
    /// everything else in Vane gives such a url too.
    nonisolated static func matchable(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user != nil || parts.password != nil else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        return parts.string ?? url.absoluteString
    }

    /// Dropping the rule `dragged` onto `target` puts it where the target was. Pure over the
    /// ids, because the arithmetic is the part that is easy to get wrong: removing the
    /// dragged rule first shifts everything after it down one, so a drag *downwards* has to
    /// land one slot earlier than the index the target had before the removal. Without the
    /// adjustment, dragging A onto C in [A, B, C] gives [B, C, A] — the rule ends up past
    /// the row it was dropped on, and with "first match wins" that is a different browser.
    ///
    /// A dropped rule always lands *above* the row it was dropped on, which is what makes
    /// dragging one up by a row swap the pair. ponytail ceiling: dragging one *down* by a
    /// single row therefore leaves it exactly where it was — its landing slot is the one it
    /// already occupies. Upgrade path is a drop indicator that says which half of the row
    /// the pointer is in, and an "insert below" for the lower half; the card's footnote
    /// says "move it up" because up is the direction this gesture is exact in.
    ///
    /// Nil when the drag was not one of ours (a link, a file, a rule already gone), which is
    /// what makes such a drop a no-op rather than a scrambled list.
    nonisolated static func reordered(_ ids: [UUID], moving dragged: UUID,
                                      onto target: UUID) -> [UUID]? {
        guard dragged != target, let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var out = ids
        out.insert(out.remove(at: from), at: from < to ? to - 1 : to)
        return out
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
            // "Most recent" means the Space the user is *looking at*, and only failing that
            // the one the profile was last left in — the same order `LittleArc.spaceMenu`
            // ticks a row in. Reading the persisted id first would drag the frontmost
            // window off the Space it is showing to a Space it was in yesterday, tearing
            // its strip down on the way; asking the live window first makes `switchTo` the
            // no-op it should be.
            let last = target(in: profile.id)?.currentSpaceID
                ?? TabStore.lastSpaceID(for: profile.id)
            open(url, in: Spaces.pick(asked: nil, last: last, from: spaces))
        }
        return true
    }

    /// The window a rule may put a tab in: an ordinary one, never a Little Arc and never a
    /// Private Window. `Windows.current(in:)` excludes only Little Arcs, and a private
    /// window is spaceless by design — `switchTo` refuses on one, so a link routed there
    /// would land in whatever that window was showing and the rule would look ignored.
    private static func target(in profileID: UUID) -> TabStore? {
        let mine = TabStore.all.filter { $0.profileID == profileID && !$0.isLittle && !$0.isPrivate }
        return mine.first { $0.window?.isKeyWindow == true } ?? mine.last
    }

    /// A link into a named Space: a Today tab in a window showing that Space, switching one
    /// over if it is showing another, and opening one if the profile has none up. `nil`
    /// cannot happen through `route` — it filters deleted Spaces out — but "Most Recent
    /// Space" for a profile with no Spaces at all reaches here, and doing nothing would eat
    /// the link, so it falls back to a plain window.
    private static func open(_ url: URL, in space: Space?) {
        guard let space, let window = target(in: space.profileID) else {
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
        get { decode(UserDefaults.vane.data(forKey: key)) }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.vane.set(data, forKey: key)
        }
    }

    /// Element-wise, because `decode([Rule].self)` is all-or-nothing: one rule written by a
    /// newer Vane with a match this one has never heard of would decode as nothing, the
    /// Settings pane would come up empty, and the user's first edit would write that empty
    /// list back over the lot. A rule that cannot be read is dropped; the ones around it
    /// keep their turn. Pure, so `selfcheck --pure` can prove exactly that.
    nonisolated static func decode(_ data: Data?) -> [Rule] {
        guard let data, let items = try? JSONDecoder().decode([Lenient].self, from: data)
        else { return [] }
        return items.compactMap(\.rule)
    }

    /// One element of the stored array, decoded so that a failure is a value rather than an
    /// error — `init(from:)` never throws, so the array around it still decodes.
    private struct Lenient: Decodable {
        let rule: Rule?
        init(from decoder: Decoder) throws {
            rule = try? Rule(from: decoder)
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

        var out: [(String, Bool)] = [
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
                guard let data = try? JSONEncoder().encode([one]) else { return false }
                return decode(data) == [one]
            }()),
            ("userinfo is not part of the url a rule reads", {
                // `https://github.com@evil.com/` is served by evil.com. A rule that files
                // github.com under a Space must not file this page there too.
                let spoof = URL(string: "https://github.com@evil.com/x")!
                return route(url: spoof, rules: [rule(.contains, "github.com", .littleArc)],
                             spaces: spaces) == nil
            }()),
            ("\u{2026}and the host it really is still matches",
             route(url: URL(string: "https://github.com@evil.com/x")!,
                   rules: [rule(.contains, "evil.com", .littleArc)], spaces: spaces)
                == .littleArc),
            ("a url with no userinfo is read exactly as it arrived",
             matchable(gh) == gh.absoluteString),
            ("a pattern's surrounding whitespace and newlines are ignored",
             route(url: gh, rules: [rule(.isEqualTo, " github.com \n", .littleArc)],
                   spaces: spaces) == .littleArc),
        ]

        // Reordering. The arithmetic that decides what "first match wins" means.
        let (a, b, c) = (UUID(), UUID(), UUID())
        out += [
            ("dragging the first rule onto the last one lands it above the last",
             reordered([a, b, c], moving: a, onto: c) == [b, a, c]),
            ("dragging the last rule onto the first one puts it first",
             reordered([a, b, c], moving: c, onto: a) == [c, a, b]),
            ("dragging a rule one row down leaves it where it was, which is above that row",
             reordered([a, b, c], moving: a, onto: b) == [a, b, c]),
            ("dragging a rule one row up swaps the pair",
             reordered([a, b, c], moving: b, onto: a) == [b, a, c]),
            ("dragging a rule onto itself is not a move",
             reordered([a, b, c], moving: a, onto: a) == nil),
            ("a drag carrying something that is not one of these rules is refused",
             reordered([a, b, c], moving: UUID(), onto: b) == nil),
            ("\u{2026}and so is a drop on a rule that is no longer there",
             reordered([a, b, c], moving: a, onto: UUID()) == nil),
            ("every rule survives a reorder",
             reordered([a, b, c], moving: a, onto: c)?.count == 3),
        ]

        // Decoding. One unreadable rule must not cost the user the rest of the list.
        let good = #"{"id":"\#(a.uuidString)","match":"contains","pattern":"x","destination":"little"}"#
        let good2 = #"{"id":"\#(b.uuidString)","match":"isEqualTo","pattern":"y","destination":"recent"}"#
        let bad = #"{"id":"\#(c.uuidString)","match":"startsWith","pattern":"z","destination":"little"}"#
        out += [
            ("a stored list decodes", decode(Data("[\(good),\(good2)]".utf8)).count == 2),
            ("one rule written by a newer Vane is dropped, not the whole list",
             decode(Data("[\(good),\(bad),\(good2)]".utf8)).map(\.pattern) == ["x", "y"]),
            ("\u{2026}and the surviving rules keep their order",
             decode(Data("[\(bad),\(good2),\(good)]".utf8)).map(\.pattern) == ["y", "x"]),
            ("a list that is not a list at all decodes as no rules",
             decode(Data("not json".utf8)).isEmpty),
            ("nothing stored means no rules", decode(nil).isEmpty),
        ]

        return out
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
                    // ponytail: the payload is the rule's id as a plain String, so the row
                    // lights up for any text drag and not only for another rule. `move`
                    // refuses anything that is not the id of a rule in this list, so such a
                    // drop changes nothing — macOS 26 favours the `(items, session) -> Void`
                    // overload, so that refusal has nowhere to be reported anyway. Ceiling:
                    // the highlight is keener than the drop. Upgrade path is a `Transferable`
                    // Rule with its own UTType, which is a type and an exported identifier
                    // for one settings row.
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
        guard let dragged = items.first.flatMap(UUID.init(uuidString:)),
              let order = AirTraffic.reordered(rules.map(\.id), moving: dragged, onto: target)
        else { return false }
        rules = order.compactMap { id in rules.first { $0.id == id } }
        return true
    }
}

/// "When a link [contains ▾] [pattern] open in [destination ▾] −", laid out on the settings
/// row grid so it sits in the card like every other row.
private struct RuleRow: View {
    @Binding var rule: AirTraffic.Rule
    let spaces: [Space]
    let remove: () -> Void

    /// True when the rule points at a Space this profile does not have.
    private var orphaned: Bool {
        rule.destination != AirTraffic.Destination.littleTag
            && rule.destination != AirTraffic.Destination.recentTag
            && !spaces.contains { $0.id.uuidString == rule.destination }
    }

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
                // A rule aimed at a Space that has since been deleted — or one belonging to
                // another profile — has no row to select, and a Picker with no matching tag
                // draws blank. `route` already skips such a rule; this is what says so on
                // screen, so the fix is to pick a real destination rather than to wonder why
                // the row does nothing.
                if orphaned {
                    Text("Deleted Space").tag(rule.destination)
                }
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
