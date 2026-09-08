import AppKit

/// Everything about an update that is a function of its inputs and nothing else: which tag
/// is newer, which asset to fetch, when the next poll is due, and what a download has to
/// prove before Vane will hand it to the user. No network, no bundle, no clock — so
/// `selfcheck --pure` can drive all of it on a headless runner.
enum Release {

    // MARK: - Versions

    /// A semver-ish tag: `1.2.3`, `v1.2.3`, `1.2.3-beta.2`, `1.2.3+7`. The numeric core is
    /// the whole of the parse; anything else is `nil`, and a `nil` version is never newer
    /// than anything. A tag nobody can read must not push an upgrade *or* a downgrade.
    struct Version: Comparable {
        let core: [Int]
        /// The `-beta.2` part, split on dots. Empty means a real release, which by semver
        /// outranks every pre-release of the same core.
        let pre: [String]

        init?(_ raw: String) {
            var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            while let f = s.first, f == "v" || f == "V" { s = s.dropFirst() }
            // Build metadata (`+7`) is not part of precedence, so it is dropped unparsed.
            s = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let halves = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            var numbers: [Int] = []
            for part in halves[0].split(separator: ".") {
                guard let n = Int(part), n >= 0 else { return nil }
                numbers.append(n)
            }
            guard !numbers.isEmpty else { return nil }
            core = numbers
            pre = halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : []
        }

        static func < (l: Version, r: Version) -> Bool {
            for i in 0..<max(l.core.count, r.core.count) {
                // `1.2` and `1.2.0` are the same version, so a missing component is a zero.
                let a = i < l.core.count ? l.core[i] : 0, b = i < r.core.count ? r.core[i] : 0
                if a != b { return a < b }
            }
            // 1.0.0-beta < 1.0.0. Without this the release *after* a pre-release looks equal
            // to it and nobody on a beta is ever offered the real thing.
            if l.pre.isEmpty != r.pre.isEmpty { return !l.pre.isEmpty }
            for i in 0..<max(l.pre.count, r.pre.count) {
                guard i < l.pre.count else { return true }
                guard i < r.pre.count else { return false }
                let a = l.pre[i], b = r.pre[i]
                if a == b { continue }
                switch (Int(a), Int(b)) {
                case let (x?, y?): return x < y      // beta.2 < beta.10, not "10" < "2"
                case (_?, nil):    return true       // numeric identifiers rank below alphanumeric
                case (nil, _?):    return false
                default:           return a < b
                }
            }
            return false
        }
    }

    /// The only version question the app ever asks. Never true for equal versions, never
    /// true downhill, never true for a tag that does not parse.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let a = Version(tag), let b = Version(current) else { return false }
        return b < a
    }

    // MARK: - Assets

    /// The `.zip`, and only the `.zip` — not the `.dmg`, which every release also ships.
    /// A sandboxed process cannot mount a disk image at all: `hdiutil attach` comes back
    /// "Device not configured", because DiskArbitration is not reachable from inside the
    /// sandbox (measured, with a probe signed with Vane.entitlements). The zip is the one
    /// asset Vane can open by itself, and opening it by itself is the whole feature. The
    /// dmg stays on the release for people downloading it in a browser.
    static func asset(_ assets: [(name: String, url: String)]) -> URL? {
        trusted(assets.first { $0.name.lowercased().hasSuffix(".zip") }
            .flatMap { URL(string: $0.url) })
    }

    // MARK: - When to look

    /// Why a check is being considered. The menu always wins; the rest are rate-limited,
    /// because the whole point of checking often is that checking is nearly free.
    enum Reason { case launch, activation, timer, menu }

    /// Coming back to the app is the moment an update is most welcome, so activation gets
    /// the shortest floor.
    static let activationFloor: TimeInterval = 5 * 60
    static let period: TimeInterval = 30 * 60
    /// After a network error or a rate-limit reply, back off until the next success. GitHub
    /// gives an unauthenticated client 60 requests an hour and a 403 when it runs out;
    /// hammering it after one is how a client stays locked out.
    static let backoffPeriod: TimeInterval = 60 * 60

    static func due(_ reason: Reason, last: Date?, backingOff: Bool, now: Date) -> Bool {
        switch reason {
        case .menu:   return true                    // the user asked; a floor would look broken
        case .launch: return true
        case .activation, .timer:
            guard let last else { return true }
            let floor = backingOff ? backoffPeriod
                                   : (reason == .activation ? activationFloor : period)
            return now.timeIntervalSince(last) >= floor
        }
    }

    // MARK: - Where the new copy goes

    /// The two folders a sandboxed Vane is allowed to write an app into, by entitlement.
    /// Nothing else is reachable, and nothing else needs to be: an app belongs in one of
    /// these, and a copy that is somewhere else is a copy that has not been installed yet.
    static func applicationsFolders(home: String) -> [String] {
        ["/Applications", home + "/Applications"]
    }

    /// Where an update to the bundle at `path` should be written, given the two folders and
    /// the home directory. A copy already living in an Applications folder is replaced where
    /// it stands, Vesta-style. A copy anywhere else — a build on the Desktop, an unzip in
    /// Downloads, a bundle still on its mounted disk image — is *installed*: the new version
    /// goes to /Applications and the old copy is left exactly where it was.
    /// ponytail: no folder picker, no bookmark, no helper. Two entitlements cover every
    /// place an app is actually kept, and there is nothing to ask.
    static func destination(forBundleAt path: String, home: String) -> (path: String, moved: Bool) {
        // Anywhere *under* an Applications folder counts as installed, not just directly in
        // one: plenty of people keep `/Applications/Browsers/Vane.app`, and hoisting it to
        // the top level would be Vane tidying up a filing system that was not its idea.
        // A folder that merely ends in the word ("~/Old Applications") is not one of them,
        // which is why this is a path prefix and not a `contains`.
        for root in applicationsFolders(home: home) where path.hasPrefix(root + "/") {
            return (path, false)
        }
        return ("/Applications/" + (path as NSString).lastPathComponent, true)
    }

    /// A bundle's `CFBundleShortVersionString`, read straight off disk. No launching, no
    /// `Bundle(url:)` — this is asked about a copy of Vane that is not running and must not
    /// be started just to be interrogated.
    static func version(ofBundleAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    // MARK: - What a check is allowed to say

    /// The answer to a check. A *background* check may only ever put up the offer of a real
    /// update: nobody opened a browser to be told it is up to date, and a browser that
    /// reports on its own update server every half hour is a browser that talks too much.
    /// A check the user pressed answers either way, because a button that does nothing
    /// visible looks broken.
    enum Answer: Equatable {
        case offer(String)   // a newer tag — the only thing a launch may ever say
        case upToDate
        case unreachable
        case nothing
    }

    static func answer(newer: String?, manual: Bool, reachable: Bool) -> Answer {
        guard reachable else { return manual ? .unreachable : .nothing }
        if let newer { return .offer(newer) }
        return manual ? .upToDate : .nothing
    }

    /// Whether this launch should install itself into `/Applications` and come back from
    /// there. Silently and without asking: a copy running from a mounted disk image or out
    /// of Downloads is a copy that was never installed, and "drag me to Applications" is not
    /// a question anyone wants to be asked by a browser.
    ///
    /// Only a real signed release does this. An ad-hoc or locally-signed build stays exactly
    /// where it was built — otherwise every `./make-app.sh` in a worktree would move itself
    /// on top of the installed app — and so does an instance running on its own data
    /// directory, which is by definition a test.
    /// `installedVersion` is what is already at the destination: `nil` when nothing is
    /// there, and the empty string when something is there whose version cannot be read.
    /// Both of those are answered deliberately — an empty destination is installed into, and
    /// one that cannot be read is left alone, because the one thing this must never do is
    /// overwrite a Vane it does not understand.
    static func shouldRelocate(bundlePath: String, home: String, official: Bool, isolated: Bool,
                               runningVersion: String, installedVersion: String?) -> Bool {
        guard official, !isolated else { return false }
        guard destination(forBundleAt: bundlePath, home: home).moved else { return false }
        // Nothing installed yet: this copy is the install.
        guard let installedVersion else { return true }
        // Something is. Only a *newer* copy may replace it — otherwise double-clicking an
        // old release still sitting in ~/Downloads would quietly downgrade the installed
        // Vane, move the good one aside as `.app.old`, and relaunch into the old one. The
        // release left in Downloads is the one people forget about; it must not win.
        return isNewer(runningVersion, than: installedVersion)
    }

    // MARK: - What a download has to prove

    /// The Developer ID team every Vane release is signed by. Pinned: this constant, and
    /// nothing read off the network or off the running bundle, is what a download has to
    /// match. See `Updater.verified`.
    static let teamID = "T7X84HN3W3"

    /// The requirement every downloaded bundle must satisfy, whoever is running. A constant
    /// rather than a question about the running copy — see `requirement(forTeam:)`.
    static var pinnedRequirement: String? { requirement(forTeam: teamID) }

    /// GitHub's own hosts, over TLS, and nothing else. The release JSON arrives over a
    /// verified connection, but the asset URL *inside* it is still a string that came off the
    /// network — and one read back out of `UserDefaults` is a string that came off the
    /// network a week ago. A downloader that follows it anywhere is a downloader that can be
    /// pointed anywhere, so both go through here.
    static func trusted(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com")
                || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
        else { return nil }
        return url
    }

    /// A release is a few tens of megabytes. Anything claiming to be hundreds is either not
    /// a release or not worth filling a disk to find out.
    static let maxAssetBytes: Int64 = 200 * 1024 * 1024

    /// The designated requirement text for a team. `nil` for a missing or empty team, which
    /// is the guard that matters: a `nil` requirement handed to `SecStaticCodeCheckValidity`
    /// means "any signature that is internally consistent", and an ad-hoc bundle is
    /// internally consistent. Callers pass `teamID` and refuse the download if this is nil —
    /// they never build a requirement out of whatever the running copy happens to be signed
    /// by, because a dev build signed by nobody would then accept a release signed by nobody.
    static func requirement(forTeam team: String?) -> String? {
        guard let team, !team.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

// MARK: - check

extension Release {
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func v(_ a: String, _ b: String) -> Bool { isNewer(a, than: b) }

        out.append(("a higher patch is newer", v("0.1.1", "0.1.0")))
        out.append(("a higher minor is newer", v("0.2.0", "0.1.9")))
        out.append(("ten beats nine, it is not a string compare", v("0.10.0", "0.9.0")))
        out.append(("a leading v is not part of the version", v("v1.0.0", "0.9.9")))
        out.append(("...on either side", v("1.0.0", "v0.9.9")))
        out.append(("the same version is not newer", !v("0.1.0", "0.1.0")))
        out.append(("0.1 and 0.1.0 are the same version", !v("0.1", "0.1.0")))
        out.append(("an older tag never downgrades", !v("0.1.0", "0.2.0")))
        out.append(("build metadata does not make a version newer", !v("1.0.0+9", "1.0.0")))
        out.append(("a pre-release is older than the release it leads to", !v("1.0.0-beta.1", "1.0.0")))
        out.append(("...and the release is offered to someone on the beta", v("1.0.0", "1.0.0-beta.1")))
        out.append(("beta.10 comes after beta.2", v("1.0.0-beta.10", "1.0.0-beta.2")))
        out.append(("alpha comes before beta", v("1.0.0-beta", "1.0.0-alpha")))
        out.append(("a malformed tag is not newer", !v("wat", "0.1.0")))
        out.append(("...nor is an empty one", !v("", "0.1.0")))
        out.append(("...nor one with a letter in the core", !v("1.2.x", "0.1.0")))
        out.append(("an unreadable current version never triggers an update either",
                    !v("9.9.9", "unknown")))

        let dmg = "https://github.com/notnaki/vane/releases/download/v1/Vane.dmg"
        let zip = "https://github.com/notnaki/vane/releases/download/v1/Vane.zip"
        out.append(("the zip is the asset to fetch, because it is the one Vane can open",
                    asset([("Vane.dmg", dmg), ("Vane.zip", zip)])?.absoluteString == zip))
        out.append(("...whatever order the release lists them in",
                    asset([("Vane.zip", zip), ("Vane.dmg", dmg)])?.absoluteString == zip))
        out.append(("a dmg-only release cannot be installed from inside the sandbox",
                    asset([("Vane.dmg", dmg)]) == nil))
        out.append(("case does not matter", asset([("VANE.ZIP", zip)])?.absoluteString == zip))
        out.append(("a release with no bundle in it offers nothing",
                    asset([("notes.txt", "https://github.com/notnaki/vane/notes.txt")]) == nil))
        out.append(("an asset whose url is not a url is not an asset",
                    asset([("Vane.zip", "")]) == nil))

        let now = Date(timeIntervalSince1970: 100_000)
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        out.append(("the first check happens at launch",
                    due(.launch, last: nil, backingOff: false, now: now)))
        out.append(("the menu always checks, however recently we looked",
                    due(.menu, last: now, backingOff: false, now: now)))
        out.append(("coming back to the app checks after five minutes",
                    due(.activation, last: ago(301), backingOff: false, now: now)))
        out.append(("...and not before",
                    !due(.activation, last: ago(60), backingOff: false, now: now)))
        out.append(("the timer checks every half hour",
                    due(.timer, last: ago(1801), backingOff: false, now: now)))
        out.append(("...and a minute-by-minute tick in between costs no request",
                    !due(.timer, last: ago(600), backingOff: false, now: now)))
        out.append(("after an error nothing asks again for an hour",
                    !due(.activation, last: ago(1800), backingOff: true, now: now)))
        out.append(("...and then it does",
                    due(.activation, last: ago(3601), backingOff: true, now: now)))
        out.append(("backing off never silences the menu",
                    due(.menu, last: now, backingOff: true, now: now)))

        let home = "/Users/ada"
        func dest(_ p: String) -> (path: String, moved: Bool) {
            destination(forBundleAt: p, home: home)
        }
        out.append(("an app in /Applications is replaced where it stands",
                    dest("/Applications/Vane.app") == ("/Applications/Vane.app", false)))
        out.append(("...and one in the user's own Applications folder too",
                    dest("/Users/ada/Applications/Vane.app")
                        == ("/Users/ada/Applications/Vane.app", false)))
        out.append(("a build on the Desktop is installed rather than updated in place",
                    dest("/Users/ada/Desktop/vane/Vane.app") == ("/Applications/Vane.app", true)))
        out.append(("...and so is a copy still running off its disk image",
                    dest("/Volumes/Vane/Vane.app") == ("/Applications/Vane.app", true)))
        out.append(("a folder that merely ends in Applications is not one of them",
                    dest("/Users/ada/Old Applications/Vane.app").moved))
        out.append(("an app filed in a folder inside Applications is already installed",
                    dest("/Applications/Browsers/Vane.app")
                        == ("/Applications/Browsers/Vane.app", false)))

        out.append(("an asset served from anywhere but GitHub is not an asset",
                    asset([("Vane.zip", "https://evil.example.com/Vane.zip")]) == nil))
        out.append(("...nor one served in the clear",
                    asset([("Vane.zip", "http://github.com/Vane.zip")]) == nil))
        out.append(("...nor one on a host that merely ends in the right letters",
                    asset([("Vane.zip", "https://notgithub.com/Vane.zip")]) == nil))
        out.append(("the redirect target GitHub actually uses is trusted",
                    trusted(URL(string: "https://objects.githubusercontent.com/x")) != nil))
        out.append(("a release is capped at something a release could be",
                    maxAssetBytes > 50 * 1024 * 1024 && maxAssetBytes < 1024 * 1024 * 1024))

        out.append(("a launch that finds an update says so",
                    answer(newer: "v2", manual: false, reachable: true) == .offer("v2")))
        out.append(("a launch that finds nothing says nothing at all",
                    answer(newer: nil, manual: false, reachable: true) == .nothing))
        out.append(("...and a launch that cannot reach GitHub says nothing either",
                    answer(newer: nil, manual: false, reachable: false) == .nothing))
        out.append(("pressing Check for Updates when there is none says so",
                    answer(newer: nil, manual: true, reachable: true) == .upToDate))
        out.append(("...and says so when GitHub cannot be reached",
                    answer(newer: nil, manual: true, reachable: false) == .unreachable))
        out.append(("pressing it when there IS one offers it, same as a launch",
                    answer(newer: "v2", manual: true, reachable: true) == .offer("v2")))

        func relocate(_ path: String, official: Bool = true, isolated: Bool = false,
                      running: String = "1.0.0", installed: String? = nil) -> Bool {
            shouldRelocate(bundlePath: path, home: home, official: official, isolated: isolated,
                           runningVersion: running, installedVersion: installed)
        }
        out.append(("a release opened from its disk image installs itself",
                    relocate("/Volumes/Vane/Vane.app")))
        out.append(("...and one unzipped into Downloads does too",
                    relocate("/Users/ada/Downloads/Vane.app")))
        out.append(("an absent destination is installed into, whatever version is running",
                    relocate("/Users/ada/Downloads/Vane.app", running: "0.9.0", installed: nil)))
        out.append(("a newer release opened from Downloads replaces the installed one",
                    relocate("/Users/ada/Downloads/Vane.app", running: "2.0.0", installed: "1.0.0")))
        out.append(("an older release opened from Downloads never replaces a newer installed Vane",
                    !relocate("/Users/ada/Downloads/Vane.app", running: "1.0.0", installed: "2.0.0")))
        out.append(("...nor does one that is exactly the version already installed",
                    !relocate("/Users/ada/Downloads/Vane.app", running: "2.0.0", installed: "2.0.0")))
        out.append(("a destination whose version cannot be read is left alone",
                    !relocate("/Users/ada/Downloads/Vane.app", running: "2.0.0", installed: "")))
        out.append(("one already in /Applications stays put", !relocate("/Applications/Vane.app")))
        out.append(("...as does one in the user's own Applications folder",
                    !relocate("/Users/ada/Applications/Vane.app")))
        out.append(("...and one filed in a folder inside Applications",
                    !relocate("/Applications/Browsers/Vane.app")))
        out.append(("a build that is not a signed release never moves itself",
                    !relocate("/Users/ada/Desktop/vane/Vane.app", official: false)))
        out.append(("...and neither does a test instance on its own data directory",
                    !relocate("/Users/ada/Desktop/vane/Vane.app", isolated: true)))

        // The version read, against a real bundle on disk — the input `shouldRelocate`
        // depends on, and the one part of it that is not arithmetic.
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("vane-version-check-\(getpid())")
        let bundle = scratch.appendingPathComponent("Vane.app")
        try? fm.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.3.4", "CFBundleName": "Vane"]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0) {
            try? data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        out.append(("an installed bundle's version is read off disk, without launching it",
                    version(ofBundleAt: bundle) == "2.3.4"))
        out.append(("a bundle that is not there has no version",
                    version(ofBundleAt: scratch.appendingPathComponent("Nope.app")) == nil))
        // ...and a bundle whose plist is unreadable, which `relocateIfNeeded` turns into ""
        // so that the destination is left alone rather than overwritten.
        let broken = scratch.appendingPathComponent("Broken.app")
        try? fm.createDirectory(at: broken.appendingPathComponent("Contents"),
                                withIntermediateDirectories: true)
        try? Data("not a plist".utf8).write(to: broken.appendingPathComponent("Contents/Info.plist"))
        out.append(("a bundle with an unreadable Info.plist has no version either",
                    version(ofBundleAt: broken) == nil))
        try? fm.removeItem(at: scratch)

        out.append(("the requirement is pinned to one team, not to whoever is running",
                    pinnedRequirement == requirement(forTeam: teamID) && pinnedRequirement != nil))
        out.append(("a release must be signed by Vane's own team",
                    requirement(forTeam: teamID)
                        == "anchor apple generic and certificate leaf[subject.OU] = \"T7X84HN3W3\""))
        out.append(("an ad-hoc build demands no Developer ID it does not have itself",
                    requirement(forTeam: nil) == nil))
        out.append(("...and an empty team is the same as none", requirement(forTeam: "") == nil))
        return out
    }
}

/// Vane's in-app updater: ask GitHub for the latest release, and if it is newer than the
/// running bundle say so in a sticky toast the user can act on or dismiss. Modelled on
/// Vesta's `Updater.swift`, and it ends the same way — a bundle swapped in place and a
/// relaunch — but it gets there differently, because Vane is sandboxed.
///
/// What a sandboxed Vane can and cannot do, measured with a probe app signed with
/// `Vane.entitlements` rather than assumed:
///
///   * the bundle's parent directory is **not** writable by default — not in
///     `~/Applications`, not anywhere; `isWritableFile` says false and the write fails
///   * `hdiutil attach` fails outright ("Device not configured"): DiskArbitration is not
///     reachable from a sandboxed process, so the release's **dmg can never be mounted**
///     in-process. The zip is the asset this file downloads, and `ditto -x -k` unpacks it
///     inside the container, which *is* allowed.
///   * everything a sandboxed app writes is stamped `com.apple.quarantine`, and
///     `removexattr` on it is denied. The downloaded zip carries it, `ditto` propagates it
///     to the unpacked bundle and its executable, and the copy into /Applications keeps it.
///     **This turned out not to matter.** Measured on the real notarized release: the
///     installed copy assesses as `accepted, source=Notarized Developer ID` and
///     `stapler validate` passes on it, because the ticket is stapled into the bundle and
///     Gatekeeper never needs the xattr gone. The quarantine flags come back `0282` — the
///     "already assessed" bit is not set — so macOS assesses it on first launch and may show
///     the standard "downloaded from the Internet, are you sure?" confirmation once. One
///     click, not a refusal. An *unnotarized* release would be refused there instead, which
///     is why the workflow fails rather than publishing one.
///   * the two `Applications` directories are writable with the temporary-exception
///     entitlements — create, copy, rename and delete all succeed in `/Applications` and in
///     `~/Applications`, and the copy/rename/rename/sweep sequence below was rehearsed there
///     on a scratch bundle of its own
///
/// So the swap is Vane's to do, and the user's only step is pressing Update.
/// ponytail: no folder picker and no security-scoped bookmark. Those were built and then
/// deleted: two entitlements cover every directory an app is actually kept in, and for a
/// copy living anywhere else the honest answer is to *install* it into /Applications rather
/// than to ask permission to update it where it sits. Ceiling: a privileged helper, which
/// would buy the one case nobody has — an app installed somewhere neither of those two.
@MainActor final class Updater {
    static let shared = Updater()
    static let repo = "notnaki/vane"

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
    /// Only a real `.app` can be replaced by a downloaded one; the bare binary out of
    /// `.build` has no version to compare and nothing to install into, so it opens the page.
    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    enum Phase: Equatable {
        case available(String)      // tag — press Update to fetch it
        case downloading(Double)    // 0…1
        case installing             // unpacking and swapping
        case ready                  // the new copy is in place; only a relaunch is left
        case failed
    }

    private(set) var phase: Phase?
    private var pending: (tag: String, asset: URL)?
    /// Where the new copy went — the same path, or /Applications when it was installed.
    private var installed: URL?
    private var working = false
    private var progress: NSKeyValueObservation?
    private var poll: Task<Void, Never>?
    private var lastCheck: Date?
    private var backingOff = false
    /// One id for the whole update, so every phase rewrites the same pill in place rather
    /// than sliding a new one up from the sidebar's edge five times.
    private let toastID = UUID()

    // MARK: - Polling

    /// Called once from `main.swift`. A single minute-by-minute tick drives launch, timer
    /// and backoff alike — `Release.due` decides whether a tick costs a request, and mostly
    /// it costs a conditional one that comes back 304.
    func begin() {
        // Not installed yet — running off a mounted disk image, or out of Downloads, or
        // wherever it was unzipped. Put it where apps live and come back from there, with no
        // toast and no question: "drag me to Applications" is not something a browser should
        // ever ask, and neither is "may I?". Only a real signed release does this; see
        // `Release.shouldRelocate`. If it works this process is on its way out, so there is
        // nothing else to start.
        if relocateIfNeeded() { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.tick(.activation) }
        }
        poll?.cancel()
        poll = Task { [weak self] in
            // Not at launch: the first seconds belong to restoring windows and loading pages.
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            tick(.launch)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                tick(.timer)
            }
        }
    }

    private func tick(_ reason: Release.Reason) {
        guard Prefs.checkForUpdates,
              Release.due(reason, last: lastCheck, backingOff: backingOff, now: Date())
        else { return }
        check(silent: true)
    }

    // MARK: - Check

    /// `silent: false` is the menu item: it reports "up to date" rather than saying nothing,
    /// and it checks however recently the timer did.
    func check(silent: Bool) {
        // A background check must not disturb a download in flight or a finished one waiting
        // to be dragged. The menu still runs, so the user can see where things got to.
        // Not while an install is in flight, and not while one is finished and waiting for
        // its relaunch — for the menu as much as for the timer. A loud check used to be
        // exempt, which meant Vane ▸ Check for Updates… during an install could re-arm the
        // Update button behind it: press it and a second `unpackAndSwap` starts, deletes the
        // `.old` the first one had just moved the running app into, and the only copy of the
        // app is gone. `working` stays true from the first byte of the download until the
        // swap has returned, so the two of them cannot overlap.
        if working || phase == .installing || phase == .ready {
            // Say where it got to rather than saying nothing; the phase toast is already up,
            // so this is only for the case where the user dismissed it with the ×.
            if !silent, let phase { set(phase) }
            return
        }
        lastCheck = Date()
        Task { await fetch(silent: silent) }
    }

    private func fetch(silent: Bool) async {
        guard let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")
        else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Conditional, so half-hourly polling costs nothing: a 304 does not count against
        // GitHub's 60-an-hour unauthenticated limit and carries no body to parse. The stored
        // tag and asset are what make a 304 actionable across a relaunch — without them the
        // "nothing changed" reply would answer a question we had forgotten the answer to.
        if let etag = UserDefaults.vane.string(forKey: Keys.etag) {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let since = UserDefaults.vane.string(forKey: Keys.lastModified) {
            req.setValue(since, forHTTPHeaderField: "If-Modified-Since")
        }
        // URLSession's own cache would answer a 304 with the cached 200 and hide the cheap
        // path from us; our two headers are the cache.
        req.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return failedCheck(silent) }
            switch http.statusCode {
            case 304:
                backingOff = false
                // Through `trusted` again: a url that has been sitting in defaults since a
                // previous launch is still a url that came off the network.
                present(tag: UserDefaults.vane.string(forKey: Keys.tag),
                        asset: Release.trusted(UserDefaults.vane.string(forKey: Keys.asset)
                            .flatMap(URL.init(string:))), silent: silent)
            case 200:
                backingOff = false
                remember(http)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return failedCheck(silent) }
                let tag = json["tag_name"] as? String
                let assets: [(name: String, url: String)] =
                    ((json["assets"] as? [[String: Any]]) ?? []).compactMap { a in
                        guard let name = a["name"] as? String,
                              let url = a["browser_download_url"] as? String else { return nil }
                        return (name, url)
                    }
                let asset = Release.asset(assets)
                UserDefaults.vane.set(tag, forKey: Keys.tag)
                UserDefaults.vane.set(asset?.absoluteString, forKey: Keys.asset)
                present(tag: tag, asset: asset, silent: silent)
            default:
                // 403 is the rate limit, 404 a repo with no release yet, 5xx a bad day.
                backingOff = true
                failedCheck(silent)
            }
        } catch {
            backingOff = true
            failedCheck(silent)
        }
    }

    private enum Keys {
        static let etag = "updateETag"
        static let lastModified = "updateLastModified"
        static let tag = "updateTag"
        static let asset = "updateAsset"
    }

    private func remember(_ http: HTTPURLResponse) {
        UserDefaults.vane.set(http.value(forHTTPHeaderField: "ETag"), forKey: Keys.etag)
        UserDefaults.vane.set(http.value(forHTTPHeaderField: "Last-Modified"),
                              forKey: Keys.lastModified)
    }

    /// A silent check that cannot reach GitHub says nothing at all — a browser that toasts
    /// about its own update server every half hour on a bad connection is a broken browser.
    private func failedCheck(_ silent: Bool) {
        guard Release.answer(newer: nil, manual: !silent, reachable: false) == .unreachable
        else { return }
        Toasts.show("Couldn't check for updates",
                    action: ("Open Releases", { NSWorkspace.shared.open(Self.releasesPage) }))
    }

    private func present(tag: String?, asset: URL?, silent: Bool) {
        // The whole of the "when may this say anything" rule, in one pure call. A launch and
        // a half-hourly tick may only ever offer a real update; "up to date" belongs to the
        // person who pressed Check for Updates and to nobody else.
        let newer = tag.flatMap { Release.isNewer($0, than: Self.currentVersion) ? $0 : nil }
        switch Release.answer(newer: newer, manual: !silent, reachable: true) {
        case .upToDate:
            Toasts.show("Vane \(Self.currentVersion) is up to date")
            return
        case .nothing:
            return
        case .unreachable:
            return failedCheck(silent)
        case .offer:
            break
        }
        guard let tag else { return }
        // No bundle (the dev binary) or a release with nothing to install: the page is the
        // honest answer, and only when the user asked.
        guard Self.isBundled, let asset else {
            if !silent { NSWorkspace.shared.open(Self.releasesPage) }
            return
        }
        // An ad-hoc or locally-signed build can download a release perfectly well and then
        // refuse it: `verified` pins Vane's Developer ID team, and this copy is not it. Say
        // so up front rather than arming an Update button whose whole journey is a download
        // followed by "Update failed".
        guard Self.isOfficialBuild else {
            if !silent {
                Toasts.show("This copy isn't signed for updates",
                            action: ("Releases", { NSWorkspace.shared.open(Self.releasesPage) }))
            }
            return
        }
        // Belt and braces with the guard in `check`: a reply that was already in flight when
        // an install started must not put an Update button back on screen underneath it.
        if working || phase == .installing || phase == .ready { return }
        // Already offered this one. Re-sticking it would undo the ×: a toast the user has
        // put away must not come back every half hour for the same release.
        if case let .available(offered) = phase, offered == tag { return }
        pending = (tag, asset)
        set(.available(tag))
    }


    // MARK: - Download

    func startDownload() {
        guard !working, let (tag, asset) = pending else { return }
        working = true
        set(.downloading(0))
        // The container's own tmp: nobody has to find this file, because nobody has to open
        // it. It is unpacked, checked and deleted without ever being shown.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vane-update-\(UUID().uuidString).zip")
        let task = URLSession.shared.downloadTask(with: asset) { tmp, response, error in
            // The temp file is gone the moment this returns, so everything that inspects it
            // happens here and the main actor hears about the result, not the file handle.
            let http = response as? HTTPURLResponse
            let size = (try? tmp.flatMap {
                try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64
            }) ?? nil
            guard error == nil, let tmp, let http, (200..<300).contains(http.statusCode),
                  // GitHub redirects the download to its asset host; the *final* url is the
                  // one the bytes came from, so it gets the same check the first one did.
                  Release.trusted(http.url ?? asset) != nil,
                  http.expectedContentLength <= Release.maxAssetBytes,
                  let size, size > 0, size <= Release.maxAssetBytes,
                  (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
            else {
                NSLog("[vane] update: download rejected (status %d, %lld bytes, from %@)",
                      http?.statusCode ?? -1, size ?? -1, (http?.url?.host() ?? "?"))
                Task { @MainActor in Updater.shared.fail() }
                return
            }
            Task { @MainActor in Updater.shared.install(dest, tag: tag) }
        }
        // No captures: the observation runs off the main actor and reaches the singleton
        // through a hop rather than holding a reference across it.
        progress = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in Updater.shared.downloaded(fraction: f) }
        }
        task.resume()
    }

    private func downloaded(fraction: Double) {
        guard working else { return }
        set(.downloading(fraction))
    }

    // MARK: - Install

    private func install(_ zip: URL, tag: String) {
        // `working` deliberately stays true across the swap — it is the flag every other
        // entry point checks. Only the detached task below clears it, and only after
        // `unpackAndSwap` has returned one way or the other.
        progress = nil
        set(.installing)
        let bundle = Bundle.main.bundleURL
        let path = Release.destination(forBundleAt: bundle.path, home: Self.realHome).path
        let target = URL(fileURLWithPath: path)
        Task.detached(priority: .userInitiated) {
            let ok = Self.unpackAndSwap(zip: zip, target: target)
            await MainActor.run {
                Updater.shared.working = false
                guard ok else { return Updater.shared.fail() }
                Updater.shared.pending = nil
                Updater.shared.installed = target
                Updater.shared.set(.ready)
            }
        }
    }

    /// The real home directory. `NSHomeDirectory()` is the container's, which has an
    /// Applications folder of its own that nobody's apps are in.
    nonisolated static var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// Unpack the release and put it at `target`, replacing whatever is there.
    ///
    /// Vesta mounts a dmg for this; Vane cannot — `hdiutil attach` is refused inside the
    /// sandbox — so the zip is expanded with `ditto -x -k`, which is allowed. Everything
    /// after that is Vesta's shape: check the new bundle, stage it beside the target, move
    /// the old one aside, move the new one in, and put the old one back if any step fails.
    /// macOS lets a running bundle be renamed, so the app can do this to itself while it is
    /// running — which is the whole reason an update needs no installer.
    nonisolated private static func unpackAndSwap(zip: URL, target: URL) -> Bool {
        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent("Vane-new-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged); try? fm.removeItem(at: zip) }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path]) else { return false }
        let incoming = staged.appendingPathComponent(target.lastPathComponent)
        guard fm.fileExists(atPath: incoming.path) else {
            NSLog("[vane] update: the release has no %@ in it", target.lastPathComponent)
            return false
        }
        guard verified(incoming) else {
            NSLog("[vane] update: the download is not signed by %@ — refusing it", Release.teamID)
            return false
        }

        let parent = target.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let new = parent.appendingPathComponent(target.lastPathComponent + ".new")
        let old = parent.appendingPathComponent(target.lastPathComponent + ".old")
        try? fm.removeItem(at: new)
        try? fm.removeItem(at: old)
        guard (try? fm.copyItem(at: incoming, to: new)) != nil else { return false }
        let replacing = fm.fileExists(atPath: target.path)
        if replacing, (try? fm.moveItem(at: target, to: old)) == nil {
            try? fm.removeItem(at: new)
            return false
        }
        guard (try? fm.moveItem(at: new, to: target)) != nil else {
            // Nothing is at the real path and the old copy is at `.old`: put it back, or the
            // next launch has no app to launch.
            if replacing { try? fm.moveItem(at: old, to: target) }
            try? fm.removeItem(at: new)
            return false
        }
        // `.old` is left for the new copy to sweep on its next launch — deleting it here
        // would unlink the bundle this very process is running out of — and the path is
        // written down so that sweep deletes *this*, not any `Vane.app.old` a user happens to
        // keep beside their app.
        //
        // The window: between the two renames above there is a moment with no bundle at
        // `target` and the running app at `.old`. A crash or a power cut inside it leaves the
        // app installed under the wrong name; the fix is a rename in Finder, and it is the
        // same window Vesta and every in-place updater has. Making it atomic needs
        // `renameatx_np(RENAME_SWAP)`, which needs both paths to already exist — they do not.
        UserDefaults.vane.set(old.path, forKey: "updateOldBundle")
        return true
    }

    /// Run a tool and say what it said. A bare `Bool` here meant a failed unpack was
    /// indistinguishable from a failed signature check in the one place there is no window
    /// to look at — so the status and the tail of stderr go to the log, which is where
    /// anyone debugging a failed update will actually be.
    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            NSLog("[vane] update: could not run %@: %@", path, error.localizedDescription)
            return false
        }
        // Read before waiting: a tool that fills the pipe blocks forever otherwise.
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            NSLog("[vane] update: %@ exited %d: %@", path, p.terminationStatus,
                  String(stderr.suffix(500)))
            return false
        }
        return true
    }

    /// The previous version, left beside the bundle by the swap that replaced it.
    /// Called once at launch: by now the process that was running out of `.old` is gone.
    static func sweep() {
        // Only the exact path a swap of ours wrote down, and only once. `Vane.app.old`
        // beside the app is otherwise just a folder with a name we happen to recognise —
        // possibly a backup somebody made on purpose — and deleting it would be Vane
        // throwing away a copy of itself nobody asked it to touch.
        if let path = UserDefaults.vane.string(forKey: "updateOldBundle") {
            UserDefaults.vane.removeObject(forKey: "updateOldBundle")
            if path.hasSuffix(".app.old") { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    private func fail() {
        working = false
        progress = nil
        set(.failed)
    }

    /// Relaunch into the copy that was just put in place, then go.
    ///
    /// Not `openApplication(at:)`: when the new bundle sits at the *same path* this process
    /// was launched from, LaunchServices sees a running instance of that application and
    /// activates it instead of starting one — so the completion handler fires, this process
    /// terminates, and there is no Vane left running at all. `createsNewApplicationInstance`
    /// would avoid that but leaves two instances racing for the same windows file.
    ///
    /// So the launch happens *after* this process is gone, the way Vesta does it: a detached
    /// `/bin/sh` waits for the pid to disappear and then opens the bundle. The helper is
    /// orphaned to launchd when we exit, which is exactly the lifetime needed, and it retries
    /// rather than leaving the user with no app if the first `open` loses a race with quit.
    /// `Process` is reachable from inside the sandbox — `ditto` in `unpackAndSwap` is the
    /// same mechanism — and the child inherits the sandbox, which `open` does not mind.
    func restart() {
        let target = installed ?? Bundle.main.bundleURL
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; "
            + "for i in 1 2 3; do /usr/bin/open \(quoted(target.path)) && exit 0; sleep 1; done; exit 1"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        do {
            try helper.run()
        } catch {
            // Could not even start the helper: stay alive and usable rather than quitting
            // into nothing. The update is installed — it just needs a manual relaunch.
            NSLog("[vane] relaunch helper failed: \(error.localizedDescription)")
            Toasts.stick("Update installed — quit and reopen Vane", id: toastID)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - The toast

    private func set(_ p: Phase) {
        phase = p
        Toasts.stick(Self.text(for: p), id: toastID, action: Self.action(for: p))
    }

    /// What the pill says, as a function of the phase — so the wording is provable without
    /// a sidebar to draw it in.
    nonisolated static func text(for phase: Phase) -> String {
        switch phase {
        case let .available(tag):   return "Vane **\(tag)** is available"
        case let .downloading(f):   return "Downloading… \(Int((f * 100).rounded()))%"
        case .installing:           return "Installing…"
        case .ready:                return "Restart to update"
        case .failed:               return "Update failed"
        }
    }

    private static func action(for phase: Phase) -> (title: String, run: @MainActor () -> Void)? {
        switch phase {
        case .available:
            return ("Update", { Updater.shared.startDownload() })
        case .downloading, .installing:
            return nil                                  // nothing to press while it works
        case .ready:
            return ("Restart", { Updater.shared.restart() })
        case .failed:
            return ("Open Releases", { NSWorkspace.shared.open(Updater.releasesPage) })
        }
    }

    // MARK: - Installing, and proving what was downloaded

    /// Install this copy into `/Applications` and relaunch from there. Returns true when
    /// that is under way and this process should do nothing else.
    ///
    /// The only toast this can produce is the one for a failure, because a failure is the
    /// only outcome the user has to know about: a copy that cannot install itself will go on
    /// running from wherever it is, and it will never be able to update itself from there.
    private func relocateIfNeeded() -> Bool {
        // Asked before anything is read off disk: a bare binary out of `.build` has no
        // bundle to move and no destination worth stat-ing.
        guard Self.isBundled else { return false }
        let source = Bundle.main.bundleURL
        let target = URL(fileURLWithPath:
            Release.destination(forBundleAt: source.path, home: Self.realHome).path)
        // What is already installed, read off disk without launching it. `nil` means the
        // destination is empty; `""` means something is there whose Info.plist could not be
        // read, and `shouldRelocate` leaves that alone rather than guessing.
        let installed = FileManager.default.fileExists(atPath: target.path)
            ? (Release.version(ofBundleAt: target) ?? "") : nil
        guard Release.shouldRelocate(bundlePath: source.path, home: Self.realHome,
                                     official: Self.isOfficialBuild,
                                     isolated: Store.overrideDirectory != nil,
                                     runningVersion: Self.currentVersion,
                                     installedVersion: installed)
        else { return false }
        Task.detached(priority: .userInitiated) {
            let ok = Self.place(source, at: target)
            await MainActor.run {
                guard ok else {
                    // Left where it is and still usable — just not updatable from there.
                    Toasts.show("Couldn't move Vane to Applications")
                    Updater.shared.begin()      // carry on as an ordinary launch
                    return
                }
                Updater.shared.installed = target
                Updater.shared.restart()
            }
        }
        return true
    }

    /// Copy a bundle to `target`, moving anything already there aside first and putting it
    /// back if the copy fails. The one move that must not lose the app that is there.
    ///
    /// Deliberately does *not* write `updateOldBundle`: the displaced copy is somebody's
    /// installed Vane, not a version this updater downloaded, so `sweep` must never delete
    /// it on the next launch. It stays as `Vane.app.old` until a person decides otherwise.
    nonisolated private static func place(_ source: URL, at target: URL) -> Bool {
        let fm = FileManager.default
        let old = URL(fileURLWithPath: target.path + ".old")
        try? fm.removeItem(at: old)
        let replacing = fm.fileExists(atPath: target.path)
        if replacing, (try? fm.moveItem(at: target, to: old)) == nil { return false }
        guard (try? fm.copyItem(at: source, to: target)) != nil else {
            if replacing { try? fm.moveItem(at: old, to: target) }
            return false
        }
        return true
    }

    /// The downloaded bundle must be signed by Vane's Developer ID team — `Release.teamID`,
    /// a constant — and its signature must be intact.
    ///
    /// The team is pinned rather than compared against the running copy. An ad-hoc build has
    /// no team, `SecCodeCopySigningInformation` can fail for reasons of its own, and either
    /// way the answer would be `nil`; a `nil` requirement makes `SecStaticCodeCheckValidity`
    /// accept *any* self-consistent signature, ad-hoc included. That is the whole check
    /// turning itself off at exactly the moment it is needed. So: one team, always, and a
    /// build that cannot name it refuses to install anything.
    ///
    /// The flags are what make this `codesign --verify --deep --strict --all-architectures`
    /// rather than a glance at the top-level seal: `checkNestedCode` walks the frameworks and
    /// helpers inside the bundle, `strictValidate` rejects the resource-envelope tricks that
    /// let unsealed files ride along, and `checkAllArchitectures` checks every slice rather
    /// than the one this Mac happens to run. Every file gets re-hashed, so a truncated or
    /// edited download is refused here rather than launched.
    nonisolated private static func verified(_ bundle: URL) -> Bool {
        guard let text = Release.pinnedRequirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode
                               | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Whether this copy is signed by the team it will demand of its downloads. `verified`
    /// pins that team regardless, so this is not what makes an update safe — it is what
    /// stops a dev build offering one. Without it a locally-signed copy downloads a release
    /// and then refuses it, and the user gets "Update failed" with no way to tell that the
    /// release was fine and the running copy was the problem. See `present`.
    nonisolated static var isOfficialBuild: Bool {
        var me: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &me) == errSecSuccess,
              let me else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(me, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String == Release.teamID
    }
}
