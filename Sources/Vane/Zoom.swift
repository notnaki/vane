import Foundation
import WebKit

/// Per-site zoom that survives navigation and relaunch.
///
/// `WKWebView.pageZoom` is a property of the *view*, not of the site, so the pre-existing
/// View menu items zoomed whatever page happened to be loaded and forgot it the moment the
/// user clicked a link. Every real browser remembers zoom per site, because the reason a
/// site is zoomed — its body text is 12px — is a property of the site and does not change
/// between visits.
///
/// ponytail: one `[String: Double]` dictionary in UserDefaults per profile, keyed by host,
/// reusing `ProfileManager.defaultsKey` like Blocker and TidyTitles do. Not a table in
/// vane.db: this is at most a few dozen rows, it is read on every navigation (so it wants
/// to be in memory already), and a dictionary makes `sites()`, `forgetAll()` and
/// `forget(profile:)` one line each. Ceiling: no sync, no per-tab override, no "zoom text
/// only". The upgrade path for all three is the same dictionary with a struct value.
@MainActor enum Zoom {

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    /// Same trick as `CertificateTrust` and `SitePermissions`.
    private static var defaults: UserDefaults = .vane

    // MARK: - The ladder

    /// The steps Safari and Chrome both use. Menu.swift multiplied by 1.1 forever, which
    /// walks off the end of double precision (1.2100000000000002) and gives the user no
    /// way back to a round number — `zoomIn` then `zoomOut` did not return where it
    /// started. A fixed ladder makes every reachable level a value a human would name.
    static let ladder: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// 100%. The value that is deliberately *not* persisted — see `set(_:for:)`.
    static let normal = 1.0

    /// Comparisons are fuzzy because a stored level can be off-ladder: an older build wrote
    /// 1.2100000000000002, and `pageZoom` round-trips through CGFloat. An exact `>` would
    /// leave those values stuck one step away from where the user expects.
    private static let epsilon = 0.001

    /// Next rung up, clamped at the top rather than wrapping or growing without bound.
    static func stepUp(from level: Double) -> Double {
        ladder.first { $0 > level + epsilon } ?? ladder[ladder.count - 1]
    }

    static func stepDown(from level: Double) -> Double {
        ladder.last { $0 < level - epsilon } ?? ladder[0]
    }

    // MARK: - Storage

    private static let base = "siteZoom"
    private static func key(_ profile: UUID) -> String { ProfileManager.defaultsKey(base, profile) }

    /// The key a level is filed under.
    ///
    /// `www.example.com` and `example.com` deliberately SHARE one entry. They are the same
    /// site to the user and to nearly every server — sites redirect between the two
    /// constantly, and often mid-session — so keying them apart means zooming a page and
    /// watching the zoom vanish on the next click, which is the exact bug this file exists
    /// to fix. Nothing deeper is collapsed: `news.example.com` keeps its own level, because
    /// deciding that two subdomains are "the same site" needs the Public Suffix List, and
    /// that is a dependency (and a monthly-updating data file) for a case nobody has
    /// complained about. Ceiling: `m.example.com` and `example.com` are still separate.
    static func host(for url: URL) -> String? {
        guard let raw = url.host?.lowercased(), !raw.isEmpty else { return nil }
        return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    /// `dictionary(forKey:)` hands back `[String: Any]` of NSNumbers. Values that are not
    /// numbers — a hand-edited plist, a future schema — are dropped rather than crashing.
    private static func table(_ profile: UUID) -> [String: Double] {
        let raw = defaults.dictionary(forKey: key(profile)) ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// An empty table removes the key outright, so a profile that has been reset leaves
    /// nothing behind for `forget(profile:)` — or for a plist reader — to find.
    private static func write(_ table: [String: Double], _ profile: UUID) {
        if table.isEmpty { defaults.removeObject(forKey: key(profile)) }
        else { defaults.set(table, forKey: key(profile)) }
    }

    // MARK: - Read and write a level

    /// The remembered level for this url's site, or 100% if there isn't one. Never fails:
    /// a url with no host (file://, about:blank, a data: url) is simply never zoomed.
    static func level(for url: URL, profile: UUID = ProfileManager.activeProfileID) -> Double {
        guard let host = host(for: url) else { return normal }
        return table(profile)[host] ?? normal
    }

    /// Storing 100% for every site the user visits is how this feature turns into a junk
    /// drawer: a thousand rows that all mean "nothing was ever changed here", and a Sites
    /// list nobody can scan. So the default is the *absence* of an entry, and setting a
    /// site back to 100% deletes its entry rather than writing 1.0 over it.
    static func set(_ level: Double, for url: URL, profile: UUID = ProfileManager.activeProfileID) {
        guard let host = host(for: url), level.isFinite else { return }
        var t = table(profile)
        // Clamped to the ladder's ends: a hand-edited plist must not be able to make a page
        // 5000% and leave the user with no visible UI to fix it from.
        let clamped = min(max(level, ladder[0]), ladder[ladder.count - 1])
        if abs(clamped - normal) < epsilon { t.removeValue(forKey: host) } else { t[host] = clamped }
        write(t, profile)
    }

    // MARK: - Applying to a tab

    /// Put the stored level on the tab's web view.
    ///
    /// MUST be called from `webView(_:didCommit:)` — see the wiring note in the report.
    /// `didCommit` is the first moment the destination is final (redirects are done, so
    /// `w.url` is the host we will actually key on) and the last moment before the new
    /// document lays out and paints. Applying it in `didFinish` instead means the page
    /// appears at 100%, then visibly reflows to 125% under the user's eyes on every single
    /// navigation, which reads as a bug even though the end state is right.
    ///
    /// Unconditional, including when the answer is 100%: the web view carries the previous
    /// page's `pageZoom`, so navigating from a zoomed site to an unzoomed one has to
    /// actively put it back.
    static func apply(to tab: Tab) {
        guard let url = tab.currentURL else { return }
        tab.web.pageZoom = level(for: url, profile: tab.profileID)
        tab.zoom = tab.web.pageZoom      // the pill's chip
    }

    // MARK: - The three menu commands

    /// Step up, apply live, and remember it. The persist half is the whole point: without
    /// it these are the old menu items with rounder numbers.
    static func zoomIn(_ tab: Tab)  { move(tab) { stepUp(from: $0) } }
    static func zoomOut(_ tab: Tab) { move(tab) { stepDown(from: $0) } }

    /// Actual Size. Persisting 100% is defined as *forgetting* the site (see `set`), so
    /// this is also how a user removes an entry without opening any list.
    static func reset(_ tab: Tab)   { move(tab) { _ in normal } }

    private static func move(_ tab: Tab, _ next: (Double) -> Double) {
        let level = next(tab.web.pageZoom)
        tab.web.pageZoom = level
        tab.zoom = level                 // the pill's chip
        // A private window reads stored levels — a site you zoomed yesterday is still
        // readable today — but writes nothing, because "which sites did you zoom" is
        // exactly the browsing record private mode exists not to keep.
        guard !tab.isPrivate, let url = tab.currentURL else { return }
        set(level, for: url, profile: tab.profileID)
    }

    // MARK: - Managing the list

    /// Every site with a non-default level, sorted by host so a list built from this does
    /// not reshuffle itself between launches — dictionary order is not stable.
    static func sites(profile: UUID = ProfileManager.activeProfileID) -> [(host: String, level: Double)] {
        table(profile).sorted { $0.key < $1.key }.map { (host: $0.key, level: $0.value) }
    }

    /// Exact key, not a prefix sweep: `forget("example.com")` must not take
    /// `example.com.au` or `news.example.com` with it.
    static func forget(host: String, profile: UUID = ProfileManager.activeProfileID) {
        var t = table(profile)
        let normalized = host.lowercased().hasPrefix("www.")
            ? String(host.lowercased().dropFirst(4)) : host.lowercased()
        t.removeValue(forKey: normalized)
        write(t, profile)
    }

    static func forgetAll(profile: UUID = ProfileManager.activeProfileID) {
        defaults.removeObject(forKey: key(profile))
    }

    /// For `ProfileManager.delete`, alongside the other per-profile defaults keys it sweeps.
    static func forget(profile: UUID) {
        defaults.removeObject(forKey: key(profile))
    }

    // MARK: - check

    /// Runs against a throwaway defaults suite that is deleted afterwards; the user's real
    /// preferences are never read or written, and nothing here needs a window server, a
    /// network, or a WKWebView.
    static func check() -> [(String, Bool)] {
        let suite = "vane.zoomcheck.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }

        let p1 = UUID(), p2 = UUID()
        let example = URL(string: "https://example.com/page")!
        let www = URL(string: "https://www.example.com/other")!
        let news = URL(string: "https://news.example.com/")!
        var out: [(String, Bool)] = []

        // The ladder: stepping, and clamping at both ends rather than running away.
        out.append(("zooming in from 100% lands on 115%", stepUp(from: 1.0) == 1.15))
        out.append(("zooming out from 100% lands on 85%", stepDown(from: 1.0) == 0.85))
        out.append(("in then out returns to exactly where it started",
                    stepDown(from: stepUp(from: 1.0)) == 1.0))
        out.append(("the ladder is the levels Safari and Chrome use",
                    ladder == [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]))
        out.append(("zooming in clamps at 300%, it does not keep growing",
                    stepUp(from: 3.0) == 3.0 && stepUp(from: 99) == 3.0))
        out.append(("zooming out clamps at 50%", stepDown(from: 0.5) == 0.5 && stepDown(from: 0.01) == 0.5))
        // The value the old *= 1.1 code produced. It must snap back onto the ladder.
        out.append(("an off-ladder level snaps up onto the ladder", stepUp(from: 1.2100000000000002) == 1.25))
        out.append(("an off-ladder level snaps down onto the ladder",
                    stepDown(from: 1.2100000000000002) == 1.15))
        out.append(("every rung is reachable by stepping up from the bottom",
                    (1..<ladder.count).allSatisfy { stepUp(from: ladder[$0 - 1]) == ladder[$0] }))
        out.append(("every rung is reachable by stepping down from the top",
                    (1..<ladder.count).allSatisfy { stepDown(from: ladder[$0]) == ladder[$0 - 1] }))

        // Default is 1.0 and is never written.
        out.append(("an unvisited site reads back as 100%", level(for: example, profile: p1) == 1.0))
        set(1.0, for: example, profile: p1)
        out.append(("setting a site to 100% stores NOTHING", sites(profile: p1).isEmpty))
        out.append(("...and the profile's key is not even created",
                    scratch.object(forKey: ProfileManager.defaultsKey("siteZoom", p1)) == nil))

        set(1.25, for: example, profile: p1)
        out.append(("a set level reads back", level(for: example, profile: p1) == 1.25))
        out.append(("the site now appears in the list", sites(profile: p1).map(\.host) == ["example.com"]))
        set(1.0, for: example, profile: p1)
        out.append(("setting a site back to 100% REMOVES its entry", sites(profile: p1).isEmpty))
        out.append(("...and it reads back as the 100% default", level(for: example, profile: p1) == 1.0))

        // Host keying: www is the same site, a deeper subdomain is not.
        set(1.5, for: example, profile: p1)
        out.append(("www.example.com shares example.com's level", level(for: www, profile: p1) == 1.5))
        set(2.0, for: www, profile: p1)
        out.append(("...in both directions", level(for: example, profile: p1) == 2.0))
        out.append(("the shared entry is stored once, under the bare host",
                    sites(profile: p1).map(\.host) == ["example.com"]))
        out.append(("a deeper subdomain keeps its own level", level(for: news, profile: p1) == 1.0))
        out.append(("host matching is case-insensitive",
                    level(for: URL(string: "https://EXAMPLE.COM/x")!, profile: p1) == 2.0))
        out.append(("a url with no host reads 100%",
                    level(for: URL(fileURLWithPath: "/tmp/x.html"), profile: p1) == 1.0))
        set(1.5, for: URL(fileURLWithPath: "/tmp/x.html"), profile: p1)
        out.append(("a url with no host stores nothing", sites(profile: p1).count == 1))
        // A hand-edited plist must not be able to make a page unusable.
        set(50, for: news, profile: p1)
        out.append(("an absurd level is clamped to the top of the ladder",
                    level(for: news, profile: p1) == 3.0))
        set(0.001, for: news, profile: p1)
        out.append(("...and to the bottom", level(for: news, profile: p1) == 0.5))
        set(Double.nan, for: news, profile: p1)
        out.append(("a NaN level is refused, leaving the old one", level(for: news, profile: p1) == 0.5))

        // Per-profile isolation.
        out.append(("another profile does not see the first profile's levels",
                    level(for: example, profile: p2) == 1.0 && sites(profile: p2).isEmpty))
        set(0.75, for: example, profile: p2)
        out.append(("the two profiles hold different levels for the same site",
                    level(for: example, profile: p1) == 2.0 && level(for: example, profile: p2) == 0.75))

        // Persistence round-trip: read the raw plist back through a separate defaults
        // object, which is what proves the value really left memory in a readable shape.
        let reread = UserDefaults(suiteName: suite)?
            .dictionary(forKey: ProfileManager.defaultsKey("siteZoom", p1)) ?? [:]
        out.append(("levels round-trip through UserDefaults as a host-keyed dictionary",
                    (reread["example.com"] as? NSNumber)?.doubleValue == 2.0))
        out.append(("the default profile stores under the unsuffixed key, like every other feature",
                    ProfileManager.defaultsKey("siteZoom", ProfileManager.defaultID) == "siteZoom"))

        // sites() ordering.
        set(1.5, for: URL(string: "https://zebra.example/")!, profile: p1)
        set(1.5, for: URL(string: "https://apple.example/")!, profile: p1)
        out.append(("sites() is sorted by host, not dictionary order",
                    sites(profile: p1).map(\.host) == ["apple.example", "example.com",
                                                       "news.example.com", "zebra.example"]))
        out.append(("sites() reports the stored level with each host",
                    sites(profile: p1).first { $0.host == "example.com" }?.level == 2.0))

        // forget semantics.
        set(1.25, for: URL(string: "https://example.com.au/")!, profile: p1)
        forget(host: "example.com", profile: p1)
        out.append(("forget(host:) drops that site", level(for: example, profile: p1) == 1.0))
        out.append(("forget(host:) does not eat a host that merely starts the same way",
                    level(for: URL(string: "https://example.com.au/")!, profile: p1) == 1.25))
        out.append(("forget(host:) does not eat a subdomain", level(for: news, profile: p1) == 0.5))
        out.append(("forget(host:) accepts the www form of the same site", {
            set(1.5, for: example, profile: p1)
            forget(host: "www.example.com", profile: p1)
            return level(for: example, profile: p1) == 1.0
        }()))
        forgetAll(profile: p1)
        out.append(("forgetAll empties that profile", sites(profile: p1).isEmpty))
        out.append(("forgetAll leaves other profiles alone", level(for: example, profile: p2) == 0.75))

        set(1.75, for: news, profile: p1)
        forget(profile: p2)
        out.append(("forget(profile:) erases everything that profile stored",
                    sites(profile: p2).isEmpty && level(for: example, profile: p2) == 1.0))
        out.append(("forget(profile:) leaves the other profile untouched",
                    level(for: news, profile: p1) == 1.75))
        out.append(("forget(profile:) removes the key itself, leaving no empty dictionary behind",
                    scratch.object(forKey: ProfileManager.defaultsKey("siteZoom", p2)) == nil))

        return out
    }
}
