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

    /// The `.dmg` if the release has one, else the `.zip`. Both are published; the dmg is
    /// the one a person can mount and drag, so it wins.
    static func asset(_ assets: [(name: String, url: String)]) -> URL? {
        func pick(_ ext: String) -> URL? {
            assets.first { $0.name.lowercased().hasSuffix(ext) }
                .flatMap { URL(string: $0.url) }
        }
        return pick(".dmg") ?? pick(".zip")
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

    // MARK: - What a download has to prove

    /// The Developer ID team every Vane release is signed by.
    static let teamID = "T7X84HN3W3"

    /// The designated requirement a downloaded release must satisfy, given the team the
    /// *running* copy is signed by. An ad-hoc build (no team) gets `nil`: a copy with no
    /// Developer ID cannot honestly demand one of its replacement, and pretending otherwise
    /// would make every local build refuse every real release. A signed copy demands its own
    /// team, so a release signed by anybody else — or by nobody — is refused.
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

        let dmg = "https://example.com/Vane.dmg", zip = "https://example.com/Vane.zip"
        out.append(("the dmg is the asset to fetch",
                    asset([("Vane.zip", zip), ("Vane.dmg", dmg)])?.absoluteString == dmg))
        out.append(("...whatever order the release lists them in",
                    asset([("Vane.dmg", dmg), ("Vane.zip", zip)])?.absoluteString == dmg))
        out.append(("a zip-only release still updates",
                    asset([("Vane.zip", zip)])?.absoluteString == zip))
        out.append(("case does not matter", asset([("VANE.DMG", dmg)])?.absoluteString == dmg))
        out.append(("a release with no bundle in it offers nothing",
                    asset([("notes.txt", "https://example.com/notes.txt")]) == nil))
        out.append(("an asset whose url is not a url is not an asset",
                    asset([("Vane.dmg", "")]) == nil))

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
/// Vesta's `Updater.swift`, with one difference that changes the ending — Vane is sandboxed.
///
/// Vesta swaps its own bundle: mount the dmg, copy the new app beside the running one, move
/// the old aside, relaunch. Every step of that is denied here, measured rather than assumed
/// (a probe app signed with `Vane.entitlements`, run three ways):
///
///   * the bundle's parent directory is not writable — not in `~/Applications`, not
///     anywhere; `isWritableFile` says false and the write fails
///   * the running bundle cannot be moved aside, same reason
///   * `hdiutil attach` fails outright ("Device not configured"): DiskArbitration is not
///     reachable from a sandboxed process, so the dmg can never be mounted in-process
///   * every file a sandboxed app writes is stamped `com.apple.quarantine`, and
///     `removexattr` on it is denied — so a copy made from inside could not be launched
///     even if it could be made
///
/// So the last step belongs to the user: Vane downloads the release, checks its signature,
/// and opens it. Finder mounts the image and the drag to Applications is a drag.
/// ponytail: no NSOpenPanel grant on the parent folder either. It would buy the write, but
/// not the mount and not the de-quarantine, so it would be a permission prompt that still
/// ends in "drag it yourself". Ceiling: a Developer-ID-signed *helper* outside the sandbox,
/// or leaving the sandbox — both cost more than this feature is worth.
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
        case installing             // handing the image to Finder
        case ready                  // downloaded and open; the drag is the user's
        case failed
    }

    private(set) var phase: Phase?
    private var pending: (tag: String, asset: URL)?
    private var downloaded: URL?
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
        if silent, working || downloaded != nil { return }
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
                present(tag: UserDefaults.vane.string(forKey: Keys.tag),
                        asset: UserDefaults.vane.string(forKey: Keys.asset)
                            .flatMap(URL.init(string:)), silent: silent)
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
        guard !silent else { return }
        Toasts.show("Couldn't check for updates",
                    action: ("Open Releases", { NSWorkspace.shared.open(Self.releasesPage) }))
    }

    private func present(tag: String?, asset: URL?, silent: Bool) {
        guard let tag, Release.isNewer(tag, than: Self.currentVersion) else {
            if !silent { Toasts.show("Vane \(Self.currentVersion) is up to date") }
            return
        }
        // No bundle (the dev binary) or a release with nothing to install: the page is the
        // honest answer, and only when the user asked.
        guard Self.isBundled, let asset else {
            if !silent { NSWorkspace.shared.open(Self.releasesPage) }
            return
        }
        // Already offered this one. Re-sticking it would undo the ×: a toast the user has
        // put away must not come back every half hour for the same release.
        if case let .available(offered) = phase, offered == tag { return }
        pending = (tag, asset)
        set(.available(tag))
    }

    /// The user's real `~/Downloads`, which `com.apple.security.files.downloads.read-write`
    /// grants — and which none of the APIs that name it will hand back:
    /// `urls(for: .downloadsDirectory)` and `NSHomeDirectory()` both answer with the
    /// container's redirected copy, a path no Finder window will ever show. The passwd entry
    /// is the one place the real home survives the sandbox. A downloaded update has to land
    /// somewhere the user can find, because finding it is the last step of the install.
    nonisolated static var downloadsFolder: URL {
        guard let pw = getpwuid(getuid()) else { return DownloadLocation.systemDownloads }
        let home = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        return FileManager.default.fileExists(atPath: downloads.path)
            ? downloads : DownloadLocation.systemDownloads
    }

    // MARK: - Download

    func startDownload() {
        guard !working, let (tag, asset) = pending else { return }
        working = true
        set(.downloading(0))
        let dest = Downloads.uniqueDestination(in: Self.downloadsFolder,
                                               suggested: asset.lastPathComponent)
        let task = URLSession.shared.downloadTask(with: asset) { tmp, response, _ in
            // The temp file is gone the moment this returns, so it moves synchronously here
            // and the main actor hears about the result, not the file handle.
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard let tmp, ok, (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else {
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

    private func install(_ file: URL, tag: String) {
        working = false
        progress = nil
        set(.installing)
        // The one check that is still ours to make. Gatekeeper will run it again when the
        // app is launched from Applications, but by then a tampered image has already been
        // mounted and its contents shown; refusing here is cheaper and clearer.
        guard Self.verified(file) else {
            try? FileManager.default.removeItem(at: file)
            return fail()
        }
        downloaded = file
        pending = nil
        // Finder is not sandboxed: it mounts the image, and the volume that opens has
        // Vane.app in it. That is the whole install, and it is the user's to finish.
        guard NSWorkspace.shared.open(file) else { return fail() }
        set(.ready)
    }

    /// The downloaded image must be signed by the same Developer ID team as the running
    /// copy. An ad-hoc build has no team to compare against, so it only checks that the
    /// signature it does have is intact — which is still worth doing: `checkValidity`
    /// re-hashes the file, so a truncated or edited download is caught here.
    /// A release built without secrets is not signed at all and has no signature to check;
    /// that is a `nil` static code, and it is refused.
    nonisolated private static func verified(_ file: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        if let text = Release.requirement(forTeam: runningTeam()) {
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
            else { return false }
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The team the running copy is signed by, or nil when it is ad-hoc signed.
    nonisolated private static func runningTeam() -> String? {
        var me: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &me) == errSecSuccess,
              let me else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(me, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func fail() {
        working = false
        progress = nil
        set(.failed)
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
        case .ready:                return "Drag Vane to Applications to finish"
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
            return ("Show in Finder", {
                guard let file = Updater.shared.downloaded else { return }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        case .failed:
            return ("Open Releases", { NSWorkspace.shared.open(Updater.releasesPage) })
        }
    }
}
