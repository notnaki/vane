import AppKit
import SwiftUI
import WebKit

// MARK: - The model

/// Arc's Site Control Center: everything this browser can be told about *one site*, in one
/// popover hanging off the address pill's trailing controls button. Before it, the glyph opened the whole
/// Settings window and the per-site answers (camera, zoom, the inspector) were spread across
/// four menus and a preferences pane.
///
/// The model is the interesting half and it is pure. Turning "this page, this profile" into
/// "these rows, in this order, live or inert" is where a site panel goes quietly wrong — a
/// Reader row on a page with no article, a camera toggle reading "off" when the honest
/// answer is "nobody has been asked yet" — so it is proved offline in `check()` rather than
/// looked at in a screenshot.
///
/// ponytail: a value built fresh on every render out of the statics that already own each
/// setting (`SitePermissions`, `Zoom`, `Blocker`, `Reader`, `ExtensionHost`), not a store of
/// its own. There is nothing here to persist that those files do not already persist better.
struct SiteControlModel: Equatable, Sendable {
    /// One extension, as this site sees it.
    struct Ext: Equatable, Sendable {
        let name: String
        let allowed: Bool
        /// What `browser.action.setBadgeText` put on the button for this tab, truncated to
        /// what a 16pt glyph holds. Nil is no badge.
        var badge: String?
        /// `browser.action.disable()`. The button greys out; the access switch beside it
        /// does not, because "may this extension see this site" is still a live question.
        var enabled = true
        /// Its action is also a glyph in the address pill.
        var pinned = false
    }

    /// One app this site may open without being asked again — a remembered "Always Allow".
    struct App: Equatable, Sendable {
        /// The url scheme the answer was given for: "zoommtg", "msteams", "mailto".
        let scheme: String
        /// The handler's display name, or the scheme itself when nothing on this Mac claims
        /// it any more — the answer is still standing and still has to be removable.
        let name: String
    }

    /// Empty for anything with no site to control: nothing loaded, a file, about:blank.
    var host = ""
    var scheme: String?
    var secureContent = true
    var certificateTrusted = true
    var navigationFailed = false
    /// nil is not "off": it means this site has never been answered, so it will be asked.
    var camera: Bool?
    var microphone: Bool?
    var location: Bool?
    /// Ask here means blocked with a toast offering to open it, not a prompt.
    var popups: Bool?
    var notifications: Bool?
    var notificationsOnce = false
    var locationOnce = false
    var cameraOnce = false
    var microphoneOnce = false
    var pictureInPicture = false
    var zoom = 1.0
    var blocking = true
    var profileBlocking = true
    var reader = false
    var readerAvailable = false
    var translated = false
    /// nil in a private window, which offers nothing and so has nothing to switch.
    var offersTranslation: Bool?
    var extensions: [Ext] = []
    /// The apps this site is allowed to open without asking. See ExternalApps.swift.
    var apps: [App] = []
    var boosted = false
    var developer = false
    var actAsChrome = false
    /// Develop → User Agent is set to something other than the default, and wins here.
    var userAgentOverridden = false
}

extension SiteControlModel {

    /// Which row, so the view can act on one without matching on its title.
    enum RowID: Hashable, Sendable {
        case camera, microphone, location, popups, notifications, pictureInPicture, zoom, blocker, blockerSettings, reader, translate, translateOffers, actAsChrome, capture, boost, clearData, developer
        /// The index into `extensions`, which is also the index into the host's contexts.
        case ext(Int)
        /// The index into `apps`: one remembered "Always Allow" for another app.
        case app(Int)
    }

    /// What sits at the trailing edge of a row.
    enum Control: Equatable, Sendable {
        case toggle(Bool)
        /// Allow / Block / Ask. A permission has three answers, and collapsing the third
        /// into "off" is the lie this case exists to avoid.
        case permission(Bool?)
        /// The zoom stepper's current label ("100%", "125%").
        case zoom(String)
        /// The row is the button: Clear Site Data.
        case action
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: RowID
        let title: String
        let glyph: String
        let control: Control
        /// A second line under the title, for when a row does less than its name promises.
        var note: String?
        /// Greyed and unclickable. `note` says why.
        var inert = false
        /// A mark on the row's icon: an extension action's badge.
        var badge: String?
        /// The icon is drawn dim and the row's tap does nothing, but the row is not inert —
        /// its switch still works. A disabled extension action, and only that.
        var dim = false
    }

    /// No host is no site: a `file://` page, `about:blank`, or no tab at all. The popover
    /// says so rather than offering eleven controls that would each write nothing.
    var siteless: Bool { host.isEmpty }

    /// The host as the pill shows it — Arc drops `www.`, and so must the title over a panel
    /// that claims to be about the same site.
    var title: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var insecure: Bool {
        PillState.insecure(scheme: scheme, onlySecureContent: secureContent,
                           trusted: certificateTrusted)
    }

    /// The pill's leading glyph, which is also the button that opens this popover. Always
    /// something: a button that comes and goes as pages load makes the pill jump, and the
    /// sidebar's chrome does not move.
    var glyph: String {
        if siteless || navigationFailed { return "globe" }
        if insecure { return PillState.glyph(scheme: scheme) }
        // Only https has earned a closed lock. A host on some other scheme — a custom one,
        // a `vane:` page — is not encrypted and is not "not secure" either; it gets the
        // neutral globe rather than a padlock promising something nobody checked.
        return scheme?.lowercased() == "https" ? "lock" : "globe"
    }

    /// The header's second line. Says *which* kind of not-secure, because "you clicked
    /// through a certificate warning here" and "this page is plain http" are different
    /// problems with different fixes.
    var connection: String {
        guard !siteless else { return "No page loaded" }
        if navigationFailed { return "This page did not load" }
        switch scheme?.lowercased() {
        case "https":
            if !certificateTrusted { return "Not secure — a certificate problem was accepted here" }
            if !secureContent { return "Not fully secure — part of this page loaded over http" }
            return "Connection is secure"
        case "http": return "Not secure — this page is not encrypted"
        default:     return "Not a web page"
        }
    }

    /// The tiny mark on the pill's glyph. Only a *grant* badges: a remembered "no" is not
    /// something the user has to be told about at a glance, and badging both would make the
    /// mark mean nothing. Nil is no badge.
    var badge: String? {
        switch (camera == true, microphone == true) {
        case (true, true):  "Camera and microphone allowed"
        case (true, false): "Camera allowed"
        case (false, true): "Microphone allowed"
        default:            nil
        }
    }

    /// The rows, in Arc's order: what the page may do, then how it is shown, then what can
    /// be taken away from it, and the developer switch last.
    var rows: [Row] {
        guard !siteless else { return [] }
        var out: [Row] = [
            Row(id: .camera, title: "Camera", glyph: "camera", control: .permission(camera),
                note: cameraOnce ? "Allowed once, until this tab navigates or closes." : nil),
            Row(id: .microphone, title: "Microphone", glyph: "mic",
                control: .permission(microphone),
                note: microphoneOnce ? "Allowed once, until this tab navigates or closes." : nil),
            Row(id: .popups, title: "Pop-ups", glyph: "macwindow.on.rectangle",
                control: .permission(popups),
                note: "Pop-ups you click open either way. Ask blocks the rest and offers to open them."),
            Row(id: .notifications, title: "Notifications", glyph: "bell",
                control: .permission(notifications),
                note: notificationsOnce ? "Allowed once, until this tab navigates or closes." : nil),
            // ponytail: the switch is offered whatever the page holds, because whether
            // there is a detachable video is a question only the page can answer and only
            // asynchronously — `window.__vanePiP()` returns 'unsupported' and the switch
            // springs back. Upgrade path: publish that answer onto `Tab` from the same
            // script that already reports the mode, and this row gets `inert` like Reader's.
            Row(id: .pictureInPicture, title: "Picture in Picture", glyph: "pip",
                control: .toggle(pictureInPicture)),
            Row(id: .zoom, title: "Zoom", glyph: "textformat.size",
                control: .zoom(PillState.zoomLabel(zoom) ?? "100%")),
            Row(id: .blocker, title: "Block Ads", glyph: "shield",
                control: .toggle(blocking),
                note: profileBlocking ? "This exact host in this profile. Changing it reloads the page." : "Blocking is off for this profile. Enable it in Privacy settings.",
                inert: !profileBlocking),
            Row(id: .blockerSettings, title: "Filter Lists and Diagnostics", glyph: "list.bullet.rectangle",
                control: .action),
            Row(id: .reader, title: "Reader Mode", glyph: "doc.plaintext",
                control: .toggle(reader),
                note: reader || readerAvailable ? nil : "This page has no article to read.",
                inert: !(reader || readerAvailable)),
            Row(id: .translate, title: "Translate Page", glyph: "translate",
                control: .toggle(translated)),
        ]
        if let offersTranslation {
            out.append(Row(id: .translateOffers, title: "Offer to Translate", glyph: "character.bubble",
                           control: .toggle(offersTranslation),
                           note: offersTranslation ? nil : "Never translate this site is on."))
        }
        for (i, ext) in extensions.enumerated() {
            out.append(Row(id: .ext(i), title: ext.name,
                           // The fallback only: the view draws the action's own icon when
                           // WebKit can load one, which is nearly always.
                           glyph: "puzzlepiece.extension",
                           control: .toggle(ext.allowed),
                           note: ext.enabled ? nil : "Not available on this page.",
                           badge: ext.badge, dim: !ext.enabled))
        }
        // What this site may open outside the browser. Only ever the answers that exist: a
        // site that has never been allowed an app has no row here, the same way a site with
        // no extensions has none for those.
        for (i, app) in apps.enumerated() {
            out.append(Row(id: .app(i), title: "Can Open " + app.name,
                           glyph: "arrow.up.forward.app",
                           control: .toggle(true),
                           note: "Always opens " + app.scheme + ": links from this site."))
        }
        if scheme?.lowercased() == "http" || scheme?.lowercased() == "https" {
            out.append(Row(id: .boost, title: boosted ? "Edit Boost" : "Boost This Site", glyph: "paintbrush.pointed", control: .action))
            out.append(Row(id: .actAsChrome, title: "Act as Chrome", glyph: "theatermasks",
                           control: .toggle(actAsChrome && !userAgentOverridden),
                           note: userAgentOverridden ? "Develop → User Agent is set and applies to every site."
                            : "For sites that turn away other browsers. Streaming video may stop working with it on. Changing it reloads the page.",
                           inert: userAgentOverridden))
        }
        if SitePermissions.supportsLocation {
            out.insert(Row(id: .location, title: "Location", glyph: "location", control: .permission(location),
                           note: (locationOnce ? "Allowed once, until this tab navigates or closes. " : "")
                            + "Revoking location reloads this page. Existing access ends when reload completes."), at: 2)
        }
        out.append(Row(id: .capture, title: "Capture a Portion of This Page",
                       glyph: "camera.viewfinder", control: .action))
        out.append(Row(id: .clearData, title: "Clear Site Data…", glyph: "trash",
                       control: .action))
        out.append(Row(id: .developer, title: "Developer Mode", glyph: "hammer",
                       control: .toggle(developer),
                       note: "The dev bar and Web Inspector for this site. On by itself for localhost."))
        return out
    }

    /// Arc's Settings section: not every setting, only the ones this site has something to
    /// say about. Developer Mode always; a permission once it has an answer; zoom once it is
    /// off 100%; ad blocking once it is off here; an app once it may be opened. Everything
    /// else waits in Site Settings, one click further in.
    struct Setting: Identifiable, Equatable, Sendable {
        let id: RowID
        let title: String
        let value: String
        let glyph: String
        /// Drawn on a light disc rather than a dark one: allowed, or on.
        let on: Bool
    }

    var settings: [Setting] {
        guard !siteless else { return [] }
        var out = [Setting(id: .developer, title: "Developer Mode", value: developer ? "On" : "Off",
                           glyph: "hammer.fill", on: developer)]
        let permissions: [(RowID, String, String, Bool?, Bool)] = [
            (.camera, "Camera", "camera.fill", camera, cameraOnce),
            (.microphone, "Microphone", "mic.fill", microphone, microphoneOnce),
            (.location, "Location", "location.fill", location, locationOnce),
            (.popups, "Pop-ups", "macwindow.on.rectangle", popups, false),
            (.notifications, "Notifications", "bell.fill", notifications, notificationsOnce),
        ]
        for (id, title, glyph, answer, once) in permissions {
            guard let answer else { continue }
            out.append(Setting(id: id, title: title,
                               value: answer ? (once ? "Allowed Once" : "Allowed") : "Blocked",
                               glyph: glyph, on: answer))
        }
        if pictureInPicture {
            out.append(Setting(id: .pictureInPicture, title: "Picture in Picture", value: "On", glyph: "pip.fill", on: true))
        }
        if let label = PillState.zoomLabel(zoom) {
            out.append(Setting(id: .zoom, title: "Zoom", value: label, glyph: "textformat.size", on: true))
        }
        if profileBlocking && !blocking {
            out.append(Setting(id: .blocker, title: "Block Ads", value: "Off", glyph: "shield.slash", on: false))
        }
        if actAsChrome && !userAgentOverridden {
            out.append(Setting(id: .actAsChrome, title: "Act as Chrome", value: "On", glyph: "theatermasks.fill", on: true))
        }
        if translated {
            out.append(Setting(id: .translate, title: "Translation", value: "On", glyph: "translate", on: true))
        }
        for (i, app) in apps.enumerated() {
            out.append(Setting(id: .app(i), title: "Open " + app.name, value: "Allowed",
                               glyph: "arrow.up.forward.app.fill", on: true))
        }
        return out
    }

    /// A `WKWebsiteDataRecord` is named for its registrable domain, so the record covering
    /// `news.example.com` is called `example.com`. Clearing one site's data has to match
    /// that — and must never be a bare suffix test, which would take `notexample.com` down
    /// with `example.com`.
    nonisolated static func covers(record: String, host: String) -> Bool {
        let r = record.lowercased(), h = host.lowercased()
        guard !r.isEmpty, !h.isEmpty else { return false }
        return h == r || h.hasSuffix("." + r)
    }
}

// MARK: - Reading and writing the page's state

@MainActor extension SiteControlModel {
    /// Everything the popover shows, read out of the files that own it. Cheap enough to do
    /// on every render — six UserDefaults lookups and a walk of the loaded extensions —
    /// which is what keeps this a derived value rather than another thing to keep in sync.
    init(_ tab: Tab?) {
        self.init()
        guard let tab, let url = tab.currentURL, let h = url.host(), !h.isEmpty else { return }
        host = h
        scheme = url.scheme
        secureContent = tab.secureContent
        certificateTrusted = tab.certificateTrusted
        navigationFailed = tab.displayingNavigationError
        if let permissionScope = SitePermissions.scope(for: tab) {
            camera = SitePermissions.effective(scope: permissionScope, type: .camera, tabID: tab.id)
            microphone = SitePermissions.effective(scope: permissionScope, type: .microphone, tabID: tab.id)
            cameraOnce = SitePermissions.isAllowedOnce(scope: permissionScope, type: .camera, tabID: tab.id)
            location = SitePermissions.effective(scope: permissionScope, type: .location, tabID: tab.id)
            locationOnce = SitePermissions.isAllowedOnce(scope: permissionScope, type: .location, tabID: tab.id)
            microphoneOnce = SitePermissions.isAllowedOnce(scope: permissionScope, type: .microphone, tabID: tab.id)
            popups = SitePermissions.remembered(scope: permissionScope, type: .popups)
            notifications = SitePermissions.effective(scope: permissionScope, type: .notifications, tabID: tab.id)
            notificationsOnce = SitePermissions.isAllowedOnce(scope: permissionScope, type: .notifications, tabID: tab.id)
        }
        pictureInPicture = tab.pictureInPicture
        zoom = tab.zoom
        profileBlocking = Blocker.enabled(for: tab.profileID)
        blocking = Blocker.enabled(for: tab.profileID, url: url)
        reader = Reader.isOn(tab)
        readerAvailable = tab.readerAvailable
        translated = PageTranslation.isOn(tab)
        offersTranslation = tab.isPrivate ? nil
            : !PageTranslation.neverListed(h, in: PageTranslation.neverTranslated(profileID: tab.profileID))
        let host = tab.extensions
        extensions = host.visible(in: tab).map { context in
            let action = host.action(context, for: tab)
            return Ext(name: context.webExtension.displayName ?? "Extension",
                       allowed: context.hasAccess(to: url),
                       badge: action.flatMap { ExtensionPins.badge($0.badgeText) },
                       enabled: action?.isEnabled ?? true,
                       pinned: host.isPinned(context))
        }
        // The name is looked up per scheme rather than stored: the answer is a (site,
        // scheme) pair, and which app answers to a scheme is macOS's to change.
        apps = ExternalApps.schemes(scope: SitePermissions.scope(for: tab)).map { scheme in
            let handler = URL(string: scheme + "://open").flatMap(ExternalApps.handler(for:))
            return App(scheme: scheme, name: ExternalApps.name(of: handler) ?? scheme)
        }
        if let origin = SiteBoosts.origin(url) { boosted = SiteBoosts.value(origin: origin, tab: tab) != SiteBoost() }
        developer = tab.developer
        actAsChrome = ActAsChrome.isOn(url, profileID: tab.profileID, isPrivate: tab.isPrivate)
        userAgentOverridden = ActAsChrome.overridden
    }
}

/// What makes the pill and the popover redraw when a *setting* changes rather than the tab.
///
/// One bump off `UserDefaults.didChangeNotification` catches persistent settings. Private
/// media answers live in memory, so their modal prompt calls `bump()` explicitly. The
/// popover's own actions also bump directly so their feedback is immediate.
@MainActor final class SiteChanges: ObservableObject {
    static let shared = SiteChanges()
    @Published private(set) var revision = 0

    private init() {
        // `assumeIsolated` would trap if this ever arrived off the main queue; a hop costs
        // nothing here, since all it does is invalidate two small views. Weak self rather
        // than `SiteChanges.shared`, which is still being assigned while this init runs.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.revision &+= 1 } }
    }

    func bump() { revision &+= 1 }
}

/// The side that writes. Split from the view so a row's action is one named call.
@MainActor enum SiteControl {

    /// The host the popover is about, as the model keys everything on.
    static func host(of tab: Tab) -> String { tab.currentURL?.host() ?? "" }

    /// Every case reads the setting it is about to flip *now*, rather than inverting what
    /// the model said when the row was drawn. A popover can sit open across a navigation,
    /// a second window, or the modal permission prompt, and a stale `!on` writes the value
    /// the user is already looking at back over the one that changed underneath them.
    static func act(_ id: SiteControlModel.RowID, on tab: Tab) {
        let host = host(of: tab)
        switch id {
        case .camera:     cycle(.camera, on: tab)
        case .microphone: cycle(.microphone, on: tab)
        case .location: cycle(.location, on: tab)
        case .popups: cycle(.popups, on: tab)
        case .notifications: cycle(.notifications, on: tab)
        case .pictureInPicture: PictureInPicture.toggle(tab)
        case .zoom: Zoom.reset(tab)
        case .blocker:
            guard Blocker.enabled(for: tab.profileID) else { return }
            let excepted = Blocker.siteExceptions(for: tab.profileID).contains(host.lowercased())
            Blocker.setSiteException(host, allowed: !excepted, profileID: tab.profileID, recompile: false)
            Blocker.refresh(completion: { [weak tab] in tab?.reload() })
        case .blockerSettings:
            VanePages.open(.settings(.privacy), profileID: tab.profileID, from: VanePages.store(of: tab))
        case .reader: Reader.toggle(tab)
        case .translate: PageTranslation.toggle(tab, in: PageTranslation.store(of: tab) ?? Windows.current)
        case .translateOffers:
            let never = PageTranslation.neverListed(host, in: PageTranslation.neverTranslated(profileID: tab.profileID))
            PageTranslation.setOffers(never, host: host, tab: tab)
        case .capture: PageCapture.start(tab)
        case .boost: SiteBoostEditor.open(tab: tab)
        case .ext(let i): toggleExtension(i, on: tab)
        // The switch is on because the answer exists; the only thing it can do is take it
        // back, which puts the site back to being asked.
        case .app(let i): forgetApp(i, on: tab)
        case .clearData: clearSiteData(host: host, tab: tab)
        case .developer: DeveloperMode.toggle(tab)
        case .actAsChrome: ActAsChrome.toggle(tab)
        }
        SiteChanges.shared.bump()
    }

    /// The permission row's own control is a picker; this is what a click on the row body
    /// does, so the keyboard and VoiceOver have a route that is not a menu.
    private static func cycle(_ type: SitePermissions.Kind, on tab: Tab) {
        guard let scope = SitePermissions.scope(for: tab) else { return }
        let current = SitePermissions.effective(scope: scope, type: type, tabID: tab.id)
        set(type, to: current == nil ? true : (current == true ? false : nil), on: tab)
    }

    static func set(_ type: SitePermissions.Kind, to answer: Bool?, on tab: Tab) {
        guard let scope = SitePermissions.scope(for: tab) else { return }
        SitePermissions.set(scope: scope, type: type, answer: answer, tabID: tab.id)
        SiteChanges.shared.bump()
    }

    /// The extensions the rows are indexed against — the same list the model built itself
    /// from, so `.ext(2)` is the third row and not the third *installed* extension, which
    /// differ in a private window.
    static func contexts(on tab: Tab) -> [WKWebExtensionContext] { tab.extensions.visible(in: tab) }

    /// Per-site extension access, flipped from what this extension can see right now.
    /// WebKit turns the url into a match pattern for us, so "allow this extension here" is
    /// one call and does not need a pattern built by hand.
    ///
    /// Takes the context, not a row index: the row was drawn from a snapshot of
    /// `contexts(on:)` and an extension can finish loading between the draw and the click,
    /// which would slide every index along by one and flip the wrong extension.
    static func toggleAccess(_ context: WKWebExtensionContext, on tab: Tab) {
        guard let url = tab.currentURL else { return }
        let allowed = !context.hasAccess(to: url)
        context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: url)
    }

    /// "Always Allow", taken back. Indexed the way the row was drawn — against the sorted
    /// list `ExternalApps.schemes` returns — and re-read here rather than carried, so a row
    /// whose answer has gone in the meantime removes nothing instead of its neighbour.
    static func forgetApp(_ index: Int, on tab: Tab) {
        let scope = SitePermissions.scope(for: tab)
        let all = ExternalApps.schemes(scope: scope)
        guard all.indices.contains(index) else { return }
        ExternalApps.forget(scope: scope, scheme: all[index])
    }

    /// The index-keyed way in, for `act` — which is keyed on `RowID` and has nothing else to
    /// go on. The popover's own rows use their snapshot instead.
    static func toggleExtension(_ index: Int, on tab: Tab) {
        let all = contexts(on: tab)
        guard all.indices.contains(index) else { return }
        toggleAccess(all[index], on: tab)
    }

    /// Inspect the exact tab's store before choosing which website data to clear.
    static func clearSiteData(host: String, tab: Tab) {
        guard !host.isEmpty else { return }
        WebsiteDataWindow.show(host: host, tab: tab)
    }

    // MARK: - check

    /// The mapping, proved without a page. Every assertion here is something a screenshot
    /// cannot show: that a row is inert for the right reason, that "never asked" survives
    /// the trip to the control, that clearing one site's data cannot reach another's.
    nonisolated static func check() -> [(String, Bool)] {
        var m = SiteControlModel()
        var out: [(String, Bool)] = []

        // Nothing loaded.
        out.append(("no page is no site", m.siteless))
        out.append(("…so there are no rows to offer", m.rows.isEmpty))
        out.append(("…and the header says so rather than claiming a secure connection",
                    m.connection == "No page loaded"))
        out.append(("…but the pill keeps a glyph, so the button does not come and go",
                    m.glyph == "globe"))

        // The connection line.
        m = SiteControlModel(host: "example.com", scheme: "https")
        out.append(("plain https reads as secure", m.connection == "Connection is secure"))
        out.append(("…and wears the lock", m.glyph == "lock" && !m.insecure))
        var mixed = m
        mixed.secureContent = false
        out.append(("mixed content is called out as partly insecure",
                    mixed.connection.contains("part of this page loaded over http")))
        out.append(("…and the glyph changes with it", mixed.glyph == "exclamationmark.triangle"))
        var untrusted = m
        untrusted.certificateTrusted = false
        out.append(("a clicked-through certificate is named as the reason, not lumped in",
                    untrusted.connection.contains("certificate")))
        var plain = m
        plain.scheme = "http"
        out.append(("http reads as not encrypted", plain.connection == "Not secure — this page is not encrypted"))
        out.append(("…and wears the broken lock", plain.glyph == "lock.slash"))
        // A lock is a claim about encryption, and only https has made one.
        var other = m
        other.scheme = "vane"
        out.append(("a host on some other scheme gets no padlock", other.glyph == "globe"))
        out.append(("…and is not called insecure either", !other.insecure))
        out.append(("…and says what it is rather than promising security",
                    other.connection == "Not a web page"))
        out.append(("HTTPS in capitals still earns the lock",
                    { var c = m; c.scheme = "HTTPS"; return c.glyph == "lock" }()))

        // www. is dropped in the title, the way the pill drops it.
        var www = m
        www.host = "www.example.com"
        out.append(("the title drops www., the way the pill does", www.title == "example.com"))
        out.append(("…and a host that merely starts with w is left alone",
                    SiteControlModel(host: "wwworld.example").title == "wwworld.example"))

        // Rows.
        let ids = m.rows.map(\.id)
        out.append(("a site gets the whole panel", ids.count >= 8))
        out.append(("camera and microphone lead it", ids.prefix(2) == [.camera, .microphone]))
        out.append(("developer mode is last, the way Arc buries it", ids.last == .developer))
        out.append(("clearing site data sits just above it",
                    ids.dropLast().last == .clearData))
        out.append(("every row is uniquely identified", Set(ids).count == ids.count))
        out.append(("every row names itself", m.rows.allSatisfy { !$0.title.isEmpty }))
        out.append(("every row has a glyph", m.rows.allSatisfy { !$0.glyph.isEmpty }))

        // A permission that has never been answered is not "off".
        func control(_ model: SiteControlModel, _ id: SiteControlModel.RowID) -> SiteControlModel.Control? {
            model.rows.first { $0.id == id }?.control
        }
        out.append(("an unanswered camera is Ask, not Block",
                    control(m, .camera) == .permission(nil)))
        var allowed = m
        allowed.camera = true
        out.append(("an allowed camera reads as allowed", control(allowed, .camera) == .permission(true)))
        var denied = m
        denied.camera = false
        out.append(("a denied camera reads as denied, which is not the same as unanswered",
                    control(denied, .camera) == .permission(false)))
        out.append(("…and the two are told apart",
                    control(denied, .camera) != control(m, .camera)))

        // The badge on the pill's glyph.
        out.append(("an untouched site does not badge the pill", m.badge == nil))
        out.append(("a remembered no does not badge it either — a badge means a grant exists",
                    denied.badge == nil))
        out.append(("an allowed camera badges it", allowed.badge == "Camera allowed"))
        var both = m
        both.camera = true
        both.microphone = true
        out.append(("both grants read as one badge", both.badge == "Camera and microphone allowed"))
        var mic = m
        mic.microphone = true
        out.append(("a microphone grant badges on its own", mic.badge == "Microphone allowed"))

        // Reader.
        out.append(("Reader is inert on a page with no article",
                    m.rows.first { $0.id == .reader }?.inert == true))
        out.append(("…and says why rather than just greying out",
                    m.rows.first { $0.id == .reader }?.note?.contains("no article") == true))
        var readable = m
        readable.readerAvailable = true
        out.append(("Reader wakes up on an article",
                    readable.rows.first { $0.id == .reader }?.inert == false))
        var reading = m
        reading.reader = true
        out.append(("Reader stays live while it is on, so it can be turned off again",
                    reading.rows.first { $0.id == .reader }?.inert == false))
        out.append(("…and reads as on", control(reading, .reader) == .toggle(true)))

        // The blocker row is honest about its reach.
        out.append(("the ad blocker row explains exact-host scope",
                    m.rows.first { $0.id == .blocker }?.note?.lowercased()
                        .contains("exact host in this profile") == true))
        out.append(("…and is never inert, because it does work",
                    m.rows.first { $0.id == .blocker }?.inert == false))

        // Zoom.
        out.append(("an unzoomed page reads 100%", control(m, .zoom) == .zoom("100%")))
        var zoomed = m
        zoomed.zoom = 1.25
        out.append(("a zoomed page reads its level", control(zoomed, .zoom) == .zoom("125%")))

        // Extensions.
        out.append(("no extensions means no extension rows",
                    !m.rows.contains { if case .ext = $0.id { return true } else { return false } }))
        var withExts = m
        withExts.extensions = [.init(name: "uBlock", allowed: true),
                               .init(name: "Dark Reader", allowed: false)]
        let extRows = withExts.rows.filter { if case .ext = $0.id { return true } else { return false } }
        out.append(("each loaded extension gets a row", extRows.count == 2))
        out.append(("…named after the extension", extRows.first?.title == "uBlock"))
        out.append(("…reading whether it may see this site",
                    extRows.map(\.control) == [.toggle(true), .toggle(false)]))
        out.append(("…and indexed so the right one is toggled",
                    extRows.map(\.id) == [.ext(0), .ext(1)]))
        // The action button on the row: its badge, and what an extension disabling it does.
        out.append(("an extension with no badge does not draw one",
                    extRows.allSatisfy { $0.badge == nil }))
        var badged = m
        badged.extensions = [.init(name: "uBlock", allowed: true, badge: "12")]
        out.append(("a badge set for this tab reaches the row",
                    badged.rows.first { $0.id == .ext(0) }?.badge == "12"))
        var off = m
        off.extensions = [.init(name: "uBlock", allowed: true, enabled: false)]
        let offRow = off.rows.first { $0.id == .ext(0) }
        out.append(("an action its extension disabled is drawn dim", offRow?.dim == true))
        out.append(("…and says so rather than just greying out",
                    offRow?.note == "Not available on this page."))
        out.append(("…but the row is not inert, because its access switch still works",
                    offRow?.inert == false))
        out.append(("…and that switch still reads the site's answer",
                    offRow?.control == .toggle(true)))
        out.append(("a live action is neither dim nor noted",
                    extRows.allSatisfy { !$0.dim && $0.note == nil }))
        var pinnedExt = m
        pinnedExt.extensions = [.init(name: "uBlock", allowed: true, pinned: true),
                                .init(name: "Dark Reader", allowed: true)]
        out.append(("the model says which extensions are pinned to the pill",
                    pinnedExt.extensions.map(\.pinned) == [true, false]))

        // Developer mode.
        out.append(("developer mode is off by default in the model", control(m, .developer) == .toggle(false)))
        var dev = m
        dev.developer = true
        out.append(("…and reads as on when the tab is inspectable", control(dev, .developer) == .toggle(true)))

        // Act as Chrome. `m` is an https page.
        out.append(("act as chrome is off by default", control(m, .actAsChrome) == .toggle(false)
                    && !m.settings.contains { $0.id == .actAsChrome }))
        var chrome = m
        chrome.actAsChrome = true
        out.append(("…shows in Settings once on", control(chrome, .actAsChrome) == .toggle(true)
                    && chrome.settings.contains { $0.id == .actAsChrome }))
        chrome.userAgentOverridden = true
        out.append(("…and is inert while Develop's user agent wins",
                    chrome.rows.first { $0.id == .actAsChrome }?.inert == true
                    && !chrome.settings.contains { $0.id == .actAsChrome }))

        // Apps this site may open without asking. See ExternalApps.swift.
        out.append(("a site that has never been allowed an app gets no row for one",
                    !m.rows.contains { if case .app = $0.id { return true }; return false }))
        var opens = m
        opens.apps = [SiteControlModel.App(scheme: "zoommtg", name: "Zoom"),
                      SiteControlModel.App(scheme: "msteams", name: "Microsoft Teams")]
        let appRows: [SiteControlModel.Row] =
            opens.rows.filter { if case .app = $0.id { return true }; return false }
        out.append(("one row per remembered app", appRows.count == 2))
        out.append(("…named after the app, not the scheme", appRows.first?.title == "Can Open Zoom"))
        out.append(("…and saying which links it takes",
                    appRows.first?.note == "Always opens zoommtg: links from this site."))
        out.append(("…as a switch that is on, because the only thing it can do is be taken back",
                    appRows.allSatisfy { $0.control == .toggle(true) && !$0.inert }))
        out.append(("…in the order the store hands them over, so the rows do not shuffle",
                    appRows.map(\.title) == ["Can Open Zoom", "Can Open Microsoft Teams"]))
        out.append(("…and they sit above Clear Site Data, which is still the last thing but one",
                    opens.rows.dropLast().last?.id == .clearData))
        out.append(("a scheme nothing claims any more is still listed, so it can be removed",
                    { var orphan = opens
                      orphan.apps = [SiteControlModel.App(scheme: "zoommtg", name: "zoommtg")]
                      return orphan.rows.contains { $0.title == "Can Open zoommtg" } }()))

        // The Settings section shows only what this site has an answer for.
        out.append(("a fresh site shows Developer Mode and nothing else",
                    m.settings.map(\.id) == [.developer]))
        var answered = opens
        answered.camera = true
        answered.popups = false
        answered.zoom = 1.25
        answered.blocking = false
        let shown = answered.settings
        out.append(("…an answered permission appears, allowed or blocked",
                    shown.first { $0.id == .camera }?.value == "Allowed"
                        && shown.first { $0.id == .popups }?.value == "Blocked"))
        out.append(("…an unanswered one does not", !shown.contains { $0.id == .microphone }))
        out.append(("…zoom appears once it is off 100%", shown.contains { $0.id == .zoom }))
        out.append(("…ad blocking once it is off for the site", shown.first { $0.id == .blocker }?.value == "Off"))
        out.append(("…and each app the site may open", shown.filter { if case .app = $0.id { true } else { false } }.count == 2))
        var once = m
        once.camera = true
        once.cameraOnce = true
        out.append(("a one-time answer says so", once.settings.first { $0.id == .camera }?.value == "Allowed Once"))
        out.append(("nothing loaded has no settings", SiteControlModel().settings.isEmpty))

        // Clearing site data, scoped.
        out.append(("a site's own record is cleared",
                    SiteControlModel.covers(record: "example.com", host: "example.com")))
        out.append(("a subdomain is covered by its registrable domain's record",
                    SiteControlModel.covers(record: "example.com", host: "news.example.com")))
        out.append(("a host that merely ends the same way is not",
                    !SiteControlModel.covers(record: "example.com", host: "notexample.com")))
        out.append(("a different site's record is left alone",
                    !SiteControlModel.covers(record: "other.example", host: "example.com")))
        out.append(("matching is case-insensitive, the way hosts are",
                    SiteControlModel.covers(record: "Example.COM", host: "NEWS.example.com")))
        out.append(("an empty record matches nothing, rather than everything",
                    !SiteControlModel.covers(record: "", host: "example.com")))
        out.append(("an empty host clears nothing",
                    !SiteControlModel.covers(record: "example.com", host: "")))
        return out
    }
}

// MARK: - The popover

/// Arc's layout at Arc's width: action tiles, the extensions as tiles, a Settings list whose
/// permissions fold away, and a footer with the connection and a ··· menu. It sits on the
/// popover's own translucent material, so every fill is `Look` ink rather than a ground.
struct SiteControlPopover: View {
    @ObservedObject var tab: Tab
    /// Redraws when a setting changes rather than the tab — see `SiteChanges`.
    @ObservedObject private var changes = SiteChanges.shared
    /// Site Settings: every setting this site has, one page in from the summary.
    @State private var allSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = SiteControlModel(tab)
        // One snapshot, taken where the model was built and handed to every tile: the model's
        // `.ext(i)` indexes into *this* list, and re-reading it at click time would let an
        // extension that finished loading in between renumber the tiles under the pointer.
        let contexts = SiteControl.contexts(on: tab)
        let rows = model.rows
        ZStack(alignment: .top) {
            if model.siteless {
                Text("There is nothing to control on this page.")
                    .font(Look.caption)
                    .foregroundStyle(Look.inkQuiet)
                    .padding(Look.rowInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if allSettings {
                siteSettings(model, rows: rows)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(alignment: .leading, spacing: Look.rowGap) {
                    tiles(rows)
                    extensions(rows, contexts: contexts)
                    section("Settings")
                    ForEach(model.settings) { SettingItem(setting: $0, tab: tab) }
                    Divider().padding(.horizontal, Look.captionGap).padding(.vertical, Look.captionGap)
                    footer(model, rows: rows)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(Look.inset)
        .frame(width: Look.siteWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Site Control Center")
        .accessibilityValue(model.siteless ? "No page loaded" : "\(model.title), \(model.connection)")
        // An extension turned on or removed from here redraws the tiles.
        .onReceive(tab.extensions.objectWillChange) { _ in Task { @MainActor in SiteChanges.shared.bump() } }
        .vaneMotionPolicy()
    }

    private func show(allSettings: Bool) {
        withAnimation(Motion.reduced ? nil : Look.quick) { self.allSettings = allSettings }
    }

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Look.siteTileGap), count: 4)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Look.heading).foregroundStyle(Look.inkPrimary)
            .padding(.horizontal, Look.captionGap).padding(.top, Look.captionGap)
            .accessibilityAddTraits(.isHeader)
    }

    /// Run a row's action after the popover has gone, for the ones that open a window or
    /// take over the page.
    private func afterDismiss(_ id: SiteControlModel.RowID) {
        dismiss()
        Task { @MainActor in SiteControl.act(id, on: tab) }
    }

    /// Arc's four: Share, Boost, Capture, Reader.
    private func tiles(_ rows: [SiteControlModel.Row]) -> some View {
        let row = { (id: SiteControlModel.RowID) in rows.first { $0.id == id } }
        return LazyVGrid(columns: grid, spacing: Look.siteTileGap) {
            ShareTile(tab: tab)
            if let boost = row(.boost) {
                SiteTile(glyph: "paintbrush.pointed", label: boost.title, help: boost.title,
                         on: tab.currentURL.flatMap(SiteBoosts.origin).map { SiteBoosts.value(origin: $0, tab: tab) != SiteBoost() } ?? false,
                         inert: false, dark: true) { afterDismiss(.boost) }
            }
            if let capture = row(.capture) {
                SiteTile(glyph: "camera", label: capture.title, help: capture.title,
                         on: false, inert: false, dark: true) { afterDismiss(.capture) }
            }
            if let reader = row(.reader) {
                SiteTile(glyph: "text.viewfinder", label: reader.title, help: reader.note ?? reader.title,
                         on: reader.control == .toggle(true), inert: reader.inert, dark: true) {
                    SiteControl.act(.reader, on: tab)
                }
            }
        }
    }

    @ViewBuilder
    private func extensions(_ rows: [SiteControlModel.Row], contexts: [WKWebExtensionContext]) -> some View {
        let installable = tab.extensions.profileID != Profile.incognito.id
        let extRows = rows.filter { if case .ext = $0.id { true } else { false } }
        if !extRows.isEmpty || installable {
            section("Extensions")
            LazyVGrid(columns: grid, spacing: Look.siteTileGap) {
                ForEach(extRows) { row in
                    if case .ext(let i) = row.id, contexts.indices.contains(i) {
                        ExtensionTile(row: row, tab: tab, context: contexts[i])
                    }
                }
                // Installed but not running: turned off, or waiting on a fix. Every extension in
                // the profile has a tile, not only the ones that happen to be loaded.
                if installable {
                    ForEach(tab.extensions.inactive) { entry in
                        OffExtensionTile(host: tab.extensions, entry: entry, store: VanePages.store(of: tab))
                    }
                    SiteTile(glyph: "plus", label: "Add Extension", help: "Find extensions in the Chrome Web Store",
                             on: false, inert: false) { addExtension() }
                }
            }
        }
    }

    /// Arc's +: the store, in a tab, where Add to Chrome installs into Vane.
    private func addExtension() {
        dismiss()
        // The tab's own window, or another of its profile's: Add to Chrome installs into
        // whichever profile the store page is open in, and never a private one.
        let profile = tab.profileID
        let ok = { (store: TabStore) in store.profileID == profile && !store.isPrivate && store.window != nil }
        let store = PageTranslation.store(of: tab)
            ?? Windows.current.flatMap { ok($0) ? $0 : nil }
            ?? TabStore.all.first(where: ok)
        Task { @MainActor in store?.newTab(URL(string: "https://chromewebstore.google.com/")) }
    }

    private func footer(_ model: SiteControlModel, rows: [SiteControlModel.Row]) -> some View {
        HStack(spacing: Look.rowSpacing) {
            if model.insecure || model.glyph == "lock" {
                Label(model.insecure ? "Not Secure" : "Secure", systemImage: model.glyph)
                    .font(Look.caption.weight(.semibold))
                    .foregroundStyle(model.insecure ? Look.warning : Look.inkSecondary)
                    .padding(.horizontal, Look.rowInset).padding(.vertical, Look.captionGap * 3)
                    .background(model.insecure ? Look.warning.opacity(0.15) : Look.controlFill,
                                in: .rect(cornerRadius: Look.pillRadius))
                    .help(model.connection)
                    .accessibilityLabel(model.connection)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Clear Site Data…") { afterDismiss(.clearData) }
                Divider()
                if let translate = rows.first(where: { $0.id == .translate }) {
                    Button(translate.control == .toggle(true) ? "Show Original" : "Translate Page") {
                        SiteControl.act(.translate, on: tab)
                    }
                }
                if let offers = rows.first(where: { $0.id == .translateOffers }), case .toggle(let on) = offers.control {
                    Toggle("Offer to Translate", isOn: Binding(get: { on }, set: { _ in SiteControl.act(.translateOffers, on: tab) }))
                }
                if let chrome = rows.first(where: { $0.id == .actAsChrome }), !chrome.inert, case .toggle(let on) = chrome.control {
                    Toggle("Act as Chrome", isOn: Binding(get: { on }, set: { _ in SiteControl.act(.actAsChrome, on: tab) }))
                }
                Divider()
                Button("Manage Extensions…") {
                    dismiss()
                    let host = tab.extensions, store = VanePages.store(of: tab)
                    ExtensionMenu.afterMenu { ExtensionManagement.openPage(for: host, from: store) }
                }
                if tab.extensions.profileID != Profile.incognito.id {
                    Button("Add Extension…") { addExtension() }
                }
                Divider()
                Button("Filter Lists and Diagnostics…") { afterDismiss(.blockerSettings) }
                Button("Site Settings…") { show(allSettings: true) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(Look.inkPrimary)
            .frame(width: Look.siteTile, height: Look.siteTile)
            .background(Look.controlFill, in: .circle)
            .help("More Site Actions")
            .accessibilityLabel("More Site Actions")
        }
    }

    /// Every setting this site has, as rows with their controls, one page in.
    private func siteSettings(_ model: SiteControlModel, rows: [SiteControlModel.Row]) -> some View {
        let shown: Set<SiteControlModel.RowID> = [.camera, .microphone, .location, .popups, .notifications, .pictureInPicture,
                                                  .zoom, .blocker, .translateOffers, .actAsChrome, .developer]
        return VStack(alignment: .leading, spacing: 0) {
            Button { show(allSettings: false) } label: {
                HStack(spacing: Look.rowSpacing) {
                    Image(systemName: "chevron.left").font(Look.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Site Settings").font(Look.heading).foregroundStyle(Look.inkPrimary)
                        Text(model.title).font(Look.caption).foregroundStyle(Look.inkTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Look.captionGap).padding(.bottom, Look.inset)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            ForEach(rows.filter { row in
                if case .app = row.id { return true }
                return shown.contains(row.id)
            }) { SiteControlRow(row: $0, tab: tab) }
        }
    }
}

/// One entry in the Settings section: Arc's disc with a glyph, the setting's name, and its
/// state under it. A click flips it; a permission's right-click offers all three answers.
private struct SettingItem: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let setting: SiteControlModel.Setting
    let tab: Tab
    @State private var hovering = false

    private var kind: SitePermissions.Kind? {
        switch setting.id {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .popups: .popups
        case .notifications: .notifications
        default: nil
        }
    }

    /// The glyph on an "on" disc: the ink's opposite, so it reads on the dark disc in light
    /// mode as well as the light one in dark mode.
    private static let onGlyph = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.75) : NSColor(white: 1, alpha: 0.9)
    })

    var body: some View {
        Button(action: flip) {
            HStack(spacing: Look.rowSpacing) {
                Image(systemName: setting.glyph).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(setting.on ? Self.onGlyph : Look.inkPrimary)
                    .frame(width: Look.siteDisc, height: Look.siteDisc)
                    .background(setting.on ? Look.ink(0.9) : Look.ink(0.16), in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(setting.title).font(Look.heading).foregroundStyle(Look.inkPrimary).lineLimit(1)
                    Text(setting.value).font(Look.caption).foregroundStyle(Look.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Look.captionGap * 2)
            .background(hovering ? chromeTheme.hovered : .clear, in: .rect(cornerRadius: Look.pillRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovering)
        .animation(Motion.reduced ? nil : Look.quick, value: setting)
        .contextMenu {
            if let kind {
                Button("Ask") { SiteControl.set(kind, to: nil, on: tab) }
                Button("Allow") { SiteControl.set(kind, to: true, on: tab) }
                Button("Block") { SiteControl.set(kind, to: false, on: tab) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(setting.title)
        .accessibilityValue(setting.value)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if let kind {
                Button("Ask") { SiteControl.set(kind, to: nil, on: tab) }
                Button("Allow") { SiteControl.set(kind, to: true, on: tab) }
                Button("Block") { SiteControl.set(kind, to: false, on: tab) }
            }
        }
    }

    /// A permission swaps Allowed and Blocked; everything else does what its row did.
    private func flip() {
        if let kind { return SiteControl.set(kind, to: !setting.on, on: tab) }
        SiteControl.act(setting.id, on: tab)
    }
}

/// A square in the popover's grids: an SF Symbol on a fill, brighter when its state is on.
private struct SiteTile: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let glyph: String
    let label: String
    let help: String
    let on: Bool
    let inert: Bool
    /// Arc's top row sits darker than the popover; its extension tiles sit lighter.
    var dark = false
    let action: () -> Void
    @State private var hovering = false

    private var fill: Color {
        if on { return chromeTheme.selected }
        if dark { return Color.black.opacity(hovering ? 0.32 : 0.45) }
        return hovering ? chromeTheme.hovered : chromeTheme.controlFill
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph).font(.system(size: 16))
                .frame(maxWidth: .infinity, minHeight: Look.siteTile)
                .background(fill, in: .rect(cornerRadius: Look.pillRadius))
                .overlay { if dark { RoundedRectangle(cornerRadius: Look.pillRadius).strokeBorder(Look.ink(0.08)) } }
                .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle())
        .foregroundStyle(inert ? Look.inkDisabled : Look.inkPrimary)
        .disabled(inert)
        .onHover { hovering = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovering)
        .animation(Motion.reduced ? nil : Look.quick, value: on)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "")
    }
}

/// The system share sheet, anchored to its own tile.
private struct ShareTile: View {
    let tab: Tab
    @StateObject private var anchor = ActionAnchor()

    var body: some View {
        SiteTile(glyph: "square.and.arrow.up", label: "Share", help: "Share…", on: false, inert: false, dark: true) {
            guard let url = tab.currentURL, let view = anchor.view else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        .actionAnchor(anchor)
    }
}

/// An extension's action as a tile. A click runs it; a right-click is Arc's extension menu.
private struct ExtensionTile: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @Environment(\.dismiss) private var dismiss
    let row: SiteControlModel.Row
    let tab: Tab
    let context: WKWebExtensionContext
    @StateObject private var anchor = ActionAnchor()
    @State private var hovering = false

    var body: some View {
        let host = tab.extensions
        let pinned = host.isPinned(context)
        Button {
            guard !row.dim else { return }
            host.run(context, for: tab, from: anchor.view)
        } label: {
            ActionIcon(host: host, context: context, tab: tab, badge: row.badge)
                .opacity(row.dim ? Look.dimmed : 1)
                .frame(maxWidth: .infinity, minHeight: Look.siteTile)
                .background(hovering && !row.dim ? chromeTheme.hovered : chromeTheme.controlFill,
                            in: .rect(cornerRadius: Look.pillRadius))
                .overlay(alignment: .bottomTrailing) {
                    if pinned {
                        // Arc's pin: a small light disc on the tile's corner.
                        Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.7))
                            .frame(width: 14, height: 14)
                            .background(Look.ink(0.85), in: .circle)
                            .offset(x: -6, y: 4)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle())
        .actionAnchor(anchor)
        .onHover { hovering = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovering)
        .contextMenu { ExtensionMenu(host: host, context: context, tab: tab, leave: { dismiss() }) }
        .help(row.note.map { "\(row.title) — \($0)" } ?? row.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue([row.badge.map { "Badge \($0)" },
                             row.control == .toggle(true) ? "Allowed on this site" : "Not allowed on this site",
                             row.dim ? "Unavailable on this page" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(row.dim ? "" : "Runs this extension here. More actions are in its context menu.")
        .accessibilityActions { ExtensionMenu(host: host, context: context, tab: tab, leave: { dismiss() }).accessibility }
    }
}

/// An installed extension that is not running. Drawn dim; a click turns it back on.
private struct OffExtensionTile: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @Environment(\.dismiss) private var dismiss
    let host: ExtensionHost
    let entry: ExtensionHost.Inactive
    /// The popover's window, where Manage Extension opens its tab.
    let store: TabStore?

    var body: some View {
        Button { entry.needsAttention ? manage() : turnOn() } label: {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "puzzlepiece.extension").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Look.rowIcon, height: Look.rowIcon)
            .saturation(0).opacity(Look.dimmed)
            .frame(maxWidth: .infinity, minHeight: Look.siteTile)
            .background(chromeTheme.controlFill, in: .rect(cornerRadius: Look.pillRadius))
            .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(entry.busy)
        .contextMenu { menu }
        .help("\(entry.name) — " + state + (entry.busy || entry.needsAttention ? "" : ". Click to turn it on."))
        .accessibilityLabel(entry.name)
        .accessibilityValue(state)
        .accessibilityHint(entry.busy ? "" : entry.needsAttention ? "Opens it in Extensions." : "Turns this extension on.")
        .accessibilityActions { menu }
    }

    @ViewBuilder private var menu: some View {
        if !entry.needsAttention { Button("Turn On", action: turnOn) }
        Button("Remove from Vane…") {
            dismiss()
            let host = host, entry = entry
            ExtensionMenu.afterMenu { ExtensionMenu.confirmRemoval(name: entry.name) { host.remove(path: entry.path) } }
        }
        Button("Manage Extension…", action: manage)
    }

    private var state: String { entry.busy ? "Loading…" : entry.needsAttention ? "Needs attention" : "Off" }

    private func turnOn() {
        let host = host, path = entry.path
        Task { await host.enable(path: path) }
    }

    private func manage() {
        dismiss()
        let host = host, path = entry.path, store = store
        ExtensionMenu.afterMenu { ExtensionManagement.openPage(for: host, selecting: path, from: store) }
    }
}

/// Arc's right-click menu for an extension, in the popover and on the address bar alike.
/// `leave` runs before anything that opens a window — the popover passes its dismiss.
struct ExtensionMenu: View {
    let host: ExtensionHost
    let context: WKWebExtensionContext
    let tab: Tab?
    var leave: () -> Void = {}

    var body: some View {
        Text(name)
        Divider()
        if let access {
            Toggle("Can Read and Change This Site", isOn: Binding(get: { access }, set: { _ in toggleAccess() }))
            Divider()
        }
        actions
    }

    /// The menu as VoiceOver actions: buttons only, since a Toggle or a Text in
    /// `accessibilityActions` is dropped rather than published.
    @ViewBuilder var accessibility: some View {
        if let access {
            Button(access ? "Deny Access to This Site" : "Allow Access to This Site", action: toggleAccess)
        }
        actions
    }

    @ViewBuilder private var actions: some View {
        if context.optionsPageURL != nil {
            Button("Options") {
                leave()
                let host = host, context = context
                Trace.note("options chosen")
                ExtensionMenu.afterMenu {
                    Task { @MainActor in
                        do { try await host.webExtensionController(host.controller, openOptionsPageFor: context) }
                        catch { NSLog("[vane] extension options did not open: %@", error.localizedDescription) }
                    }
                }
            }
        }
        let pinned = host.isPinned(context)
        let full = !pinned && !host.canPin
        Button(full ? "Address Bar Is Full — \(ExtensionPins.cap) Pinned"
                    : pinned ? "Unpin from Address Bar" : "Pin to Address Bar") {
            host.togglePin(context)
        }
        .disabled(full)
        if host.profileID != Profile.incognito.id {
            Button("Remove from Vane…") {
                leave()
                let host = host, context = context, name = name
                ExtensionMenu.afterMenu { ExtensionMenu.confirmRemoval(name: name) { host.remove(context) } }
            }
        }
        Divider()
        Button("Manage Extension…") {
            leave()
            let host = host, path = host.path(of: context), store = tab.flatMap(VanePages.store(of:))
            ExtensionMenu.afterMenu { ExtensionManagement.openPage(for: host, selecting: path, from: store) }
        }
    }

    /// What an item opens waits for the menu to be gone. A `Task` is not enough: Dispatch's
    /// main queue also runs inside AppKit's menu tracking loop, where building a window and
    /// its web view held the menu on screen, highlighted, until that work was done. Default
    /// mode resumes only once tracking has ended.
    static func afterMenu(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { work() } }
        // perform does not wake a sleeping run loop by itself.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private var name: String { context.webExtension.displayName ?? "Extension" }

    /// Whether it may see this tab's site; nil when there is no site to ask about.
    private var access: Bool? {
        guard let url = tab?.currentURL, url.host() != nil else { return nil }
        return context.hasAccess(to: url)
    }

    private func toggleAccess() {
        guard let tab else { return }
        SiteControl.toggleAccess(context, on: tab)
        SiteChanges.shared.bump()
    }

    /// The same question the Extensions window asks before removing one.
    static func confirmRemoval(name: String, remove: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)” from this profile?"
        alert.informativeText = "This removes the installation, its approval, and toolbar pin. Your original source folder is kept. Reinstalling creates a new extension identity and cannot restore its old settings."
        alert.addButton(withTitle: "Remove Extension").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remove()
    }
}

/// One Settings or Permissions row: glyph, title, and whatever control the model asked for.
/// The whole row is the hit target, the way the sidebar's rows are — a 20pt switch is not
/// something anyone should have to aim at. At this width a note is a tooltip unless it is
/// the reason the row is greyed or a one-time answer that ends by itself.
private struct SiteControlRow: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let row: SiteControlModel.Row
    let tab: Tab
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inlineNote: String? {
        guard let note = row.note, row.inert || note.hasPrefix("Allowed once") else { return nil }
        return note
    }

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: row.glyph).font(Look.symbol)
                .frame(width: Look.rowIcon, height: Look.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Look.captionGap) {
                // Shrinks a little before truncating: "Notifications" beside a picker.
                Text(row.title).font(Look.rowTitle).lineLimit(1).minimumScaleFactor(0.85)
                if let note = inlineNote {
                    Text(note).font(Look.caption).foregroundStyle(Look.inkQuiet)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Look.rowGap)
            control
        }
        .foregroundStyle(row.inert ? Look.inkDisabled : Look.inkPrimary)
        .padding(.horizontal, Look.rowInset)
        .padding(.vertical, Look.rowPadding)
        .frame(minHeight: Look.rowHeight)
        .background(hovering && !row.inert ? chromeTheme.hovered : .clear,
                    in: .rect(cornerRadius: Look.pillRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .animation(Motion.reduced ? nil : Look.quick, value: row.control)
        .contentShape(.rect)
        .onHover { hovering = $0 && !row.inert }
        .onTapGesture { if !row.inert { SiteControl.act(row.id, on: tab) } }
        .help(row.note ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(axValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hint)
        .accessibilityActions {
            // The stepper's own buttons are inside an element VoiceOver is told to ignore,
            // so its two actions have to be published by the row itself — otherwise the
            // only zoom a screen reader can reach is the row's tap, which is Actual Size.
            if case .zoom = row.control {
                Button("Zoom In") { Zoom.zoomIn(tab); SiteChanges.shared.bump() }
                Button("Zoom Out") { Zoom.zoomOut(tab); SiteChanges.shared.bump() }
            }
        }
    }

    private var hint: String {
        if case .zoom = row.control {
            return "Resets the page to actual size. Zoom In and Zoom Out are also available."
        }
        return row.note ?? ""
    }

    @ViewBuilder private var control: some View {
        switch row.control {
        case .toggle(let on):
            Toggle("", isOn: Binding(get: { on }, set: { _ in SiteControl.act(row.id, on: tab) }))
                // A switch, not the checkbox a bare `Toggle` renders as in a popover: this
                // is a setting that takes effect as it is flipped, not a box on a form.
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).disabled(row.inert)
                .accessibilityHidden(true)          // the row already reads as a button
        case .permission(let answer):
            Picker("", selection: Binding(
                get: { PermissionAnswer(answer) },
                set: { answer in
                    let type: SitePermissions.Kind = switch row.id {
                    case .camera: .camera
                    case .location: .location
                    case .popups: .popups
                    case .notifications: .notifications
                    default: .microphone
                    }
                    SiteControl.set(type, to: answer.value, on: tab)
                })) {
                ForEach(PermissionAnswer.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            .accessibilityHidden(true)
        case .zoom(let label):
            HStack(spacing: Look.stepGap) {
                StepButton(glyph: "minus") { Zoom.zoomOut(tab); SiteChanges.shared.bump() }
                Text(label).font(Look.caption).monospacedDigit()
                    .frame(width: Look.stepLabel)
                    .accessibilityHidden(true)
                StepButton(glyph: "plus") { Zoom.zoomIn(tab); SiteChanges.shared.bump() }
            }
        case .action:
            Image(systemName: "chevron.right").font(Look.caption)
                .foregroundStyle(Look.inkQuiet).accessibilityHidden(true)
        }
    }

    private var axValue: String {
        switch row.control {
        case .toggle(let on):        on ? "On" : "Off"
        case .permission(let a):     PermissionAnswer(a).title
        case .zoom(let label):       label
        case .action:                ""
        }
    }
}


/// −/+ beside the zoom label. A plain glyph on a fill, sized like a settings control.
private struct StepButton: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let glyph: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(Look.caption)
                .frame(width: Look.step, height: Look.step)
                .background(chromeTheme.controlFill, in: .rect(cornerRadius: Look.chipRadius))
                .contentShape(.rect)
        }
        .buttonStyle(CompactControlStyle(size: Look.step))
        .accessibilityLabel(glyph == "plus" ? "Zoom In" : "Zoom Out")
    }
}

/// The three answers a permission has, as a picker can hold them. `Bool?` cannot be a
/// `Picker` tag on its own — `nil` is not `Hashable` as a selection — and naming the third
/// state is the point anyway.
private enum PermissionAnswer: String, CaseIterable, Identifiable {
    case ask, allow, block
    var id: String { rawValue }

    init(_ value: Bool?) {
        switch value {
        case .some(true):  self = .allow
        case .some(false): self = .block
        case nil:          self = .ask
        }
    }

    var value: Bool? {
        switch self {
        case .ask:   nil
        case .allow: true
        case .block: false
        }
    }

    var title: String {
        switch self {
        case .ask:   "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }
}
