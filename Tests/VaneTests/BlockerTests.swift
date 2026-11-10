import XCTest
import WebKit
@testable import vane

@MainActor final class BlockerTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }

    func testDiagnosticsKeepLineNumbersAndCountReasons() {
        let result = Blocker.convert("! comment\n\n||ads.example^\n/(regex|alternative)/\nexample.com##+js(foo)\n||x.example^$redirect=noop\n")
        XCTAssertEqual(result.rules, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.diagnostics.map(\.line), [4, 5, 6])
        XCTAssertEqual(result.reasonCounts["Regular expression"], 1)
        XCTAssertEqual(result.reasonCounts["Scriptlet or procedural selector"], 1)
    }

    func testCaseSensitiveRulesPreservePatternCase() throws {
        let converted = Blocker.convert("/BannerAd.gif$match-case\n/BannerAd.gif")
        XCTAssertEqual(converted.rules, 2)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(converted.json.utf8)) as? [[String: Any]])
        guard rules.count == 2 else { return }
        let sensitive = try XCTUnwrap(rules[0]["trigger"] as? [String: Any])
        let insensitive = try XCTUnwrap(rules[1]["trigger"] as? [String: Any])
        XCTAssertEqual(sensitive["url-filter-is-case-sensitive"] as? Bool, true)
        XCTAssertEqual(sensitive["url-filter"] as? String, #"/BannerAd\.gif"#)
        XCTAssertEqual(insensitive["url-filter"] as? String, #"/bannerad\.gif"#)
    }

    func testNegatedTypesNarrowExplicitPositiveTypes() throws {
        let converted = Blocker.convert("||ads.example^$script,image,~image\n||ads.example^$image,~image")
        XCTAssertEqual(converted.rules, 1)
        XCTAssertEqual(converted.skipped, 1)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(converted.json.utf8)) as? [[String: Any]])
        let trigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["script"])
    }

    func testUnsupportedNegationsCannotBroadenOrInvertRules() {
        for options in ["~image", "script,~script", "xmlhttprequest,~ping", "image,~other", "script,~document"] {
            let converted = Blocker.convert("||ads.example^$" + options)
            XCTAssertEqual(converted.rules, 0, options)
            XCTAssertEqual(converted.skipped, 1, options)
        }
    }

    func testCaseSensitiveSeparatorStillTreatsUppercaseLettersAsWordCharacters() throws {
        let converted = Blocker.convert("Banner^$match-case")
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(converted.json.utf8)) as? [[String: Any]])
        let trigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let pattern = try XCTUnwrap(trigger["url-filter"] as? String)
        XCTAssertNil("https://example.invalid/BannerAd".range(of: pattern, options: .regularExpression))
        XCTAssertNotNil("https://example.invalid/Banner/Ad".range(of: pattern, options: .regularExpression))
    }

    func testMixedAndMalformedDomainsNeverBecomeBroaderRules() {
        for text in ["||ads.example^$domain=a.com|~b.a.com", "invalid##.ad", "||ads.example^$domain=valid.com|bad/path", "a.com,~b.a.com##.ad"] {
            XCTAssertEqual(Blocker.convert(text).rules, 0, text)
            XCTAssertEqual(Blocker.convert(text).skipped, 1, text)
        }
    }

    func testConditionalBranchesAreNotUnconditionallyInstalled() {
        let result = Blocker.convert("!#if env_chromium\n||conditional.example^\n!#else\n||other.example^\n!#endif\n||always.example^")
        XCTAssertEqual(result.rules, 1)
        XCTAssertEqual(result.skipped, 2)
    }

    func testDiagnosticSamplesAreBoundedButCountsAreComplete() {
        let result = Blocker.convert(Array(repeating: "/(regex|alternative)/", count: 100).joined(separator: "\n"))
        XCTAssertEqual(result.skipped, 100)
        XCTAssertEqual(result.diagnostics.count, 20)
        XCTAssertEqual(result.reasonCounts["Regular expression"], 100)
    }
}

extension BlockerTests {
    func testSiteExceptionsPersistPerProfileAndPrivateExceptionsStayInMemory() {
        let profile = UUID(), other = UUID()
        let key = ProfileManager.defaultsKey("blockerSiteExceptions", profile)
        defer { UserDefaults.vane.removeObject(forKey: key) }
        Blocker.setSiteException("example.com", allowed: true, profileID: profile, recompile: false)
        XCTAssertEqual(Blocker.siteExceptions(for: profile), ["example.com"])
        XCTAssertTrue(Blocker.siteExceptions(for: other).isEmpty)
        XCTAssertFalse(Blocker.enabled(for: profile, url: URL(string: "https://example.com/path")))
        XCTAssertTrue(Blocker.enabled(for: profile, url: URL(string: "https://sub.example.com")))
        Blocker.setSiteException("private.example", allowed: true, profileID: Profile.incognito.id, recompile: false)
        XCTAssertNil(UserDefaults.vane.object(forKey: ProfileManager.defaultsKey("blockerSiteExceptions", Profile.incognito.id)))
        Blocker.setSiteException("private.example", allowed: false, profileID: Profile.incognito.id, recompile: false)
    }

    func testExceptionRegexExcludesExactTopHostForNetworkAndCosmeticRules() async throws {
        let converted = Blocker.convert("||ads.example^\n##.ad", excludingHosts: ["example.com"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(converted.json.utf8)) as? [[String: Any]])
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let patterns = try XCTUnwrap(trigger["unless-top-url"] as? [String])
            let regex = try NSRegularExpression(pattern: patterns[0])
            for (url, match) in [("https://example.com/path", true), ("http://example.com:8080/", true), ("https://sub.example.com/", false), ("https://evil-example.com/", false)] {
                XCTAssertEqual(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, match)
            }
        }
        let id = "vane-test-\(UUID())"
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        _ = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: converted.json)
        try await store.removeContentRuleList(forIdentifier: id)
    }
}

extension BlockerTests {
    func testCRLFReportsOriginalLineNumbers() {
        let result = Blocker.convert("! heading\r\n||ads.example^\r\n/(regex|alternative)/\r\n")
        XCTAssertEqual(result.diagnostics.first?.line, 3)
    }
}

extension BlockerTests {
    func testConditionalStateCannotSuppressAnotherSourceOrItsExceptions() {
        let result = Blocker.convertSources(["||first.example^\n!#if env_chromium", "||second.example^\n@@||allowed.example^"])
        XCTAssertEqual(result.rules, 3)
        XCTAssertTrue(result.json.contains("second"))
        XCTAssertTrue(result.json.contains("ignore-previous-rules"))
    }

    func testImportDialogKeepsLongDiagnosticsInScrollingReport() {
        let report = Blocker.convert(Array(repeating: String(repeating: "x", count: 230) + "$redirect=noop", count: 20).joined(separator: "\n")).report
        let alert = Blocker.makeImportSuccessAlert(report)
        XCTAssertLessThan(alert.informativeText.count, 500)
        XCTAssertEqual(alert.buttons.map(\.title), ["Done", "Unsupported Rules…"])
    }

    func testAcceptedSnapshotStillRecompilesSiteExceptionsAfterSourceFailure() async throws {
        let profile = ProfileManager.shared.active.id
        let saved = UserDefaults.vane.object(forKey: "blockerLists")
        let exceptionKey = ProfileManager.defaultsKey("blockerSiteExceptions", profile)
        let savedExceptions = UserDefaults.vane.object(forKey: exceptionKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("legacy.txt")
        try "||fixture.example^".write(to: file, atomically: true, encoding: .utf8)
        UserDefaults.vane.set([file.path], forKey: "blockerLists")
        defer {
            UserDefaults.vane.set(saved, forKey: "blockerLists")
            UserDefaults.vane.set(savedExceptions, forKey: exceptionKey)
            try? FileManager.default.removeItem(at: root)
        }
        await withCheckedContinuation { continuation in Blocker.refresh(completion: { continuation.resume() }) }
        try FileManager.default.removeItem(at: file)
        Blocker.setSiteException("fixture.example", allowed: true, profileID: profile, recompile: false)
        await withCheckedContinuation { continuation in Blocker.refresh(completion: { continuation.resume() }) }
        XCTAssertTrue(Blocker.hasCurrentExceptionVariant(for: profile))
        XCTAssertTrue(BlockerStatus.shared.message.contains("Previous working rules"))
    }

    func testPrivateRuleCacheIsSeparateAndSweepingPreservesLiveOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cache: BlockerPrivateCache? = try BlockerPrivateCache(root: root)
        let directory = try XCTUnwrap(cache?.directory)
        let store = try XCTUnwrap(cache?.store)
        let id = "vane-private-test-\(UUID())"
        let json = Blocker.convert("||ads.example^", excludingHosts: ["private.example"]).json
        _ = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
        let defaultIDs = await WKContentRuleListStore.default()?.availableIdentifiers() ?? []
        XCTAssertFalse(defaultIDs.contains(id))
        try BlockerPrivateCache.sweep(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        cache?.close(removeFiles: false) // Simulate a crashed process releasing its owner lock.
        cache = nil
        try BlockerPrivateCache.sweep(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

extension BlockerTests {
    func testSafeRegularExpressionsPreserveAnchorsClassesEscapesAndOptions() throws {
        for source in [#"/\/ad[0-9]+\.js$/$script,match-case"#, #"/^https?:\/\/ads\.example\//"#, #"@@/ad[abc]?.js/$image"#] {
            XCTAssertEqual(Blocker.convert(source).rules, 1, source)
            XCTAssertEqual(Blocker.convert(source).skipped, 0, source)
        }
        for source in [#"/(ad|tracker)/"#, #"/ad\d+/"#, #"/ad{2}/"#, #"/(?=ad)/"#, #"/ad^x/"#, #"/ad[Z-a]/"#, #"/ad.*?/"#, #"/ad/$unknown"#] {
            XCTAssertEqual(Blocker.convert(source).rules, 0, source)
            XCTAssertEqual(Blocker.convert(source).skipped, 1, source)
        }
    }

    func testBadfilterDisablesOnlyMatchingSupportedNetworkRuleAcrossSources() {
        let result = Blocker.convertSources(["/ad.js$script\n/ad.js$image\n@@/allowed.js$script", "/ad.js$badfilter,script\n@@/allowed.js$script,badfilter"])
        XCTAssertEqual(result.rules, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.json.contains("image"))
        XCTAssertFalse(result.json.contains("ignore-previous-rules"))
        let conditional = Blocker.convert("/ad.js\n!#if unknown\n/ad.js$badfilter\n!#endif")
        XCTAssertEqual(conditional.rules, 1)
        XCTAssertEqual(conditional.skipped, 1)
        for source in ["/ad.js$redirect=noop,badfilter", "example.com#@#.ad$badfilter", "/ad.js$badfilter,badfilter"] {
            XCTAssertEqual(Blocker.convert(source).skipped, 1)
        }
    }

    func testBadfilterCanonicalizesSupportedPartyAliasesDomainsAndInsensitivePatterns() {
        for (rule, modifier) in [
            ("/ad.js$3p", "/ad.js$third-party,badfilter"),
            ("/ad.js$first-party", "/ad.js$1p,badfilter"),
            ("@@/ad.js$1p", "@@/ad.js$~third-party,badfilter"),
            ("/Ad.js$domain=a.example|b.example", "/ad.js$domain=B.EXAMPLE|a.example,badfilter"),
            ("/ad.js$domain=~a.example|~b.example", "/ad.js$domain=~b.example|~a.example,badfilter")
        ] {
            let result = Blocker.convertSources([rule, modifier])
            XCTAssertEqual(result.rules, 0, rule)
            XCTAssertEqual(result.skipped, 0, modifier)
        }
        let sensitive = Blocker.convertSources(["/Ad.js$match-case", "/ad.js$match-case,badfilter"])
        XCTAssertEqual(sensitive.rules, 1, "A case-sensitive pattern is a different filter")
        let distinctTypes = Blocker.convertSources(["/ad.js$xmlhttprequest", "/ad.js$websocket,badfilter"])
        XCTAssertEqual(distinctTypes.rules, 1, "WebKit's shared raw bucket does not make these EasyList types equivalent")
    }
}

extension BlockerTests {
    func testBadfilterDomainDecompositionIsReportedInsteadOfPretendingToDisableSubset() {
        let conversion = Blocker.convert("*$domain=a.example|b.example\n*$domain=b.example,badfilter")
        XCTAssertEqual(conversion.rules, 1)
        XCTAssertEqual(conversion.skipped, 1)
    }
}

extension BlockerTests {
    func testLinkedSourcePublicationValidatesAllOtherSourcesBeforeSaving() async throws {
        let defaults = UserDefaults.vane
        let savedSnapshots = defaults.object(forKey: LocalFilterSources.snapshotsKey)
        let savedLegacy = defaults.object(forKey: "blockerLists")
        defer {
            if let savedSnapshots { defaults.set(savedSnapshots, forKey: LocalFilterSources.snapshotsKey) }
            else { defaults.removeObject(forKey: LocalFilterSources.snapshotsKey) }
            if let savedLegacy { defaults.set(savedLegacy, forKey: "blockerLists") }
            else { defaults.removeObject(forKey: "blockerLists") }
        }
        let source = LocalFilterSource(name: "synthetic.txt", text: "||linked.example^", report: Blocker.convert("||linked.example^").report)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults.set([missing.path], forKey: "blockerLists")
        do { try await Blocker.commitLinkedSources([source]); XCTFail("Must include unavailable legacy sources in candidate admission") } catch { }
        XCTAssertEqual(defaults.data(forKey: LocalFilterSources.snapshotsKey), savedSnapshots as? Data)
        defaults.set([], forKey: "blockerLists")
        try await Blocker.commitLinkedSources([source])
        XCTAssertEqual(try LocalFilterSources.read(defaults: defaults), [source])
        defaults.set([missing.path], forKey: "blockerLists")
        do { try await Blocker.commitLinkedSources([]); XCTFail("Removal must validate remaining sources") } catch { }
        XCTAssertEqual(try LocalFilterSources.read(defaults: defaults), [source])
    }
}

extension BlockerTests {
    func testBadfilterRejectsRepeatedOrderSensitiveOptionsWithoutRemovingDifferentRule() {
        for source in [
            "/ad.js$domain=a.example,domain=b.example\n/ad.js$domain=b.example,domain=a.example,badfilter",
            "/ad.js$third-party,~third-party\n/ad.js$~third-party,third-party,badfilter"
        ] {
            let conversion = Blocker.convert(source)
            XCTAssertEqual(conversion.rules, 1)
            XCTAssertEqual(conversion.skipped, 1)
        }
    }
}
