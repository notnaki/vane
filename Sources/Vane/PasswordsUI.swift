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
/// has more than one; Arc shows Chromium's. This is Vane's, in Vane's own flat idiom rather
/// than the platform's popover chrome — it is part of the page, not a panel over it.
///
/// Drawn as an overlay on the *pane's* web view rather than on the window's card, so a split
/// shows it over the page it belongs to instead of across its neighbour.
struct PasswordChooser: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            if let choice = tab.passwordChoice,
               let at = PasswordChooser.place(anchor: choice.anchor, in: geo.size,
                                              height: height(of: choice)) {
                list(choice).offset(x: at.x, y: at.y)
            }
        }
        // A click on the page, a blur and a scroll all come back from the page itself
        // (see Autofill.script). These two do not, because they never reach it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { _ in tab.closeChooser(.resign) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification)) { _ in tab.closeChooser(.resign) }
    }

    private func height(of choice: PasswordChoice) -> CGFloat {
        CGFloat(choice.accounts.count) * Look.rowHeight
    }

    private func list(_ choice: PasswordChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choice.accounts.enumerated()), id: \.element) { i, account in
                if i > 0 { Hairline() }
                ChooserRow(account: account) { tab.fillChosen(account) }
            }
        }
        .frame(width: max(choice.anchor.width, Look.chooserWidth), alignment: .leading)
        .background(Look.panelFill, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved logins for \(choice.host)")
        // It appears under the field with no focus change, so say so — and say only the
        // usernames, which is all this view ever knows.
        .onAppear { axAnnounce("\(choice.accounts.count) saved logins for \(choice.host).") }
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

    /// Where the list actually goes: under the field, and never outside the page.
    ///
    /// Nil for an anchor that is not on screen at all. A page can put its input anywhere,
    /// including far off the viewport, and a list pinned to nothing is one the user cannot
    /// see to dismiss and cannot tell is there.
    static func place(anchor: CGRect, in viewport: CGSize, height: CGFloat) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0,
              anchor.minX >= 0, anchor.minY >= 0,
              anchor.minX <= viewport.width, anchor.minY <= viewport.height else { return nil }
        let width = max(anchor.width, Look.chooserWidth)
        return CGPoint(x: min(max(0, anchor.minX), max(0, viewport.width - width)),
                       y: min(max(0, anchor.minY), max(0, viewport.height - height)))
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
        ]
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
