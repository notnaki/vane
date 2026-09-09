import AppKit
import SwiftUI

/// Links that leave the browser: `zoommtg:`, `msteams:`, `slack:`, `mailto:`, `tel:`, an
/// App Store `itms-apps:` — a scheme WebKit has no loader for and macOS does.
///
/// Before this they were dropped on the floor. WebKit asked `decidePolicyFor`, Vane said
/// `.allow`, WebKit failed the navigation with "unsupported URL", and `ErrorPage` — which
/// quite rightly does not draw a page for a navigation that was never going to happen —
/// showed nothing. So the "Join Zoom Meeting" button did nothing at all, twice, and then
/// the user went and found the meeting in another browser.
///
/// Arc asks. So does this: the navigation is cancelled, and a card names the app macOS
/// would hand the link to, the site that asked, and three answers — Cancel, Allow once, or
/// Always Allow, which is remembered for that (site, scheme) pair and never asked again.
///
/// ponytail: a UserDefaults bool per (host, scheme), exactly like `SitePermissions` — no
/// expiry, no per-tab "allow for this visit", no allow-list shipped with the app. The two
/// places it can be taken back are the Site Control Center's rows for that site and Clear
/// Browsing Data's "cookies and site data", which is where a user goes looking for
/// "what has this site been allowed to do".
@MainActor enum ExternalApps {

    // MARK: - What counts as leaving

    /// The schemes WebKit loads itself. Everything else with a scheme at all belongs to
    /// some other app — which is the point: a browser cannot keep a list of the world's
    /// url schemes, and does not need one. `about:` and `data:` are in here because
    /// `about:blank` is how every popup starts and a `data:` url is a page, not an app;
    /// prompting for either would put a card up on ordinary browsing.
    ///
    /// `mailto:` and `tel:` are deliberately *not* here. They are exactly as much "leaving
    /// for another app" as `zoommtg:` is — Mail and FaceTime open, the page goes away — and
    /// Arc prompts for them too.
    /// `webkit-extension:` and `safari-web-extension:` are in here for the same reason
    /// `about:` is: they are WebKit's own, not another app's. An installed extension's
    /// pages, its redirects and the links out of its popup all carry one, and cancelling
    /// those put "No app can open webkit-extension links" over the page an extension was
    /// trying to show.
    nonisolated static let webSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "javascript", "ws", "wss",
        "webkit-extension", "safari-web-extension",
    ]

    /// Vane's own. A `vane:` url is never another app's and never WebKit's: the only one
    /// that exists is the GitHub sign-in's redirect, which `decidePolicyFor` cancels and
    /// hands to `LiveFolders` before either of them is asked — see `GitHubOAuth.redirect`.
    ///
    /// Deliberately *not* in `webSchemes`, which is the list of schemes WebKit has a loader
    /// for: allowing one would fail the navigation with "unsupported URL" and render
    /// nothing. And deliberately not declared in the bundle's Info.plist either, so it stays
    /// a url this browser recognises inside its own page rather than a system-wide handler
    /// any process could aim a url at. `URLHandling.normalize` refuses it for that reason.
    nonisolated static let ownScheme = "vane"

    /// Whether a url is one Vane answers itself. `decidePolicyFor` cancels every one of
    /// these, ours or not: a page that redirects to `vane://anything` gets nothing at all.
    nonisolated static func isOwn(_ scheme: String?) -> Bool {
        scheme?.lowercased() == ownScheme
    }

    /// Whether a url is one for another app. A url with no scheme is not: WebKit resolves
    /// it against the page and it never reaches here as a bare string anyway. Neither is one
    /// of ours — nothing is handed to macOS for a scheme this app answers itself.
    nonisolated static func isExternal(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !isOwn(scheme) && !webSchemes.contains(scheme)
    }

    /// What to do about one. Pure, so the table is proved without a window server, a
    /// LaunchServices lookup or a page.
    enum Decision: Equatable, Sendable {
        /// Put the card up.
        case ask
        /// This site said "always" for this scheme: hand it over without asking.
        case open
        /// Nothing to hand over — WebKit's own scheme, or no scheme at all. Not a card, and
        /// not an `NSWorkspace.open` either: `javascript:` and `data:` handed to the system
        /// are exactly the two things a browser must never pass on.
        case refuse
    }

    /// The whole decision. `remembered` is the stored answer for the pair, which the caller
    /// has already looked up — so this function reads no defaults and can be checked.
    ///
    /// A page with no host (a `file://` page, an opaque origin) can still ask, because the
    /// link is still real; it simply cannot be *remembered*, since there is nothing to
    /// remember it against. That is why the emptiness is tested here rather than left to
    /// the key, which would otherwise happily store an answer under "".
    nonisolated static func decision(remembered: Bool, host: String, scheme: String) -> Decision {
        guard isExternal(scheme) else { return .refuse }
        return remembered && !host.isEmpty ? .open : .ask
    }

    // MARK: - What is remembered

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    private static var defaults: UserDefaults = .vane

    nonisolated private static let prefix = "externalApp."

    /// `externalApp.<host>`, holding the schemes that site may open, sorted.
    ///
    /// One key per *site* rather than one per (site, scheme) pair, which is what
    /// `SitePermissions` does. The Site Control Center asks "what may this site open?" on
    /// every render, and against a key per pair the only way to answer was to walk
    /// `dictionaryRepresentation()` — every preference in the app's domain *and* all of
    /// NSGlobalDomain — parsing each key. Per site it is one `stringArray(forKey:)`, and a
    /// pair key would also have needed a separator that is legal in neither half (a url
    /// scheme may itself contain dots: `com.example.app:` is a legal scheme).
    nonisolated static func key(host: String) -> String { prefix + host.lowercased() }

    /// Which site a key names, or nil when the key is not one of ours. Pure, so the sweep
    /// in `forgetAll` cannot reach a preference belonging to something else.
    nonisolated static func parse(key: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let host = String(key.dropFirst(prefix.count))
        return host.isEmpty ? nil : host
    }

    static func remembered(host: String, scheme: String) -> Bool {
        schemes(host: host).contains(scheme.lowercased())
    }

    /// "Always Allow". Never for a site with no host: the answer would be filed under "" and
    /// would then answer for every hostless page in the browser.
    static func allow(host: String, scheme: String) {
        guard !host.isEmpty, !scheme.isEmpty else { return }
        let scheme = scheme.lowercased()
        var all = schemes(host: host)
        guard !all.contains(scheme) else { return }
        all.append(scheme)
        defaults.set(all.sorted(), forKey: key(host: host))
    }

    /// One row of the Site Control Center, switched off. The site's key goes with its last
    /// scheme rather than being left behind as an empty array nothing would ever read.
    static func forget(host: String, scheme: String) {
        let scheme = scheme.lowercased()
        let left = schemes(host: host).filter { $0 != scheme }
        if left.isEmpty { defaults.removeObject(forKey: key(host: host)) }
        else { defaults.set(left, forKey: key(host: host)) }
    }

    /// Every scheme this site may open without being asked, in the order they were stored —
    /// sorted, so the panel's rows do not shuffle between renders. Exact host, never a
    /// suffix test: an answer given to `example.com` is not one `evil-example.com` gets.
    static func schemes(host: String) -> [String] {
        guard !host.isEmpty else { return [] }
        return defaults.stringArray(forKey: key(host: host)) ?? []
    }

    /// Clear Site Data for one site.
    static func reset(host: String) {
        guard !host.isEmpty else { return }
        defaults.removeObject(forKey: key(host: host))
    }

    /// Clear Browsing Data's "cookies and site data". An app a site was allowed to open is
    /// something that site was allowed to do, and a sweep that leaves it standing has not
    /// cleared the site.
    static func forgetAll() {
        for key in defaults.dictionaryRepresentation().keys where parse(key: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - The card

    /// One question on screen. `Equatable` and `Identifiable` so it can drive a sheet.
    struct Prompt: Identifiable, Equatable, Sendable {
        let url: URL
        /// The site that asked. Empty for a page with no host, which can be told apart in
        /// the card's wording and is never remembered.
        let host: String
        let scheme: String
        /// Where the handler lives, so the card can draw its icon. Nil when nothing on this
        /// Mac claims the scheme, which is a different card with one button.
        let app: URL?
        /// Its display name — "Zoom", not "zoom.us.app".
        let name: String?
        /// The pair, which is also what keeps two cards for the same question off the
        /// screen. Not a defaults key — the store is keyed by site — just an id for the one
        /// question this card is asking.
        var id: String { host + "|" + scheme }
    }

    /// What the buttons say, in the order they are read.
    enum Answer: Equatable, Sendable { case cancel, once, always }

    /// An app name worth printing, or nil. One place, so the heading and the line under it
    /// cannot disagree about whether there is an app.
    nonisolated static func named(_ app: String?) -> String? {
        let name = (app ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The card's heading. A missing app is not a failure to report as an error — the link
    /// is fine, this Mac simply has nothing installed that answers to it — so it is the
    /// same card saying so, with nothing to allow. Pure.
    nonisolated static func title(app: String?, scheme: String) -> String {
        guard let name = named(app) else { return "No app can open \(scheme.lowercased()) links" }
        return "Open \u{201C}\(name)\u{201D}?"
    }

    /// The line under it: who is asking. With no app to open there is nothing to want, so
    /// the sentence says what happened instead of promising something that cannot follow.
    /// Pure.
    nonisolated static func body(host: String, app: String?) -> String {
        let who = host.isEmpty ? "This page" : "\u{201C}\(host)\u{201D}"
        return named(app) == nil
            ? "\(who) linked to an app that isn\u{2019}t installed."
            : "\(who) wants to open this application."
    }

    /// The app macOS would hand this url to. Nil when nothing claims the scheme.
    static func handler(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// What to call it. The bundle's display name first, because that is the name on the
    /// Dock icon; `displayName(atPath:)` second, which is what Finder shows and already
    /// drops the `.app` when the user has extensions hidden — so the suffix is trimmed by
    /// hand for the users who do not.
    static func name(of app: URL?) -> String? {
        guard let app else { return nil }
        if let info = Bundle(url: app)?.infoDictionary,
           let display = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
           !display.isEmpty {
            return display
        }
        let shown = FileManager.default.displayName(atPath: app.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    /// Which (host, scheme) pairs already have a card up. A page that redirects to its own
    /// app link on a timer, or a frame that retries, is one navigation after another and
    /// must be one card: without this a `location =` loop stacked a sheet per turn of the
    /// run loop and the window could not be reached at all.
    ///
    /// ponytail: keyed by the pair alone, so it is app-wide rather than per window. The
    /// same site open in two windows, both firing the same app link at once, puts one card
    /// up and the second window's navigation is dropped. Deliberate — the answer is
    /// remembered per site anyway, so the second window would only be asking a question
    /// that is already on screen — and the ceiling is that the second window's click needs
    /// a second try. Upgrade path if anyone ever hits it: key the set by (window, pair).
    private static var asking: Set<String> = []

    /// The whole of it, from `decidePolicyFor`. `page` is the url of the page the link is
    /// on — the site the card names — and is deliberately not the link's own host: a
    /// `zoommtg:` url's "host" is part of the meeting address, not a site that can be
    /// granted anything.
    static func offer(_ url: URL, from page: URL?, tab: Tab) {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = page?.host()?.lowercased() ?? ""
        switch decision(remembered: remembered(host: host, scheme: scheme),
                        host: host, scheme: scheme) {
        case .refuse:
            return
        case .open:
            NSWorkspace.shared.open(url)
        case .ask:
            ask(url, host: host, scheme: scheme, tab: tab)
        }
    }

    private static func ask(_ url: URL, host: String, scheme: String, tab: Tab) {
        // The window the tab is in — a browser window, a Little Vane or a Peek all hold
        // their tabs the same way, which is what gives all three the same card.
        guard let store = TabStore.all.first(where: { s in s.tabs.contains { $0 === tab } }),
              store.externalApp == nil else { return }
        let app = handler(for: url)
        let prompt = Prompt(url: url, host: host, scheme: scheme, app: app, name: name(of: app))
        guard asking.insert(prompt.id).inserted else { return }
        store.externalApp = prompt
    }

    /// A button on the card. Takes the card down first, so "Always Allow" cannot leave a
    /// second copy of the question behind it if the page fires again while the app launches.
    static func answer(_ prompt: Prompt, _ answer: Answer, in store: TabStore) {
        release(prompt)
        store.externalApp = nil
        switch answer {
        case .cancel:
            axAnnounce("Didn’t open the link.")
        case .always:
            allow(host: prompt.host, scheme: prompt.scheme)
            SiteChanges.shared.bump()          // the site panel grew a row
            open(prompt)
        case .once:
            open(prompt)
        }
    }

    private static func open(_ prompt: Prompt) {
        NSWorkspace.shared.open(prompt.url)
        axAnnounce("Opened the link in \(prompt.name ?? "another app").")
    }

    /// The pair may be asked about again. Called by the card as it goes away, whatever took
    /// it away — so a sheet dismissed by anything but a button cannot wedge the question
    /// shut for the rest of the session.
    static func release(_ prompt: Prompt) { asking.remove(prompt.id) }

    // MARK: - check

    /// The decision table, the key format and the store, proved without LaunchServices, a
    /// page or a window. Runs against a throwaway defaults suite that is deleted afterwards.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = [
            // What leaves, and what does not. The four in the second group are the ones a
            // prompt on ordinary browsing would come from.
            ("a meeting link is another app's", isExternal("zoommtg")),
            ("so is a Teams link", isExternal("msteams")),
            ("mailto: counts — Mail opens and the page stays put", isExternal("mailto")),
            ("and so does tel:", isExternal("tel")),
            ("a reverse-DNS scheme is still another app's", isExternal("com.example.helper")),
            ("scheme matching is case-insensitive", isExternal("ZoomMtg")),
            ("http is not", !isExternal("http")),
            ("https is not", !isExternal("https")),
            ("about: is not — about:blank is how every popup starts",
             !isExternal("about")),
            ("data: is not — a data url is a page, not an app", !isExternal("data")),
            ("blob: is not", !isExternal("blob")),
            ("javascript: is not, and must never be handed to the system",
             !isExternal("javascript")),
            ("file: is not", !isExternal("file")),
            ("an extension's own page is WebKit's, not another app's",
             !isExternal("webkit-extension")),
            ("…and so is Safari's spelling of it", !isExternal("safari-web-extension")),
            ("…whatever case WebKit hands it over in", !isExternal("WebKit-Extension")),
            ("a url with no scheme at all is not", !isExternal(nil) && !isExternal("")),

            // The decision.
            ("an app link nobody has answered for asks",
             decision(remembered: false, host: "example.com", scheme: "zoommtg") == .ask),
            ("…and opens once the site has said always",
             decision(remembered: true, host: "example.com", scheme: "zoommtg") == .open),
            ("a web link is refused rather than handed to the system",
             decision(remembered: false, host: "example.com", scheme: "https") == .refuse),
            ("…even if something had somehow remembered one",
             decision(remembered: true, host: "example.com", scheme: "javascript") == .refuse),
            ("a page with no host still asks",
             decision(remembered: false, host: "", scheme: "zoommtg") == .ask),
            ("…and asks again, because there is nothing to remember it against",
             decision(remembered: true, host: "", scheme: "zoommtg") == .ask),

            // The card's words.
            ("the card names the app", title(app: "Zoom", scheme: "zoommtg") == "Open \u{201C}Zoom\u{201D}?"),
            ("with nothing installed it says so instead of blaming the link",
             title(app: nil, scheme: "zoommtg") == "No app can open zoommtg links"),
            ("…and a blank name is no name",
             title(app: "  ", scheme: "ZOOMMTG") == "No app can open zoommtg links"),
            ("the body names the site that asked",
             body(host: "zoom.us", app: "Zoom")
                == "\u{201C}zoom.us\u{201D} wants to open this application."),
            ("a page with no host does not name an empty one",
             body(host: "", app: "Zoom") == "This page wants to open this application."),
            ("with nothing installed the line does not promise an app is about to open",
             body(host: "zoom.us", app: nil)
                == "\u{201C}zoom.us\u{201D} linked to an app that isn\u{2019}t installed."),
            ("a blank name is no name in the body either, the way it is in the heading",
             body(host: "zoom.us", app: " ") == body(host: "zoom.us", app: nil)),
        ]

        // The key format. One key per site, so the sweep that clears them all has to be
        // able to tell one of ours from somebody else's preference.
        out += [
            ("a site round-trips through its key",
             parse(key: key(host: "zoom.us")) == "zoom.us"),
            ("a host with dots survives the parse",
             parse(key: key(host: "sub.example.co.uk")) == "sub.example.co.uk"),
            ("the key is lowercased, the way hosts are",
             key(host: "Zoom.US") == key(host: "zoom.us")),
            ("somebody else's preference is not one of ours",
             parse(key: "homepage") == nil
                && parse(key: "sitePermission.camera.example.com") == nil),
            ("a key with no host is not one of ours", parse(key: "externalApp.") == nil),
            ("a key that merely starts the same way is not one of ours",
             parse(key: "externalAppsomething") == nil),
        ]

        let suite = "vane.check.apps.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return out + [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }

        out.append(("a site nobody has answered for is not remembered",
                    !remembered(host: "zoom.us", scheme: "zoommtg")))
        allow(host: "zoom.us", scheme: "zoommtg")
        out += [
            ("Always Allow round-trips", remembered(host: "zoom.us", scheme: "zoommtg")),
            ("…case-insensitively", remembered(host: "ZOOM.US", scheme: "ZoomMtg")),
            ("…for that scheme only",
             !remembered(host: "zoom.us", scheme: "msteams")),
            ("…and for that site only",
             !remembered(host: "evil.example", scheme: "zoommtg")),
            ("…not for a site that merely ends the same way",
             !remembered(host: "not-zoom.us", scheme: "zoommtg")),
            ("…nor for one of its subdomains, which is a different origin",
             !remembered(host: "sub.zoom.us", scheme: "zoommtg")),
            ("the site panel lists what it may open",
             schemes(host: "zoom.us") == ["zoommtg"]),
            ("saying always twice does not list the same app twice",
             { allow(host: "zoom.us", scheme: "ZoomMtg")
               return schemes(host: "zoom.us") == ["zoommtg"] }()),
        ]

        allow(host: "zoom.us", scheme: "msteams")
        allow(host: "other.example", scheme: "tel")
        out += [
            ("…in a stable order, so the rows do not shuffle",
             schemes(host: "zoom.us") == ["msteams", "zoommtg"]),
            ("a site with no host is never remembered at all",
             { allow(host: "", scheme: "zoommtg"); return schemes(host: "").isEmpty }()),
            ("…and is never answered for either",
             !remembered(host: "", scheme: "zoommtg")),
            ("a scheme with dots in it is stored and read back whole",
             { allow(host: "dots.example", scheme: "com.example.helper")
               return remembered(host: "dots.example", scheme: "com.example.helper") }()),
        ]

        forget(host: "zoom.us", scheme: "msteams")
        out += [
            ("switching a row off forgets that pair", schemes(host: "zoom.us") == ["zoommtg"]),
            ("…and leaves the site's other answers standing",
             remembered(host: "zoom.us", scheme: "zoommtg")),
        ]

        reset(host: "zoom.us")
        out += [
            ("Clear Site Data forgets every app that site could open",
             schemes(host: "zoom.us").isEmpty),
            ("…and leaves the other sites alone",
             remembered(host: "other.example", scheme: "tel")),
        ]

        forgetAll()
        out.append(("Clear Browsing Data's cookies and site data forgets them all",
                    !remembered(host: "other.example", scheme: "tel")))
        return out
    }
}

// MARK: - The card

/// "Open “Zoom”?" — the flat card the answer is given on, in the shape the Clear Browsing
/// Data sheet is built from: a heading, a line saying who is asking, and the buttons at the
/// trailing edge with the safe one furthest from the pointer's path.
///
/// Presented as a sheet on whichever window the tab is in, so it is anchored to the page
/// that asked rather than floating over the whole app: a background tab in another window
/// cannot put a dialog in front of what you are reading.
struct ExternalAppCard: View {
    let prompt: ExternalApps.Prompt
    let answer: (ExternalApps.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            HStack(alignment: .top, spacing: Look.rowSpacing) {
                icon
                    .frame(width: Look.appIcon, height: Look.appIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Look.captionGap) {
                    Text(ExternalApps.title(app: prompt.name, scheme: prompt.scheme))
                        .font(Look.heading).foregroundStyle(Look.inkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ExternalApps.body(host: prompt.host, app: prompt.name))
                        .font(Look.footnote).foregroundStyle(Look.inkQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Look.inset) {
                Spacer(minLength: 0)
                if prompt.app == nil {
                    // Nothing to allow: the only honest button is the one that says so.
                    Button("OK") { answer(.cancel) }
                        .keyboardShortcut(.defaultAction)
                        // …and Escape has to take it down as well, since it is the key
                        // every other card in the app answers to. A hidden second button
                        // rather than a second `keyboardShortcut` on the same one, which
                        // replaces the first instead of adding to it.
                        .background {
                            Button("Cancel") { answer(.cancel) }
                                .keyboardShortcut(.cancelAction)
                                .frame(width: 0, height: 0).opacity(0)
                                .accessibilityHidden(true)
                        }
                } else {
                    Button("Cancel") { answer(.cancel) }.keyboardShortcut(.cancelAction)
                    // Not the default action: "never ask me again" is not what Return
                    // should mean, and it is the one answer that cannot be taken back by
                    // simply clicking Cancel next time.
                    Button("Always Allow") { answer(.always) }
                        .disabled(prompt.host.isEmpty)
                        .help(prompt.host.isEmpty
                              ? "This page has no site to remember an answer for."
                              : "Opens \(prompt.scheme): links from \(prompt.host) without asking.")
                    Button("Allow") { answer(.once) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Look.paneMargin)
        .frame(width: Look.appPrompt)
        .onDisappear { ExternalApps.release(prompt) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ExternalApps.title(app: prompt.name, scheme: prompt.scheme))
        .accessibilityValue(ExternalApps.body(host: prompt.host, app: prompt.name))
    }

    /// The handler's own icon, which is the fastest way to see whether the app about to
    /// open is the one you meant. A symbol when nothing claims the scheme.
    @ViewBuilder private var icon: some View {
        if let app = prompt.app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(Look.inkQuiet)
        }
    }
}

extension View {
    /// The card, on this window. Applied by all three kinds of window that hold a page — a
    /// browser window, a Little Vane and a Peek — so a link out of any of them asks the
    /// same question in the same place.
    func externalAppPrompt(_ store: TabStore) -> some View {
        modifier(ExternalAppPrompt(store: store))
    }
}

private struct ExternalAppPrompt: ViewModifier {
    @ObservedObject var store: TabStore

    func body(content: Content) -> some View {
        content.sheet(item: $store.externalApp) { prompt in
            ExternalAppCard(prompt: prompt) { ExternalApps.answer(prompt, $0, in: store) }
        }
    }
}
