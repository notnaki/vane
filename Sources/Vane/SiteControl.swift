import AppKit
import SwiftUI
import WebKit

// MARK: - The model

/// Arc's Site Control Center: everything this browser can be told about *one site*, in one
/// popover hanging off the address pill's site glyph. Before it, the glyph opened the whole
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
    }

    /// Empty for anything with no site to control: nothing loaded, a file, about:blank.
    var host = ""
    var scheme: String?
    var secureContent = true
    var certificateTrusted = true
    /// nil is not "off": it means this site has never been answered, so it will be asked.
    var camera: Bool?
    var microphone: Bool?
    var pictureInPicture = false
    var zoom = 1.0
    var blocking = true
    var reader = false
    var readerAvailable = false
    var extensions: [Ext] = []
    var developer = false
}

extension SiteControlModel {

    /// Which row, so the view can act on one without matching on its title.
    enum RowID: Hashable, Sendable {
        case camera, microphone, pictureInPicture, zoom, blocker, reader, clearData, developer
        /// The index into `extensions`, which is also the index into the host's contexts.
        case ext(Int)
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
        if siteless { return "globe" }
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
            Row(id: .camera, title: "Camera", glyph: "camera", control: .permission(camera)),
            Row(id: .microphone, title: "Microphone", glyph: "mic",
                control: .permission(microphone)),
            // ponytail: no Notifications row. WKWebView has no web-notification permission
            // hook on macOS — nothing asks, so there is nothing to remember and nothing to
            // switch, and a dead toggle is a promise Vane cannot keep. Upgrade path the day
            // WebKit exposes one: a third `.permission` row keyed exactly like these two.
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
                // Honest rather than flattering: Vane's blocker is one compiled rule list
                // attached per profile, so there is no per-site answer to give here.
                note: "Every site in this profile."),
            Row(id: .reader, title: "Reader Mode", glyph: "doc.plaintext",
                control: .toggle(reader),
                note: reader || readerAvailable ? nil : "This page has no article to read.",
                inert: !(reader || readerAvailable)),
        ]
        for (i, ext) in extensions.enumerated() {
            out.append(Row(id: .ext(i), title: ext.name, glyph: "puzzlepiece.extension",
                           control: .toggle(ext.allowed)))
        }
        out.append(Row(id: .clearData, title: "Clear Site Data…", glyph: "trash",
                       control: .action))
        out.append(Row(id: .developer, title: "Developer Mode", glyph: "hammer",
                       control: .toggle(developer),
                       note: "Web Inspector for this tab."))
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
        camera = SitePermissions.effective(host: h, type: .camera)
        microphone = SitePermissions.effective(host: h, type: .microphone)
        pictureInPicture = tab.pictureInPicture
        zoom = tab.zoom
        blocking = Blocker.enabled(for: tab.profileID)
        reader = Reader.isOn(tab)
        readerAvailable = tab.readerAvailable
        extensions = tab.extensions.installed.map {
            Ext(name: $0.webExtension.displayName ?? "Extension", allowed: $0.hasAccess(to: url))
        }
        developer = tab.web.isInspectable
    }
}

/// What makes the pill and the popover redraw when a *setting* changes rather than the tab.
///
/// ponytail: one bump off `UserDefaults.didChangeNotification` instead of a publisher in
/// each of the five files that own a setting. Every per-site answer in Vane is a
/// UserDefaults write, so this catches the modal camera prompt granting a permission from
/// under the sidebar as well as the popover's own switches. Upgrade path if the notification
/// ever becomes hot: an explicit `bump()` from each writer, which is already wired here for
/// the extension toggles (they are not defaults-backed).
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
        case .camera:     cycle(.camera, host: host)
        case .microphone: cycle(.microphone, host: host)
        case .pictureInPicture: PictureInPicture.toggle(tab)
        case .zoom: Zoom.reset(tab)
        case .blocker: Blocker.setEnabled(!Blocker.enabled(for: tab.profileID), for: tab.profileID)
        case .reader: Reader.toggle(tab)
        case .ext(let i): toggleExtension(i, on: tab)
        case .clearData: clearSiteData(host: host, tab: tab)
        case .developer: setDeveloper(!tab.web.isInspectable, on: tab)
        }
        SiteChanges.shared.bump()
    }

    /// The permission row's own control is a picker; this is what a click on the row body
    /// does, so the keyboard and VoiceOver have a route that is not a menu.
    private static func cycle(_ type: WKMediaCaptureType, host: String) {
        let current = SitePermissions.effective(host: host, type: type)
        set(type, to: current == nil ? true : (current == true ? false : nil), host: host)
    }

    static func set(_ type: WKMediaCaptureType, to answer: Bool?, host: String) {
        guard !host.isEmpty else { return }
        SitePermissions.set(host: host, type: type, answer: answer)
        SiteChanges.shared.bump()
    }

    /// Per-site extension access, flipped from what this extension can see right now.
    /// WebKit turns the url into a match pattern for us, so "allow this extension here" is
    /// one call and does not need a pattern built by hand.
    static func toggleExtension(_ index: Int, on tab: Tab) {
        let contexts = tab.extensions.installed
        guard contexts.indices.contains(index), let url = tab.currentURL else { return }
        let allowed = !contexts[index].hasAccess(to: url)
        contexts[index].setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly,
                                            for: url)
    }

    /// Web Inspector for this tab only. `Settings.inspectorEnabled` is the global default
    /// this starts from; flipping it here is deliberately not written back, so turning the
    /// inspector on for one page does not turn it on for the whole browser.
    ///
    /// Both halves, because they are different switches: `isInspectable` opens the view to
    /// Safari's Develop menu, while "Inspect Element" and the in-app inspector window are
    /// gated on the `developerExtrasEnabled` preference — the same KVC hop
    /// `Tab.configuration` makes, and the reason setting only the first did nothing
    /// visible. It takes effect on the live page, with no reload.
    ///
    /// ponytail: the intent lives on the web view, not on the Tab, so suspending the tab
    /// or changing the global setting (which rebuild or re-apply to the view) puts it back
    /// to `Settings.inspectorEnabled`. Upgrade path: a `developerMode: Bool?` on Tab that
    /// `attach()` re-applies, which is a field, a line in `attach`, and a line here.
    static func setDeveloper(_ on: Bool, on tab: Tab) {
        tab.web.isInspectable = on
        tab.web.configuration.preferences.setValue(on, forKey: "developerExtrasEnabled")
    }

    /// Cookies, storage and caches belonging to this host, and the answers Vane itself is
    /// keeping about it. Scoped by `WKWebsiteDataRecord`, which is the finest grain WebKit
    /// offers — a registrable domain, so clearing `news.example.com` also clears
    /// `example.com`. The alert says so; it is not something to do quietly.
    static func clearSiteData(host: String, tab: Tab) {
        guard !host.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the data “\(host)” has stored?"
        alert.informativeText = "Cookies, local storage and cached files for this site and its "
            + "subdomains go, and you will be signed out of it. Vane also forgets the camera, "
            + "microphone and zoom answers you gave this site, any certificate warning you "
            + "clicked through for it, and its exemption from HTTPS-only mode. History and "
            + "passwords are not touched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SitePermissions.reset(host: host)
        Zoom.forget(host: host, profile: tab.profileID)
        // The header advertises both of these — "a certificate problem was accepted here",
        // and http that HTTPS-only was told to allow. Clearing a site cannot leave standing
        // the two decisions that made it less safe than the others.
        CertificateTrust.forget(host: host)
        HTTPSOnly.forget(host: host, profileID: tab.profileID)
        done(host)

        let store = tab.web.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { SiteControlModel.covers(record: $0.displayName, host: host) }
            guard !mine.isEmpty else { return }
            // `assumeIsolated` would trap here: WebKit does not promise this completion a
            // queue, and a fetch that lands off the main one would take the app with it.
            store.removeData(ofTypes: types, for: mine) { Task { @MainActor in done(host) } }
        }
    }

    /// Said once when the answers go and again when WebKit's records follow, because the
    /// two land seconds apart and a site with no stored data at all never reaches the
    /// second — the user still cleared something, and still has to hear so.
    private static func done(_ host: String) {
        axAnnounce("Cleared the data stored by \(host).")
        SiteChanges.shared.bump()
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
        out.append(("the ad blocker row admits it is not per site",
                    m.rows.first { $0.id == .blocker }?.note?.lowercased()
                        .contains("every site in this profile") == true))
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

        // Developer mode.
        out.append(("developer mode is off by default in the model", control(m, .developer) == .toggle(false)))
        var dev = m
        dev.developer = true
        out.append(("…and reads as on when the tab is inspectable", control(dev, .developer) == .toggle(true)))

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

/// ~300pt of flat rows hanging off the pill's site glyph. No blur and no material: it is a
/// panel of controls, and every fill in it comes from `Look` like the sidebar's do.
struct SiteControlPopover: View {
    @ObservedObject var tab: Tab
    /// Redraws when a setting changes rather than the tab — see `SiteChanges`.
    @ObservedObject private var changes = SiteChanges.shared

    var body: some View {
        let model = SiteControlModel(tab)
        VStack(alignment: .leading, spacing: Look.rowGap) {
            header(model)
            if model.siteless {
                Text("There is nothing to control on this page.")
                    .font(Look.caption)
                    .foregroundStyle(Look.inkQuiet)
                    .padding(.horizontal, Look.rowInset)
                    .padding(.bottom, Look.inset)
            } else {
                ForEach(model.rows) { row in
                    SiteControlRow(row: row, tab: tab, host: model.host)
                }
            }
        }
        .padding(Look.inset)
        .frame(width: Look.siteWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Site Control Center")
        .accessibilityValue(model.siteless ? "No page loaded" : "\(model.title), \(model.connection)")
    }

    private func header(_ model: SiteControlModel) -> some View {
        HStack(spacing: Look.rowSpacing) {
            Group {
                if let icon = tab.favicon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: model.glyph).resizable().foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: Look.rowIcon, height: Look.rowIcon)
            VStack(alignment: .leading, spacing: Look.captionGap) {
                Text(model.siteless ? "This Page" : model.title)
                    .font(Look.heading).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(model.connection)
                    .font(Look.caption)
                    .foregroundStyle(model.insecure ? Look.warning : Look.inkTertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.rowInset)
        .padding(.vertical, Look.inset)
        .accessibilityElement(children: .combine)
    }
}

/// One row: glyph, title, an optional second line, and whatever control the model asked for.
/// The whole row is the hit target, the way the sidebar's rows are — a 20pt switch is not
/// something anyone should have to aim at.
private struct SiteControlRow: View {
    let row: SiteControlModel.Row
    let tab: Tab
    /// Only for the permission picker, which names the site it is answering for. Every
    /// other action reads the state it is flipping at click time — see `SiteControl.act`.
    let host: String
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A modal alert must not open over a live popover, so Clear Site Data closes this
    /// first and runs on the next turn of the loop.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: Look.rowSpacing) {
            Image(systemName: row.glyph)
                .font(Look.symbol)
                .frame(width: Look.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Look.captionGap) {
                Text(row.title).font(Look.rowTitle).lineLimit(1)
                if let note = row.note {
                    Text(note).font(Look.caption).foregroundStyle(Look.inkQuiet)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Look.rowGap)
            control
        }
        .foregroundStyle(row.inert ? Look.inkDisabled : Look.inkPrimary)
        .padding(.horizontal, Look.rowInset)
        .padding(.vertical, Look.rowPadding)
        .frame(minHeight: Look.rowHeight)
        .background(hovering && !row.inert ? Look.hovered : .clear,
                    in: .rect(cornerRadius: Look.pillRadius))
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 && !row.inert }
        .onTapGesture(perform: press)
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

    private func press() {
        guard !row.inert else { return }
        guard case .action = row.control else { return SiteControl.act(row.id, on: tab) }
        dismiss()
        Task { @MainActor in SiteControl.act(row.id, on: tab) }
    }

    /// What the row is about to do, when that is not obvious from its title — and, on the
    /// two rows that do something a tap cannot be taken back from, what it costs.
    private var hint: String {
        switch row.control {
        case .zoom:   "Resets the page to actual size. Zoom In and Zoom Out are also available."
        case .action: "Signs you out of this site and forgets what it stored. This cannot be undone."
        default:      row.note ?? ""
        }
    }

    @ViewBuilder private var control: some View {
        switch row.control {
        case .toggle(let on):
            Toggle("", isOn: Binding(get: { on },
                                     set: { _ in SiteControl.act(row.id, on: tab) }))
                // A switch, not the checkbox a bare `Toggle` renders as in a popover: this
                // is a setting that takes effect as it is flipped, not a box on a form.
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).disabled(row.inert)
                .accessibilityHidden(true)          // the row already reads as a button
        case .permission(let answer):
            Picker("", selection: Binding(
                get: { PermissionAnswer(answer) },
                set: { SiteControl.set(row.id == .camera ? .camera : .microphone,
                                       to: $0.value, host: host) })) {
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
    let glyph: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(Look.caption)
                .frame(width: Look.step, height: Look.step)
                .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
