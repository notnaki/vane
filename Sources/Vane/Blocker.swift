import AppKit
import WebKit

// MARK: - The rule shape WebKit compiles

/// One content-blocker rule, in WebKit's own vocabulary. Encodable so the JSON is
/// generated rather than string-built — a hand-built rule with a stray comma fails the
/// whole compile, and a failed compile means no blocking at all.
///
/// Declaration order is the encoding order, so the same filter text always produces the
/// same bytes. That matters: the JSON's hash is the compile-cache identifier.
private struct BlockRule: Encodable, Equatable {
    struct Trigger: Encodable, Equatable {
        var urlFilter: String
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var resourceType: [String]?
        var loadType: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter     = "url-filter"
            case ifDomain      = "if-domain"
            case unlessDomain  = "unless-domain"
            case resourceType  = "resource-type"
            case loadType      = "load-type"
        }
    }

    struct Action: Encodable, Equatable {
        var type: String
        var selector: String?
    }

    var trigger: Trigger
    var action: Action

    var isException: Bool { action.type == "ignore-previous-rules" }
}

/// Ad and tracker blocking through `WKContentRuleListStore` — WebKit's own declarative
/// blocker. The rules are compiled to bytecode once and evaluated inside the network
/// process, so there is no injected JavaScript, nothing to run per page, and a blocked
/// request never leaves the machine.
///
/// ponytail: this converts a documented *subset* of EasyList syntax, not all of it.
/// WebKit's trigger vocabulary genuinely cannot express the rest (no `$important`, no
/// `$redirect`, no negated resource types, no procedural selectors), so anything outside
/// the subset is counted and dropped rather than half-translated into a rule that quietly
/// blocks the wrong thing. Upgrade path the day that stops being enough: vendor AdGuard's
/// SafariConverter instead of growing this file.
@MainActor enum Blocker {

    // MARK: - Public API

    /// Off is a real choice (some sites break, some users pay for the ads), so it persists.
    /// Defaults on — a browser that ships a blocker and leaves it off ships nothing.
    static var enabled: Bool {
        get { enabled(for: ProfileManager.shared.active.id) }
        set { setEnabled(newValue, for: ProfileManager.shared.active.id) }
    }

    /// Per profile: one profile can browse with the blocker off without turning it off for
    /// the others. The default profile keeps the un-suffixed key, so an existing preference
    /// carries over.
    static func enabled(for profileID: UUID) -> Bool {
        UserDefaults.vane.object(forKey: ProfileManager.defaultsKey("blockerEnabled", profileID)) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, for profileID: UUID) {
        UserDefaults.vane.set(on, forKey: ProfileManager.defaultsKey("blockerEnabled", profileID))
        refresh()
    }

    /// Attach the compiled list to a web view that is about to be created. Synchronous and
    /// cheap; if the first compile has not finished yet this does nothing and `refresh()`
    /// picks the tab up when it lands.
    static func apply(to configuration: WKWebViewConfiguration,
                      profileID: UUID = ProfileManager.shared.active.id) {
        apply(to: configuration.userContentController, profileID: profileID)
    }

    /// The same, for a caller that is building the controller rather than the configuration
    /// around it — a popup's, which arrives sharing the opener's and is given one of its own.
    /// See `Tab.contentController`.
    static func apply(to controller: WKUserContentController,
                      profileID: UUID = ProfileManager.shared.active.id) {
        guard enabled(for: profileID), let compiled else { return }
        controller.add(compiled)
    }

    /// Recompile from the current sources and reattach to every live web view. Cheap after
    /// the first run — the identifier is a hash of the generated JSON, so an unchanged
    /// filter set is a store lookup rather than a compile. Call it at startup.
    static func refresh() {
        let generation = refreshState.begin()
        Task {
            let wanted = ProfileManager.shared.profiles.contains { enabled(for: $0.id) }
            if wanted {
                do {
                    let fresh = try await build()
                    guard refreshState.finish(.success(fresh), generation: generation) else { return }
                    UserDefaults.vane.set(fresh.identifier, forKey: "blockerLastGoodList")
                    lastFailure = nil
                    // Publish first: recovery must always name a list that still exists.
                    // Only then can prior Vane-owned compile results be swept.
                    await sweepCompiledLists(keeping: fresh.identifier, generation: generation)
                } catch {
                    // On relaunch, recover the last successful WebKit list even if an
                    // imported source has since gone missing or become unreadable.
                    if compiled == nil,
                       let id = UserDefaults.vane.string(forKey: "blockerLastGoodList"),
                       let store = WKContentRuleListStore.default(),
                       let previous = try? await store.contentRuleList(forIdentifier: id) {
                        guard refreshState.finish(.success(previous), generation: generation) else { return }
                    }
                    guard refreshState.finish(.failure(error), generation: generation) else { return }
                    let detail = error.localizedDescription
                    if lastFailure != detail {
                        lastFailure = detail
                        NSLog("[vane] content blocker update failed: %@", detail)
                        Toasts.show(compiled == nil
                            ? "Content blocking couldn’t start. " + detail
                            : "Filter update failed; previous blocking rules remain active. " + detail)
                    }
                }
            }
            guard refreshState.isCurrent(generation) else { return }
            for store in TabStore.all {
                let on = enabled(for: store.profileID)
                for tab in store.everyTab {
                    let controller = tab.web.configuration.userContentController
                    controller.removeAllContentRuleLists()
                    if on, let compiled { controller.add(compiled) }
                }
            }
        }
    }

    /// Add a filter list from disk. Anything in EasyList syntax works — uBlock/AdGuard
    /// subscription files, a hand-written list, whatever the user already has.
    static func chooseAndAddList() {
        let panel = NSOpenPanel()
        panel.title = "Add Filter List"
        panel.message = "Choose a filter list in EasyList syntax (.txt) — an EasyList, "
            + "EasyPrivacy or uBlock Origin subscription file, or your own rules."
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let alert = NSAlert()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            alert.alertStyle = .warning
            alert.messageText = "Could not read that file."
            alert.informativeText = "It has to be a plain-text filter list."
            alert.runModal()
            return
        }
        let result = convert(text)
        guard result.rules > 0 else {
            alert.alertStyle = .warning
            alert.messageText = "No usable rules in that file."
            alert.informativeText = "\(result.skipped) line(s) were skipped. "
                + "Is it really an EasyList-syntax filter list?"
            alert.runModal()
            return
        }
        Task {
            await compileGate.acquire()
            defer { compileGate.release() }
            var validationID: String?
            do {
                guard let ruleStore = WKContentRuleListStore.default() else {
                    throw BlockerFiles.Failure("WebKit’s content-blocking store is unavailable.")
                }
                let candidate = convert(try sources() + "\n" + text).json
                let candidateID = "vane-\(hash(candidate))"
                validationID = candidateID
                guard try await ruleStore.compileContentRuleList(forIdentifier: candidateID,
                                                                 encodedContentRuleList: candidate) != nil else {
                    throw BlockerFiles.Failure("WebKit could not compile that filter list.")
                }
                let name = try BlockerFiles.importList(text, into: importedDirectory)
                var names = UserDefaults.vane.stringArray(forKey: "blockerImportedLists") ?? []
                if !names.contains(name) { names.append(name) }
                UserDefaults.vane.set(names, forKey: "blockerImportedLists")
            } catch {
                if let validationID { await removeValidationCompileIfUnreferenced(validationID) }
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t add that filter list."
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
            refresh()

            alert.messageText = "Added \(result.rules) rule\(result.rules == 1 ? "" : "s")."
            alert.informativeText = result.skipped > 0
                ? "\(result.skipped) line(s) use syntax WebKit cannot express and were skipped."
                : "Every line converted."
            alert.runModal()
        }
    }

    // MARK: - Compilation

    private static var refreshState = BlockerRefreshState<WKContentRuleList>()
    private static let compileGate = BlockerAsyncGate()
    private static var compiled: WKContentRuleList? { refreshState.current }
    private static var lastFailure: String?
    private static var importedDirectory: URL { Store.directory.appendingPathComponent("FilterLists", isDirectory: true) }

    /// Sweep only after the caller has persisted `identifier` as last-good. Re-read both
    /// protected identifiers after WebKit answers so a newer refresh that ran while this
    /// task was suspended cannot lose its current or recovery entry.
    private static func sweepCompiledLists(keeping identifier: String, generation: UInt64) async {
        await compileGate.acquire()
        defer { compileGate.release() }
        guard refreshState.isCurrent(generation) else { return }
        guard let store = WKContentRuleListStore.default(),
              let available = await store.availableIdentifiers() else { return }
        let protected = Set([identifier, compiled?.identifier,
                             UserDefaults.vane.string(forKey: "blockerLastGoodList")].compactMap { $0 })
        for stale in BlockerCache.stale(available, keeping: protected) {
            guard refreshState.isCurrent(generation) else { return }
            try? await store.removeContentRuleList(forIdentifier: stale)
        }
    }

    /// A prospective import compile is disposable when persistence fails, unless another
    /// refresh has meanwhile published that same identifier as current or last-good.
    private static func removeValidationCompileIfUnreferenced(_ identifier: String) async {
        let protected = Set([compiled?.identifier,
                             UserDefaults.vane.string(forKey: "blockerLastGoodList")].compactMap { $0 })
        guard BlockerCache.stale([identifier], keeping: protected) == [identifier],
              let store = WKContentRuleListStore.default() else { return }
        try? await store.removeContentRuleList(forIdentifier: identifier)
    }

    private static func sources() throws -> String {
        var files: [URL] = []
        // Resolve legacy selections without ScopedPaths.urls: that helper drops failed
        // bookmarks, which would silently discard part of the user's blocking rules.
        var accessed: [URL] = []
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        for entry in UserDefaults.vane.array(forKey: "blockerLists") ?? [] {
            let url: URL
            if let data = entry as? Data {
                var stale = false
                guard let resolved = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale))
                    ?? (try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale)) else {
                    throw BlockerFiles.Failure("A previously added filter file is unavailable. Reconnect its drive or restore the file.")
                }
                url = resolved
            } else if let path = entry as? String {
                url = URL(fileURLWithPath: path)
            } else {
                throw BlockerFiles.Failure("A saved filter file reference is unreadable. Restore your filter-list settings.")
            }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            files.append(url)
        }
        for name in UserDefaults.vane.stringArray(forKey: "blockerImportedLists") ?? [] {
            guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".txt") else {
                throw BlockerFiles.Failure("A saved filter-list filename is invalid.")
            }
            files.append(importedDirectory.appendingPathComponent(name))
        }
        return try BlockerFiles.sources(builtin: builtin, files: files)
    }

    /// Compile the full candidate before touching any installed rules. A failed source
    /// read or compiler response is an error, never an empty replacement list.
    private static func build() async throws -> WKContentRuleList {
        await compileGate.acquire()
        defer { compileGate.release() }
        let json = convert(try sources()).json
        guard json != "[]" else { throw BlockerFiles.Failure("The filter lists contain no usable rules.") }
        let id = "vane-\(hash(json))"
        guard let store = WKContentRuleListStore.default() else {
            throw BlockerFiles.Failure("WebKit’s content-blocking store is unavailable. Try restarting Vane.")
        }
        if let hit = try? await store.contentRuleList(forIdentifier: id) { return hit }
        do {
            guard let fresh = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
                throw BlockerFiles.Failure("WebKit did not return compiled rules.")
            }
            return fresh
        } catch {
            throw BlockerFiles.Failure("WebKit couldn’t compile the filter lists. Restore the most recently changed list and try again.")
        }
        // Keep prior compiled versions available for recovery after a failed refresh or
        // relaunch. A stale concurrent task must never sweep another task's active list.
    }

    /// FNV-1a. `hashValue` is seeded per process, which would miss the cache every launch.
    private nonisolated static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    // MARK: - EasyList → content-rule-list JSON

    /// Supported: `||domain^` host anchors, `|` start/end anchors, `*` wildcards,
    /// `@@` exceptions, `$third-party` / `$~third-party`, the resource-type options
    /// (`script`, `image`, `stylesheet`, `document`, `subdocument`, `font`, `media`,
    /// `xmlhttprequest`, `websocket`, `ping`, `popup`), `$domain=a.com|~b.com`, and
    /// `domains##selector` cosmetic rules.
    ///
    /// Skipped and counted: `/regex/` rules, `#@#` / `#?#` / `#$#` cosmetic variants,
    /// scriptlets, procedural selectors, negated resource types, `$important`,
    /// `$redirect`, `$csp`, `$removeparam`, non-ASCII patterns, and anything with an
    /// option this does not know — an unknown option can invert a rule's meaning, so an
    /// unrecognised one drops the whole line.
    nonisolated static func convert(_ text: String) -> (json: String, rules: Int, skipped: Int) {
        var rules: [BlockRule] = []
        var skipped = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if let r = rule(for: line) { rules.append(r) } else { skipped += 1 }
        }
        // WebKit applies rules in order and `ignore-previous-rules` only cancels what came
        // *before* it, so every allowlist rule has to sort after every block rule. Two
        // filters rather than sort(by:) because Swift's sort is not stable.
        let ordered = rules.filter { !$0.isException } + rules.filter { $0.isException }

        let encoder = JSONEncoder()
        // sortedKeys is load-bearing, not cosmetic: JSONEncoder does not promise a stable
        // key order, and the cache identifier is a hash of this string. Without it the hash
        // changes between runs and the rule list recompiles on every launch.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(ordered) else { return ("[]", 0, skipped) }
        return (String(decoding: data, as: UTF8.self), ordered.count, skipped)
    }

    /// One filter line to one rule, or nil if WebKit cannot express it.
    fileprivate nonisolated static func rule(for line: String) -> BlockRule? {
        // Cosmetic first: `##` lines start with `#`, which is also a comment marker.
        if let hash = line.range(of: "##") { return cosmetic(line, at: hash) }
        // Everything else with a `#` is either a hosts-file comment or one of the cosmetic
        // variants this cannot express (`#@#` exceptions, `#?#`/`#$#` procedural rules).
        // A network pattern never legitimately contains one — fragments are not sent.
        if line.contains("#") { return nil }

        var body = line
        var exception = false
        if body.hasPrefix("@@") {
            exception = true
            body = String(body.dropFirst(2))
        }

        var trigger = BlockRule.Trigger(urlFilter: "")
        if let dollar = body.firstIndex(of: "$") {
            let options = String(body[body.index(after: dollar)...])
            body = String(body[..<dollar])
            guard applyOptions(options, to: &trigger) else { return nil }
        }
        guard let filter = urlFilter(body) else { return nil }
        trigger.urlFilter = filter
        return BlockRule(trigger: trigger,
                         action: .init(type: exception ? "ignore-previous-rules" : "block"))
    }

    /// `example.com,~shop.example.com##.banner` → css-display-none.
    private nonisolated static func cosmetic(_ line: String,
                                             at hash: Range<String.Index>) -> BlockRule? {
        let selector = line[hash.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.allSatisfy({ $0.isASCII }) else { return nil }
        // Scriptlets and uBlock/AdGuard procedural selectors are not CSS; WebKit's
        // stylesheet cannot host them and a truncated version would hide the wrong nodes.
        for unsupported in ["+js(", ":has-text(", ":-abp-", ":style(", ":remove(",
                            ":matches-css", ":upward(", ":xpath(", ":nth-ancestor(", ":watch-attr("] {
            if selector.contains(unsupported) { return nil }
        }
        let domains = domainLists(line[..<hash.lowerBound].split(separator: ","))
        // `.*` because a cosmetic rule applies to every URL its domains allow.
        return BlockRule(trigger: .init(urlFilter: ".*",
                                        ifDomain: domains.yes,
                                        unlessDomain: domains.no),
                         action: .init(type: "css-display-none", selector: selector))
    }

    /// EasyList resource options → WebKit resource types. `subdocument` folds into
    /// `document` because WebKit has no separate frame type; `xmlhttprequest`, `websocket`
    /// and `ping` all fold into `raw`, which is what WebKit calls "not one of the above".
    private nonisolated static let resourceTypes: [String: String] = [
        "document": "document", "subdocument": "document",
        "script": "script", "image": "image", "stylesheet": "style-sheet",
        "font": "font", "media": "media", "popup": "popup",
        "xmlhttprequest": "raw", "websocket": "raw", "ping": "raw", "other": "raw",
    ]

    /// Returns false when an option cannot be represented — the caller then drops the rule.
    private nonisolated static func applyOptions(_ options: String,
                                                 to trigger: inout BlockRule.Trigger) -> Bool {
        var types: [String] = []
        for part in options.split(separator: ",") {
            let option = part.trimmingCharacters(in: .whitespaces).lowercased()
            switch option {
            case "third-party", "3p":
                trigger.loadType = ["third-party"]
            case "~third-party", "first-party", "1p":
                trigger.loadType = ["first-party"]
            default:
                if let type = resourceTypes[option] {
                    if !types.contains(type) { types.append(type) }
                } else if option.hasPrefix("domain=") {
                    let list = domainLists(option.dropFirst(7).split(separator: "|"))
                    guard list.yes != nil || list.no != nil else { return false }
                    trigger.ifDomain = list.yes
                    trigger.unlessDomain = list.no
                } else {
                    return false      // unknown, or a negated type: cannot be expressed
                }
            }
        }
        if !types.isEmpty { trigger.resourceType = types }
        return true
    }

    /// `*` prefixes mean "this domain and its subdomains", which is what a filter list
    /// always means by a bare domain.
    /// ponytail: WebKit rejects a trigger carrying both if-domain and unless-domain, so a
    /// mixed `$domain=a.com|~b.a.com` keeps the positives and drops the exclusions —
    /// over-blocks a subdomain rather than under-blocking everything.
    private nonisolated static func domainLists(_ parts: [Substring]) -> (yes: [String]?, no: [String]?) {
        var yes: [String] = [], no: [String] = []
        for part in parts {
            let negated = part.hasPrefix("~")
            let domain = String(negated ? part.dropFirst() : part)
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard !domain.isEmpty, domain.contains("."), !domain.contains("/"),
                  domain.allSatisfy({ $0.isASCII }) else { continue }
            if negated { no.append("*" + domain) } else { yes.append("*" + domain) }
        }
        if !yes.isEmpty { return (yes, nil) }
        return (nil, no.isEmpty ? nil : no)
    }

    /// Translate an EasyList pattern into WebKit's url-filter regex, or nil if it uses
    /// something the regex subset has no answer for.
    private nonisolated static func urlFilter(_ pattern: String) -> String? {
        // Matching is case-insensitive by default and an uppercase literal in the filter
        // would simply never match, so everything is lowered. Filter patterns have no
        // character classes of their own, so nothing is lost.
        var p = pattern.lowercased()
        guard !p.isEmpty, p.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        // /regex/ rules: full regex, not the subset WebKit accepts.
        if p.hasPrefix("/") && p.hasSuffix("/") && p.count > 2 { return nil }

        var out = ""
        if p.hasPrefix("||") {
            p = String(p.dropFirst(2))
            guard let first = p.first, first != "*", first != "|" else { return nil }
            // The optional `([^/]+\.)?` is what makes this match subdomains without also
            // matching `evilads.example.com` — the group has to end on a dot.
            out = "^https?://([^/]+\\.)?"
        } else if p.hasPrefix("|") {
            p = String(p.dropFirst())
            out = "^"
        }
        var tail = ""
        if p.hasSuffix("|") { p = String(p.dropLast()); tail = "$" }
        // A `|` left in the middle is alternation-ish syntax this does not handle.
        guard !p.isEmpty, !p.contains("|") else { return nil }

        for c in p {
            switch c {
            case "*": out += ".*"
            // The separator `^`: anything that cannot appear in a hostname or path atom.
            // A trailing one still matches because WebKit canonicalises URLs to have a
            // path, so there is always at least a `/` to consume.
            case "^": out += "[^a-z0-9_.%-]"
            case ".", "?", "+", "$", "(", ")", "[", "]", "{", "}", "\\":
                out += "\\" + String(c)
            default: out.append(c)
            }
        }
        return out + tail
    }

    // MARK: - Built-in list

    /// A starter list, so blocking works on first launch with no subscription and no
    /// network fetch. High-value ad exchanges, tag managers and session recorders only —
    /// nothing that breaks logins or payments, and no generic cosmetic rules (those are
    /// what break layouts, and they are the reason people turn blockers off).
    /// ponytail: a static constant, not a downloaded-and-updated subscription. There is no
    /// updater, no schedule and no server; the upgrade path is Add Filter List.
    private nonisolated static let builtin = """
    ! Vane built-in starter list
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^
    ||googletagservices.com^
    ||googletagmanager.com^
    ||google-analytics.com^
    ||analytics.google.com^
    ||adservice.google.com^
    ||2mdn.net^
    ||adnxs.com^
    ||adsrvr.org^
    ||amazon-adsystem.com^
    ||criteo.com^
    ||criteo.net^
    ||taboola.com^
    ||outbrain.com^
    ||scorecardresearch.com^
    ||quantserve.com^
    ||quantcount.com^
    ||moatads.com^
    ||rubiconproject.com^
    ||pubmatic.com^
    ||openx.net^
    ||casalemedia.com^
    ||indexww.com^
    ||sharethrough.com^
    ||smartadserver.com^
    ||adform.net^
    ||teads.tv^
    ||zedo.com^
    ||bidswitch.net^
    ||mathtag.com^
    ||yieldmo.com^
    ||serving-sys.com^
    ||flashtalking.com^
    ||adsafeprotected.com^
    ||doubleverify.com^
    ||ads-twitter.com^
    ||advertising.com^
    ||adcolony.com^
    ||applovin.com^
    ||inmobi.com^
    ||media.net^$third-party
    ||hotjar.com^
    ||hotjar.io^
    ||mouseflow.com^
    ||fullstory.com^
    ||crazyegg.com^
    ||mixpanel.com^
    ||segment.io^
    ||segment.com^$third-party
    ||chartbeat.com^
    ||chartbeat.net^
    ||optimizely.com^
    ||clarity.ms^
    ||branch.io^$third-party
    ||appsflyer.com^
    ||adjust.com^
    ||kissmetrics.com^
    ||connect.facebook.net^$script,third-party
    ||facebook.com/tr^$image,third-party
    ||bat.bing.com^
    ||static.ads-twitter.com^
    """

    // MARK: - Self-check

    /// `vane selfcheck`. The converter is the branchy part and the only part worth
    /// asserting: pure string in, JSON out, no WebKit, no disk, no network.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let block = rule(for: "||ads.example.com^")
        assert("||domain^ anchors to the host and allows subdomains",
               block?.trigger.urlFilter == "^https?://([^/]+\\.)?ads\\.example\\.com[^a-z0-9_.%-]")
        assert("||domain^ blocks", block?.action.type == "block")
        assert("a plain block rule carries no trigger it does not need",
               block?.trigger.resourceType == nil && block?.trigger.loadType == nil
               && block?.trigger.ifDomain == nil && block?.trigger.unlessDomain == nil)

        let allow = rule(for: "@@||good.example.com^")
        assert("@@ becomes ignore-previous-rules", allow?.action.type == "ignore-previous-rules")
        assert("@@ keeps the same url-filter as the block form",
               allow?.trigger.urlFilter == "^https?://([^/]+\\.)?good\\.example\\.com[^a-z0-9_.%-]")

        assert("$third-party sets load-type",
               rule(for: "||ads.example.com^$third-party")?.trigger.loadType == ["third-party"])
        assert("$~third-party sets first-party",
               rule(for: "||ads.example.com^$~third-party")?.trigger.loadType == ["first-party"])
        assert("$script sets resource-type",
               rule(for: "||ads.example.com^$script")?.trigger.resourceType == ["script"])
        assert("$image,$stylesheet map to WebKit's names",
               rule(for: "||ads.example.com^$image,stylesheet")?.trigger.resourceType
               == ["image", "style-sheet"])
        assert("$document is a resource type, not an option",
               rule(for: "||ads.example.com^$document")?.trigger.resourceType == ["document"])

        let scoped = rule(for: "||track.example.com^$domain=a.com|~b.com")
        assert("$domain= positives become if-domain with a subdomain wildcard",
               scoped?.trigger.ifDomain == ["*a.com"])
        assert("if-domain and unless-domain never appear together",
               scoped?.trigger.unlessDomain == nil)
        assert("a negated-only $domain= becomes unless-domain",
               rule(for: "||track.example.com^$domain=~b.com")?.trigger.unlessDomain == ["*b.com"])

        let cosmeticRule = rule(for: "example.com##.banner")
        assert("##selector becomes css-display-none",
               cosmeticRule?.action.type == "css-display-none")
        assert("##selector keeps the selector", cosmeticRule?.action.selector == ".banner")
        assert("##selector is scoped by if-domain", cosmeticRule?.trigger.ifDomain == ["*example.com"])
        assert("##selector applies to every url in those domains",
               cosmeticRule?.trigger.urlFilter == ".*")
        assert("a generic ##selector is not domain-scoped",
               rule(for: "##.ad-slot")?.trigger.ifDomain == nil)

        assert("|https://example.com/ads| anchors both ends",
               rule(for: "|https://example.com/ads|")?.trigger.urlFilter
               == "^https://example\\.com/ads$")
        assert("* becomes .*",
               rule(for: "||example.com^*/ads/")?.trigger.urlFilter
               == "^https?://([^/]+\\.)?example\\.com[^a-z0-9_.%-].*/ads/")

        // Everything below must be skipped, not emitted: a half-translated rule blocks the
        // wrong thing, and one malformed rule fails the whole compile.
        assert("a /regex/ rule is skipped", rule(for: "/ad[0-9]+\\.js/") == nil)
        assert("an unknown option is skipped", rule(for: "||ads.example.com^$redirect=noop.js") == nil)
        assert("$important is skipped", rule(for: "||ads.example.com^$important") == nil)
        assert("a negated resource type is skipped", rule(for: "||ads.example.com^$~script") == nil)
        assert("a cosmetic exception is skipped", rule(for: "example.com#@#.banner") == nil)
        assert("a scriptlet is skipped", rule(for: "example.com##+js(aopr, ads)") == nil)
        assert("a procedural selector is skipped",
               rule(for: "example.com##.item:has-text(Sponsored)") == nil)
        assert("a non-ASCII pattern is skipped", rule(for: "||рекламa.example^") == nil)
        assert("an empty pattern is skipped", rule(for: "$third-party") == nil)
        assert("a mid-pattern | is skipped", rule(for: "||example.com/a|b") == nil)

        let converted = convert("""
        ! a comment
        [Adblock Plus 2.0]

        ||ads.example.com^
        @@||good.example.com^
        /regex/
        ||more.example.com^
        """)
        assert("comments and blank lines are not counted as rules", converted.rules == 3)
        assert("unsupported lines are counted as skipped", converted.skipped == 1)
        // Hostnames appear dot-escaped in the JSON, so match on the distinctive label.
        let good = converted.json.range(of: "good")?.lowerBound
        let more = converted.json.range(of: "more")?.lowerBound
        assert("exceptions sort after blocks, or they cancel nothing",
               good != nil && more != nil && good! > more!)
        assert("the output is valid JSON",
               (try? JSONSerialization.jsonObject(with: Data(converted.json.utf8))) != nil)

        let shipped = convert(builtin)
        assert("the built-in list converts whole", shipped.skipped == 0 && shipped.rules > 30)
        assert("the built-in list is valid JSON",
               (try? JSONSerialization.jsonObject(with: Data(shipped.json.utf8))) != nil)
        assert("the same filters hash the same way", hash(shipped.json) == hash(convert(builtin).json))
        out += BlockerFiles.check()
        out += BlockerRefreshState<String>.check()
        out += BlockerCache.check()
        out += BlockerAsyncGate.check()
        return out
    }
}

/// Vane owns only identifiers with its prefix. The protected set is captured after a new
/// last-good identifier is published, so cleanup can never remove the recovery target.
enum BlockerCache {
    static func stale(_ available: [String], keeping protected: Set<String>) -> [String] {
        available.filter { $0.hasPrefix("vane-") && !protected.contains($0) }
    }

    static func check() -> [(String, Bool)] {
        let available = ["foreign", "vane-old", "vane-current", "vane-last-good"]
        let protected = Set(["vane-current", "vane-last-good"])
        let swept = stale(available, keeping: protected)
        return [
            ("compiled-list cleanup preserves current and persisted last-good rules",
             swept == ["vane-old"]),
            ("compiled-list cleanup never removes another owner's cache",
             !swept.contains("foreign")),
            ("failed validation compile is retained when it became current",
             stale(["vane-current"], keeping: protected).isEmpty),
            ("failed validation compile is removable when it is unreferenced",
             stale(["vane-validation"], keeping: protected) == ["vane-validation"]),
        ]
    }
}

/// Serializes WebKit list-store operations across their suspension points. A refresh may
/// begin while an old cleanup is awaiting WebKit, but it cannot publish its identifier until
/// that cleanup releases the gate; if the old task removed the wanted identifier, the newer
/// build recompiles it before publishing.
final class BlockerAsyncGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private var held: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(held: Bool = false) { self.held = held }

    func acquire() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if held {
                waiters.append(continuation)
                stateLock.unlock()
            } else {
                held = true
                stateLock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        stateLock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next == nil { held = false }
        stateLock.unlock()
        next?.resume()
    }

    /// A controlled reproduction of the cleanup race: removal owns the gate and pauses;
    /// promotion starts while it is paused, then must run after removal and restore the id.
    static func check() -> [(String, Bool)] {
        final class Fixture: @unchecked Sendable {
            let lock = NSLock()
            let removalEntered = DispatchSemaphore(value: 0)
            let promotionStarted = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            var identifiers = Set(["vane-promoted"])
            func remove() { lock.withLock { _ = identifiers.remove("vane-promoted") } }
            func promote() { lock.withLock { _ = identifiers.insert("vane-promoted") } }
            func containsPromoted() -> Bool { lock.withLock { identifiers.contains("vane-promoted") } }
        }

        let gate = BlockerAsyncGate()
        let removalPause = BlockerAsyncGate(held: true)
        let fixture = Fixture()
        Task.detached {
            await gate.acquire()
            fixture.removalEntered.signal()
            await removalPause.acquire()
            removalPause.release()
            fixture.remove()
            gate.release()
        }
        guard fixture.removalEntered.wait(timeout: .now() + 2) == .success else {
            removalPause.release()
            return [("compiled-list operations serialize across WebKit suspension", false)]
        }
        Task.detached {
            fixture.promotionStarted.signal()
            await gate.acquire()
            fixture.promote()
            gate.release()
            fixture.finished.signal()
        }
        guard fixture.promotionStarted.wait(timeout: .now() + 2) == .success else {
            removalPause.release()
            return [("compiled-list operations serialize across WebKit suspension", false)]
        }
        removalPause.release()
        let completed = fixture.finished.wait(timeout: .now() + 2) == .success
        return [("a newly promoted compiled identifier cannot be left removed",
                 completed && fixture.containsPromoted())]
    }
}

/// Only the newest refresh may publish. Failed candidates leave the current value intact.
struct BlockerRefreshState<Value> {
    private(set) var current: Value?
    private var generation: UInt64 = 0
    mutating func begin() -> UInt64 { generation &+= 1; return generation }
    func isCurrent(_ candidate: UInt64) -> Bool { candidate == generation }
    @discardableResult
    mutating func finish(_ result: Result<Value, Error>, generation candidate: UInt64) -> Bool {
        guard isCurrent(candidate) else { return false }
        if case let .success(value) = result { current = value }
        return true
    }
}

extension BlockerRefreshState where Value == String {
    static func check() -> [(String, Bool)] {
        var state = Self()
        let first = state.begin()
        state.finish(.success("working"), generation: first)
        let failed = state.begin()
        state.finish(.failure(BlockerFiles.Failure("compiler failure")), generation: failed)
        let retained = state.current == "working"
        let obsolete = state.begin()
        let newest = state.begin()
        state.finish(.success("newest"), generation: newest)
        let rejected = !state.finish(.success("obsolete"), generation: obsolete)
        _ = state.finish(.failure(BlockerFiles.Failure("late failure")), generation: obsolete)
        return [("failed filter compilation retains working rules", retained),
                ("out-of-order filter refresh cannot replace current rules", rejected && state.current == "newest")]
    }
}

/// Files imported into Vane are owned snapshots, so moving the original cannot silently
/// change protection. Source loading fails as a whole if any requested list is unreadable.
enum BlockerFiles {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func importList(_ text: String, into directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".txt"
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return name
    }

    static func sources(builtin: String, files: [URL]) throws -> String {
        var result = builtin
        for file in files {
            do { result += "\n" + (try String(contentsOf: file, encoding: .utf8)) }
            catch { throw Failure("Couldn’t read filter list “\(file.lastPathComponent)”. Restore that file or reconnect its drive, then retry.") }
        }
        return result
    }

    static func check() -> [(String, Bool)] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Vane-filter-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let original = root.appendingPathComponent("original.txt")
            let text = "||fixture.example^"
            try text.write(to: original, atomically: true, encoding: .utf8)
            let folder = root.appendingPathComponent("owned")
            let name = try importList(try String(contentsOf: original, encoding: .utf8), into: folder)
            try fm.removeItem(at: original)
            let owned = folder.appendingPathComponent(name)
            let loaded = try sources(builtin: "builtin", files: [owned])
            var out = [("imported filter list survives removal of original", loaded == "builtin\n" + text)]
            do {
                _ = try sources(builtin: "builtin", files: [owned, original])
                out.append(("missing filter input fails whole candidate instead of dropping protection", false))
            } catch {
                out.append(("missing filter input fails whole candidate instead of dropping protection", true))
            }
            let file = root.appendingPathComponent("not-a-directory")
            try Data().write(to: file)
            do {
                _ = try importList(text, into: file)
                out.append(("failed filter import reports persistence failure", false))
            } catch {
                out.append(("failed filter import reports persistence failure", true))
            }
            return out
        } catch { return [("filter filesystem fixtures: \(error.localizedDescription)", false)] }
    }
}
