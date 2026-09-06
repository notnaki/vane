import AppKit
import SwiftUI

/// Settings ▸ Passwords: the saved logins, grouped by site, searchable, editable.
///
/// Arc leans on Chromium's own password page for this; Vane has no Chromium, so this is
/// that page. The store underneath is still the login keychain — Passwords.swift owns every
/// query — and Keychain Access opens exactly the same items. What this adds is the part
/// Keychain Access is bad at: finding a login by site, seeing which account is which, and
/// changing one without three sheets.
///
/// No password is read until something actually needs it: the list is names only, and a
/// reveal, a copy or an edit decrypts that one row behind the system's own authentication,
/// then forgets it again a minute later.
///
/// The pure parts (grouping, search, what a keystroke means, what VoiceOver is allowed to
/// hear) are static functions with a `check()`, so they can be proved headless.
@MainActor struct PasswordsPane: View {
    @ObservedObject private var manager = ProfileManager.shared
    @State private var query = ""
    /// The keychain is not a publisher, so the pane holds its own copy of the *names* and
    /// reloads after every write it makes.
    @State private var logins: [Passwords.Login] = []
    /// Sites the user answered "Never for This Site" on. Listed so the answer can be taken
    /// back, which is otherwise a decision with no undo.
    @State private var never: [String] = []
    @State private var selected: String?
    /// Plaintext the user has authenticated to see, by row id. Dropped when the row is
    /// hidden again, when the pane goes away, and on its own after `revealFor`.
    @State private var revealed: [String: String] = [:]
    /// The row being edited, and its two fields. Held apart from `logins` on purpose: Cancel
    /// is then free, and the draft password can be wiped without touching the store.
    @State private var editing: String?
    @State private var draftAccount = ""
    @State private var draftPassword = ""
    @FocusState private var listFocused: Bool

    /// What a hidden password looks like. Eight bullets whatever the real length — the
    /// length of a password is itself worth not leaking.
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
    /// How long a revealed password stays on screen. Long enough to type it somewhere,
    /// short enough that a settings window left open is not a password on a wall.
    static let revealFor: Duration = .seconds(60)
    /// And how long a copied one stays on the clipboard.
    static let copyFor: Duration = .seconds(60)

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var profileID: UUID { manager.active.id }
    private var groups: [(host: String, logins: [Passwords.Login])] {
        PasswordsPane.groups(logins, query: query)
    }
    private var neverShown: [String] { PasswordsPane.matching(never, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            search
            if groups.isEmpty && neverShown.isEmpty {
                quiet(logins.isEmpty && never.isEmpty
                      ? "Passwords you save as you sign in to sites appear here."
                      : "Nothing matches \u{201C}\(query)\u{201D}")
            } else {
                if !groups.isEmpty { list }
                if !neverShown.isEmpty { neverCard }
            }
        }
        .padding(.top, Look.inset * 2)
        .onAppear { reload() }
        .onDisappear { forgetSecrets() }
        .onChange(of: manager.active.id) { reload() }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(Look.text).foregroundStyle(Look.inkSecondary)
            .padding(.horizontal, Look.cardInset)
    }

    private var search: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: "magnifyingglass").font(Look.fieldIcon)
                .foregroundStyle(Look.inkTertiary)
            TextField("", text: $query, prompt: Text("Search saved logins"))
                .textFieldStyle(.plain).font(Look.text)
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.control + Look.inset)
        .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
        .accessibilityLabel("Search saved logins")
    }

    /// One card per site, the way Arc groups anything that has a host: the favicon and the
    /// host once at the top, then a row per account under it.
    private var list: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            ForEach(groups, id: \.host) { group in
                SettingsCard {
                    site(group.host, count: group.logins.count)
                    ForEach(group.logins) { row($0) }
                }
            }
        }
        .focusable()
        .focused($listFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .delete, .deleteForward, "c"],
                    phases: .down) { press in
            handle(PasswordsPane.command(for: press.key, press.modifiers))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved logins")
    }

    /// Arc keeps its "Never Saved" list under the passwords themselves, as the answer to
    /// "why is this site not offering". One row per site, and one button to change the mind.
    private var neverCard: some View {
        SettingsSection("Never Saved") {
            SettingsCard {
                ForEach(neverShown, id: \.self) { host in
                    SettingsRow(host) {
                        Button {
                            Passwords.allowSaving(host: host, profileID: profileID)
                            reload()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
                            .accessibilityLabel("Offer to save passwords for \(host) again")
                    }
                }
                Footnote("Vane does not offer to save a password on these sites. Remove one "
                         + "and it will ask again the next time you sign in there.")
            }
        }
    }

    private func site(_ host: String, count: Int) -> some View {
        HStack(spacing: Look.inset) {
            SiteIcon(icon: URL(string: "https://" + host).flatMap {
                Favicons.cache(for: profileID).icon(for: $0)
            }, fallback: "key.fill", size: Look.rowIcon)
            Text(host).font(Look.heading).foregroundStyle(Look.inkPrimary)
            Spacer(minLength: Look.inset)
            if count > 1 {
                Text("\(count) logins").font(Look.caption).foregroundStyle(Look.inkQuiet)
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(minHeight: Look.settingsRow)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func row(_ login: Passwords.Login) -> some View {
        let isEditing = editing == login.id
        VStack(alignment: .leading, spacing: Look.inset) {
            HStack(spacing: Look.inset) {
                if isEditing {
                    TextField("", text: $draftAccount, prompt: Text("Username"))
                        .textFieldStyle(.plain).font(Look.text).frame(width: 180)
                } else {
                    Text(login.account.isEmpty ? "No username" : login.account)
                        .font(Look.text).foregroundStyle(Look.inkPrimary)
                }
                Spacer(minLength: Look.inset)
                secret(login, editing: isEditing)
                controls(login, editing: isEditing)
            }
            if isEditing {
                HStack(spacing: Look.inset) {
                    Spacer(minLength: 0)
                    Button("Cancel") { cancelEditing() }
                    Button("Save") { commit(login) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, Look.cardInset)
        .padding(.vertical, Look.inset / 2)
        .frame(minHeight: Look.settingsRow)
        .background(selected == login.id ? Look.accentSelected : .clear,
                    in: .rect(cornerRadius: Look.chipRadius))
        .contentShape(.rect)
        .onTapGesture { selected = login.id; listFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(login.account.isEmpty ? "No username" : login.account)
        // Never the password unless the user has authenticated to see it — an accessibility
        // value is read aloud and is readable by any process with the trust to ask.
        .accessibilityValue(PasswordsPane.spoken(revealed[login.id]))
        .accessibilityAddTraits(selected == login.id ? [.isSelected] : [])
    }

    /// The password itself, or eight bullets. A plain Text while hidden rather than a
    /// disabled SecureField: nothing to select, nothing to copy out of the view hierarchy.
    @ViewBuilder private func secret(_ login: Passwords.Login, editing: Bool) -> some View {
        let shown = revealed[login.id]
        if editing {
            if shown != nil {
                TextField("", text: $draftPassword).textFieldStyle(.plain)
                    .font(Look.text).frame(width: 160)
            } else {
                SecureField("", text: $draftPassword).textFieldStyle(.plain)
                    .font(Look.text).frame(width: 160)
            }
        } else {
            Text(shown ?? PasswordsPane.dots)
                .font(Look.text)
                .foregroundStyle(shown == nil ? Look.inkTertiary : Look.inkPrimary)
                .lineLimit(1).truncationMode(.tail).frame(width: 160, alignment: .trailing)
        }
    }

    private func controls(_ login: Passwords.Login, editing isEditing: Bool) -> some View {
        let shown = revealed[login.id] != nil
        return HStack(spacing: Look.inset) {
            glyph(shown ? "eye.slash" : "eye", shown ? "Hide password" : "Show password") {
                toggleReveal(login)
            }
            glyph("person.crop.circle", "Copy username for \(login.host)") {
                copy(login.account, secret: false)
            }
            glyph("key", "Copy password for \(login.host)") { copyPassword(login) }
            if !isEditing {
                glyph("pencil", "Edit \(login.account) on \(login.host)") { startEditing(login) }
            }
            glyph("trash", "Delete \(login.account) on \(login.host)") { remove(login) }
        }
        .font(Look.rowGlyph)
    }

    private func glyph(_ symbol: String, _ label: String,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
            .accessibilityLabel(label)
    }

    // MARK: Actions

    private func reload() {
        logins = Passwords.all(profileID: profileID)
        never = Passwords.neverSaved(profileID: profileID)
        if let selected, !logins.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    private func forgetSecrets() {
        revealed.removeAll()
        draftPassword = ""
        editing = nil
    }

    /// Hiding needs no permission; showing does — and what comes back is held for a minute
    /// and then dropped, whether or not anybody is still looking at this window.
    private func toggleReveal(_ login: Passwords.Login) {
        if revealed.removeValue(forKey: login.id) != nil { return }
        Passwords.authenticate("show the password for \(login.host)") { ok in
            guard ok, let plain = Passwords.password(host: login.host, account: login.account,
                                                     profileID: profileID) else { return }
            revealed[login.id] = plain
            axAnnounce("Password for \(login.host) shown.")
            Task {
                try? await Task.sleep(for: PasswordsPane.revealFor)
                revealed[login.id] = nil
            }
        }
    }

    private func copy(_ text: String, secret: Bool) {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        // Clipboard managers and history utilities honour this type by not recording the
        // item. Costs two lines and keeps a password out of a dozen third-party databases.
        board.declareTypes(secret ? [.string, PasswordsPane.concealed] : [.string], owner: nil)
        board.setString(text, forType: .string)
        guard secret else { return }
        board.setString("", forType: PasswordsPane.concealed)
        let stamp = board.changeCount
        Task {
            try? await Task.sleep(for: PasswordsPane.copyFor)
            // Only if nobody has copied anything since. Wiping somebody else's clipboard is
            // worse than leaving a password on it for a minute.
            if NSPasteboard.general.changeCount == stamp { NSPasteboard.general.clearContents() }
        }
    }

    /// Copying a password is the same door as revealing one, so it asks the same way.
    private func copyPassword(_ login: Passwords.Login) {
        if let shown = revealed[login.id] {
            copy(shown, secret: true)
            axAnnounce("Password copied.")
            return
        }
        Passwords.authenticate("copy the password for \(login.host)") { ok in
            guard ok, let plain = Passwords.password(host: login.host, account: login.account,
                                                     profileID: profileID) else { return }
            copy(plain, secret: true)
            axAnnounce("Password copied.")
        }
    }

    /// Editing puts the password into a field the user can read, so it is the same door as
    /// revealing one and asks the same way.
    private func startEditing(_ login: Passwords.Login) {
        Passwords.authenticate("edit the saved login for \(login.host)") { ok in
            guard ok, let plain = Passwords.password(host: login.host, account: login.account,
                                                     profileID: profileID) else { return }
            selected = login.id
            editing = login.id
            draftAccount = login.account
            draftPassword = plain
        }
    }

    private func cancelEditing() {
        editing = nil
        draftPassword = ""
    }

    /// A changed username is a different keychain item, so the old one goes — but only after
    /// the new one is safely stored, and only after its last-used stamp has moved across.
    private func commit(_ login: Passwords.Login) {
        let account = draftAccount.trimmingCharacters(in: .whitespaces)
        // Checked before anything is closed or written. An empty password is not a password,
        // and quietly keeping the old one while the field says otherwise is worse than
        // refusing.
        guard !draftPassword.isEmpty, !account.isEmpty else { return }
        Passwords.save(host: login.host, account: account, password: draftPassword,
                       profileID: profileID)
        if account != login.account {
            Passwords.renameUse(host: login.host, from: login.account, to: account,
                                profileID: profileID)
            Passwords.delete(host: login.host, account: login.account, profileID: profileID)
        }
        editing = nil
        draftPassword = ""
        revealed[login.id] = nil
        selected = Passwords.key(host: login.host, account: account)
        reload()
    }

    private func remove(_ login: Passwords.Login) {
        guard confirm("Delete the saved login for \(login.host)?", "Delete",
                      PasswordsPane.deleteDetail(login)) else { return }
        Passwords.delete(host: login.host, account: login.account, profileID: profileID)
        revealed[login.id] = nil
        if editing == login.id { cancelEditing() }
        reload()
        axAnnounce("Saved login for \(login.host) deleted.")
    }

    // MARK: Keyboard

    private func handle(_ command: RowCommand?) -> KeyPress.Result {
        let ids = groups.flatMap { $0.logins.map(\.id) }
        guard let command, !ids.isEmpty else { return .ignored }
        switch command {
        case .up, .down:
            selected = PasswordsPane.move(selected, in: ids, by: command == .up ? -1 : 1)
            cancelEditing()
        case .delete:
            guard let hit = logins.first(where: { $0.id == selected }) else { return .ignored }
            remove(hit)
        case .copy:
            // Only what is already on screen: ⌘C must not be a way around the authentication.
            guard let id = selected, let shown = revealed[id] else { return .ignored }
            copy(shown, secret: true)
            axAnnounce("Password copied.")
        }
        return .handled
    }
}

// MARK: - Pure

/// What a keystroke on the list means. An enum rather than four branches inside the view so
/// the mapping can be asserted without a window server.
enum RowCommand: Equatable { case up, down, delete, copy }

extension PasswordsPane {
    static func command(for key: KeyEquivalent, _ modifiers: EventModifiers) -> RowCommand? {
        switch key {
        case .upArrow where modifiers.isEmpty: .up
        case .downArrow where modifiers.isEmpty: .down
        // Backspace and Delete both, and ⌘⌫ too: every Mac list deletes on all three.
        case .delete, .deleteForward: modifiers.subtracting(.command).isEmpty ? .delete : nil
        case "c": modifiers.contains(.command) ? .copy : nil
        default: nil
        }
    }

    /// ↑↓ clamp at the ends rather than wrapping — a list you can fall off the bottom of and
    /// reappear at the top of is a list you lose your place in.
    static func move(_ current: String?, in ids: [String], by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else {
            return delta < 0 ? ids.last : ids.first
        }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    /// Sites a–z, each with its logins, filtered by the search field. A query matches a host
    /// or a username; there is nothing else to match, because the list never holds a
    /// password in the first place.
    static func groups(_ logins: [Passwords.Login],
                       query: String) -> [(host: String, logins: [Passwords.Login])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = needle.isEmpty ? logins : logins.filter {
            $0.host.lowercased().contains(needle) || $0.account.lowercased().contains(needle)
        }
        return Dictionary(grouping: hits, by: \.host)
            .map { (host: $0.key, logins: $0.value.sorted { $0.account < $1.account }) }
            .sorted { $0.host < $1.host }
    }

    /// The same needle against a bare list of hosts, for the Never Saved card.
    static func matching(_ hosts: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? hosts : hosts.filter { $0.lowercased().contains(needle) }
    }

    /// What VoiceOver is allowed to say about a row: the password only while it is on
    /// screen, which means only after the user authenticated to put it there.
    static func spoken(_ revealed: String?) -> String { revealed ?? "Password hidden" }

    /// The confirmation's second line. Named so it can be asserted: "and 1 others" and a
    /// dangling account name are exactly the wording bugs a delete dialog must not have.
    static func deleteDetail(_ login: Passwords.Login) -> String {
        let who = login.account.isEmpty ? "This login" : "\u{201C}\(login.account)\u{201D}"
        return "\(who) is removed from your keychain. This cannot be undone."
    }

    static func check() -> [(String, Bool)] {
        let all = [Passwords.Login(host: "bank.example", account: "ada"),
                   Passwords.Login(host: "mail.example", account: "ada@example.com"),
                   Passwords.Login(host: "mail.example", account: "bob@example.com")]
        let ids = all.map(\.id)
        let every = groups(all, query: "")
        return [
            ("an empty query lists every site",
             every.map(\.host) == ["bank.example", "mail.example"]),
            ("…and every login under it", every.flatMap(\.logins).count == 3),
            ("two accounts on one host are one group", every[1].logins.count == 2),
            ("a query matches a host", groups(all, query: "bank").flatMap(\.logins).count == 1),
            ("a query matches a username",
             groups(all, query: "bob").flatMap(\.logins).map(\.account) == ["bob@example.com"]),
            ("search is case-insensitive", groups(all, query: "BOB").count == 1),
            ("whitespace still means everything", groups(all, query: "  ").count == 2),
            ("a query matching nothing draws nothing", groups(all, query: "zzz").isEmpty),

            ("never-saved sites list whole with no query",
             matching(["a.example", "b.example"], query: "") == ["a.example", "b.example"]),
            ("…and narrow to the query", matching(["a.example", "b.example"], query: "b")
                == ["b.example"]),
            ("…case-insensitively", matching(["A.example"], query: "a.ex") == ["A.example"]),

            ("↑ with no selection lands on the last row", move(nil, in: ids, by: -1) == ids.last),
            ("↓ with no selection lands on the first", move(nil, in: ids, by: 1) == ids.first),
            ("↓ steps down one", move(ids[0], in: ids, by: 1) == ids[1]),
            ("↑ steps up one", move(ids[1], in: ids, by: -1) == ids[0]),
            ("↑ clamps at the top, it does not wrap", move(ids[0], in: ids, by: -1) == ids[0]),
            ("↓ clamps at the bottom", move(ids[2], in: ids, by: 1) == ids[2]),
            ("an empty list has nothing to select", move(nil, in: [], by: 1) == nil),

            ("↑ moves", command(for: .upArrow, []) == .up),
            ("↓ moves", command(for: .downArrow, []) == .down),
            ("⌫ deletes", command(for: .delete, []) == .delete),
            ("⌘⌫ deletes too", command(for: .delete, .command) == .delete),
            ("⌘C copies", command(for: "c", .command) == .copy),
            ("a bare c is typing, not a copy", command(for: "c", []) == nil),
            ("⌥↑ is not ours", command(for: .upArrow, .option) == nil),

            ("a hidden password is never spoken", spoken(nil) == "Password hidden"),
            ("a revealed one is", spoken("hunter2") == "hunter2"),
            ("the delete dialog names the account",
             deleteDetail(all[0]).contains("\u{201C}ada\u{201D}")),
            ("…and copes with a login that has none",
             deleteDetail(.init(host: "x.example", account: "")).hasPrefix("This login")),
        ]
    }
}

// MARK: - The chooser on the page

/// Everything that can happen to the account list once it is up. One enum and one function,
/// so "when does it close" is a table that can be read and asserted rather than a handful of
/// clears scattered across a delegate.
enum ChooserEvent: Equatable {
    /// The username or password field took focus.
    case focus
    /// It lost focus, the user clicked elsewhere on the page, or the page scrolled.
    case blur, click, scroll
    /// The page went somewhere, the window stopped being key, or another tab came forward.
    case navigate, resign, tabSwitch
    /// Escape, or a row was picked and the fields are filled.
    case escape, filled

    /// What the page's own dismiss messages mean. A string on the wire rather than four
    /// message names, and one place that turns it back into a case — an unknown reason
    /// still closes the list, because the page only ever sends one to say "not any more".
    init(page reason: String) {
        switch reason {
        case "blur": self = .blur
        case "scroll": self = .scroll
        case "navigate": self = .navigate
        default: self = .click
        }
    }
}

/// Chromium drops a list of saved accounts under a login form's username field when a site
/// has more than one; Arc shows Chromium's. This is Vane's: a flat card of rows, the site's
/// own favicon on each, the account in primary ink and eight bullets after it — the same
/// shape as a row of Settings ▸ Passwords, so the two read as one feature.
///
/// Drawn as an overlay on the *pane's* web view rather than on the window's card, so a split
/// shows it over the page it belongs to instead of across its neighbour.
struct PasswordChooser: View {
    @ObservedObject var tab: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if let choice = tab.passwordChoice,
               let at = PasswordChooser.place(anchor: choice.anchor, in: geo.size,
                                              height: height(of: choice)) {
                card(choice, width: PasswordChooser.width(of: choice.anchor, in: geo.size))
                    .offset(x: at.x, y: at.y)
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .scale(scale: Look.appearScale,
                                                                 anchor: .topLeading)))
            }
        }
        .animation(reduceMotion ? nil : Look.appear, value: tab.passwordChoice)
        // A click on the page, a blur and a scroll all come back from the page itself
        // (see Autofill.script). These two do not, because they never reach it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { _ in tab.closeChooser(.resign) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification)) { _ in tab.closeChooser(.resign) }
    }

    /// The rows plus the footer. Fixed per account, so nothing shifts as the list is walked.
    private func height(of choice: PasswordChoice) -> CGFloat {
        CGFloat(choice.accounts.count) * Look.rowHeight + Look.settingsRow
    }

    private func card(_ choice: PasswordChoice, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choice.accounts.enumerated()), id: \.element) { i, account in
                ChooserRow(account: account, host: choice.host,
                           profileID: tab.profileID, selected: i == choice.selected) {
                    tab.fillChosen(account)
                }
            }
            Hairline()
            Button {
                tab.closeChooser(.escape)
                SettingsWindow.show(tab: "passwords")
            } label: {
                Text("Manage Passwords\u{2026}")
                    .font(Look.caption).foregroundStyle(Look.inkSecondary)
                    .padding(.horizontal, Look.rowInset)
                    .frame(height: Look.settingsRow, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, alignment: .leading)
        .background(Look.panelFill, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved logins for \(choice.host)")
        // It appears under the field with no focus change, so say so — and say only the
        // usernames, which is all this view ever knows.
        .onAppear { axAnnounce("\(choice.accounts.count) saved logins for \(choice.host). "
                              + "Up and Down to choose, Return to fill, Escape to dismiss.") }
    }
}

// MARK: chooser rules

extension PasswordChooser {
    /// How long after a fill a focus event is ignored. Filling takes the focus out of the
    /// page and hands it back, which is another `focusin` — without this, the list the user
    /// just chose from reopens on top of the form they wanted to submit.
    static let refillGrace: TimeInterval = 1

    /// The dismiss rule, whole, in one place. Focus is the only thing that opens the list;
    /// everything else closes it.
    static func opens(_ event: ChooserEvent, sinceFill: TimeInterval) -> Bool {
        switch event {
        case .focus: sinceFill >= refillGrace
        case .blur, .click, .scroll, .navigate, .resign, .tabSwitch, .escape, .filled: false
        }
    }

    /// As wide as the field it hangs off, so it reads as part of the form — but never
    /// narrower than a username needs, and never wider than the pane it is drawn in.
    static func width(of anchor: CGRect, in viewport: CGSize) -> CGFloat {
        min(max(anchor.width, Look.chooserWidth), max(Look.chooserWidth, viewport.width))
    }

    /// Where the list actually goes: under the field, and never outside the page.
    ///
    /// Nil for an anchor that is not on screen at all. A page can put its input anywhere,
    /// including far off the viewport, and a list pinned to nothing is one the user cannot
    /// see to dismiss and cannot tell is there.
    static func place(anchor: CGRect, in viewport: CGSize, height: CGFloat) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0,
              anchor.minX >= 0, anchor.minY >= 0,
              anchor.minX <= viewport.width, anchor.minY <= viewport.height else { return nil }
        let w = width(of: anchor, in: viewport)
        return CGPoint(x: min(max(0, anchor.minX), max(0, viewport.width - w)),
                       y: min(max(0, anchor.minY), max(0, viewport.height - height)))
    }

    /// ↑↓ inside the list. Wraps, because it is a menu-shaped popup of two or three rows and
    /// every menu on the Mac wraps; the settings list, which can be long, clamps instead.
    static func step(_ index: Int, by delta: Int, of count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// ↑↓ and Return while the list is up, taken before Peek's and the keybinding registry's
    /// — it is the newest thing on screen. Escape is *not* here: it goes through the
    /// window's own Escape order, with the multi-select and the stop. See `VaneWindow`.
    @MainActor static func handleKey(_ event: NSEvent) -> Bool {
        // Only the modifiers a *chord* would use. An arrow key carries .function and
        // .numericPad of its own, so testing the whole device-independent mask rejects every
        // arrow there is — which is exactly how this went unnoticed the first time.
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let store = TabStore.all.first(where: { $0.window === event.window }),
              let tab = store.active, tab.passwordChoice != nil else { return false }
        switch event.keyCode {
        case 126: tab.moveChoice(-1)
        case 125: tab.moveChoice(1)
        case 36, 76: tab.fillSelected()
        default: return false
        }
        return true
    }

    /// Escape, taken before anything else on the window: the list is the most recent thing
    /// on screen, so it is what Escape means. Returns true when it acted, so the caller
    /// swallows the key — see `VaneWindow.sendEvent`.
    @MainActor static func dismiss(in window: NSWindow?) -> Bool {
        guard let store = TabStore.all.first(where: { $0.window === window }),
              let tab = store.active, tab.passwordChoice != nil else { return false }
        tab.closeChooser(.escape)
        return true
    }

    static func check() -> [(String, Bool)] {
        let viewport = CGSize(width: 800, height: 600)
        let mid = CGRect(x: 100, y: 200, width: 240, height: 0)
        let height: CGFloat = 72
        return [
            ("focus opens the list", opens(.focus, sinceFill: 10)),
            ("…but not straight after a fill", opens(.focus, sinceFill: 0) == false),
            ("…and the grace window does end", opens(.focus, sinceFill: refillGrace)),
            ("blur closes it", opens(.blur, sinceFill: 10) == false),
            ("a click elsewhere closes it", opens(.click, sinceFill: 10) == false),
            ("scrolling closes it", opens(.scroll, sinceFill: 10) == false),
            ("navigating closes it", opens(.navigate, sinceFill: 10) == false),
            ("the window losing key closes it", opens(.resign, sinceFill: 10) == false),
            ("switching tabs closes it", opens(.tabSwitch, sinceFill: 10) == false),
            ("Escape closes it", opens(.escape, sinceFill: 10) == false),
            ("picking a row closes it", opens(.filled, sinceFill: 10) == false),

            ("the page's blur is a blur", ChooserEvent(page: "blur") == .blur),
            ("the page's scroll is a scroll", ChooserEvent(page: "scroll") == .scroll),
            ("the page's history move is a navigation", ChooserEvent(page: "navigate") == .navigate),
            ("anything else the page says still closes it",
             opens(ChooserEvent(page: "whatever"), sinceFill: 10) == false),

            ("the list is as wide as the field", width(of: mid, in: viewport) == 240),
            ("…never narrower than a username needs",
             width(of: CGRect(x: 0, y: 0, width: 40, height: 0), in: viewport)
                == Look.chooserWidth),
            ("…and never wider than the pane",
             width(of: CGRect(x: 0, y: 0, width: 5000, height: 0), in: viewport) == 800),

            ("an anchor inside the pane is left where it is",
             place(anchor: mid, in: viewport, height: height) == CGPoint(x: 100, y: 200)),
            ("…one near the right edge is pulled in",
             place(anchor: CGRect(x: 700, y: 200, width: 240, height: 0),
                   in: viewport, height: height)?.x == 560),
            ("…one near the bottom is lifted",
             place(anchor: CGRect(x: 100, y: 590, width: 240, height: 0),
                   in: viewport, height: height)?.y == 528),
            ("…and a narrow field still gets a readable list",
             place(anchor: CGRect(x: 780, y: 10, width: 10, height: 0),
                   in: viewport, height: height)?.x == 800 - Look.chooserWidth),
            ("a negative anchor is refused",
             place(anchor: CGRect(x: -50, y: 10, width: 100, height: 0),
                   in: viewport, height: height) == nil),
            ("an anchor past the right edge is refused",
             place(anchor: CGRect(x: 900, y: 10, width: 100, height: 0),
                   in: viewport, height: height) == nil),
            ("an anchor below the page is refused",
             place(anchor: CGRect(x: 10, y: 900, width: 100, height: 0),
                   in: viewport, height: height) == nil),
            ("a pane with no size draws nothing",
             place(anchor: mid, in: .zero, height: height) == nil),

            ("↓ steps down the list", step(0, by: 1, of: 3) == 1),
            ("↑ steps up it", step(2, by: -1, of: 3) == 1),
            ("↓ off the end wraps to the top", step(2, by: 1, of: 3) == 0),
            ("↑ off the top wraps to the end", step(0, by: -1, of: 3) == 2),
            ("one row stays put", step(0, by: 1, of: 1) == 0),
            ("no rows is index zero", step(0, by: 1, of: 0) == 0),
        ]
    }
}

private struct ChooserRow: View {
    let account: String
    let host: String
    let profileID: UUID
    let selected: Bool
    let fill: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: fill) {
            HStack(spacing: Look.inset) {
                SiteIcon(icon: URL(string: "https://" + host).flatMap {
                    Favicons.cache(for: profileID).icon(for: $0)
                }, fallback: "key.fill", size: Look.rowIcon)
                Text(account.isEmpty ? "Saved password" : account)
                    .font(Look.text).foregroundStyle(Look.inkPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Look.inset)
                // The same eight bullets the settings list shows, for the same reason: a row
                // that says only a username does not look like it is offering a password.
                Text(PasswordsPane.dots).font(Look.caption).foregroundStyle(Look.inkTertiary)
            }
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.rowHeight)
            .background(fill(for: selected, hovered: hovered),
                        in: .rect(cornerRadius: Look.chipRadius))
            .padding(.horizontal, Look.rowGap / 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Fill \(account)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Hover wins over the selection, so the row under the pointer is always the one that
    /// looks like it will be clicked.
    private func fill(for selected: Bool, hovered: Bool) -> Color {
        hovered ? Look.hovered : (selected ? Look.accentSelected : .clear)
    }
}

// MARK: - The save offer

/// Asking before storing a credential is the whole trust boundary here — never silent.
///
/// A card, not a toast: it carries a decision with three answers, so it is shaped like the
/// rest of Vane's floating surfaces (Look.cardRadius, the panel fill, a hairline and the
/// float shadow) and hangs at the top of the page card where the address pill points.
struct PasswordOffer: View {
    @ObservedObject var tab: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Revealing what is about to be saved is a check on Vane, not a secret being handed
    /// out — it is the user's own password, which they just typed into the page.
    @State private var revealed = false

    var body: some View {
        if let p = tab.pendingSave {
            VStack(alignment: .leading, spacing: Look.inset) {
                header(p)
                credential(p)
                buttons()
            }
            .padding(Look.cardInset)
            .frame(width: Look.offerWidth, alignment: .leading)
            .background(Look.panelFill, in: .rect(cornerRadius: Look.cardRadius))
            .hairline(radius: Look.cardRadius)
            .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius,
                    y: Look.floatShadowY)
            .transition(reduceMotion ? .opacity
                        : .opacity.combined(with: .scale(scale: Look.appearScale, anchor: .top)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(p.title)
            // A credential decision is the first thing in the window worth reaching, not the
            // last. Not .isModal, though: the page underneath stays usable.
            .accessibilitySortPriority(2)
            // It appears on its own, with no focus change and no sound — say so.
            .onAppear { revealed = false; axAnnounce(p.title) }
        }
    }

    private func header(_ p: PendingSave) -> some View {
        HStack(spacing: Look.inset) {
            SiteIcon(icon: URL(string: "https://" + p.host).flatMap {
                Favicons.cache(for: tab.profileID).icon(for: $0)
            }, fallback: "key.fill", size: Look.rowIcon)
            Text(p.title).font(Look.heading).foregroundStyle(Look.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Look.inset)
            Button { tab.pendingSave = nil } label: {
                Image(systemName: "xmark").font(Look.glyph)
            }
            .buttonStyle(.plain).foregroundStyle(Look.inkTertiary)
            .accessibilityLabel("Not now")
        }
    }

    /// What is about to be stored, so "Save" is never a blind yes: the account, and the
    /// password as bullets until the eye is used.
    private func credential(_ p: PendingSave) -> some View {
        HStack(spacing: Look.inset) {
            Text(p.account.isEmpty ? "No username" : p.account)
                .font(Look.text).foregroundStyle(Look.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Look.inset)
            Text(revealed ? p.password : PasswordsPane.dots)
                .font(Look.text)
                .foregroundStyle(revealed ? Look.inkPrimary : Look.inkTertiary)
                .lineLimit(1).truncationMode(.tail)
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").font(Look.rowGlyph)
            }
            .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.control + Look.inset)
        .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
        // The password is the user's own and is on its way into their keychain, but it is
        // still not something VoiceOver should read out unprompted.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.account.isEmpty ? "No username" : p.account)
        .accessibilityValue(PasswordsPane.spoken(revealed ? p.password : nil))
    }

    private func buttons() -> some View {
        HStack(spacing: Look.inset) {
            Button("Never for This Site") { tab.neverSaveHere() }
                .buttonStyle(.plain).font(Look.text)
                .foregroundStyle(Look.inkSecondary)
            Spacer(minLength: Look.inset)
            Button("Not Now") { tab.pendingSave = nil }
                .keyboardShortcut(.cancelAction)
            Button(tab.pendingSave?.update == true ? "Update" : "Save") { tab.confirmSave() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
