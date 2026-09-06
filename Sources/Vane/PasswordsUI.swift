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
/// The pure parts (grouping, search, what a keystroke means, what VoiceOver is allowed to
/// hear) are static functions with a `check()`, so they can be proved headless.
@MainActor struct PasswordsPane: View {
    @ObservedObject private var manager = ProfileManager.shared
    @State private var query = ""
    /// The keychain is not a publisher, so the pane holds its own copy and reloads after
    /// every write it makes.
    @State private var logins: [Passwords.Credential] = []
    @State private var selected: String?
    /// Ids whose password the user has authenticated to see. Reset when the pane goes away —
    /// a revealed password should not still be revealed the next time Settings opens.
    @State private var revealed: Set<String> = []
    /// The row being edited, and its two fields. Held apart from `logins` so Cancel is free.
    @State private var editing: String?
    @State private var draftAccount = ""
    @State private var draftPassword = ""
    @FocusState private var listFocused: Bool

    /// What a hidden password looks like. Eight bullets whatever the real length — the
    /// length of a password is itself worth not leaking.
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    private var profileID: UUID { manager.active.id }
    private var groups: [(host: String, logins: [Passwords.Credential])] {
        PasswordsPane.groups(logins, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            search
            if logins.isEmpty {
                quiet("Passwords you save as you sign in to sites appear here.")
            } else if groups.isEmpty {
                quiet("No saved login matches \u{201C}\(query)\u{201D}")
            } else {
                list
            }
        }
        .padding(.top, Look.inset * 2)
        .onAppear { reload() }
        .onDisappear { revealed.removeAll() }
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

    @ViewBuilder private func row(_ login: Passwords.Credential) -> some View {
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
                    Button("Cancel") { editing = nil }
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
        .accessibilityValue(PasswordsPane.spoken(login, revealed: revealed.contains(login.id)))
        .accessibilityAddTraits(selected == login.id ? [.isSelected] : [])
    }

    /// The password itself, or eight bullets. A plain Text while hidden rather than a
    /// disabled SecureField: nothing to select, nothing to copy out of the view hierarchy.
    @ViewBuilder private func secret(_ login: Passwords.Credential, editing: Bool) -> some View {
        let shown = revealed.contains(login.id)
        if editing {
            if shown {
                TextField("", text: $draftPassword).textFieldStyle(.plain)
                    .font(Look.text).frame(width: 160)
            } else {
                SecureField("", text: $draftPassword).textFieldStyle(.plain)
                    .font(Look.text).frame(width: 160)
            }
        } else {
            Text(shown ? login.password : PasswordsPane.dots)
                .font(Look.text).foregroundStyle(shown ? Look.inkPrimary : Look.inkTertiary)
                .lineLimit(1).truncationMode(.tail).frame(width: 160, alignment: .trailing)
        }
    }

    private func controls(_ login: Passwords.Credential, editing isEditing: Bool) -> some View {
        HStack(spacing: Look.inset) {
            glyph(revealed.contains(login.id) ? "eye.slash" : "eye",
                  revealed.contains(login.id) ? "Hide password" : "Show password") {
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
        if let selected, !logins.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    /// Hiding needs no permission; showing does.
    private func toggleReveal(_ login: Passwords.Credential) {
        if revealed.remove(login.id) != nil { return }
        Passwords.authenticate("show the password for \(login.host)") { ok in
            guard ok else { return }
            revealed.insert(login.id)
            axAnnounce("Password for \(login.host) shown.")
        }
    }

    private func copy(_ text: String, secret: Bool) {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        // Clipboard managers and history utilities honour this type by not recording the
        // item. Costs one line and keeps a password out of a dozen third-party databases.
        if secret { board.setString("", forType: .init("org.nspasteboard.ConcealedType")) }
        board.setString(text, forType: .string)
    }

    /// Copying a password is the same door as revealing one, so it asks the same way.
    private func copyPassword(_ login: Passwords.Credential) {
        guard !revealed.contains(login.id) else {
            copy(login.password, secret: true)
            axAnnounce("Password copied.")
            return
        }
        Passwords.authenticate("copy the password for \(login.host)") { ok in
            guard ok else { return }
            copy(login.password, secret: true)
            axAnnounce("Password copied.")
        }
    }

    private func startEditing(_ login: Passwords.Credential) {
        selected = login.id
        editing = login.id
        draftAccount = login.account
        draftPassword = login.password
    }

    /// A changed username is a different keychain item, so the old one goes.
    private func commit(_ login: Passwords.Credential) {
        editing = nil
        let account = draftAccount.trimmingCharacters(in: .whitespaces)
        guard !draftPassword.isEmpty else { return }
        if account != login.account {
            Passwords.delete(host: login.host, account: login.account, profileID: profileID)
        }
        Passwords.save(host: login.host, account: account, password: draftPassword,
                       profileID: profileID)
        selected = Passwords.key(host: login.host, account: account)
        draftPassword = ""
        reload()
    }

    private func remove(_ login: Passwords.Credential) {
        guard confirm("Delete the saved login for \(login.host)?", "Delete",
                      PasswordsPane.deleteDetail(login)) else { return }
        Passwords.delete(host: login.host, account: login.account, profileID: profileID)
        revealed.remove(login.id)
        if editing == login.id { editing = nil }
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
            editing = nil
        case .delete:
            guard let hit = logins.first(where: { $0.id == selected }) else { return .ignored }
            remove(hit)
        case .copy:
            // Only once it is on screen: ⌘C must not be a way around the authentication.
            guard let id = selected, revealed.contains(id),
                  let hit = logins.first(where: { $0.id == id }) else { return .ignored }
            copy(hit.password, secret: true)
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
    /// or a username, never a password: typing a password into a search field would put it
    /// in the field's undo stack and, on a shared screen, in plain view.
    static func groups(_ credentials: [Passwords.Credential],
                       query: String) -> [(host: String, logins: [Passwords.Credential])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = needle.isEmpty ? credentials : credentials.filter {
            $0.host.lowercased().contains(needle) || $0.account.lowercased().contains(needle)
        }
        return Dictionary(grouping: hits, by: \.host)
            .map { (host: $0.key, logins: $0.value.sorted { $0.account < $1.account }) }
            .sorted { $0.host < $1.host }
    }

    /// What VoiceOver is allowed to say about a row. The password only once the user has
    /// authenticated to show it — an accessibility value is not a private channel.
    static func spoken(_ login: Passwords.Credential, revealed: Bool) -> String {
        revealed ? login.password : "Password hidden"
    }

    /// The confirmation's second line. Named so it can be asserted: "and 1 others" and a
    /// dangling account name are exactly the wording bugs a delete dialog must not have.
    static func deleteDetail(_ login: Passwords.Credential) -> String {
        let who = login.account.isEmpty ? "This login" : "\u{201C}\(login.account)\u{201D}"
        return "\(who) is removed from your keychain. This cannot be undone."
    }

    static func check() -> [(String, Bool)] {
        func c(_ host: String, _ account: String) -> Passwords.Credential {
            .init(host: host, account: account, password: "s3cret-" + account)
        }
        let all = [c("bank.example", "ada"), c("mail.example", "ada@example.com"),
                   c("mail.example", "bob@example.com")]
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
            ("a password is never searchable", groups(all, query: "s3cret").isEmpty),

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

            ("a hidden password is never spoken",
             spoken(all[0], revealed: false) == "Password hidden"),
            ("a revealed one is", spoken(all[0], revealed: true) == all[0].password),
            ("the delete dialog names the account",
             deleteDetail(all[0]).contains("\u{201C}ada\u{201D}")),
            ("…and copes with a login that has none",
             deleteDetail(c("x.example", "")).hasPrefix("This login")),
        ]
    }
}

// MARK: - The chooser on the page

/// Chromium drops a list of saved accounts under a login form's username field when a site
/// has more than one; Arc shows Chromium's. This is Vane's, in Vane's own flat idiom rather
/// than the platform's popover chrome — it is part of the page, not a panel over it.
struct PasswordChooser: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let choice = tab.passwordChoice {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(choice.accounts.enumerated()), id: \.element) { i, account in
                    if i > 0 { Hairline() }
                    ChooserRow(account: account) { tab.fillChosen(account) }
                }
            }
            .frame(width: max(choice.anchor.width, Look.chooserWidth), alignment: .leading)
            .background(Look.panelFill, in: .rect(cornerRadius: Look.cardRadius))
            .hairline(radius: Look.cardRadius)
            .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius,
                    y: Look.floatShadowY)
            .offset(x: choice.anchor.minX, y: choice.anchor.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saved logins for \(choice.host)")
            // It appears under the field with no focus change, so say so — and say only the
            // usernames, which is all this view ever knows.
            .onAppear {
                axAnnounce("\(choice.accounts.count) saved logins for \(choice.host).")
            }
        }
    }
}

private struct ChooserRow: View {
    let account: String
    let fill: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: fill) {
            HStack(spacing: Look.inset) {
                Image(systemName: "key.fill").font(Look.glyph)
                    .foregroundStyle(Look.inkTertiary)
                Text(account.isEmpty ? "Saved password" : account)
                    .font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Spacer(minLength: Look.inset)
            }
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.rowHeight)
            .background(hovered ? Look.hovered : .clear,
                        in: .rect(cornerRadius: Look.chipRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Fill \(account)")
    }
}
