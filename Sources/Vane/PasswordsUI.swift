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
    @AppStorage(FolderUnlockMethod.key, store: UserDefaults.vane) private var folderUnlockMethod = FolderUnlockMethod.touchID
    var settingsProfileID: UUID? = nil
    @ObservedObject private var manager = ProfileManager.shared
    @State private var query = ""
    @State private var sort = PasswordSort.website
    /// The keychain is not a publisher, so the pane holds its own copy of the *names* and
    /// reloads after every write it makes.
    @StateObject private var metadata = Feel06PasswordMetadata()
    private var logins: [Passwords.Login] { metadata.logins }
    @State private var used: [String: Date] = [:]
    @State private var presentation = Feel06PasswordPresentation()
    @FocusState private var searchFocused: Bool

    /// Sites the user answered "Never for This Site" on. Listed so the answer can be taken
    /// back, which is otherwise a decision with no undo.
    @State private var never: [String] = []
    @State private var selected: String?
    @State private var selectedHost: String?
    @State private var draftSite = ""
    @State private var addProblem: String?
    @State private var feedback: String?
    /// A refused write must be visible, so a failed save never looks like success.
    @State private var problem: String?
    /// Plaintext lives only while the manager is visible, including its add/edit drafts.
    @StateObject private var secrets = PasswordManagerSecrets()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    /// What a hidden password looks like. Eight bullets whatever the real length — the
    /// length of a password is itself worth not leaking.
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
    /// How long a revealed password stays on screen. Long enough to type it somewhere,
    /// short enough that a settings window left open is not a password on a wall.
    static let revealFor: Duration = .seconds(60)
    /// And how long a copied one stays on the clipboard.
    static let copyFor: Duration = .seconds(60)

    private var profileID: UUID {
        manager.profiles.first { $0.id == settingsProfileID }?.id ?? manager.active.id
    }
    private var groups: [(host: String, logins: [Passwords.Login])] {
        presentation.groups(logins, query: query, sort: sort, used: used)
    }
    private var neverShown: [String] { PasswordsPane.matching(never, query: query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var resultCount: Int { groups.reduce(0) { $0 + $1.logins.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 2) {
            Feel06ActivityLine(busy: metadata.busy, text: "Loading passwords…")
            if let host = selectedHost {
                Button { navigate(to: nil) } label: {
                    Label("All passwords", systemImage: "chevron.left")
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                HStack {
                    site(host, count: logins.filter { $0.host == host }.count)
                    Spacer(minLength: 0)
                    Button { beginAdding(host: host) } label: {
                        Label("Add login", systemImage: "plus")
                    }
                }
                ScrollView {
                    LazyVStack(spacing: Look.inset * 2) {
                        ForEach(logins.filter { $0.host == host }) { login in detail(login) }
                    }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password Manager").font(Look.heading)
                        Text("Your saved logins, on this Mac")
                            .font(Look.caption).foregroundStyle(Look.inkSecondary)
                    }
                    Spacer()
                    Button { beginAdding() } label: { Label("Add password", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                Footnote("Passkeys are pending Apple’s browser capability approval and provisioning. Saved passwords remain available here.")
                DisclosureGroup("Folder unlock method") {
                    SettingsRow("Unlock folders using") {
                        Picker("Folder unlock method", selection: $folderUnlockMethod) {
                            Text("Touch ID").tag(FolderUnlockMethod.touchID)
                            Text("System").tag(FolderUnlockMethod.system)
                        }.labelsHidden()
                    }
                    Footnote("Macs without Touch ID use system authentication automatically.")
                }.font(Look.caption)
                search
                Picker("Sort passwords", selection: $sort) {
                    Text("Website").tag(PasswordSort.website)
                    Text("Username").tag(PasswordSort.username)
                    Text("Recently used").tag(PasswordSort.recent)
                }.pickerStyle(.segmented)
                HStack {
                    Text(searching
                         ? "\(resultCount) matching \(resultCount == 1 ? "password" : "passwords")"
                         : "\(logins.count) \(logins.count == 1 ? "password" : "passwords") · \(groups.count) \(groups.count == 1 ? "site" : "sites")")
                        .font(Look.caption)
                        .foregroundStyle(Look.inkSecondary)
                    Spacer()
                    Button("Import passwords…") { PasswordImport.chooseAndImport(profileID: profileID); reload() }
                }
                if metadata.busy && logins.isEmpty {
                    // This pane is also the hosting view's intrinsic content. An
                    // unbounded Spacer during loading can grow the retained window.
                    Color.clear.frame(height: 160).accessibilityHidden(true)
                } else if groups.isEmpty && neverShown.isEmpty {
                    VStack(spacing: Look.inset) {
                        Image(systemName: searching ? "magnifyingglass" : "key.fill")
                            .font(.system(size: 28)).foregroundStyle(Look.inkSecondary)
                        Text(searching ? "No passwords found" : "Your passwords in one place")
                            .font(Look.heading)
                        quiet(searching ? "Try another website or username."
                              : "Save a password when you sign in, add one here, or import from another browser.")
                        if searching { Button("Clear search") { query = "" } }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    if !groups.isEmpty { list }
                    else { ScrollView { neverCard } }
                }
            }
            if let problem = problem ?? metadata.error {
                Text(problem).font(Look.text).foregroundStyle(Look.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh passwords") { reload() }
            }
            if let feedback {
                Text(feedback).font(Look.caption).foregroundStyle(Look.inkSecondary)
            }
        }
        .padding(.top, Look.inset * 2)
        .sheet(isPresented: $secrets.adding, onDismiss: { forgetSecrets() }) { addSheet }
        .onAppear { reload(); secrets.watchSettingsClose() }
        .onDisappear { secrets.stopWatching(); metadata.cancel() }
        .onChange(of: logins) {
            // Reloads finish asynchronously; reconcile the detail destination only
            // once the refreshed metadata arrives, including the last-login deletion.
            if let selectedHost, !logins.contains(where: { $0.host == selectedHost }) {
                navigate(to: nil)
            }
            if let selected, !logins.contains(where: { $0.id == selected || $0.host == selected }) { self.selected = nil }
        }
        .onChange(of: selectedHost) { forgetSecrets(); problem = nil; feedback = nil }
        .onChange(of: profileID) { selectedHost = nil; secrets.adding = false; forgetSecrets(); reload() }
        .onChange(of: query) { selected = nil }
        .onChange(of: sort) { used = Passwords.lastUsed(profileID: profileID) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.vane)) { _ in
            let latest = Passwords.lastUsed(profileID: profileID)
            if latest != used { used = latest }
        }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: selectedHost)
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: sort)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(Look.text).foregroundStyle(Look.inkSecondary)
            .padding(.horizontal, Look.cardInset)
    }

    private var search: some View {
        HStack(spacing: Look.inset) {
            Image(systemName: "magnifyingglass").font(Look.fieldIcon)
                .foregroundStyle(Look.inkTertiary)
            TextField("", text: $query, prompt: Text("Search passwords by site or username"))
                .textFieldStyle(.plain).font(Look.text).focused($searchFocused)
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Look.inkSecondary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Look.inset)
        .frame(height: Look.control + Look.inset)
        .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
        .accessibilityLabel("Search saved logins")
    }

    private var list: some View {
        PasswordManagerList(groups: groups, selected: $selected, profileID: profileID,
                            open: { navigate(to: $0) }) {
            if !neverShown.isEmpty { neverCard }
        }
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
                        } label: { Text("Allow saving") }
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
            PasswordSiteIcon(host: host, profileID: profileID)
            Text(host).font(Look.heading).foregroundStyle(Look.inkPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Look.inset)
            if count > 1 {
                Text("\(count) logins").font(Look.caption).foregroundStyle(Look.inkQuiet)
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(minHeight: Look.settingsRow)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ login: Passwords.Login) -> some View {
        let isEditing = secrets.editing == login.id
        let shown = secrets.revealed[login.id]
        return SettingsCard {
            VStack(alignment: .leading, spacing: Look.cardInset) {
                VStack(alignment: .leading, spacing: Look.inset) {
                    Text("Website").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    if isEditing {
                        TextField("Website", text: $draftSite).textFieldStyle(.roundedBorder)
                    } else {
                        Text(login.origin.url.absoluteString).textSelection(.enabled)
                    }
                }
                VStack(alignment: .leading, spacing: Look.inset) {
                    Text("Username").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    HStack {
                        if isEditing {
                            TextField("Username", text: $secrets.draftAccount).textFieldStyle(.roundedBorder)
                        } else {
                            Text(login.account.isEmpty ? "No username" : login.account)
                                .textSelection(.enabled)
                            Spacer()
                            glyph("doc.on.doc", "Copy username") { copy(login.account, secret: false) }
                                .disabled(login.account.isEmpty)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Look.inset) {
                    if isEditing {
                        PasswordDraftField(text: $secrets.draftPassword).id(login.id)
                    } else {
                        Text("Password").font(Look.caption).foregroundStyle(Look.inkSecondary)
                        HStack {
                            PasswordValue(value: shown)
                            Spacer()
                            PasswordEyeButton(revealed: shown != nil) {
                                toggleReveal(login)
                            }
                            glyph("doc.on.doc", "Copy password") { copyPassword(login) }
                        }
                    }
                }
                if logins.filter({ $0.host == login.host && $0.account == login.account }).count > 1 {
                    Text("This username is saved for multiple website origins. Check the website and port above.")
                        .font(Look.caption).foregroundStyle(Look.inkSecondary)
                }
                HStack(spacing: Look.inset * 1.5) {
                    if isEditing {
                        Button("Save") { commit(login) }.keyboardShortcut(.defaultAction)
                            .disabled(secrets.draftPassword.isEmpty)
                        Button("Cancel") { cancelEditing() }.keyboardShortcut(.cancelAction)
                    } else {
                        Button("Edit password") { startEditing(login) }
                        Spacer()
                        Button("Delete…", role: .destructive) { remove(login) }
                    }
                }
            }
            .font(Look.text).padding(Look.cardInset)
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: Look.inset * 2) {
            Label("Add password", systemImage: "key.fill").font(Look.heading)
            Text("Save a login for this profile on your Mac.")
                .font(Look.caption).foregroundStyle(Look.inkSecondary)
            Text("Website").font(Look.caption).foregroundStyle(Look.inkSecondary)
            TextField("example.com", text: $draftSite).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Website")
            Text("Username").font(Look.caption).foregroundStyle(Look.inkSecondary)
            TextField("Username (optional)", text: $secrets.draftAccount).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Username")
            PasswordDraftField(text: $secrets.draftPassword)
            if let addProblem { Text(addProblem).font(Look.caption).foregroundStyle(Look.warning) }
            HStack {
                Spacer()
                Button("Cancel") { secrets.adding = false; forgetSecrets() }.keyboardShortcut(.cancelAction)
                Button("Save") { addPassword() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(Self.siteOrigin(draftSite) == nil || secrets.draftPassword.isEmpty)
            }
        }.padding(24).frame(width: 400)
    }

    private func beginAdding(host: String = "") {
        forgetSecrets()
        draftSite = host; secrets.draftAccount = ""; addProblem = nil
        secrets.adding = true
    }

    private func addPassword() {
        guard let origin = Self.siteOrigin(draftSite), !secrets.draftPassword.isEmpty else { return }
        let host = origin.host
        let account = secrets.draftAccount
        guard !logins.contains(where: { $0.origin == origin && $0.account == account }) else {
            addProblem = "This login already exists. Open it and choose Edit to change it."
            return
        }
        do {
            try Passwords.saveChecked(origin: origin, account: account, password: secrets.draftPassword,
                                      profileID: profileID, replacingExisting: false)
        } catch { addProblem = error.localizedDescription; return }
        Passwords.allowSaving(host: host, profileID: profileID)
        secrets.adding = false; forgetSecrets(); reload()
        navigate(to: host)
        axAnnounce("Password saved.")
    }

    private func glyph(_ symbol: String, _ label: String,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
            .accessibilityLabel(label).help(label)
            .frame(minWidth: 28, minHeight: 28)
    }

    // MARK: Actions

    private func reload() {
        problem = nil
        metadata.load(profileID: profileID)
        used = Passwords.lastUsed(profileID: profileID)
        never = Passwords.neverSaved(profileID: profileID)
    }

    private func navigate(to host: String?) {
        forgetSecrets()
        selected = host
        selectedHost = host
        if host == nil { searchFocused = true }
    }

    private func forgetSecrets() { secrets.forget() }

    /// Hiding needs no permission; showing does — and what comes back is held for a minute
    /// and then dropped, whether or not anybody is still looking at this window.
    private func toggleReveal(_ login: Passwords.Login) {
        if secrets.revealed.removeValue(forKey: login.id) != nil {
            secrets.forgetting.removeValue(forKey: login.id)?.cancel()
            return
        }
        let scope = profileID, context = secrets.secretContext
        Passwords.authenticate("show the password for \(login.host)") { ok in
            guard profileID == scope, secrets.secretContext == context else { return }
            guard ok else { problem = "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."; return }
            guard let plain = readPassword(login, profileID: scope) else { return }
            secrets.revealed[login.id] = plain
            axAnnounce("Password for \(login.host) shown.")
            secrets.forgetting.removeValue(forKey: login.id)?.cancel()
            secrets.forgetting[login.id] = Task {
                try? await Task.sleep(for: PasswordsPane.revealFor)
                guard !Task.isCancelled else { return }
                secrets.revealed[login.id] = nil
                secrets.forgetting[login.id] = nil
            }
        }
    }

    private func copy(_ text: String, secret: Bool) {
        guard !text.isEmpty else { return }
        feedback = secret ? "Password copied" : "Username copied"
        let board = NSPasteboard.general
        guard secret else {
            board.clearContents()
            board.setString(text, forType: .string)
            return
        }
        let stamp = PasswordClipboard.write(text, to: board)
        Task {
            try? await Task.sleep(for: PasswordsPane.copyFor)
            guard !Task.isCancelled else { return }
            PasswordClipboard.clearIfUnchanged(.general, changeCount: stamp)
        }
    }

    /// Copying a password is the same door as revealing one, so it asks the same way.
    private func copyPassword(_ login: Passwords.Login) {
        if let shown = secrets.revealed[login.id] {
            copy(shown, secret: true)
            axAnnounce("Password copied.")
            return
        }
        let scope = profileID, context = secrets.secretContext
        Passwords.authenticate("copy the password for \(login.host)") { ok in
            guard profileID == scope, secrets.secretContext == context else { return }
            guard ok else { problem = "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."; return }
            guard let plain = readPassword(login, profileID: scope) else { return }
            copy(plain, secret: true)
            axAnnounce("Password copied.")
        }
    }

    /// Editing puts the password into a field the user can read, so it is the same door as
    /// revealing one and asks the same way.
    private func startEditing(_ login: Passwords.Login) {
        forgetSecrets()
        problem = nil; feedback = nil
        let scope = profileID, context = secrets.secretContext
        Passwords.authenticate("edit the saved login for \(login.host)") { ok in
            guard profileID == scope, secrets.secretContext == context else { return }
            guard ok else { problem = "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."; return }
            guard let plain = readPassword(login, profileID: scope) else { return }
            selected = login.id
            secrets.editing = login.id
            draftSite = login.origin.url.absoluteString
            secrets.draftAccount = login.account
            secrets.draftPassword = plain
        }
    }

    private func readPassword(_ login: Passwords.Login, profileID: UUID) -> String? {
        do {
            guard let password = try Passwords.passwordChecked(origin: login.origin, account: login.account, profileID: profileID)
            else { problem = "This login is no longer in Keychain. Refresh passwords to update the list."; return nil }
            return password
        } catch { problem = error.localizedDescription; axAnnounce(problem ?? ""); return nil }
    }

    private func cancelEditing() {
        secrets.editing = nil
        secrets.draftAccount = ""
        secrets.draftPassword = ""
        secrets.secretContext = UUID()
    }

    /// A changed username is a different keychain item, so the old one goes — but only after
    /// the new one is safely stored, and only after its last-used stamp has moved across.
    private func commit(_ login: Passwords.Login) {
        let account = secrets.draftAccount
        // Checked before anything is closed or written. An empty password is not a password,
        // and quietly keeping the old one while the field says otherwise is worse than
        // refusing.
        guard !secrets.draftPassword.isEmpty else { return }
        let unchangedLegacy = URL(string: draftSite).flatMap(PasswordOrigin.init(url:)) == login.origin ? login.origin : nil
        guard let origin = Self.siteOrigin(draftSite) ?? unchangedLegacy else {
            problem = "Enter a valid HTTPS website without a username or password in its URL."
            return
        }
        do {
            try Passwords.editChecked(login, origin: origin, account: account,
                                      password: secrets.draftPassword, profileID: profileID)
        } catch {
            problem = error.localizedDescription
            axAnnounce(problem ?? "")
            return
        }
        selectedHost = origin.host
        forgetSecrets()
        feedback = "Password updated"
        selected = origin.key(account: account)
        reload()
    }

    private func remove(_ login: Passwords.Login) {
        guard confirm("Delete the saved login for \(login.host)?", "Delete",
                      PasswordsPane.deleteDetail(login)) else { return }
        do { try Passwords.deleteChecked(origin: login.origin, account: login.account, profileID: profileID) }
        catch { problem = error.localizedDescription; axAnnounce(problem ?? ""); return }
        problem = nil
        secrets.secretContext = UUID()
        secrets.forgetting.removeValue(forKey: login.id)?.cancel()
        secrets.revealed[login.id] = nil
        if secrets.editing == login.id { cancelEditing() }
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
            guard let id = selected, let shown = secrets.revealed[id] else { return .ignored }
            copy(shown, secret: true)
            axAnnounce("Password copied.")
        }
        return .handled
    }
}

/// A bounded list keeps the manager's search in place and keyboard selection visible.
@MainActor struct PasswordManagerList<Footer: View>: View {
    let groups: [(host: String, logins: [Passwords.Login])]
    @Binding var selected: String?
    let profileID: UUID
    let open: (String) -> Void
    @ViewBuilder var footer: Footer
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Look.inset * 2) {
                    SettingsCard(divided: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.host) { group in
                                Button { open(group.host) } label: {
                                    HStack(spacing: Look.inset * 1.5) {
                                        PasswordSiteIcon(host: group.host, profileID: profileID)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.host).font(Look.text.weight(.medium)).foregroundStyle(Look.inkPrimary)
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(group.logins.count == 1
                                                 ? (group.logins[0].account.isEmpty ? "No username" : group.logins[0].account)
                                                 : "\(group.logins.count) accounts")
                                                .font(Look.caption).foregroundStyle(Look.inkSecondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Look.inkTertiary)
                                    }
                                    .padding(Look.cardInset).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == group.host ? Look.accentSelected : .clear)
                                    .contentShape(.rect)
                                }.buttonStyle(.plain).id(group.host)
                                if group.host != groups.last?.host {
                                    Hairline().padding(.horizontal, Look.cardInset)
                                }
                            }
                        }
                        .clipShape(.rect(cornerRadius: Look.cardRadius))
                    }
                    footer
                }
            }
            .onChange(of: selected) {
                guard let selected, groups.contains(where: { $0.host == selected }) else { return }
                withAnimation(reduceMotion || batterySaver.isActive ? nil : Look.quick) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
        .focusable().focused($listFocused)
        .overlay { RoundedRectangle(cornerRadius: Look.cardRadius).stroke(listFocused ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false) }
        .onKeyPress(.upArrow) { moveSite(-1) }
        .onKeyPress(.downArrow) { moveSite(1) }
        .onKeyPress(.return) {
            guard let selected, groups.contains(where: { $0.host == selected }) else { return .ignored }
            open(selected)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved passwords")
    }

    private func moveSite(_ delta: Int) -> KeyPress.Result {
        let hosts = groups.map(\.host)
        guard !hosts.isEmpty else { return .ignored }
        selected = PasswordsPane.move(selected, in: hosts, by: delta)
        return .handled
    }
}

// MARK: - Pure

/// What a keystroke on the list means. An enum rather than four branches inside the view so
/// the mapping can be asserted without a window server.
enum RowCommand: Equatable { case up, down, delete, copy }
enum PasswordSort: Hashable { case website, username, recent }

extension PasswordsPane {
    static func siteOrigin(_ raw: String) -> PasswordOrigin? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard siteHost(raw) != nil,
              let url = URL(string: raw.contains("://") ? raw : "https://" + raw) else { return nil }
        return PasswordOrigin(url: url)
    }

    static func siteHost(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host, !host.isEmpty, host.contains("."),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return nil }
        return host.lowercased()
    }

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
                       query: String, sort: PasswordSort = .website,
                       used: [String: Date] = [:]) -> [(host: String, logins: [Passwords.Login])] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let hits = terms.isEmpty ? logins : logins.filter { login in
            terms.allSatisfy { login.host.lowercased().contains($0) || login.account.lowercased().contains($0) }
        }
        return Dictionary(grouping: hits, by: \.host)
            .map { (host: $0.key, logins: $0.value.sorted { a, b in
                if sort == .recent, used[a.id] != used[b.id] { return (used[a.id] ?? .distantPast) > (used[b.id] ?? .distantPast) }
                return (a.account, a.origin.url.absoluteString) < (b.account, b.origin.url.absoluteString)
            }) }
            .sorted { a, b in
                if sort == .recent {
                    let first = a.logins.compactMap { used[$0.id] }.max() ?? .distantPast
                    let second = b.logins.compactMap { used[$0.id] }.max() ?? .distantPast
                    if first != second { return first > second }
                }
                if sort == .username, a.logins.first?.account != b.logins.first?.account {
                    return (a.logins.first?.account ?? "") < (b.logins.first?.account ?? "")
                }
                return a.host < b.host
            }
    }

    /// Why a rename is refused, or nil when it is fine. Named so the wording can be
    /// asserted, and pure so the rule is not buried in a view.
    static func renameClash(_ logins: [Passwords.Login], host: String,
                           from: String, to: String, origin: PasswordOrigin? = nil) -> String? {
        let origin = origin ?? PasswordOrigin(host: host)
        guard from != to,
              logins.contains(where: { $0.origin == origin && $0.account == to })
        else { return nil }
        return "\(host) already has a login for \u{201C}\(to)\u{201D}. "
            + "Delete that one first, or pick another username."
    }

    /// Why a save is refused. The keychain's primary key ignores the creator code, so
    /// another app's item for the same site and account is in the way and there is nothing
    /// of Vane's to replace.
    static func saveFailed(host: String) -> String {
        "Vane could not save that password. Another app may already have a login for "
            + "\(host) in your keychain."
    }

    /// The same needle against a bare list of hosts, for the Never Saved card.
    static func matching(_ hosts: [String], query: String) -> [String] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return terms.isEmpty ? hosts : hosts.filter { host in
            terms.allSatisfy { host.lowercased().contains($0) }
        }
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
            ("manual add normalizes a website to its host", siteHost(" https://EXAMPLE.com/login ") == "example.com"),
            ("manual add accepts a bare website", siteHost("accounts.example.com") == "accounts.example.com"),
            ("manual add refuses insecure or non-web schemes",
             siteHost("http://example.com") == nil && siteHost("javascript:alert(1)") == nil),
            ("manual add refuses URL credentials and malformed hosts",
             siteHost("https://user:secret@example.com") == nil && siteHost("not a site") == nil
             && siteHost("example..com") == nil),
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

            ("renaming to a free username is fine",
             renameClash(all, host: "mail.example", from: "ada@example.com", to: "cam") == nil),
            ("…renaming onto an existing one is refused",
             renameClash(all, host: "mail.example", from: "ada@example.com",
                         to: "bob@example.com")?.contains("bob@example.com") == true),
            ("…and the same site on another host is not a clash",
             renameClash(all, host: "bank.example", from: "ada", to: "bob@example.com") == nil),
            ("…leaving a username alone is never a clash",
             renameClash(all, host: "mail.example", from: "ada@example.com",
                         to: "ada@example.com") == nil),
            ("a refused save names the site", saveFailed(host: "x.example").contains("x.example")),

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
    case blur, click, scroll, input
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
        case "input": self = .input
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
    @ObservedObject private var batterySaver = BatterySaver.shared
    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    var body: some View {
        GeometryReader { geo in
            if let generation = tab.passwordGeneration,
               let at = PasswordChooser.place(anchor: generation.anchor, in: geo.size, height: 280) {
                PasswordGenerationCard(website: generation.origin.url.absoluteString,
                    problem: tab.passwordGenerationProblem, use: { tab.useGeneratedPassword($0) },
                    dismiss: { tab.closeChooser(.escape) })
                    .frame(width: min(320, geo.size.width), height: 280, alignment: .top)
                    .offset(x: min(at.x, max(0, geo.size.width - 320)), y: at.y)
                    .onHover { tab.chooserHovered = $0 }
                    .transition(reduced ? .identity : .opacity)
            }
            if let choice = tab.passwordChoice {
                if let at = PasswordChooser.place(
                    anchor: choice.anchor, in: geo.size,
                    height: PasswordChooser.height(rows: choice.accounts.count, in: geo.size)) {
                    PasswordChooserCard(choice: choice, profileID: tab.profileID,
                        width: PasswordChooser.width(of: choice.anchor, in: geo.size),
                        height: PasswordChooser.height(rows: choice.accounts.count, in: geo.size),
                        fill: { tab.fillChosen(host: choice.host, account: $0, port: choice.port, target: choice.target) },
                        manage: {
                            tab.closeChooser(.escape)
                            SettingsWindow.show(tab: "passwords", profileID: tab.profileID)
                        })
                        .offset(x: at.x, y: at.y)
                        .onHover { tab.chooserHovered = $0 }
                        .transition(reduced ? .identity
                                    : .opacity.combined(with: .scale(scale: Look.appearScale,
                                                                     anchor: .topLeading)))
                } else {
                    // The pane resized, or a split closed, under an anchor that is no longer
                    // on it. Open and invisible is the state this must never sit in.
                    Color.clear.onAppear { tab.closeChooser(.resign) }
                }
            }
        }
        .animation(reduced ? nil : Look.appear, value: tab.passwordChoice == nil)
        .animation(reduced ? nil : Look.appear, value: tab.passwordGeneration == nil)
        // A click on the page, a blur and a scroll all come back from the page itself
        // (see Autofill.script). These two do not, because they never reach it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { _ in tab.closeChooser(.resign) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification)) { _ in tab.closeChooser(.resign) }
        .onChange(of: tab.passwordChoice == nil) { if tab.passwordChoice == nil {
            tab.chooserHovered = false
        } }
    }

}

struct PasswordChooserCard: View {
    let choice: PasswordChoice
    let profileID: UUID
    let width: CGFloat
    let height: CGFloat
    let fill: (String) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.accounts.count == 1 ? "Saved password" : "Saved passwords")
                    .font(Look.text.weight(.medium)).foregroundStyle(Look.inkPrimary)
                Text(PasswordOrigin(host: choice.host, port: choice.port).url.absoluteString).font(Look.caption).foregroundStyle(Look.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, Look.rowInset + Look.passwordChooserInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Look.passwordChooserHeader)
            .overlay(alignment: .bottom) { Hairline() }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(choice.accounts.enumerated()), id: \.offset) { i, account in
                            ChooserRow(account: account, host: choice.host,
                                website: PasswordOrigin(host: choice.host, port: choice.port).url.absoluteString,
                                profileID: profileID, selected: i == choice.selected) { fill(account) }
                                .id(i)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: height - PasswordChooser.chromeHeight)
                .onChange(of: choice.selected) { proxy.scrollTo(choice.selected) }
                .onAppear { proxy.scrollTo(choice.selected) }
            }
            .padding(.vertical, Look.passwordChooserInset)
            Button(action: manage) {
                HStack(spacing: Look.inset) {
                    Image(systemName: "key.horizontal").font(Look.rowGlyph)
                    Text("Manage passwords…").font(Look.caption)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Look.caption)
                }
                .foregroundStyle(Look.inkSecondary)
                .padding(.horizontal, Look.rowInset + Look.passwordChooserInset)
                .frame(height: Look.passwordChooserFooter)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Hairline() }
        }
        .frame(width: width, alignment: .leading)
        .background(Look.panelFill, in: .rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius)
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
    static var chromeHeight: CGFloat {
        Look.passwordChooserHeader + Look.passwordChooserFooter + Look.passwordChooserInset * 2
    }
    /// How long after a fill a focus event is ignored. Filling takes the focus out of the
    /// page and hands it back, which is another `focusin` — without this, the list the user
    /// just chose from reopens on top of the form they wanted to submit.
    static let refillGrace: TimeInterval = 1

    /// The dismiss rule, whole, in one place. Focus is the only thing that opens the list;
    /// everything else closes it — except the blur caused by pressing a row, which is the
    /// mouse-*down* of the click that is about to pick that row. Closing on it loses every
    /// click the list exists for, so a blur with the pointer inside the list is ignored.
    static func opens(_ event: ChooserEvent, sinceFill: TimeInterval,
                      pointerInside: Bool = false) -> Bool {
        switch event {
        case .focus: sinceFill >= refillGrace
        case .blur: pointerInside
        case .click, .scroll, .input, .navigate, .resign, .tabSwitch, .escape, .filled: false
        }
    }

    /// The rows plus the footer. Fixed per account, so nothing shifts as the list is walked,
    /// and known before the list is drawn — `Engine` needs it to decide whether the list
    /// would be on screen at all.
    static func height(rows: Int, in viewport: CGSize = CGSize(width: 800, height: 600)) -> CGFloat {
        guard rows > 0 else { return 0 }
        let available = max(1, floor((viewport.height - chromeHeight) / Look.passwordChooserRow))
        return chromeHeight + min(CGFloat(rows), 4, available) * Look.passwordChooserRow
    }

    /// As wide as the field it hangs off, so it reads as part of the form — but never
    /// narrower than a username needs, and never wider than the pane it is drawn in.
    static func width(of anchor: CGRect, in viewport: CGSize) -> CGFloat {
        min(max(anchor.width, Look.chooserWidth), max(0, viewport.width))
    }

    /// Where the list actually goes: under the field, and never outside the page.
    ///
    /// Nil for an anchor that is not on screen at all. A page can put its input anywhere,
    /// including far off the viewport, and a list pinned to nothing is one the user cannot
    /// see to dismiss and cannot tell is there.
    static func place(anchor: CGRect, in viewport: CGSize, height: CGFloat) -> CGPoint? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              anchor.minX.isFinite, anchor.minY.isFinite, anchor.width.isFinite,
              anchor.width >= 0, height.isFinite, height > 0,
              viewport.width > 0, viewport.height >= height,
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
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let store = TabStore.all.first(where: { $0.window === event.window }),
              let tab = store.active, tab.passwordChoice != nil else { return false }
        if event.modifierFlags.contains(.shift), [126, 125, 36, 76].contains(event.keyCode) { return false }
        switch event.keyCode {
        case 126: tab.moveChoice(-1)
        case 125: tab.moveChoice(1)
        case 36, 76: tab.fillSelected()
        default:
            tab.closeChooser(.input)
            return false // let the original key reach the field
        }
        return true
    }

    /// Native events also cover clicks in browser chrome and pages that suppress DOM
    /// events. Preserve clicks inside the card so its buttons still receive mouse-up.
    @MainActor static func handlePointer(_ event: NSEvent) {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else { return }
        for store in TabStore.all where store.window === event.window {
            for tab in store.everyTab where tab.existingWeb?.window === event.window {
                guard let web = tab.existingWeb else { continue }
                if let generation = tab.passwordGeneration {
                    let size = web.bounds.size
                    let point = web.convert(event.locationInWindow, from: nil)
                    let topPoint = CGPoint(x: point.x, y: web.isFlipped ? point.y : size.height - point.y)
                    let at = place(anchor: generation.anchor, in: size, height: 280)
                    let inside = at.map {
                        CGRect(x: min($0.x, max(0, size.width - 320)), y: $0.y, width: min(320, size.width), height: 280).contains(topPoint)
                    } ?? false
                    if !inside { tab.closeChooser(.click) }
                }
                guard let choice = tab.passwordChoice else { continue }
                let size = web.bounds.size
                let point = web.convert(event.locationInWindow, from: nil)
                let topPoint = CGPoint(x: point.x, y: web.isFlipped ? point.y : size.height - point.y)
                let height = height(rows: choice.accounts.count, in: size)
                let at = place(anchor: choice.anchor, in: size, height: height)
                let inside = at.map {
                    CGRect(origin: $0, size: CGSize(width: width(of: choice.anchor, in: size), height: height))
                        .contains(topPoint)
                } ?? false
                if !inside { tab.closeChooser(.click) }
            }
        }
    }

    /// Escape, taken before anything else on the window: the list is the most recent thing
    /// on screen, so it is what Escape means. Returns true when it acted, so the caller
    /// swallows the key — see `VaneWindow.sendEvent`.
    @MainActor static func dismiss(in window: NSWindow?) -> Bool {
        guard let store = TabStore.all.first(where: { $0.window === window }),
              let tab = store.active, tab.passwordChoice != nil || tab.passwordGeneration != nil else { return false }
        tab.closeChooser(.escape)
        return true
    }

    static func check() -> [(String, Bool)] {
        let viewport = CGSize(width: 800, height: 600)
        let mid = CGRect(x: 100, y: 200, width: 320, height: 0)
        let height: CGFloat = 72
        return [
            ("focus opens the list", opens(.focus, sinceFill: 10)),
            ("…but not straight after a fill", opens(.focus, sinceFill: 0) == false),
            ("…and the grace window does end", opens(.focus, sinceFill: refillGrace)),
            ("blur closes it", opens(.blur, sinceFill: 10) == false),
            ("…unless it is the click on a row that caused it",
             opens(.blur, sinceFill: 10, pointerInside: true)),
            ("…and a click still closes it, pointer or no pointer",
             opens(.click, sinceFill: 10, pointerInside: true) == false),
            ("a click elsewhere closes it", opens(.click, sinceFill: 10) == false),
            ("typing closes it even when the pointer is over the card",
             opens(.input, sinceFill: 10, pointerInside: true) == false),
            ("the page's input message means typing", ChooserEvent(page: "input") == .input),
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

            ("the list is as wide as the field", width(of: mid, in: viewport) == 320),
            ("…never narrower than a username needs",
             width(of: CGRect(x: 0, y: 0, width: 40, height: 0), in: viewport)
                == Look.chooserWidth),
            ("…and never wider than the pane",
             width(of: CGRect(x: 0, y: 0, width: 5000, height: 0), in: viewport) == 800),

            ("an anchor inside the pane is left where it is",
             place(anchor: mid, in: viewport, height: height) == CGPoint(x: 100, y: 200)),
            ("…one near the right edge is pulled in",
             place(anchor: CGRect(x: 700, y: 200, width: 240, height: 0),
                   in: viewport, height: height)?.x == 800 - Look.chooserWidth),
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

            ("two rows and a footer is a known height",
             PasswordChooser.height(rows: 2) == chromeHeight + Look.passwordChooserRow * 2),
        ]
    }
}

private struct ChooserRow: View {
    let account: String
    let host: String
    let website: String
    let profileID: UUID
    let selected: Bool
    let fill: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        Button(action: fill) {
            HStack(spacing: Look.inset) {
                PasswordSiteIcon(host: host, profileID: profileID)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.isEmpty ? "No username" : account)
                        .font(Look.text.weight(.medium)).foregroundStyle(Look.inkPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(website).font(Look.caption).foregroundStyle(Look.inkSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "return").font(Look.caption)
                    .foregroundStyle(Look.inkSecondary).opacity(selected || hovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.passwordChooserRow)
            .background(fill(for: selected, hovered: hovered),
                        in: .rect(cornerRadius: Look.chipRadius))
            .padding(.horizontal, Look.passwordChooserInset)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: hovered)
        .accessibilityLabel(account.isEmpty ? "Fill saved password for \(host)"
                            : "Fill \(account) for \(host)")
        .accessibilityValue("Password hidden")
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
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        Group {
            if let offer = tab.pendingSave {
                PasswordOfferCard(offer: offer, profileID: tab.profileID,
                    problem: tab.passwordSaveProblem,
                    dismiss: { tab.pendingSave = nil }, save: { tab.confirmSave() },
                    never: { tab.neverSaveHere() },
                    saveReviewed: { tab.confirmSave(origin: $0, account: $1, password: $2) })
                    .id(offer.id)
                    .transition(reduceMotion || batterySaver.isActive ? .identity
                        : .opacity.combined(with: .scale(scale: Look.appearScale, anchor: .topTrailing)))
            }
        }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.appear, value: tab.pendingSave?.id)
    }
}

struct PasswordOfferCard: View {
    let offer: PendingSave
    let profileID: UUID
    var problem: String? = nil
    let dismiss: () -> Void
    let save: () -> Void
    let never: () -> Void
    var saveReviewed: ((PasswordOrigin, String, String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var reviewing = false
    @State private var draftSite = ""
    @State private var draftAccount = ""
    @State private var draftPassword = ""
    @State private var revealRequest = UUID()
    @State private var revealProblem: String?
    /// Revealing what is about to be saved is a check on Vane, not a secret being handed
    /// out — it is the user's own password, which they just typed into the page.
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Look.cardInset) {
            header
            if reviewing {
                VStack(alignment: .leading, spacing: Look.inset) {
                    Text("Website").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    TextField("HTTPS website", text: $draftSite).textFieldStyle(.roundedBorder)
                    Text("Username").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    TextField("Username (optional)", text: $draftAccount).textFieldStyle(.roundedBorder)
                    PasswordDraftField(text: $draftPassword)
                }
            } else { credential }
            if let revealProblem { Text(revealProblem).font(Look.caption).foregroundStyle(Look.warning) }
            Text("Submitted password · Sign-in success is unverified")
                .font(Look.caption).foregroundStyle(Look.inkSecondary)
            if let problem {
                Text(problem).font(Look.caption).foregroundStyle(Look.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label("Saved on this Mac", systemImage: "lock")
                    .font(Look.caption).foregroundStyle(Look.inkSecondary)
                Spacer(minLength: 0)
            }
            buttons
        }
            .padding(Look.cardInset)
            .frame(maxWidth: Look.offerWidth, alignment: .leading)
            .background(Look.panelFill, in: .rect(cornerRadius: Look.pillRadius))
            .hairline(radius: Look.pillRadius)
            .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius,
                    y: Look.floatShadowY)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(offer.title)
            .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: reviewing)
            // A credential decision is the first thing in the window worth reaching, not the
            // last. Not .isModal, though: the page underneath stays usable.
            .accessibilitySortPriority(2)
            // It appears on its own, with no focus change and no sound — say so.
            .onAppear { axAnnounce(offer.title) }
            .onDisappear { revealRequest = UUID(); revealed = false; draftPassword = "" }
            .task(id: revealed) {
                guard revealed else { return }
                try? await Task.sleep(for: PasswordsPane.revealFor)
                if !Task.isCancelled { revealed = false }
            }
    }

    private var header: some View {
        HStack(spacing: Look.inset) {
            PasswordSiteIcon(host: offer.host, profileID: profileID)
            VStack(alignment: .leading, spacing: 4) {
                Text(offer.update ? "Update password?" : "Save password?")
                    .font(Look.heading).foregroundStyle(Look.inkPrimary)
                Text(offer.origin.url.absoluteString).font(Look.caption).foregroundStyle(Look.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(Look.glyph)
                    .frame(width: Look.control, height: Look.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(Look.inkTertiary)
            .help("Not now")
            .accessibilityLabel("Not now")
        }
    }

    /// What is about to be stored, so "Save" is never a blind yes: the account, and the
    /// password as bullets until the eye is used.
    private var credential: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Username").font(Look.caption).foregroundStyle(Look.inkSecondary)
                Text(offer.account.isEmpty ? "No username" : offer.account)
                    .font(Look.text).foregroundStyle(Look.inkPrimary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(Look.rowInset)
            Hairline().padding(.horizontal, Look.rowInset)
            HStack(spacing: Look.inset) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Password").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    PasswordValue(value: revealed ? offer.password : nil)
                }
                Spacer(minLength: 0)
                PasswordEyeButton(revealed: revealed) {
                    if revealed { revealed = false; return }
                    revealRequest = UUID()
                    let request = revealRequest
                    Passwords.authenticate("show the submitted password for \(offer.host)") { ok in
                        guard revealRequest == request else { return }
                        if ok { revealed = true; revealProblem = nil }
                        else { revealProblem = "Authentication was not completed. Try again with your Mac login password." }
                    }
                }
            }
            .padding(Look.rowInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
        // The password is the user's own and is on its way into their keychain, but it is
        // still not something VoiceOver should read out unprompted.
        .accessibilityElement(children: .contain)
    }

    private var buttons: some View {
        HStack(spacing: Look.inset) {
            Spacer(minLength: 0)
            Button("Never", action: never).buttonStyle(.bordered)
                .help("Never save passwords for \(offer.host)")
                .accessibilityLabel("Never save passwords for \(offer.host)")
            Button(reviewing ? (offer.update ? "Update" : "Save") : "Review…") {
                if !reviewing {
                    draftSite = offer.origin.url.absoluteString
                    draftAccount = offer.account
                    draftPassword = offer.password
                    reviewing = true
                } else if let origin = PasswordsPane.siteOrigin(draftSite) {
                    if let saveReviewed { saveReviewed(origin, draftAccount, draftPassword) }
                    else { save() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(reviewing && (PasswordsPane.siteOrigin(draftSite) == nil || draftPassword.isEmpty))
        }
        .controlSize(.large)
    }
}

struct PasswordEyeButton: View {
    let revealed: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye")
                .overlay {
                    Rectangle().frame(width: 1.5, height: 20).rotationEffect(.degrees(-45))
                        .scaleEffect(y: revealed ? 1 : 0)
                }
                .font(Look.rowGlyph)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(Look.inkSecondary)
        .help(revealed ? "Hide password" : "Show password")
        .accessibilityLabel(revealed ? "Hide password" : "Show password")
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: revealed)
    }
}

struct PasswordDraftField: View {
    @Binding var text: String
    @State private var revealed = false
    @State private var options = PasswordGenerator.Options()
    @State private var configuring = false
    @State private var revealRequest = UUID()
    @State private var revealProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            Text("Password").font(Look.caption).foregroundStyle(Look.inkSecondary)
            HStack(spacing: Look.inset) {
                Group {
                    if revealed { TextField("Password", text: $text) }
                    else { SecureField("Password", text: $text) }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                PasswordEyeButton(revealed: revealed) {
                    if revealed { revealed = false; return }
                    revealRequest = UUID()
                    let request = revealRequest
                    Passwords.authenticate("show this password") { ok in
                        guard revealRequest == request else { return }
                        if ok { revealed = true; revealProblem = nil }
                        else { revealProblem = "Authentication was not completed. Try again with your Mac login password." }
                    }
                }
            }
            if let revealProblem { Text(revealProblem).font(Look.caption).foregroundStyle(Look.warning) }
            Button { configuring.toggle() } label: {
                Label("Generate password…", systemImage: "sparkles")
            }.buttonStyle(.plain).font(Look.caption).foregroundStyle(Color.accentColor)
                .popover(isPresented: $configuring) {
                    VStack(alignment: .leading, spacing: Look.cardInset) {
                        PasswordGeneratorOptions(options: $options)
                        Button("Use generated password") {
                            text = PasswordGenerator.generate(options: options)
                            configuring = false
                        }.disabled(!options.hasCharacters)
                    }.padding(Look.cardInset).frame(width: 280)
                }
        }
        .onDisappear { revealRequest = UUID(); revealed = false }
        .task(id: revealed) {
            guard revealed else { return }
            try? await Task.sleep(for: PasswordsPane.revealFor)
            if !Task.isCancelled { revealed = false }
        }
    }
}

/// Fixed-length masking is shared by the manager and both page popups.
struct PasswordValue: View {
    let value: String?

    var body: some View {
        Text(value ?? PasswordsPane.dots)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .tracking(value == nil ? 1.5 : 0)
            .foregroundStyle(Look.inkPrimary)
            .lineLimit(1).truncationMode(.tail)
            .accessibilityLabel("Password")
            .accessibilityValue(PasswordsPane.spoken(value))
    }
}

struct PasswordSiteIcon: View {
    let host: String
    let profileID: UUID

    var body: some View {
        SiteIcon(icon: URL(string: "https://" + host).flatMap {
            Favicons.cache(for: profileID).icon(for: $0)
        }, fallback: "key.fill", size: Look.rowIcon)
            .frame(width: 32, height: 32)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
            .accessibilityHidden(true)
    }
}
