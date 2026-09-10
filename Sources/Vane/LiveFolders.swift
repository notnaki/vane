import AppKit
import SwiftUI

/// Arc's Live Folders: a folder in the Pinned section that fills itself. Today one source —
/// GitHub pull requests — because that is the one Arc shipped and the one that pays for the
/// machinery around it.
///
/// ponytail: an enum with one case rather than a protocol and a registry. A second source
/// (Linear issues, a Jira filter) is another case and another `fetch`; nothing about
/// `Folder`, the sidebar or the reconcile changes for it. A protocol here would be a
/// dispatch table with one entry.
enum LiveSource: Codable, Equatable, Sendable {
    case github(GitHubQuery)

    /// What the folder's "Edit…" sheet opens on, and what a nameless folder is called.
    var title: String {
        switch self {
        case .github(let q): q.filter.title
        }
    }
}

/// What a GitHub live folder tracks: one of Arc's four "about me" filters, optionally
/// narrowed to a single repository.
struct GitHubQuery: Codable, Equatable, Sendable {
    /// Arc's four. Each is one GitHub search qualifier and nothing else, which is why
    /// there is no free-text query box: a folder is a saved *view*, not a search bar.
    enum Filter: String, Codable, CaseIterable, Sendable, Identifiable {
        /// GitHub's `involves:` — authored, assigned, mentioned or asked to review, in one
        /// search. What Arc's "pull requests from you and your team" actually means: a
        /// folder that only held review requests sat empty for anyone whose own pull
        /// requests were the ones open.
        case involved, reviewRequested, assigned, created, mentioned

        var id: String { rawValue }

        var title: String {
            switch self {
            case .involved: "Involving Me"
            case .reviewRequested: "Review Requested"
            case .assigned: "Assigned to Me"
            case .created: "Created by Me"
            case .mentioned: "Mentioning Me"
            }
        }

        /// The qualifier GitHub's search knows it by. `@me` rather than the login, so a
        /// folder keeps working after the token is swapped for another account's.
        var qualifier: String {
            switch self {
            case .involved: "involves:@me"
            case .reviewRequested: "review-requested:@me"
            case .assigned: "assignee:@me"
            case .created: "author:@me"
            case .mentioned: "mentions:@me"
            }
        }
    }

    /// How far back the folder looks: "Active in the last 7 days", and so on. A folder on a
    /// busy account fills up with pull requests nobody has touched in months, and Optional is
    /// what says "any time" — the default, the answer for every folder saved before this
    /// existed, and the one that adds no qualifier to the search at all.
    enum Age: String, Codable, CaseIterable, Sendable, Identifiable {
        case week, month, quarter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            case .quarter: "Last 90 Days"
            }
        }

        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            }
        }
    }

    var filter: Filter = .involved
    /// "owner/name", or nil for every repository the token can see.
    var repo: String?
    /// How recently the pull request was touched, or nil for any time.
    var age: Age? = nil
}

// MARK: - The wire, and the reconcile

/// Everything about GitHub that can be proved without a network: the query string, the
/// response shape, what a status code means, and the rule that turns a list of pull
/// requests into rows appearing and vanishing.
///
/// ponytail: raw REST over `URLSession`, no SDK and no GraphQL. One endpoint, four
/// qualifiers, five fields — a dependency for that is a dependency for a `URL` and a
/// `JSONDecoder` the standard library already has.
enum GitHub {
    static let api = "https://api.github.com"
    /// One page. A folder holding more than fifty open pull requests about you is not a
    /// folder any more, and paging would mean holding a cursor per folder to save nothing.
    static let perPage = 50

    /// One pull request, as much of it as a row needs.
    struct PR: Equatable, Sendable {
        var url: String
        var title: String
        var draft: Bool
        var repo: String
        var number: Int
    }

    /// The glyph a live row wears. `closed` is the goodbye — see `plan`.
    enum State: String, Sendable {
        case open, draft, closed

        var symbol: String {
            switch self {
            case .open: "arrow.triangle.pull"
            case .draft: "pencil.circle"
            case .closed: "checkmark.circle"
            }
        }

        var says: String {
            switch self {
            case .open: "Open pull request"
            case .draft: "Draft pull request"
            case .closed: "Merged or closed"
            }
        }
    }

    /// Why a refresh came back with nothing. Never a reason to empty a folder — see
    /// `LiveFolders.refresh`.
    enum Trouble: Error, Equatable, Sendable {
        case unauthorised
        case rateLimited
        /// 422: GitHub understood the request and refused the search — in practice a
        /// repository that does not exist, or one this token is not allowed to see.
        case badQuery
        case refused(Int)
        case offline

        var says: String {
            switch self {
            case .unauthorised: "GitHub refused the token. Sign in again in Edit Live Folder."
            case .rateLimited: "GitHub is rate-limiting Vane. The folder will try again shortly."
            case .badQuery: "GitHub would not run that search. Check the repository name, and "
                + "that your token is allowed to see it."
            case .refused(let code): "GitHub answered \(code). The folder kept what it had."
            case .offline: "Could not reach GitHub. The folder kept what it had."
            }
        }
    }

    /// nil when the reply is fine. 403 and 429 are both how GitHub says "too much"; 401 is
    /// how it says "not you". Everything else is reported with its number rather than
    /// guessed at, because a wrong explanation is worse than a bare one.
    static func trouble(status: Int) -> Trouble? {
        switch status {
        case 200..<300: nil
        case 401: .unauthorised
        case 403, 429: .rateLimited
        case 422: .badQuery
        default: .refused(status)
        }
    }

    // MARK: The query

    /// "owner/name", cleaned, or nil when it is not that. Deliberately strict: the string
    /// goes into a search query, and a slash or a space smuggled through would silently
    /// widen the folder to somebody else's repositories rather than fail.
    static func repository(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "/",
                                                                   omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        guard parts.allSatisfy({ !$0.isEmpty && CharacterSet(charactersIn: String($0))
                                                    .isSubset(of: allowed) })
        else { return nil }
        return parts.joined(separator: "/")
    }

    /// The search GitHub is asked. Only open pull requests: a folder of closed ones is the
    /// Library's job, and `is:open` is also what makes a row's disappearance mean something.
    /// `now` is a parameter so the whole query is provable offline: an age turns into a date
    /// on the wire, and a check against "seven days before whenever this ran" proves nothing.
    static func terms(_ q: GitHubQuery, now: Date = .now) -> String {
        var out = ["is:pr", "is:open", q.filter.qualifier]
        if let repo = q.repo.flatMap(repository) { out.append("repo:" + repo) }
        // GitHub reads a bare `updated:>=` date in UTC, so the day is counted in UTC too —
        // in the user's own calendar the folder would quietly hold a day more or less
        // depending on which side of midnight GMT they live.
        if let age = q.age { out.append("updated:>=" + day(now, minus: age.days)) }
        return out.joined(separator: " ")
    }

    /// `days` before `now`, as GitHub's YYYY-MM-DD. Nothing here is localised: this is a
    /// search qualifier, not a date shown to anybody.
    static func day(_ now: Date, minus days: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let then = cal.date(byAdding: .day, value: -days, to: now) ?? now
        let d = cal.dateComponents([.year, .month, .day], from: then)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    /// `URLComponents` does the escaping — the terms carry spaces, `:` and `/`, and hand
    /// rolling that is exactly how a repo name ends up meaning two qualifiers.
    static func search(_ q: GitHubQuery) -> URL? {
        var c = URLComponents(string: api + "/search/issues")
        c?.queryItems = [URLQueryItem(name: "q", value: terms(q, now: .now)),
                         URLQueryItem(name: "per_page", value: String(perPage))]
        return c?.url
    }

    /// The headers every call carries. `X-GitHub-Api-Version` is what stops a future
    /// default shape arriving unannounced.
    static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Vane", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        return r
    }

    // MARK: The reply

    private struct Reply: Decodable {
        struct Item: Decodable {
            let htmlUrl: String
            let title: String
            let draft: Bool?
            let number: Int
            let repositoryUrl: String?
        }
        let items: [Item]
    }

    /// nil when the body is not a search reply at all; an empty array is a real answer
    /// ("no pull requests"), and the two must not be confused — one keeps the rows, the
    /// other empties the folder.
    static func decode(_ data: Data) -> [PR]? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? d.decode(Reply.self, from: data) else { return nil }
        return reply.items.map {
            PR(url: $0.htmlUrl, title: $0.title, draft: $0.draft ?? false,
               // "https://api.github.com/repos/owner/name" → "owner/name". Falls back to
               // nothing rather than to a wrong name: it is only ever shown, never queried.
               repo: ($0.repositoryUrl.map { URL(string: $0) } ?? nil)
                   .map { $0.pathComponents.suffix(2).joined(separator: "/") } ?? "",
               number: $0.number)
        }
    }

    /// `GET /user`, the login, so the sheet can greet whoever the token belongs to.
    private struct User: Decodable { let login: String }

    static func login(_ data: Data) -> String? {
        (try? JSONDecoder().decode(User.self, from: data))?.login
    }

    // MARK: Reconciling

    /// Whether a row's page is that pull request: its own page, or anything under it —
    /// Files changed, a commit, a review.
    ///
    /// Matching on equality alone would make the folder think the pull request had gone the
    /// moment you clicked "Files changed" inside its row, and the next refresh would close
    /// the tab out from under you. A prefix is all it takes, and it costs no extra state:
    /// the row's url is written down as it always was.
    static func row(_ url: String, isFor pr: String) -> Bool {
        url == pr || url.hasPrefix(pr + "/") || url.hasPrefix(pr + "#") || url.hasPrefix(pr + "?")
    }

    /// Which of the rows sitting directly in a live folder are the folder's own work, in
    /// drawing order: the ones whose url `owned` records — `Folder.owned`, which is written
    /// down with the folder — matched by prefix for the reason `row(_:isFor:)` exists.
    /// Everything else in the folder is the user's and is no part of any reconcile.
    ///
    /// Nothing is ever adopted. A folder that has never refreshed owns nothing and so takes
    /// nothing; it fills itself from empty, which is the same thing it did on the day it was
    /// made. Guessing instead — "a pull request page in a live folder must be the folder's"
    /// — is wrong exactly once, on the pull request you dragged in by hand, and being wrong
    /// there means closing a tab nobody asked to close.
    ///
    /// One row per url. Two rows on the same page — a second copy of a pull request dragged
    /// in — would otherwise both answer to it, and a plan would name it twice: ordered twice
    /// and closed twice. The first is the folder's; the extra copy is left alone, which is
    /// what "never close what you did not open" means when the two are indistinguishable.
    ///
    /// A row taken somewhere else entirely — off github, or onto another pull request — stops
    /// matching and so stops being the folder's. It is left exactly where it is, and the pull
    /// request it used to stand for comes back as a new row on the next refresh. Which is
    /// right: the user took that tab somewhere, and the folder is not entitled to steer it
    /// back or to close it.
    static func mine(_ here: [String], owned: [String]) -> [String] {
        var seen = Set<String>()
        return here.filter { r in
            owned.contains { row(r, isFor: $0) } && seen.insert(r).inserted
        }
    }

    /// Which pull requests this folder has been told to stop showing. A row the folder put
    /// here and that is not here any more — unpinned, dragged out, archived, its tab closed —
    /// was taken out by the user, and putting it straight back because GitHub still lists the
    /// pull request is the folder arguing with them. So the pull request is written down as
    /// dismissed and the next search skips it.
    ///
    /// `previous` is what the folder already had hidden, and an entry leaves it the moment
    /// its pull request stops coming back from GitHub: the pull request closed, and if it is
    /// ever reopened it is news again rather than something hidden months ago. That is also
    /// what keeps the list from growing forever — it can never be longer than one page of
    /// search results.
    ///
    /// A row the folder does not own is no part of this: a page dragged into the folder is
    /// not in `owned`, and dragging it out again dismisses nothing.
    ///
    /// ponytail: the ceiling on `mine` — "a row taken somewhere else entirely stops being the
    /// folder's" — decides one case here, so it is decided out loud. `have` is built from the
    /// page each row is *on* (`TabStore.rowURL` answers `currentURL`), so a row browsed off
    /// github is missing from it for the same reason a row dragged out is, and the pull
    /// request is hidden rather than added a second time. The two cannot be told apart from a
    /// list of urls, and hiding is the recoverable half: the tab is still there, holding the
    /// page the user went to, and "Show Hidden Again" brings the row back. Re-adding instead
    /// leaves the user with two rows for one pull request and nothing to say which is which.
    static func dismissed(previous: [String], owned: [String], have: [String],
                          want: [String]) -> [String] {
        var out = previous.filter { want.contains($0) }
        var seen = Set(out)
        for pr in want where !seen.contains(pr) {
            guard owned.contains(where: { row($0, isFor: pr) }),
                  !have.contains(where: { row($0, isFor: pr) })
            else { continue }
            out.append(pr)
            seen.insert(pr)
        }
        return out
    }

    /// What a refresh does to a folder's rows. The rows become exactly the pull requests the
    /// search returned, in the order it returned them — except that a row whose pull request
    /// has just gone is kept for one more refresh wearing the "merged or closed" glyph, so
    /// it says goodbye rather than blinking out.
    struct Plan: Equatable, Sendable {
        /// Pull request urls with no row yet, in search order.
        var add: [String] = []
        /// Row urls to close: their pull request has gone and they already said goodbye.
        var remove: [String] = []
        /// Row urls kept one more refresh, marked closed.
        var closing: [String] = []
        /// Every row that should remain, in the order to draw it.
        var order: [String] = []
        /// What each arriving row is called, by url, so it has a name before it has ever
        /// loaded. A row parked with no title read "New Tab" until somebody clicked it.
        var titles: [String: String] = [:]

        var changesRows: Bool { !add.isEmpty || !remove.isEmpty || !closing.isEmpty }
    }

    /// `have` are the folder's row urls in order, `want` the search's pull request urls in
    /// order, `closing` the rows already wearing the goodbye glyph.
    static func plan(have: [String], want: [String], closing: Set<String>) -> Plan {
        var seen = Set<String>()
        let wanted = want.filter { seen.insert($0).inserted }
        var out = Plan()
        for pr in wanted {
            if let row = have.first(where: { row($0, isFor: pr) }) {
                out.order.append(row)
            } else {
                out.add.append(pr)
                out.order.append(pr)          // the row is made at the pull request's url
            }
        }
        let gone = have.filter { r in !wanted.contains { row(r, isFor: $0) } }
        out.remove = gone.filter { r in closing.contains { row(r, isFor: $0) } }
        out.closing = gone.filter { r in !closing.contains { row(r, isFor: $0) } }
        out.order += out.closing              // the ones on their way out sink to the bottom
        return out
    }

    /// What a refresh actually takes out, given what the user is looking at. A page is never
    /// taken out from under someone — not the tab in front, not another pane of the split —
    /// so those rows come back as `held` instead: the folder keeps them, wearing their
    /// goodbye, and the next refresh takes them once the user has moved on.
    ///
    /// Split out of `applyLive` and pure for it: "a refresh never closes the page you are
    /// reading, and never has a reason to touch `current`" is worth proving offline rather
    /// than trusting a guard in the middle of a store mutation.
    static func removing(_ plan: Plan, showing: Set<String>) -> (remove: [String], held: [String]) {
        (plan.remove.filter { !showing.contains($0) },
         plan.remove.filter { showing.contains($0) })
    }

    /// The floor under every refresh. Expanding a folder and switching back to the window
    /// both ask for one, and a user flicking a folder open and shut would otherwise spend
    /// the hour's API budget in a minute.
    static func due(last: Date?, now: Date, every: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= every
    }
}

// MARK: - Signing in with GitHub

/// GitHub's OAuth web flow, which is how Vane gets a token without the user ever seeing one.
/// Arc does not ask for a personal access token and neither does this: "New Live Folder…"
/// opens github.com's own consent page in a tab, and the answer comes back to a `vane:` url
/// that never leaves the page.
///
/// ponytail: the web flow rather than the device flow. Vane *is* the browser — it can open
/// the consent page in a tab and read the redirect out of its own navigation delegate, which
/// is one cancelled navigation and no polling loop. The device flow exists for televisions.
///
/// Everything here is a pure value — a url in, a url or a request out — so `selfcheck --pure`
/// proves the whole handshake with no network and no consent page.
enum GitHubOAuth {
    /// Public by design: a client id identifies the app to GitHub and is in the redirect url
    /// anyway. The secret is `OAuthSecret.github`, and is not in the repository.
    nonisolated static let clientID = "Ov23liQ1Plm1UJ9nIlWd"
    /// Registered on the OAuth app. Deliberately a scheme macOS knows nothing about: it is
    /// *not* declared in the bundle's Info.plist, so it is not a system-wide handler another
    /// app can aim a url at. The only thing that ever sees one is `decidePolicyFor` in this
    /// process, which cancels it — see `ExternalApps.ownScheme`.
    nonisolated static let redirect = "vane://oauth/github"
    nonisolated static let redirectHost = "oauth"
    nonisolated static let redirectPath = "/github"
    /// `repo`, because a pull request in a private repository is still a pull request the
    /// folder is meant to hold, and GitHub has no narrower scope that can search for one.
    nonisolated static let scope = "repo"

    nonisolated static let authorizeURL = "https://github.com/login/oauth/authorize"
    nonisolated static let tokenURL = "https://github.com/login/oauth/access_token"

    /// The page the user is sent to. `state` is the one-shot value the reply must carry
    /// back; anything else arriving at the redirect is not this sign-in.
    nonisolated static func authorize(state: String) -> URL? {
        var c = URLComponents(string: authorizeURL)
        c?.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                         URLQueryItem(name: "redirect_uri", value: redirect),
                         URLQueryItem(name: "scope", value: scope),
                         URLQueryItem(name: "state", value: state)]
        return c?.url
    }

    /// ponytail: a UUID. It has to be unguessable and used once, which is the whole of what
    /// `state` is for, and `SecRandomCopyBytes` for 122 bits Foundation already generates
    /// from the same place is ceremony.
    nonisolated static func newState() -> String { UUID().uuidString }

    /// What came back at the redirect.
    enum Redirect: Equatable, Sendable {
        /// The code to trade for a token, with the state that proves it is ours.
        case code(String)
        /// The user said no on GitHub's page, or GitHub refused for its own reason.
        case denied
        /// Our redirect, with the wrong `state` or none at all: a page trying to hand this
        /// browser somebody else's sign-in. Nothing is traded and nothing is stored.
        case mismatched
        /// Not this handshake at all — another `vane:` url, or another scheme entirely.
        case notOurs
    }

    /// Whether a url is the one this flow answers to. Host and path both, so `vane://other`
    /// is somebody else's business.
    nonisolated static func isRedirect(_ url: URL) -> Bool {
        url.scheme?.lowercased() == ExternalApps.ownScheme
            && url.host?.lowercased() == redirectHost
            && url.path == redirectPath
    }

    /// The redirect, read. `expecting` is the state the sign-in now in flight went out with,
    /// or nil when there is no sign-in in flight — in which case a redirect turning up is
    /// exactly the thing `state` exists to refuse.
    nonisolated static func read(_ url: URL, expecting: String?) -> Redirect {
        guard isRedirect(url) else { return .notOurs }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // The state first, refusal and all. `?error=` needs no code and no secret to write,
        // so honouring one before the state is checked would let any page put "Vane was not
        // allowed to connect to GitHub." in front of the user — and, worse, spend the
        // sign-in the user is in the middle of. A denial is only the user's answer when it
        // comes back carrying the state the sign-in went out with.
        guard let expecting, value("state") == expecting else { return .mismatched }
        if value("error") != nil { return .denied }
        guard let code = value("code") else { return .mismatched }
        return .code(code)
    }

    /// The exchange: code in, token out. A form post, because that is what GitHub's endpoint
    /// takes; `Accept: application/json` is what stops it answering in form encoding.
    nonisolated static func body(code: String, secret: String) -> String {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                        URLQueryItem(name: "client_secret", value: secret),
                        URLQueryItem(name: "code", value: code),
                        URLQueryItem(name: "redirect_uri", value: redirect)]
        return c.percentEncodedQuery ?? ""
    }

    nonisolated static func exchange(code: String, secret: String) -> URLRequest? {
        guard let url = URL(string: tokenURL) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("Vane", forHTTPHeaderField: "User-Agent")
        r.httpBody = Data(body(code: code, secret: secret).utf8)
        r.timeoutInterval = 15
        return r
    }

    private struct Grant: Decodable { let accessToken: String? }

    /// nil for GitHub's `{"error": "bad_verification_code"}`, which comes back 200.
    nonisolated static func token(_ data: Data) -> String? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return (try? d.decode(Grant.self, from: data))?.accessToken.flatMap {
            $0.isEmpty ? nil : $0
        }
    }
}

// MARK: - The live part

/// One per profile: the token, the clock, and what each live folder last came back with.
///
/// Signing in is GitHub's OAuth web flow — Arc asks for no token and neither does this. See
/// `GitHubOAuth` for the handshake and `OAuthSecret` for the one piece of it that only a
/// release build carries. A build without that secret keeps the old path, a personal access
/// token pasted into the sheet, because a source checkout has to be able to sign in too;
/// `route` is the whole of that decision.
///
/// Either way the token ends up in the same place — an Internet password for api.github.com,
/// through `Passwords` — so it is revocable from Settings ▸ Passwords whichever way it
/// arrived, and nothing below this line knows which way that was.
@MainActor final class LiveFolders: ObservableObject {
    /// The keychain "site" the token is filed under.
    ///
    /// ponytail: the token is an Internet password for api.github.com, stored through
    /// `Passwords` — so it is namespaced per profile and per `VANE_DATA_DIR` exactly like a
    /// saved login, is deleted with the profile, and turns up in Settings ▸ Passwords where
    /// the user can revoke it. A second keychain code path for one secret would be a second
    /// place to get `kSecAttrCreator` wrong.
    nonisolated static let host = "api.github.com"

    /// How often a folder refreshes on its own, and the floor under every other trigger.
    /// GitHub's search allowance is 30 requests a minute for a token; five minutes a folder
    /// is nowhere near it, and a minute's floor keeps a bad afternoon from getting there.
    nonisolated static let interval: TimeInterval = 300
    nonisolated static let minimum: TimeInterval = 60

    /// Arc's live folder, which is the only one there is: what it is called and what it
    /// holds. `involved` is the sentence the callout says — "pull requests from you and
    /// your team" is yours and the ones they want you on — and every repository, because
    /// narrowing to one is a thing you discover you want later, in "Edit Live Folder…",
    /// not a question to be asked first.
    nonisolated static let pullRequests = "Pull Requests"
    nonisolated static let defaultQuery = GitHubQuery(filter: .involved, repo: nil)

    private static var byProfile: [UUID: LiveFolders] = [:]

    static func shared(for profileID: UUID) -> LiveFolders {
        if let there = byProfile[profileID] { return there }
        let made = LiveFolders(profileID: profileID)
        byProfile[profileID] = made
        return made
    }

    /// The profile's instance if it has one, and nothing if it has not. For the paths that
    /// only ever tell an existing flow something — closing a tab, say — where `shared` would
    /// make a live folders instance, timer and all, for every profile that never asked.
    static func existing(for profileID: UUID) -> LiveFolders? { byProfile[profileID] }

    /// The profile's last window has gone: the timer and the activation observer go with it,
    /// or they outlive every window and keep asking GitHub about folders nobody can see.
    /// Called from `windowWillClose`.
    /// The same windows `stores()` counts: a private window and a Little Vane draw no live
    /// folder, so one of them left open is not a reason to keep asking GitHub about them.
    static func forget(_ profileID: UUID) {
        guard !TabStore.all.contains(where: {
            $0.profileID == profileID && !$0.isPrivate && !$0.isLittle
        }) else { return }
        byProfile[profileID]?.stop()
        byProfile[profileID] = nil
    }

    let profileID: UUID

    /// Per folder, the glyph each of its rows wears. Keyed by folder, not by url alone: the
    /// same pull request can sit in two live folders, and one global map would let the
    /// folder that refreshed first take the other's goodbye cycle with it.
    ///
    /// Inside a folder, a key is the pull request's url while it is open, and the row's own
    /// url once it has closed; `state(of:in:)` reads either the same way.
    ///
    /// Only the glyphs live here. *Which rows are the folder's* is `Folder.owned`, written
    /// down with the folder, because a wrong answer to that closes a tab — see `GitHub.mine`.
    /// A glyph is only a glyph: the worst a lost one costs is one plain row until the next
    /// refresh. It is dropped when the folder is deleted and not before — a Space the user
    /// has switched away from is not a deleted folder, and treating it as one was how the
    /// goodbye state used to evaporate on the way out of a Space and back.
    @Published private(set) var states: [UUID: [String: GitHub.State]] = [:]
    /// Folders whose last refresh failed. The mark wears `Look.warning` until one succeeds.
    @Published private(set) var failing: Set<UUID> = []

    private var last: [UUID: Date] = [:]
    private var busy: Set<UUID> = []
    /// Whether the profile has already been told the token is missing. One toast, not one
    /// every five minutes.
    private var saidSignedOut = false
    private var timer: Timer?
    private var active: NSObjectProtocol?

    private init(profileID: UUID) { self.profileID = profileID }

    // MARK: Signing in

    /// The token, read from the keychain once and kept for the life of the process.
    ///
    /// Not read per refresh: `Passwords.password` is a `SecItemCopyMatching` for plaintext,
    /// which is the one keychain call that can put a panel up, and doing it on the main
    /// actor every five minutes is a hitch waiting for a slow keychain. `signOut` and a
    /// fresh sign-in are the only things that change it, and both go through here.
    private var cachedToken: String??

    var signIn: (login: String, token: String)? {
        if let cached = cachedToken { return cached.map { (login: cachedLogin ?? "", token: $0) } }
        let hit = Passwords.lookup(host: LiveFolders.host, profileID: profileID)
        cachedToken = hit?.password
        cachedLogin = hit?.account
        return hit.map { (login: $0.account, token: $0.password) }
    }

    private var cachedLogin: String?

    @discardableResult
    func save(login: String, token: String) -> Bool {
        // One token per profile: a second login would mean asking which one every folder
        // meant, and Arc asks once.
        if let old = signIn, old.login != login {
            _ = Passwords.delete(host: LiveFolders.host, account: old.login, profileID: profileID)
        }
        let ok = Passwords.save(host: LiveFolders.host, account: login, password: token,
                                profileID: profileID)
        if ok {
            cachedToken = token
            cachedLogin = login
            saidSignedOut = false
            failing.removeAll()          // a new token is a reason to try every folder again
        }
        return ok
    }

    /// The token goes; the folders stay, holding whatever they last had, until a token is
    /// pasted again. Deleting the folders because a credential was withdrawn would be
    /// deleting the user's tabs.
    func signOut() {
        guard let old = signIn else { return }
        _ = Passwords.delete(host: LiveFolders.host, account: old.login, profileID: profileID)
        cachedToken = .some(nil)
        cachedLogin = nil
    }

    /// Test a pasted token by asking GitHub who it belongs to. The login is the greeting in
    /// the sheet, and a token that cannot answer this is one no folder would ever fill.
    static func identify(token: String) async -> Result<String, GitHub.Trouble> {
        guard let url = URL(string: GitHub.api + "/user") else { return .failure(.offline) }
        let answer = await ask(url, token: token) { GitHub.login($0).map { [$0] } }
        return answer.flatMap { $0.first.map { .success($0) } ?? .failure(.unauthorised) }
    }

    // MARK: The web flow

    /// What "New Live Folder…" does, given what this build and this profile have. Pure, so
    /// the one branch that decides whether the user is ever shown a token field at all can
    /// be proved without a keychain and without a client secret.
    enum Route: Equatable, Sendable {
        /// Signed in already: Arc makes the folder there and then, no sheet.
        case create
        /// A release build with the secret compiled in: send them to GitHub in a tab.
        case connect
        /// A source checkout: the sheet, and the personal access token it has always taken.
        case sheet
    }

    nonisolated static func route(signedIn: Bool, hasSecret: Bool) -> Route {
        if signedIn { return .create }
        return hasSecret ? .connect : .sheet
    }

    /// The sign-in now in flight: the `state` it went out with, whether the folder is to be
    /// made when it comes back, and the tab GitHub's consent page was opened in. One at a
    /// time — a second "New Live Folder…" while the consent page is still up shows the user
    /// that page again rather than starting another sign-in behind it.
    private var pending: (state: String, thenCreate: Bool, tab: Tab.ID)?

    /// The tab the consent page is on.
    private var authTab: Tab.ID? { pending?.tab }

    /// Whether a `vane:` navigation is the one this flow is waiting for. The redirect is
    /// only ever the main frame of the tab the consent page was opened in: an iframe on any
    /// page in the world can set `location = "vane://oauth/github?error=x"`, and one that
    /// did would otherwise cancel a sign-in the user is in the middle of somewhere else.
    /// Everything else is cancelled and dropped — no toast, no closed tab, no `pending`
    /// cleared, and so nothing a page can learn from.
    nonisolated static func accepts(tabID: Tab.ID, pending: Tab.ID?, isMainFrame: Bool) -> Bool {
        isMainFrame && pending != nil && tabID == pending
    }

    /// What "New Live Folder…" does about a sign-in that is already in flight.
    enum Consent: Equatable, Sendable {
        /// Nothing in flight: open GitHub's consent page in a new tab.
        case open
        /// One is up already: show the user the tab it is on, rather than a second consent
        /// page and a second `state` that quietly voids the first.
        case show(Tab.ID)
    }

    nonisolated static func consent(pending: Tab.ID?, open tabs: [Tab.ID]) -> Consent {
        if let pending, tabs.contains(pending) { return .show(pending) }
        return .open
    }

    /// Open GitHub's consent page in a tab of this window. Nothing is stored yet; the tab is
    /// closed and the token saved when `finish` reads the redirect out of it.
    func connect(in store: TabStore, thenCreate: Bool) {
        if case .show(let id) = LiveFolders.consent(pending: authTab,
                                                    open: TabStore.all.flatMap { $0.tabs.map(\.id) }) {
            if let owner = TabStore.all.first(where: { $0.tabs.contains { $0.id == id } }) {
                owner.current = id
                // Selecting it is not enough when the consent page is up in another window:
                // raise that window too, or the user is told nothing happened.
                owner.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        let state = GitHubOAuth.newState()
        guard let url = GitHubOAuth.authorize(state: state) else { return }
        // `newBlankTab` rather than `newTab`, for the tab itself: the redirect is only
        // honoured when it arrives in this one, so the flow has to know which it is.
        let tab = store.newBlankTab()
        tab.go(url)
        pending = (state: state, thenCreate: thenCreate, tab: tab.id)
    }

    /// The consent tab, closed by hand: there is no sign-in in flight any more, so the next
    /// "New Live Folder…" starts a fresh one instead of pointing at a tab that has gone.
    func forget(authTab id: Tab.ID) {
        if pending?.tab == id { pending = nil }
    }

    /// The redirect, caught in `decidePolicyFor` before WebKit or macOS could see it. `tab`
    /// is the tab it arrived in — the one the consent page is on, which goes as soon as the
    /// answer is read, so the sign-in leaves nothing behind either way.
    ///
    /// Called for every `vane:` navigation in every tab, and answers only the one it is
    /// waiting for: the main frame of the tab `connect` opened. See `accepts` — an ad frame
    /// three tabs away redirecting to `vane://oauth/github?error=x` does nothing at all.
    func finish(redirect url: URL, in tab: Tab, isMainFrame: Bool) {
        guard LiveFolders.accepts(tabID: tab.id, pending: authTab,
                                  isMainFrame: isMainFrame) else { return }
        let answer = GitHubOAuth.read(url, expecting: pending?.state)
        guard answer != .notOurs else { return }
        let store = TabStore.all.first { $0.tabs.contains { $0 === tab } }
        let thenCreate = pending?.thenCreate ?? false
        pending = nil
        store?.close(tab.id)
        switch answer {
        case .code(let code):
            Task { await exchange(code, in: store, thenCreate: thenCreate) }
        case .denied:
            say("Vane was not allowed to connect to GitHub.")
        // One toast, and deliberately the same shape as the denial: from here a state that
        // does not match and a sign-in nobody started are the same event.
        case .mismatched:
            say("That GitHub sign-in did not come back the way it left. Nothing was connected.")
        case .notOurs:
            break
        }
    }

    /// Code → token → login → keychain, and then the folder the click asked for.
    private func exchange(_ code: String, in store: TabStore?, thenCreate: Bool) async {
        guard let secret = OAuthSecret.github,
              let request = GitHubOAuth.exchange(code: code, secret: secret) else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // GitHub answers 200 with `{"error": …}` for a code that has been used or has
        // expired, so the body is what says whether this worked, not the status.
        guard let data = try? await session.data(for: request).0,
              let token = GitHubOAuth.token(data) else {
            say("GitHub would not finish the sign-in. Try New Live Folder again.")
            return
        }
        guard case .success(let who) = await LiveFolders.identify(token: token) else {
            say("GitHub signed Vane in, but would not say who to. Nothing was stored.")
            return
        }
        guard save(login: who, token: token) else {
            say("The keychain would not store the GitHub token.")
            return
        }
        if thenCreate, let store {
            store.newPullRequestsFolder()
        } else {
            say("Connected to GitHub as \(who).")
        }
    }

    // MARK: Fetching

    /// One request, one answer: the body decoded by `shape`, or why not. Ephemeral, like
    /// every other request Vane makes on the user's behalf that is not a page load — the
    /// token is the credential, and a cookie jar shared with github.com is not wanted.
    private static func ask<T>(_ url: URL, token: String,
                               shape: @Sendable (Data) -> [T]?) async -> Result<[T], GitHub.Trouble> {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, reply) = try await session.data(for: GitHub.request(url, token: token))
            let status = (reply as? HTTPURLResponse)?.statusCode ?? 0
            if let trouble = GitHub.trouble(status: status) { return .failure(trouble) }
            guard let out = shape(data) else { return .failure(.refused(status)) }
            return .success(out)
        } catch {
            return .failure(.offline)
        }
    }

    static func fetch(_ q: GitHubQuery, token: String) async -> Result<[GitHub.PR], GitHub.Trouble> {
        guard let url = GitHub.search(q) else { return .failure(.offline) }
        return await ask(url, token: token, shape: GitHub.decode)
    }

    // MARK: The clock

    /// Started when a window opens. It ticks whether or not the profile has a live folder —
    /// the tick is a walk over the pinned rows, and arming it only when one exists would
    /// mean disarming it when the last one is deleted, in every window.
    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: LiveFolders.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshAll() }
        }
        // Coming back to the window is the moment a stale folder is most obviously stale.
        active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.refreshAll() }
            }
        refreshAll()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let active { NotificationCenter.default.removeObserver(active) }
        active = nil
    }

    /// A folder was unfolded: Arc refreshes what you are about to look at.
    func expanded(_ folder: UUID) {
        guard let q = live()[folder] else { return }
        refresh(folder, query: q)
    }

    /// "Refresh Now" — the one trigger that ignores the floor, because the user asked.
    func refreshNow(_ folder: UUID) {
        guard let q = live()[folder] else { return }
        refresh(folder, query: q, force: true)
    }

    func refreshAll() {
        for (id, q) in live() { refresh(id, query: q) }
    }

    /// A folder has been deleted, or has stopped being live. Its glyphs go with it — this is
    /// the *only* thing that drops them, because it is the only event that means the folder
    /// is not coming back. `live()` sees only the Spaces the open windows are holding, so a
    /// folder in a Space no window has been in is missing from it, and pruning against that
    /// used to throw away a goodbye every time the user walked out of a Space and back.
    /// Called from `deleteFolder`.
    func forget(folder: UUID) {
        states[folder] = nil
        failing.remove(folder)
        last[folder] = nil
    }

    /// Every live folder this profile's windows are showing, deduplicated: two windows on
    /// the same Space draw the same folder, and it is refreshed once for both.
    ///
    /// ponytail: `pins`, not `everyPins` — a live folder in a Space the window is keeping
    /// alive behind this one stops refreshing until it is swiped back to, and then refreshes
    /// at once because its clock is five minutes stale. Widening this alone would only burn
    /// the rate limit: `apply` adds and removes real rows through `applyLive`, which is the
    /// strip and `savePins`, so the answer for a stashed folder would be fetched and thrown
    /// away. Doing it properly means teaching the apply to edit a `Stash`, which is a good
    /// deal more than a wider query.
    private func live() -> [UUID: GitHubQuery] {
        var out: [UUID: GitHubQuery] = [:]
        for store in stores() {
            for entry in store.pins.entries {
                guard let folder = entry.folder, case .github(let q)? = folder.live else { continue }
                out[folder.id] = q
            }
        }
        return out
    }

    private func stores() -> [TabStore] {
        TabStore.all.filter { $0.profileID == profileID && !$0.isPrivate && !$0.isLittle }
    }

    /// Say it in a window of *this* profile. `Windows.current` is whatever is in front, which
    /// on a second profile's window is the wrong sidebar to slide a toast up in.
    private func say(_ text: String) {
        Toasts.show(text, in: stores().first { $0.window?.isKeyWindow == true } ?? stores().last)
    }

    private func refresh(_ folder: UUID, query: GitHubQuery, force: Bool = false) {
        guard !busy.contains(folder),
              force || GitHub.due(last: last[folder], now: .now, every: LiveFolders.minimum)
        else { return }
        // Signed out: the folders keep their rows, and the reason is said once rather than
        // every five minutes for the rest of the session.
        guard let token = signIn?.token else {
            failing.insert(folder)
            if !saidSignedOut {
                saidSignedOut = true
                say("Vane is signed out of GitHub. Edit Live Folder to sign in again.")
            }
            return
        }
        busy.insert(folder)
        last[folder] = .now
        Task {
            let answer = await LiveFolders.fetch(query, token: token)
            busy.remove(folder)
            switch answer {
            // Never empty a folder on an error. A rate limit, an expired token and a train
            // tunnel all look like "no pull requests" to a reconcile that trusts the reply,
            // and the rows are the user's tabs.
            case .failure(let trouble):
                // The kept token is the one thing here that can go stale behind our back —
                // revoked on GitHub, or deleted from Settings ▸ Passwords. A 401 is how we
                // hear about it, so the next refresh reads the keychain again rather than
                // arguing with GitHub about a token that is gone.
                if trouble == .unauthorised { cachedToken = nil }
                if failing.insert(folder).inserted { say(trouble.says) }
            case .success(let prs):
                failing.remove(folder)
                apply(prs, to: folder)
            }
        }
    }

    private func apply(_ prs: [GitHub.PR], to folder: UUID) {
        let found = prs.map(\.url)
        var mine = Set<String>()
        var hidden: [String] = []
        var goodbyes = Set<String>()
        var showing = false
        for store in stores() where store.pins.folder(folder) != nil {
            showing = true
            let record = store.pins.folder(folder)
            let owned = record?.owned ?? []
            let have = GitHub.mine(store.pins.children(of: folder).compactMap(store.rowURL),
                                   owned: owned)
            // What the user took out stays out. Before the plan, not after: a dismissed pull
            // request is one the search never asked for, so there is nothing to add, nothing
            // to order and nothing to say goodbye to.
            hidden = GitHub.dismissed(previous: record?.dismissed ?? [], owned: owned,
                                      have: have, want: found)
            let want = found.filter { !hidden.contains($0) }
            mine.formUnion(want)
            let closing = Set((states[folder] ?? [:]).filter { $0.value == .closed }.keys)
            var plan = GitHub.plan(have: have, want: want, closing: closing)
            plan.titles = Dictionary(prs.map { ($0.url, $0.title) }, uniquingKeysWith: { a, _ in a })
            // A row still on its way out keeps its own url as its identity for one more
            // refresh, so the folder still owns it and still draws its goodbye. So does one
            // the apply held back because the user was looking at it — otherwise the folder
            // would disown the very row it still means to take, and nothing would ever
            // come for it again.
            for url in plan.closing + store.applyLive(plan, to: folder) {
                goodbyes.insert(url)
                mine.insert(url)
            }
        }
        // Not while the reply was in the air: a folder deleted, or told to stop keeping
        // itself filled, between the request and the answer must not be brought back to life
        // by a map entry — the glyphs would outlive the folder and `forget(folder:)` would
        // already have run.
        guard showing else { return }
        var glyphs: [String: GitHub.State] = [:]
        for pr in prs where !hidden.contains(pr.url) { glyphs[pr.url] = pr.draft ? .draft : .open }
        for url in goodbyes { glyphs[url] = .closed }
        states[folder] = glyphs
        // Written down with the folder, in every window showing it, because it is the one
        // thing a relaunch cannot guess. `applyLive` has already saved the shape around the
        // rows; this saves what the folder now claims as its own.
        //
        // Only when it has actually moved. The ordinary refresh finds exactly what the
        // folder already holds and has nothing to say, and rewriting the Space every five
        // minutes for a set that has not changed is a disk write — and a `Folder` that is
        // suddenly unequal, so every pinned row redraws — for nothing.
        let claimed = mine.sorted()
        for store in stores() {
            guard let had = store.pins.folder(folder),
                  (had.owned ?? []) != claimed || (had.dismissed ?? []) != hidden
            else { continue }
            store.pins.edit(folder: folder) { $0.owned = claimed; $0.dismissed = hidden }
            store.savePins()
        }
    }

    /// The glyph a row in this folder wears, or nil — for a row the folder does not own (a
    /// page dragged in, and every row elsewhere in the sidebar that merely happens to be on
    /// the same page), and for a folder that has never come back from GitHub.
    ///
    /// Takes the folder rather than its id so ownership is answered from the record that
    /// holds it, which is the same one the reconcile reads.
    func state(of row: String, in folder: Folder) -> GitHub.State? {
        guard let glyphs = states[folder.id],
              !GitHub.mine([row], owned: folder.owned ?? []).isEmpty else { return nil }
        if let exact = glyphs[row] { return exact }
        return glyphs.first { GitHub.row(row, isFor: $0.key) }?.value
    }

    /// "Stop Keeping Filled": the folder becomes an ordinary one holding exactly the rows it
    /// has. Nothing is closed — the whole point is to keep the pages.
    ///
    /// In every window showing it, not just the one the menu was opened from. Each window
    /// holds its own copy of the Space's shape and each writes it back, so a second window
    /// left holding the live version would put `live` straight back on the next `savePins`
    /// — and the folder would quietly start filling itself again.
    /// `saying` is false where the caller has its own thing to announce — archiving a live
    /// folder's tabs is one action to the user, not two.
    func stopKeepingFilled(_ folder: UUID, saying: Bool = true) {
        var name: String?
        for store in stores() where store.pins.folder(folder) != nil {
            name = name ?? store.pins.folder(folder)?.name
            store.pins.edit(folder: folder) { $0.live = nil; $0.owned = nil; $0.dismissed = nil }
            store.savePins()
        }
        forget(folder: folder)
        if saying { axAnnounce("Stopped keeping \(name ?? "the folder") filled.") }
    }
}

// MARK: - The store's side

extension TabStore {
    /// The page a pinned row is on, by the row's id. nil for a row whose tab has gone.
    func rowURL(_ id: String) -> String? {
        tabs.first { $0.id.uuidString == id }?.currentURL?.absoluteString
    }

    /// "New Live Folder…", the whole of it. Arc has one kind of live folder and asks nothing
    /// about it: signed in, the folder is there on the click, holding the pull requests you
    /// and your team have between you. Signed out, the click is a sign-in — the consent page
    /// in a tab of this window — and the folder is made when that comes back.
    ///
    /// `sheet` is the way in for a build with no client secret compiled in: there is no
    /// consent page to send anyone to, so the old sheet asks for a personal access token
    /// instead. See `OAuthSecret` and `LiveFolders.route`.
    func askForLiveFolder(orShow sheet: () -> Void) {
        let live = LiveFolders.shared(for: profileID)
        switch LiveFolders.route(signedIn: live.signIn != nil, hasSecret: OAuthSecret.github != nil) {
        case .create:  newPullRequestsFolder()
        case .connect: live.connect(in: self, thenCreate: true)
        case .sheet:   sheet()
        }
    }

    /// The one live folder there is, made: Arc's name, Arc's contents, every repository the
    /// account can see. "Edit Live Folder…" is where any of that is changed afterwards —
    /// which is the point of not asking first.
    @discardableResult
    func newPullRequestsFolder() -> Folder? {
        let made = newLiveFolder(named: LiveFolders.pullRequests,
                                 source: .github(LiveFolders.defaultQuery))
        // The callout is Arc's: a card hanging off the folder that was just made, saying
        // what it is going to do, gone on the next click or after `Look.calloutDuration`.
        // Per window, because the folder was made in this one.
        if let made { announce(folder: made.id) }
        return made
    }

    /// Puts the callout up, and takes it down again on its own. A click anywhere else takes
    /// it too — that is the popover's own behaviour, through the binding in
    /// `LiveFolderCallout` — and this is only the clock under it.
    ///
    /// The folder id is checked again on the way out so a second folder made inside the same
    /// six seconds keeps its own callout rather than losing it to the first one's timer.
    func announce(folder: UUID) {
        announcing = folder
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Look.calloutDuration))
            guard let self, announcing == folder else { return }
            announcing = nil
        }
    }

    /// "New Live Folder…": a folder at the end of the Pinned section with a source attached.
    /// It is not opened for renaming the way `newFolder` is — the folder's name is decided
    /// before it is made, either by Arc's one kind or by the sheet.
    @discardableResult
    func newLiveFolder(named name: String, source: LiveSource) -> Folder? {
        syncShapes()
        let made = Motion.list { () -> Folder? in
            guard let f = pins.newFolder(named: name) else { return nil }
            pins.edit(folder: f.id) { $0.live = source }
            applyOrder(.pinned)
            return pins.folder(f.id)
        }
        savePins()
        if let made {
            axAnnounce("New live folder \(made.name).")
            LiveFolders.shared(for: profileID).refreshNow(made.id)
        }
        return made
    }

    /// "Edit Live Folder…": the name and the query, together, because changing the query
    /// without renaming the folder leaves a folder called "Review Requested" full of the
    /// pull requests you wrote.
    func editLiveFolder(_ id: UUID, named name: String, source: LiveSource) {
        pins.edit(folder: id) {
            // A different search is a different view, and what was hidden from the old one
            // has nothing to say about this one. A rename is not: the folder still shows the
            // same pull requests, minus the ones taken out of it.
            if $0.live != source { $0.dismissed = nil }
            $0.name = name
            $0.live = source
        }
        savePins()
        LiveFolders.shared(for: profileID).refreshNow(id)
    }

    /// "Show Hidden Again": every pull request taken out of this folder by hand comes back on
    /// the refresh this asks for. In every window showing the folder, for the reason
    /// `LiveFolders.stopKeepingFilled` does it in every window — each holds its own copy of
    /// the Space and each writes it back, so one left holding the old list would put it
    /// straight back on its next save.
    func showHiddenAgain(_ id: UUID) {
        for store in TabStore.all where store.profileID == profileID
            && store.pins.folder(id) != nil {
            store.pins.edit(folder: id) { $0.dismissed = nil }
            store.savePins()
        }
        LiveFolders.shared(for: profileID).refreshNow(id)
    }

    /// The refresh, applied: rows leave, rows arrive, and the folder ends up holding exactly
    /// the pull requests the search returned, in its order.
    ///
    /// `plan` only ever names rows the folder owns (see `GitHub.mine`, over the folder's own
    /// `owned`), so everything else in the folder — a page the user dragged in, a pull
    /// request they dragged in, a folder they nested inside it — is untouched by all of this.
    ///
    /// Returns the rows it held back because the user is looking at them, so the folder can
    /// go on owning them and go on drawing their goodbye until it can take them.
    @discardableResult
    func applyLive(_ plan: GitHub.Plan, to folder: UUID) -> [String] {
        guard pins.folder(folder) != nil else { return [] }
        // A pull request renamed on GitHub renames its row, as Arc does — but only a parked
        // one: a loaded page has a title of its own, and the next refresh of that page is
        // GitHub's to retitle. Before the guard below, because a rename changes no rows.
        for id in pins.children(of: folder) {
            guard let url = rowURL(id), let title = plan.titles[url],
                  let tab = tabs.first(where: { $0.id.uuidString == id }),
                  tab.suspended, tab.title != title else { continue }
            tab.title = title
        }
        guard plan.changesRows || liveRows(in: folder, owning: plan) != plan.order else { return [] }
        var byURL: [String: Tab.ID] = [:]
        for id in pins.children(of: folder) {
            guard let url = rowURL(id), byURL[url] == nil,
                  let tab = tabs.first(where: { $0.id.uuidString == id }) else { continue }
            byURL[url] = tab.id
        }
        // The rows the user is looking at are left exactly where they are. Their pull
        // requests have gone, but taking a page out from under someone is not what "the
        // folder refreshed" should mean; the next refresh, once they have moved on, takes
        // them. Every pane of a split counts, not just the active one — the other panes are
        // every bit as much on screen. It is also the only way `current` could come into
        // this at all: nothing below writes it.
        let onScreen = Set([current].compactMap { $0 } + (activeSplit?.tabs ?? []))
        let (remove, held) = GitHub.removing(plan, showing: Set(onScreen.compactMap {
            rowURL($0.uuidString)
        }))
        for url in remove {
            guard let id = byURL[url] else { continue }
            // A pinned tab is never closed — `close` parks it in place. Nobody pinned this
            // one by hand, so it stops being pinned first and then goes for real, which also
            // puts it in Reopen Closed Tab.
            move(id, to: .today)
            close(id)
            byURL[url] = nil
        }
        // Parked, and unfocused, and inside the Pinned run: see `newBlankTab(focus:as:)`.
        for url in plan.add.compactMap(URL.init(string:)) {
            let tab = newBlankTab(focus: false, as: .pinned)
            tab.park(url: url, Parked(title: plan.titles[url.absoluteString] ?? ""))
            byURL[url.absoluteString] = tab.id
        }
        syncShapes()
        Motion.list {
            var previous: String?
            for url in plan.order {
                guard let id = byURL[url]?.uuidString else { continue }
                if let previous {
                    pins.move(id, next: previous, after: true)
                } else if pins.entries.first(where: { $0.id == id })?.parent != folder {
                    // Only the first row ever needs `into:`, and only when it is not already
                    // in the folder: `into:` lands at the end of the folder's whole subtree,
                    // which is past anything the user nested inside it.
                    pins.move(id, into: folder)
                }
                previous = id
            }
            applyOrder(.pinned)
        }
        savePins()
        return held
    }

    /// The folder's owned rows as they stand, for the "nothing to do" test. Takes the plan
    /// rather than asking `LiveFolders` again: the plan already names every row in question.
    private func liveRows(in folder: UUID, owning plan: GitHub.Plan) -> [String] {
        let named = Set(plan.order)
        return pins.children(of: folder).compactMap(rowURL).filter { named.contains($0) }
    }
}

// MARK: - check

extension GitHub {
    /// The whole of the live folder that does not need a network: the query, the decode,
    /// the reconcile, the prefix match and the refresh floor.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // The query.
        assert("the default folder asks for every open pull request you are part of",
               terms(GitHubQuery()) == "is:pr is:open involves:@me")
        assert("each filter is one qualifier",
               GitHubQuery.Filter.allCases.map { terms(GitHubQuery(filter: $0)).split(separator: " ").last! }
                   == ["involves:@me", "review-requested:@me", "assignee:@me", "author:@me", "mentions:@me"])
        assert("a repository narrows it",
               terms(GitHubQuery(repo: "apple/swift")) == "is:pr is:open involves:@me repo:apple/swift")
        assert("the search url escapes the spaces rather than sending them",
               search(GitHubQuery())?.absoluteString
                   == "https://api.github.com/search/issues?q=is:pr%20is:open%20involves:@me&per_page=50")
        assert("…and per_page is the cap, not a guess",
               search(GitHubQuery())?.absoluteString.hasSuffix("per_page=\(perPage)") == true)

        // A repo name goes into that query, so it is checked before it does.
        assert("owner/name is a repository", repository("apple/swift") == "apple/swift")
        assert("…with the spaces around it trimmed", repository("  apple/swift ") == "apple/swift")
        assert("dots, dashes and underscores are all real repository names",
               repository("some-owner/my_repo.js") == "some-owner/my_repo.js")
        assert("one name is not a repository", repository("swift") == nil)
        assert("three are not either", repository("a/b/c") == nil)
        assert("an empty half is not", repository("apple/") == nil && repository("/swift") == nil)
        assert("a smuggled qualifier is refused, not escaped",
               repository("apple/swift is:merged") == nil)
        assert("…and so is one hidden behind a space", repository("a b/c") == nil)
        assert("a folder with a bad repo asks for every repository instead",
               terms(GitHubQuery(repo: "not a repo")) == "is:pr is:open involves:@me")

        // "Active in". A fixed date, because the qualifier is a date and a check against
        // "whenever this ran" would pass however the arithmetic went.
        let noon = Date(timeIntervalSince1970: 1_757_246_400)     // 2025-09-07 12:00 UTC
        assert("any time asks for no date at all",
               terms(GitHubQuery(), now: noon) == "is:pr is:open involves:@me")
        assert("last 7 days is a date a week back",
               terms(GitHubQuery(age: .week), now: noon)
                   == "is:pr is:open involves:@me updated:>=2025-08-31")
        assert("last 30 days is a month back",
               terms(GitHubQuery(age: .month), now: noon)
                   == "is:pr is:open involves:@me updated:>=2025-08-08")
        assert("last 90 days is a quarter back",
               terms(GitHubQuery(age: .quarter), now: noon)
                   == "is:pr is:open involves:@me updated:>=2025-06-09")
        assert("…and it goes after the repository, not instead of it",
               terms(GitHubQuery(repo: "apple/swift", age: .week), now: noon)
                   == "is:pr is:open involves:@me repo:apple/swift updated:>=2025-08-31")
        // The day is counted in UTC: a minute past midnight in Auckland is still yesterday
        // to GitHub, and a folder that quietly held a day more or less depending on where
        // the user is, is a folder nobody could describe.
        assert("the day is GitHub's, not the machine's",
               day(Date(timeIntervalSince1970: 1_757_289_540), minus: 0) == "2025-09-07")
        assert("…and a month boundary is a real calendar's",
               day(Date(timeIntervalSince1970: 1_740_960_000), minus: 30) == "2025-02-01")
        assert("every age says how far back it goes",
               GitHubQuery.Age.allCases.map(\.days) == [7, 30, 90]
                   && GitHubQuery.Age.allCases.allSatisfy { !$0.title.isEmpty })

        // The rows arrive already named.
        var named = GitHub.plan(have: [], want: ["https://github.com/a/b/pull/1"], closing: [])
        named.titles = ["https://github.com/a/b/pull/1": "Fix the thing"]
        assert("a row arrives wearing its pull request's title, not New Tab",
               named.titles[named.add[0]] == "Fix the thing")

        // The reply.
        let body = Data("""
        {"total_count": 2, "items": [
          {"html_url": "https://github.com/apple/swift/pull/1", "title": "One", "draft": false,
           "number": 1, "repository_url": "https://api.github.com/repos/apple/swift"},
          {"html_url": "https://github.com/apple/swift/pull/2", "title": "Two", "draft": true,
           "number": 2, "repository_url": "https://api.github.com/repos/apple/swift"}]}
        """.utf8)
        let prs = decode(body) ?? []
        assert("a search reply decodes to its pull requests", prs.count == 2)
        assert("…with their pages", prs.first?.url == "https://github.com/apple/swift/pull/1")
        assert("…their titles and numbers", prs.first?.title == "One" && prs.last?.number == 2)
        assert("…which of them is a draft", prs.first?.draft == false && prs.last?.draft == true)
        assert("…and the repository they are in", prs.first?.repo == "apple/swift")
        assert("a pull request with no draft flag is not one",
               decode(Data("""
               {"items": [{"html_url": "u", "title": "t", "number": 3}]}
               """.utf8))?.first?.draft == false)
        assert("no pull requests is an answer", decode(Data(#"{"items": []}"#.utf8))?.isEmpty == true)
        assert("…and is not the same as no reply", decode(Data("not json".utf8)) == nil)
        assert("an error body is not a search reply",
               decode(Data(#"{"message": "Bad credentials"}"#.utf8)) == nil)
        assert("GET /user is read for the login",
               login(Data(#"{"login": "octocat", "id": 1}"#.utf8)) == "octocat")
        assert("…and nothing else answers it", login(Data(#"{"id": 1}"#.utf8)) == nil)

        // What a status code means.
        assert("200 is no trouble", trouble(status: 200) == nil)
        assert("401 is the token", trouble(status: 401) == .unauthorised)
        assert("403 and 429 are both the rate limit",
               trouble(status: 403) == .rateLimited && trouble(status: 429) == .rateLimited)
        // Seen against the live API: a repository the token cannot look inside comes back
        // 422 with "the listed users and repositories cannot be searched", not 404.
        assert("422 is a repository this token cannot search", trouble(status: 422) == .badQuery)
        assert("anything else is reported with its number", trouble(status: 500) == .refused(500))
        assert("every trouble says something", [GitHub.Trouble.unauthorised, .rateLimited,
                                                .badQuery, .refused(500),
                                                .offline].allSatisfy { !$0.says.isEmpty })

        // A row is its pull request, and everything under it.
        let pr = "https://github.com/apple/swift/pull/1"
        assert("the pull request's own page is its row", row(pr, isFor: pr))
        assert("so is Files changed", row(pr + "/files", isFor: pr))
        assert("…and a commit inside it", row(pr + "/commits/abc", isFor: pr))
        assert("…and an anchor to a comment", row(pr + "#issuecomment-1", isFor: pr))
        assert("…and a query on it", row(pr + "?w=1", isFor: pr))
        assert("a different pull request is not", !row(pr, isFor: pr + "0"))
        assert("…not even one whose number starts the same",
               !row("https://github.com/apple/swift/pull/10", isFor: pr))

        // The reconcile.
        let a = "https://github.com/o/n/pull/1", b = "https://github.com/o/n/pull/2"
        let c = "https://github.com/o/n/pull/3"
        var p = plan(have: [], want: [a, b], closing: [])
        assert("an empty folder takes every pull request", p.add == [a, b])
        assert("…in the order the search returned them", p.order == [a, b])
        assert("…and closes nothing", p.remove.isEmpty && p.closing.isEmpty)
        p = plan(have: [a, b], want: [a, b], closing: [])
        assert("a folder already holding them all does nothing", !p.changesRows)
        assert("…and keeps its rows", p.order == [a, b])
        p = plan(have: [b, a], want: [a, b], closing: [])
        assert("the search's order is the folder's order", p.order == [a, b])
        assert("…which is not a row change", !p.changesRows)
        p = plan(have: [a], want: [a, b, c], closing: [])
        assert("a new pull request is added where the search put it",
               p.add == [b, c] && p.order == [a, b, c])
        p = plan(have: [a, b], want: [a], closing: [])
        assert("a pull request that has gone does not take its row with it at once",
               p.remove.isEmpty && p.closing == [b])
        assert("…the row says goodbye at the bottom of the folder", p.order == [a, b])
        p = plan(have: [a, b], want: [a], closing: [b])
        assert("…and goes on the next refresh", p.remove == [b] && p.order == [a])
        p = plan(have: [a, pr + "/files"], want: [a], closing: [])
        assert("a row you navigated inside is still its pull request's row",
               p.closing == [pr + "/files"])
        p = plan(have: [a + "/files"], want: [a], closing: [])
        assert("…and is not added a second time", p.add.isEmpty && p.order == [a + "/files"])
        p = plan(have: [a + "/files"], want: [], closing: [a])
        assert("a goodbye is recognised through the sub-page too", p.remove == [a + "/files"])
        p = plan(have: [], want: [a, a, b], closing: [])
        assert("the same pull request twice is one row", p.add == [a, b])
        p = plan(have: [a], want: [], closing: [])
        assert("an empty search empties the folder, one goodbye at a time",
               p.closing == [a] && p.order == [a])

        // A live folder is still a folder. Which rows are its own is written down, and the
        // reconcile only ever names those: a page the user dragged into one is not in `have`
        // and so cannot come out of `plan` — not to be closed, not to be reordered.
        let note = "https://notion.so/plan"
        let inFolder = [a, note, b, c]
        var have = mine(inFolder, owned: [a, b])
        assert("a page dragged into a live folder is not one of its rows", have == [a, b])
        assert("…nor is a pull request the user put there by hand",
               !have.contains(c))
        assert("a folder that has never refreshed owns nothing, and so takes nothing",
               mine(inFolder, owned: []).isEmpty)
        assert("a row navigated somewhere else stops being the folder's",
               mine([note], owned: [a]).isEmpty)
        assert("…while a row navigated inside its own pull request stays it",
               mine([a + "/files"], owned: [a]) == [a + "/files"])
        assert("a second copy of the same row is left alone",
               mine([a, a, b], owned: [a, b]) == [a, b])
        p = plan(have: have, want: [a, b], closing: [])
        assert("…so a refresh that changes nothing changes nothing", !p.changesRows)
        p = plan(have: have, want: [], closing: [a, b])
        assert("…and even a refresh that empties the folder never names them",
               p.remove == [a, b] && !p.remove.contains(note) && !p.order.contains(note)
                   && !p.remove.contains(c) && !p.order.contains(c))

        // Taking a row out. The whole of the bug this exists for: unpin, drag out or archive
        // a pull request's row and the next refresh finds the pull request still open, sees
        // no row for it, and puts it straight back.
        assert("a row the folder put here and that is gone is one the user took out",
               dismissed(previous: [], owned: [a, b], have: [a], want: [a, b]) == [b])
        // The folder stops owning what it stops showing, so the second refresh has only the
        // written-down list to go on — which is the whole reason it is written down.
        assert("…and stays hidden while the pull request is still open, owned or not",
               dismissed(previous: [b], owned: [a], have: [a], want: [a, b]) == [b])
        assert("a folder holding everything it is owed hides nothing",
               dismissed(previous: [], owned: [a, b], have: [a, b], want: [a, b]).isEmpty)
        assert("a row navigated inside its own pull request is still here",
               dismissed(previous: [], owned: [a], have: [a + "/files"], want: [a]).isEmpty)
        // A pull request the user dragged in by hand: the folder does not own its row, so
        // dragging it out again is nothing to do with the folder and hides nothing. The
        // folder is left owing it a row, and puts one there on the next refresh.
        assert("a pull request the folder never owned is not one the user took out",
               dismissed(previous: [], owned: [a], have: mine([a], owned: [a]),
                         want: [a, c]).isEmpty)
        assert("a pull request that has closed is forgotten, not hidden forever",
               dismissed(previous: [b], owned: [a], have: [a], want: [a]).isEmpty)
        assert("…so reopening it makes it news again",
               dismissed(previous: [], owned: [a], have: [a], want: [a, b]).isEmpty)
        assert("a row on its way out is not a row taken out",
               dismissed(previous: [], owned: [a, b], have: [a, b], want: [a]).isEmpty)
        assert("…nor is one held back because the user is looking at it",
               dismissed(previous: [], owned: [a, b], have: [a, b], want: []).isEmpty)
        assert("nothing is hidden twice, however many refreshes see it gone",
               dismissed(previous: [b], owned: [a, b], have: [a], want: [a, b]) == [b])
        assert("what was hidden stays at the front, and the new ones follow in search order",
               dismissed(previous: [c], owned: [a, b, c], have: [], want: [a, b, c])
                   == [c, a, b])
        // What the folder then asks for. The plan never hears about a hidden pull request,
        // so there is nothing to add, nothing to order and nothing to close.
        let hidden = dismissed(previous: [], owned: [a, b], have: [a], want: [a, b])
        p = plan(have: [a], want: [a, b].filter { !hidden.contains($0) }, closing: [])
        assert("the plan is given the search minus what was taken out",
               p.add.isEmpty && p.order == [a] && !p.changesRows)
        // The ceiling, decided out loud: `have` is built from the page each row is *on*, so a
        // row browsed off github is missing from it exactly the way a row dragged out is, and
        // the pull request is hidden rather than added to the folder a second time. See
        // `dismissed`. The tab stays where the user left it either way.
        let strayed = mine([note], owned: [a])
        assert("a live row browsed somewhere else entirely is no longer one of the folder's",
               strayed.isEmpty)
        assert("…so its pull request is hidden, not put back as a second row",
               dismissed(previous: [], owned: [a], have: strayed, want: [a]) == [a])

        // The relaunch. Ownership rides with the folder, so what a window comes back to is
        // what it wrote down — and a pull request page put in the folder by hand is still
        // not the folder's, however much it looks like one of its rows.
        var live = Folder(name: "Review Requested", live: .github(GitHubQuery()), owned: [a, b])
        let shape = Pins(entries: [.init(row: .folder(live), parent: nil)]
                         + inFolder.map { Pins.Entry(row: .tab($0), parent: live.id) })
        let back = try? JSONDecoder().decode(Pins.self, from: JSONEncoder().encode(shape))
        live = back?.folder(live.id) ?? Folder(name: "lost")
        assert("a live folder comes back knowing which rows are its own", live.owned == [a, b])
        have = mine(back?.children(of: live.id) ?? [], owned: live.owned ?? [])
        assert("…so a hand-added pull request row survives the relaunch", have == [a, b])
        p = plan(have: have, want: [], closing: [a, b])
        assert("…and the first refresh after it still cannot touch that row",
               p.remove == [a, b] && !p.order.contains(c))
        let old = try? JSONDecoder().decode(Folder.self, from: Data("""
        {"id": "\(UUID().uuidString)", "name": "Work", "icon": "folder", "collapsed": false}
        """.utf8))
        assert("a folder saved before any of this owns nothing", old?.owned?.isEmpty ?? true)
        assert("…and has hidden nothing either", old?.dismissed?.isEmpty ?? true)
        assert("a folder saved before the hidden list still reads",
               (try? JSONDecoder().decode(Folder.self, from: Data("""
               {"id": "\(UUID().uuidString)", "name": "Work", "icon": "folder",
                "collapsed": false, "owned": ["\(a)"]}
               """.utf8)))?.owned == [a])
        // The same reason `owned` is an Optional, one field along: a query saved before
        // "Active in" existed has no `age` key, and a non-optional would take the folder,
        // the Space and the whole Pinned section down with it.
        assert("a query saved before Active in existed means any time",
               (try? JSONDecoder().decode(GitHubQuery.self,
                                          from: Data(#"{"filter": "assigned"}"#.utf8)))?.age == nil)
        assert("…and still knows what it tracks",
               (try? JSONDecoder().decode(GitHubQuery.self,
                                          from: Data(#"{"filter": "assigned"}"#.utf8)))?.filter
                   == .assigned)
        assert("an age survives the trip to disk",
               (try? JSONDecoder().decode(GitHubQuery.self, from: JSONEncoder()
                   .encode(GitHubQuery(age: .quarter))))?.age == .quarter)
        assert("and so does the hidden list",
               (try? JSONDecoder().decode(Folder.self, from: JSONEncoder()
                   .encode(Folder(name: "Live", dismissed: [a]))))?.dismissed == [a])

        // The page you are reading. A refresh has exactly one reason to want at `current`
        // — closing the tab that is on it — and this is where that reason goes away.
        p = plan(have: [a, b], want: [], closing: [a, b])
        var showing = removing(p, showing: [a])
        assert("the row the user is looking at is not the one that goes", showing.remove == [b])
        assert("…it is held instead, so the folder still owns it and still says goodbye",
               showing.held == [a])
        showing = removing(p, showing: [a, b])
        assert("…and a whole folder on screen loses no rows at all",
               showing.remove.isEmpty && showing.held == [a, b])
        showing = removing(p, showing: [])
        assert("…while nothing on screen holds nothing back",
               showing.remove == [a, b] && showing.held.isEmpty)
        showing = removing(plan(have: [a], want: [a], closing: []), showing: [a])
        assert("…and a refresh that removes nothing has nothing to hold",
               showing.remove.isEmpty && showing.held.isEmpty)

        // The floor.
        let now = Date()
        assert("a folder that has never refreshed is due",
               due(last: nil, now: now, every: LiveFolders.minimum))
        assert("one refreshed a moment ago is not",
               !due(last: now.addingTimeInterval(-5), now: now, every: LiveFolders.minimum))
        assert("one refreshed longer ago than the floor is",
               due(last: now.addingTimeInterval(-LiveFolders.minimum - 1), now: now,
                   every: LiveFolders.minimum))
        assert("the floor is under the timer, not over it", LiveFolders.minimum < LiveFolders.interval)

        // The folder itself: a source survives the trip to disk, and a folder from before
        // live folders existed still reads.
        var pins = Pins()
        let folder = pins.newFolder(named: "Review Requested")!
        pins.edit(folder: folder.id) { $0.live = .github(GitHubQuery(filter: .assigned,
                                                                     repo: "apple/swift")) }
        if let data = try? JSONEncoder().encode(pins),
           let back = try? JSONDecoder().decode(Pins.self, from: data) {
            assert("a live folder survives a codable round-trip", back == pins)
            assert("…carrying what it tracks",
                   back.folder(folder.id)?.live == .github(GitHubQuery(filter: .assigned,
                                                                       repo: "apple/swift")))
        } else {
            assert("a live folder survives a codable round-trip", false)
        }
        assert("a folder saved before live folders existed is an ordinary one",
               (try? JSONDecoder().decode(Folder.self, from: Data("""
               {"id": "\(UUID().uuidString)", "name": "Work", "icon": "folder", "collapsed": false}
               """.utf8)))?.live == nil)
        assert("an ordinary folder is not live", Folder(name: "Work").live == nil)
        // The strip stays sectioned when a folder fills itself: a pinned row inserted past
        // the Today run is what breaks ⌘1…9, ⌃⇥ and the next drag's clamp.
        assert("a new pinned row lands in the Pinned run, not on the end of the strip",
               TabStore.clampedDestination(others: [.favourite, .pinned, .today, .today],
                                           moving: .pinned, to: 4) == 2)
        assert("…even when the strip is all Today tabs",
               TabStore.clampedDestination(others: [.today, .today], moving: .pinned, to: 2) == 0)
        assert("…and a folder filling an empty window still puts it first",
               TabStore.clampedDestination(others: [], moving: .pinned, to: 0) == 0)

        assert("a live folder is named after what it tracks",
               LiveSource.github(GitHubQuery(filter: .mentioned)).title == "Mentioning Me")

        // MARK: Signing in

        // What the click does. The one branch that decides whether a user is ever shown a
        // token field at all, and the reason a release build never is.
        assert("signed in, New Live Folder makes the folder and asks nothing",
               LiveFolders.route(signedIn: true, hasSecret: true) == .create)
        assert("…however the token got there",
               LiveFolders.route(signedIn: true, hasSecret: false) == .create)
        assert("signed out, a build with the secret sends you to GitHub",
               LiveFolders.route(signedIn: false, hasSecret: true) == .connect)
        assert("…and one without it falls back to the sheet",
               LiveFolders.route(signedIn: false, hasSecret: false) == .sheet)
        // The four rows above are the whole table, so they already say what has to hold for
        // *both* builds: no build sends anyone to a consent page it could not finish, and
        // none asks a signed-in user for a token it already has. Deliberately not compared
        // against `OAuthSecret.github`: these same checks run against the packaged app in
        // the release workflow, after the client secret has been substituted in, so
        // anything that restates the build's own answer back to it proves nothing.

        // The folder that click makes.
        assert("Arc's one live folder is called Pull Requests",
               LiveFolders.pullRequests == "Pull Requests")
        assert("…and holds every pull request you are part of, everywhere",
               LiveFolders.defaultQuery.filter == .involved
                   && LiveFolders.defaultQuery.repo == nil)
        assert("…which is one search, no repository qualifier",
               terms(LiveFolders.defaultQuery) == "is:pr is:open involves:@me")
        assert("…and your own pull requests are in it, which review requests alone never were",
               GitHubQuery.Filter.involved.qualifier == "involves:@me"
                   && GitHubQuery.Filter.reviewRequested.qualifier == "review-requested:@me")

        // The consent page.
        let state = GitHubOAuth.newState()
        let authorize = GitHubOAuth.authorize(state: state)
        let sentItems = URLComponents(url: authorize ?? URL(fileURLWithPath: "/"),
                                      resolvingAgainstBaseURL: false)?.queryItems ?? []
        func asked(_ name: String) -> String? { sentItems.first { $0.name == name }?.value }
        assert("the sign-in goes to GitHub's authorize page",
               authorize?.absoluteString.hasPrefix("https://github.com/login/oauth/authorize?")
                   == true)
        assert("…as this app", asked("client_id") == "Ov23liQ1Plm1UJ9nIlWd")
        assert("…asking for the scope a private pull request needs", asked("scope") == "repo")
        assert("…carrying the state the reply has to come back with", asked("state") == state)
        assert("…and the redirect only this browser can answer",
               asked("redirect_uri") == "vane://oauth/github")
        assert("the state is unguessable and used once",
               GitHubOAuth.newState() != GitHubOAuth.newState() && state.count > 16)

        // The reply, which arrives as a navigation and is read before anything else can see
        // it. Every one of these is a url a page could put in front of the browser.
        func reply(_ raw: String) -> GitHubOAuth.Redirect {
            GitHubOAuth.read(URL(string: raw)!, expecting: state)
        }
        assert("a code with the right state is the sign-in",
               reply("vane://oauth/github?code=abc123&state=\(state)") == .code("abc123"))
        assert("…whichever order the parameters arrive in",
               reply("vane://oauth/github?state=\(state)&code=abc123") == .code("abc123"))
        assert("a code with somebody else's state is refused",
               reply("vane://oauth/github?code=abc123&state=nope") == .mismatched)
        assert("…and so is one with no state at all",
               reply("vane://oauth/github?code=abc123") == .mismatched)
        assert("…and a state with no code is nothing to trade",
               reply("vane://oauth/github?state=\(state)") == .mismatched)
        assert("a redirect arriving with no sign-in in flight is refused",
               GitHubOAuth.read(URL(string: "vane://oauth/github?code=a&state=b")!,
                                expecting: nil) == .mismatched)
        assert("saying no on GitHub's page is a denial, not a failure",
               reply("vane://oauth/github?error=access_denied&state=\(state)") == .denied)
        // `?error=` takes no code and no client secret to write, so it is the cheapest thing
        // for a page to aim at this redirect. Read after the state, or a page could spend a
        // sign-in the user is in the middle of and put GitHub's name on the toast.
        assert("…but a refusal is only the user's answer when it carries the state",
               reply("vane://oauth/github?error=access_denied") == .mismatched)
        assert("…and one with somebody else's state is refused like any other",
               reply("vane://oauth/github?error=access_denied&state=nope") == .mismatched)
        assert("another vane: url is not this handshake",
               reply("vane://something/else?code=abc123&state=\(state)") == .notOurs)
        assert("…nor is one on the right host but the wrong path",
               reply("vane://oauth/gitlab?code=abc123&state=\(state)") == .notOurs)
        assert("…nor is a page pretending to be the redirect over https",
               reply("https://oauth/github?code=abc123&state=\(state)") == .notOurs)
        assert("the redirect is recognised by host and path together",
               GitHubOAuth.isRedirect(URL(string: "vane://oauth/github")!)
                   && !GitHubOAuth.isRedirect(URL(string: "vane://oauth")!))

        // Where the reply is allowed to arrive. `decidePolicyFor` sees every `vane:`
        // navigation in every tab and every frame of every page the user has open; only one
        // of them is this sign-in coming back, and the rest are answered with nothing — no
        // toast, no closed tab, no sign-in cancelled.
        let consentTab = UUID(), otherTab = UUID()
        assert("the redirect counts in the consent page's own tab",
               LiveFolders.accepts(tabID: consentTab, pending: consentTab, isMainFrame: true))
        assert("…and nowhere else: an unrelated tab redirecting to vane: is ignored",
               !LiveFolders.accepts(tabID: otherTab, pending: consentTab, isMainFrame: true))
        assert("…nor may an iframe on the consent page speak for it",
               !LiveFolders.accepts(tabID: consentTab, pending: consentTab, isMainFrame: false))
        assert("…and with no sign-in in flight nothing is the redirect",
               !LiveFolders.accepts(tabID: consentTab, pending: nil, isMainFrame: true))

        // A second "New Live Folder…" while the consent page is still up. Another tab would
        // mean another `state`, which voids the page the user is already looking at.
        assert("with nothing in flight, the click opens the consent page",
               LiveFolders.consent(pending: nil, open: [otherTab]) == .open)
        assert("…with one up, it shows the tab that is already there",
               LiveFolders.consent(pending: consentTab, open: [otherTab, consentTab])
                   == .show(consentTab))
        assert("…and once that tab has been closed, it starts a fresh sign-in",
               LiveFolders.consent(pending: consentTab, open: [otherTab]) == .open)

        // The exchange. A fake secret: the real one is never in this repository and is not
        // in this process either, on any build a developer runs.
        let post = GitHubOAuth.exchange(code: "abc123", secret: "s3cr3t")
        let sent = post.flatMap { $0.httpBody }.flatMap { String(data: $0, encoding: .utf8) }
        assert("the code is traded at GitHub's token endpoint",
               post?.url?.absoluteString == "https://github.com/login/oauth/access_token")
        assert("…with a POST", post?.httpMethod == "POST")
        assert("…asking for json rather than form encoding",
               post?.value(forHTTPHeaderField: "Accept") == "application/json")
        assert("…as a form body, which is what that endpoint takes",
               post?.value(forHTTPHeaderField: "Content-Type")
                   == "application/x-www-form-urlencoded")
        assert("…carrying the four things GitHub asks for, in order",
               sent == "client_id=Ov23liQ1Plm1UJ9nIlWd&client_secret=s3cr3t&code=abc123"
                   + "&redirect_uri=vane://oauth/github")
        assert("a token comes back out of the answer",
               GitHubOAuth.token(Data(#"{"access_token": "gho_x", "scope": "repo"}"#.utf8))
                   == "gho_x")
        // GitHub answers 200 for a code that has already been used, so the body is the only
        // thing that says whether this worked.
        assert("…and a refusal is not a token, however healthy the status code",
               GitHubOAuth.token(Data(#"{"error": "bad_verification_code"}"#.utf8)) == nil)
        assert("…nor is an empty one",
               GitHubOAuth.token(Data(#"{"access_token": ""}"#.utf8)) == nil)

        // The scheme itself. It must reach neither WebKit nor macOS: `decidePolicyFor`
        // cancels every `vane:` navigation, nothing is ever handed to LaunchServices for
        // one, and a `vane:` url arriving from another app through GetURL is refused.
        assert("vane: is Vane's own, not another app's",
               !ExternalApps.isExternal("vane") && ExternalApps.isOwn("VANE"))
        assert("…so nothing offers to open it in an app",
               ExternalApps.decision(remembered: false, host: "evil.example", scheme: "vane")
                   == .refuse)
        assert("…and it is not a scheme WebKit is asked to load either",
               !ExternalApps.webSchemes.contains(ExternalApps.ownScheme))

        return out
    }
}
