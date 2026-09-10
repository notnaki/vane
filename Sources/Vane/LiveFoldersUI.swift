import SwiftUI

/// "Edit Live Folder…": sign in, say what the folder tracks, name it.
///
/// It is no longer what "New Live Folder…" opens. Arc asks nothing to make one — the folder
/// is simply there, holding the pull requests you and your team have between you — and this
/// is where any of that is changed afterwards. The one build it still opens for a *new*
/// folder is one with no client secret compiled in, which has no consent page to send anyone
/// to and so still takes a personal access token; see `OAuthSecret` and `LiveFolders.route`.
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
    /// The pull requests this folder has been told to stop showing, as they stood when the
    /// sheet opened. Held here rather than read off `editing` so the row goes away the moment
    /// the button is pressed — `editing` is the copy the sheet was handed.
    @State private var hidden: [String] = []

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
            // Only where there is a consent page to send anyone to. In a source checkout
            // `OAuthSecret.github` is nil, the button would open a page GitHub answers with
            // "The redirect_uri is not associated with this application", and the token
            // field below it is the way in — see `LiveFolders.route`.
            if OAuthSecret.github != nil {
                SettingsRow("GitHub") {
                    Button("Connect…") {
                        live.connect(in: store, thenCreate: false)
                        dismiss()
                    }
                }
            }
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
            Footnote(problem ?? tokenFootnote)
        }
    }

    /// What the token field says for itself. The last sentence is only there in a build that
    /// cannot do the web flow, because that is the build where a user would otherwise think
    /// pasting a token is what Vane asks of everybody.
    private var tokenFootnote: String {
        "A classic token with the “repo” scope, or a fine-grained token that can read pull "
            + "requests. It is stored in your keychain, for this profile only, and shows up "
            + "in Settings ▸ Passwords."
            + (OAuthSecret.github == nil ? " Signed releases connect with one click." : "")
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
            SettingsRow("Active in") {
                Picker("", selection: $query.age) {
                    Text("Any Time").tag(GitHubQuery.Age?.none)
                    ForEach(GitHubQuery.Age.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("How recently the pull requests were touched")
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
            // Only when there is something hidden to bring back. A row that says "Show 0
            // Hidden Again" is a row explaining a feature nobody has used yet.
            if let editing, !hidden.isEmpty {
                SettingsRow("Hidden rows") {
                    Button("Show \(hidden.count) Hidden Again") {
                        store.showHiddenAgain(editing.id)
                        hidden = []
                    }
                }
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
        hidden = editing.dismissed ?? []
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
                                                   repo: GitHub.repository(repo),
                                                   age: query.age))
        if let editing {
            store.editLiveFolder(editing.id, named: folderName, source: source)
        } else {
            store.newLiveFolder(named: folderName, source: source)
        }
        dismiss()
    }
}

/// GitHub's mark, as a shape. It goes on the folder's glyph, on the rows inside it and in
/// the callout, which is where Arc puts it too — the folder is a GitHub folder, and a branch
/// glyph only ever said "a git host somewhere".
///
/// ponytail: a `Shape`, not a bundled asset. Octicons' own `mark-github-24` path (MIT,
/// github/octicons), converted once into absolute curves in the unit square, is one file
/// with no resource bundle, no `Package.swift` `resources:` entry, no @2x and no image to
/// decode — and it takes the foreground colour, which is the whole reason the same mark can
/// be an orange badge on a failing folder and ink everywhere else.
///
/// Drawn into the largest square the rect holds, centred, so a caller only says how big.
struct GitHubMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - side) / 2
        let oy = rect.minY + (rect.height - side) / 2
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * side, y: oy + y * side)
        }
        var p = Path()
        p.move(to: at(0.5, 0.0123))
        p.addCurve(to: at(0, 0.5123),
                   control1: at(0.2237, 0.0123), control2: at(0, 0.2361))
        p.addCurve(to: at(0.3419, 0.9867),
                   control1: at(0, 0.7336), control2: at(0.1431, 0.9205))
        p.addCurve(to: at(0.3762, 0.9629),
                   control1: at(0.3669, 0.9911), control2: at(0.3762, 0.9761))
        p.addCurve(to: at(0.3756, 0.8698),
                   control1: at(0.3762, 0.9511), control2: at(0.3756, 0.9117))
        p.addCurve(to: at(0.2075, 0.8111),
                   control1: at(0.25, 0.8929), control2: at(0.2175, 0.8392))
        p.addCurve(to: at(0.1562, 0.7405),
                   control1: at(0.2019, 0.7967), control2: at(0.1775, 0.7523))
        p.addCurve(to: at(0.1556, 0.7073),
                   control1: at(0.1387, 0.7311), control2: at(0.1137, 0.7079))
        p.addCurve(to: at(0.2325, 0.7586),
                   control1: at(0.195, 0.7067), control2: at(0.2231, 0.7436))
        p.addCurve(to: at(0.3781, 0.7998),
                   control1: at(0.2775, 0.8342), control2: at(0.3494, 0.8129))
        p.addCurve(to: at(0.41, 0.7329),
                   control1: at(0.3825, 0.7673), control2: at(0.3956, 0.7455))
        p.addCurve(to: at(0.1825, 0.4861),
                   control1: at(0.2987, 0.7205), control2: at(0.1825, 0.6773))
        p.addCurve(to: at(0.2337, 0.343),
                   control1: at(0.1825, 0.4317), control2: at(0.2019, 0.3867))
        p.addCurve(to: at(0.2387, 0.2105),
                   control1: at(0.2287, 0.3305), control2: at(0.2113, 0.2792))
        p.addCurve(to: at(0.3763, 0.2618),
                   control1: at(0.2387, 0.2105), control2: at(0.2806, 0.1974))
        p.addCurve(to: at(0.5013, 0.2449),
                   control1: at(0.4163, 0.2505), control2: at(0.4587, 0.2449))
        p.addCurve(to: at(0.6263, 0.2618),
                   control1: at(0.5437, 0.2449), control2: at(0.5863, 0.2505))
        p.addCurve(to: at(0.7637, 0.2105),
                   control1: at(0.7219, 0.1968), control2: at(0.7637, 0.2105))
        p.addCurve(to: at(0.7687, 0.343),
                   control1: at(0.7913, 0.2792), control2: at(0.7737, 0.3305))
        p.addCurve(to: at(0.82, 0.4861),
                   control1: at(0.8006, 0.3867), control2: at(0.82, 0.4311))
        p.addCurve(to: at(0.5919, 0.7329),
                   control1: at(0.82, 0.6779), control2: at(0.7031, 0.7204))
        p.addCurve(to: at(0.6256, 0.8255),
                   control1: at(0.61, 0.7486), control2: at(0.6256, 0.7786))
        p.addCurve(to: at(0.625, 0.9629),
                   control1: at(0.6256, 0.8923), control2: at(0.625, 0.9461))
        p.addCurve(to: at(0.6593, 0.9867),
                   control1: at(0.625, 0.9761), control2: at(0.6344, 0.9917))
        p.addCurve(to: at(1, 0.5123),
                   control1: at(0.8569, 0.9205), control2: at(1, 0.7329))
        p.addCurve(to: at(0.5, 0.0123),
                   control1: at(1, 0.2361), control2: at(0.7763, 0.0123))
        p.closeSubpath()
        return p
    }
}

/// The mark on a live folder's own glyph, so the row says where its contents come from
/// without being unfolded. Orange when the last refresh failed — the folder is showing what
/// it had, not what there is.
struct LiveBadge: View {
    @ObservedObject var live: LiveFolders
    let folder: UUID

    var body: some View {
        GitHubMark()
            .fill(live.failing.contains(folder) ? Look.warning : Look.inkSecondary)
            .frame(width: Look.sourceBadge, height: Look.sourceBadge)
            .accessibilityHidden(true)       // the folder's value already says it is live
    }
}

/// Arc's "Live Folder Created": a card hanging off the folder the click just made, saying
/// what is about to fill it. There is no sheet any more — the folder is simply there — so
/// this is the only thing that explains it, once, on the one occasion it is news.
///
/// A `ViewModifier` rather than another link in `FolderRow`'s chain, for the reason
/// `LiveFolderActions` is one: that chain is already at the type-checker's ceiling.
///
/// It goes on a click anywhere else — the popover's own dismissal — or after
/// `Look.calloutDuration`, whichever comes first. See `TabStore.announce(folder:)`.
struct LiveFolderCallout: ViewModifier {
    @ObservedObject var store: TabStore
    let folder: Folder

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { store.announcing == folder.id },
                                             set: { if !$0 { store.announcing = nil } }),
                        arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: Look.captionGap) {
                HStack(spacing: Look.rowSpacing) {
                    GitHubMark().fill(Look.inkPrimary)
                        .frame(width: Look.tileIcon, height: Look.tileIcon)
                    Text("Live Folder Created").font(Look.heading)
                }
                Text("Pull requests from you and your team will show up here automatically")
                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Look.paneMargin)
            .frame(width: Look.calloutWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
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
