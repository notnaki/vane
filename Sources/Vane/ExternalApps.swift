import AppKit
import SwiftUI
import WebKit

/// External application launches are granted to an exact web origin in one profile.
/// The requesting frame supplies the origin; a child never borrows its parent's grant.
/// Private grants live only in memory for the lifetime of their tab.
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

    typealias Scope = SitePermissions.Scope
    private static var defaults: UserDefaults = .vane
    private static let prefix = "externalApp.v2."
    private static var privateAnswers: [UUID: [String: [String]]] = [:]

    private static func key(scope: Scope) -> String {
        prefix + scope.profileID.uuidString.lowercased() + "."
            + Data(scope.origin.utf8).base64EncodedString()
    }

    static func remembered(scope: Scope?, scheme: String) -> Bool {
        schemes(scope: scope).contains(scheme.lowercased())
    }

    static func schemes(scope: Scope?) -> [String] {
        guard let scope else { return [] }
        if let tab = scope.privateTabID { return privateAnswers[tab]?[key(scope: scope)] ?? [] }
        // Host-only legacy grants cannot establish scheme, port, or profile consent.
        return defaults.stringArray(forKey: key(scope: scope)) ?? []
    }

    static func allow(scope: Scope?, scheme: String) {
        guard let scope, isExternal(scheme) else { return }
        let all = Array(Set(schemes(scope: scope) + [scheme.lowercased()])).sorted()
        save(all, scope: scope)
    }

    static func forget(scope: Scope?, scheme: String) {
        guard let scope else { return }
        save(schemes(scope: scope).filter { $0 != scheme.lowercased() }, scope: scope)
    }

    private static func save(_ schemes: [String], scope: Scope) {
        let key = key(scope: scope)
        if let tab = scope.privateTabID {
            privateAnswers[tab, default: [:]][key] = schemes.isEmpty ? nil : schemes
        } else if schemes.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(schemes, forKey: key) }
    }

    static func forgetPrivate(tabID: UUID) { privateAnswers.removeValue(forKey: tabID) }

    static func forgetAll(profileID: UUID? = nil) {
        let match = profileID.map { prefix + $0.uuidString.lowercased() + "." } ?? "externalApp."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(match) {
            defaults.removeObject(forKey: key)
        }
        if profileID == nil { privateAnswers.removeAll() }
    }

    // MARK: - The card

    /// One question on screen. `Equatable` and `Identifiable` so it can drive a sheet.
    struct Prompt: Identifiable, Equatable, Sendable {
        let url: URL
        let scope: Scope?
        let tabID: UUID
        let documentID: UUID
        let id = UUID().uuidString
        var host: String { scope?.host ?? "" }
        var originLabel: String { scope?.origin ?? "" }
        let scheme: String
        /// Where the handler lives, so the card can draw its icon. Nil when nothing on this
        /// Mac claims the scheme, which is a different card with one button.
        let app: URL?
        /// Its display name — "Zoom", not "zoom.us.app".
        let name: String?
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

    /// Only WebKit's security origin is authority. Frame request URLs can retain
    /// about:blank or name an opaque/sandboxed document's untrusted source URL.
    static func offer(_ url: URL, from frame: WKFrameInfo, tab: Tab) {
        guard let web = tab.existingWeb, frame.webView === web, !tab.suspended,
              let store = TabStore.all.first(where: { $0.active === tab }),
              store.externalApp == nil else { return }
        let origin = frame.securityOrigin
        let scope = Scope(scheme: origin.protocol, host: origin.host, port: origin.port,
                          profileID: tab.profileID, privateTabID: tab.isPrivate ? tab.id : nil)
        let scheme = url.scheme?.lowercased() ?? ""
        switch decision(remembered: remembered(scope: scope, scheme: scheme),
                        host: scope?.host ?? "", scheme: scheme) {
        case .refuse: return
        case .open: NSWorkspace.shared.open(url)
        case .ask:
            let app = handler(for: url)
            store.externalApp = Prompt(url: url, scope: scope, tabID: tab.id,
                                       documentID: tab.readingDocumentGeneration,
                                       scheme: scheme, app: app, name: name(of: app))
        }
    }

    static func answer(_ prompt: Prompt, _ answer: Answer, in store: TabStore) {
        // An old SwiftUI button action must not approve a new document or prompt.
        guard store.externalApp?.id == prompt.id else { return }
        store.externalApp = nil
        guard let tab = store.active, tab.id == prompt.tabID, tab.existingWeb != nil, !tab.suspended,
              tab.readingDocumentGeneration == prompt.documentID else { return }
        switch answer {
        case .cancel: axAnnounce("Didn’t open the link.")
        case .always:
            allow(scope: prompt.scope, scheme: prompt.scheme)
            SiteChanges.shared.bump()
            open(prompt)
        case .once: open(prompt)
        }
    }

    private static func open(_ prompt: Prompt) {
        guard prompt.app != nil else { return }
        NSWorkspace.shared.open(prompt.url)
        axAnnounce("Opened the link in \(prompt.name ?? "another app").")
    }

    static func dismiss(for tab: Tab) {
        for store in TabStore.all where store.externalApp?.tabID == tab.id {
            store.externalApp = nil
        }
    }

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

        let suite = "vane.check.apps.\(UUID())"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return out + [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer { defaults = real; UserDefaults.dropScratchSuite(suite) }
        let profile = UUID()
        let scope = Scope(url: URL(string: "https://zoom.us"), profileID: profile)!
        allow(scope: scope, scheme: "ZoomMtg")
        out += [
            ("Always Allow remembers an exact origin", remembered(scope: scope, scheme: "zoommtg")),
            ("an HTTP origin cannot borrow HTTPS consent", !remembered(
                scope: Scope(url: URL(string: "http://zoom.us"), profileID: profile), scheme: "zoommtg")),
            ("a different port cannot borrow consent", !remembered(
                scope: Scope(url: URL(string: "https://zoom.us:8443"), profileID: profile), scheme: "zoommtg")),
            ("another profile cannot borrow consent", !remembered(
                scope: Scope(url: URL(string: "https://zoom.us"), profileID: UUID()), scheme: "zoommtg")),
            ("opaque origins cannot retain grants", { allow(scope: nil, scheme: "zoommtg"); return schemes(scope: nil).isEmpty }()),
        ]
        forget(scope: scope, scheme: "zoommtg")
        out.append(("revoking consent removes the launch grant", !remembered(scope: scope, scheme: "zoommtg")))
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
                    Text(ExternalApps.body(host: prompt.originLabel, app: prompt.name))
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
                    Button(prompt.scope?.privateTabID == nil ? "Always Allow" : "Allow for This Private Tab") { answer(.always) }
                        .disabled(prompt.scope == nil)
                        .help(prompt.scope == nil
                              ? "This page has no site to remember an answer for."
                              : "Opens \(prompt.scheme): links from \(prompt.originLabel) in this profile without asking.")
                    Button("Allow") { answer(.once) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Look.paneMargin)
        .frame(width: Look.appPrompt)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ExternalApps.title(app: prompt.name, scheme: prompt.scheme))
        .accessibilityValue(ExternalApps.body(host: prompt.originLabel, app: prompt.name))
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
