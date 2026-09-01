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
        UserDefaults.standard.object(forKey: ProfileManager.defaultsKey("blockerEnabled", profileID)) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, for profileID: UUID) {
        UserDefaults.standard.set(on, forKey: ProfileManager.defaultsKey("blockerEnabled", profileID))
        refresh()
    }

    /// Attach the compiled list to a web view that is about to be created. Synchronous and
    /// cheap; if the first compile has not finished yet this does nothing and `refresh()`
    /// picks the tab up when it lands.
    static func apply(to configuration: WKWebViewConfiguration,
                      profileID: UUID = ProfileManager.shared.active.id) {
        guard enabled(for: profileID), let compiled else { return }
        configuration.userContentController.add(compiled)
    }

    /// Recompile from the current sources and reattach to every live web view. Cheap after
    /// the first run — the identifier is a hash of the generated JSON, so an unchanged
    /// filter set is a store lookup rather than a compile. Call it at startup.
    static func refresh() {
        Task {
            // One compiled list for the app — the filters are the same everywhere, only
            // whether they are attached is per profile.
            let wanted = ProfileManager.shared.profiles.contains { enabled(for: $0.id) }
            compiled = wanted ? await build() : nil
            for store in TabStore.all {
                let on = enabled(for: store.profileID)
                for tab in store.tabs {
                    let controller = tab.web.configuration.userContentController
                    // Vane is the only thing adding rule lists, so a blunt reset is fine.
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
        // ponytail: the path is remembered, not the file. Move or delete the list and it
        // silently stops applying. Copying it into Application Support is the fix if that
        // ever bites; not worth the code until it does.
        var paths = listPaths
        if !paths.contains(file.path) { paths.append(file.path) }
        listPaths = paths
        refresh()

        alert.messageText = "Added \(result.rules) rule\(result.rules == 1 ? "" : "s")."
        alert.informativeText = result.skipped > 0
            ? "\(result.skipped) line(s) use syntax WebKit cannot express and were skipped."
            : "Every line converted."
        alert.runModal()
    }

    // MARK: - Compilation

    private static var compiled: WKContentRuleList?

    /// Extra lists the user added, by path. The built-in list is always on top of these.
    private static var listPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "blockerLists") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "blockerLists") }
    }

    private static func sources() -> String {
        var text = builtin
        for path in listPaths {
            if let extra = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
                text += "\n" + extra
            }
        }
        return text
    }

    /// Look the compiled list up by identifier first — compiling is the slow part and
    /// WebKit already persists the result on disk, so startup after the first run is a
    /// lookup. The identifier carries a hash of the JSON, so editing the filters (or the
    /// built-in list shipping a new version) invalidates the cache by construction.
    private static func build() async -> WKContentRuleList? {
        let json = convert(sources()).json
        guard json != "[]" else { return nil }     // WebKit refuses to compile an empty list
        let id = "vane-\(hash(json))"
        // Unannotated `instancetype` on the ObjC side, so Swift sees it as optional.
        guard let store = WKContentRuleListStore.default() else { return nil }

        if let hit: WKContentRuleList = try? await store.contentRuleList(forIdentifier: id) {
            return hit
        }
        let fresh: WKContentRuleList? = try? await store.compileContentRuleList(
            forIdentifier: id, encodedContentRuleList: json)
        // Every edit leaves a compiled list behind on disk; sweep the old ones.
        if fresh != nil {
            for old in await store.availableIdentifiers() ?? []
            where old.hasPrefix("vane-") && old != id {
                try? await store.removeContentRuleList(forIdentifier: old)
            }
        }
        return fresh
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
        return out
    }
}
