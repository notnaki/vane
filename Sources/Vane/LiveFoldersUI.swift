import SwiftUI

/// "New Live Folder…" and "Edit Live Folder…": sign in once, say what the folder tracks,
/// name it. The same sheet does both — editing a live folder is choosing the same three
/// things again.
///
/// ponytail: one sheet, no wizard. Arc walks you through picking a service, signing in and
/// choosing a filter on three screens; there is one service, and three screens for three
/// fields is three screens too many.
struct LiveFolderSheet: View {
    let store: TabStore
    /// nil for a new folder, the folder being changed for "Edit Live Folder…".
    var editing: Folder?
    @ObservedObject var live: LiveFolders
    @Environment(\.dismiss) private var dismiss

    @State private var query = GitHubQuery()
    @State private var name = ""
    @State private var repo = ""
    @State private var token = ""
    @State private var login: String?
    @State private var problem: String?
    @State private var checking = false

    private var repoIsWrong: Bool {
        !repo.trimmingCharacters(in: .whitespaces).isEmpty && GitHub.repository(repo) == nil
    }

    /// What the folder ends up called: what was typed, else the filter's own label — so a
    /// folder is never called "New Folder" and never nameless.
    private var folderName: String { TabActions.cleanName(name) ?? query.filter.title }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            Text(editing == nil ? "New Live Folder" : "Edit Live Folder").font(Look.heading)
            Text("A folder that keeps itself filled with the GitHub pull requests you care "
                 + "about. Rows appear and vanish as pull requests open and close.")
                .font(Look.footnote).foregroundStyle(Look.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)

            if login == nil { signIn } else { folder }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create Folder" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(login == nil || repoIsWrong)
            }
        }
        .padding(Look.paneMargin)
        .frame(width: 460)
        .onAppear(perform: load)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(editing == nil ? "New Live Folder" : "Edit Live Folder")
    }

    // MARK: Signing in

    private var signIn: some View {
        SettingsCard {
            SettingsRow("Personal access token") {
                // Secure, and never held anywhere but this field and the keychain: the
                // token is a password with a repository behind it.
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { check() }
                    .accessibilityLabel("GitHub personal access token")
            }
            SettingsRow("") {
                Button("Create one on GitHub") {
                    // In a tab, not the default browser: the user is already in a browser.
                    if let u = URL(string: "https://github.com/settings/tokens") { store.newTab(u) }
                    dismiss()
                }
                .buttonStyle(.link)
                Spacer(minLength: Look.inset)
                Button(checking ? "Checking…" : "Sign In") { check() }
                    .disabled(checking || TabActions.cleanName(token) == nil)
            }
            Footnote(problem ?? "A classic token with the “repo” scope, or a fine-grained "
                     + "token that can read pull requests. It is stored in your keychain, "
                     + "for this profile only, and shows up in Settings ▸ Passwords.")
        }
    }

    // MARK: What it tracks

    private var folder: some View {
        SettingsCard {
            SettingsRow("Signed in as") {
                Text(login ?? "").font(Look.text).foregroundStyle(Look.inkSecondary)
                Button("Sign Out") { signOut() }.buttonStyle(.link)
            }
            SettingsRow("Pull requests") {
                Picker("", selection: $query.filter) {
                    ForEach(GitHubQuery.Filter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("What the folder tracks")
            }
            SettingsRow("In repository") {
                TextField("Every repository", text: $repo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("Repository, owner slash name")
            }
            SettingsRow("Folder name") {
                TextField(query.filter.title, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("Folder name")
            }
            Footnote(repoIsWrong
                     ? "A repository is written “owner/name”, like apple/swift."
                     : "Refreshes every five minutes, when you unfold it, and when you come "
                       + "back to the window.")
        }
    }

    // MARK: Doing it

    private func load() {
        login = live.signIn?.login
        guard let editing, case .github(let q)? = editing.live else { return }
        query = q
        repo = q.repo ?? ""
        name = editing.name
    }

    /// The token is tested before it is stored: a token that cannot say who it belongs to
    /// would fill nothing, and finding that out from an empty folder is finding it out late.
    private func check() {
        guard let typed = TabActions.cleanName(token) else { return }
        checking = true
        problem = nil
        Task {
            switch await LiveFolders.identify(token: typed) {
            case .success(let who):
                if live.save(login: who, token: typed) {
                    login = who
                    token = ""
                } else {
                    problem = "The keychain would not store the token."
                }
            case .failure(let trouble):
                problem = trouble.says
            }
            checking = false
        }
    }

    private func signOut() {
        live.signOut()
        login = nil
    }

    private func commit() {
        let source = LiveSource.github(GitHubQuery(filter: query.filter,
                                                   repo: GitHub.repository(repo)))
        if let editing {
            store.editLiveFolder(editing.id, named: folderName, source: source)
        } else {
            store.newLiveFolder(named: folderName, source: source)
        }
        dismiss()
    }
}

/// The mark on a live folder's own glyph, so the row says where its contents come from
/// without being unfolded. Orange when the last refresh failed — the folder is showing what
/// it had, not what there is.
///
/// ponytail: an SF Symbol, not GitHub's octocat. Shipping the logo means bundling an image
/// and reading its licence; a branch glyph says "filled from a git host" well enough, and
/// the rows inside wear github.com's real favicon anyway.
struct LiveBadge: View {
    @ObservedObject var live: LiveFolders
    let folder: UUID

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(Look.badgeGlyph)
            .foregroundStyle(live.failing.contains(folder) ? Look.warning : Look.inkSecondary)
            .accessibilityHidden(true)       // the folder's value already says it is live
    }
}

/// The two live-folder commands as accessibility actions, so the keyboard and VoiceOver
/// reach them the way they reach Rename and Delete.
///
/// A modifier rather than two more links in `FolderRow`'s chain: that chain is already at
/// the type-checker's ceiling, and two more closures in it stop the file compiling.
///
/// Nothing at all on an ordinary folder — an action VoiceOver offers and that does nothing
/// is worse than no action.
struct LiveFolderActions: ViewModifier {
    let store: TabStore
    let folder: Folder
    @Binding var editing: Bool

    func body(content: Content) -> some View {
        if folder.live == nil {
            content
        } else {
            content
                .accessibilityAction(named: "Refresh Now") {
                    LiveFolders.shared(for: store.profileID).refreshNow(folder.id)
                }
                .accessibilityAction(named: "Edit Live Folder") { editing = true }
                .accessibilityAction(named: "Stop Keeping Filled") {
                    LiveFolders.shared(for: store.profileID).stopKeepingFilled(folder.id)
                }
        }
    }
}
