import Foundation
import XCTest
@testable import vane

final class ExtensionFilterRulesTests: XCTestCase {
    func testExceptionsAndImportantRulesKeepTheirPrecedenceInEveryChunk() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ad-one\n/ad-two\n@@/allowed\n/ad-important$important"], trustedSites: [], chunkLimit: 3)
        XCTAssertEqual(result.chunks.count, 2)
        for chunk in result.chunks {
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [[String: Any]])
            let types = rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
            let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
            XCTAssertLessThanOrEqual(rules.count, 3)
            XCTAssertTrue(filters.contains("/allowed"))
            if let important = filters.firstIndex(of: "/ad-important"), let exception = filters.firstIndex(of: "/allowed") {
                XCTAssertGreaterThan(important, exception)
            }
            XCTAssertEqual(types[try XCTUnwrap(filters.firstIndex(of: "/allowed"))], "ignore-previous-rules")
        }
    }

    func testTrustedHostsAndExactURLsDoNotExpandToUnrelatedPages() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads\n/critical$important"], trustedSites: ["example.com", "https://other.test/page", "about-scheme", "# comment"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.chunks[0].utf8)) as? [[String: Any]])
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let patterns = try XCTUnwrap(trigger["unless-top-url"] as? [String])
            func matches(_ url: String) -> Bool { patterns.contains { url.range(of: $0, options: .regularExpression) != nil } }
            XCTAssertTrue(matches("https://sub.example.com/path"))
            XCTAssertFalse(matches("https://badexample.com/path"))
            XCTAssertTrue(matches("https://other.test/page"))
            XCTAssertFalse(matches("https://other.test/page2"))
        }
    }

    func testBadfilterCancelsAcrossListsAndHostsFilesConvert() throws {
        let result = try ExtensionFilterRules.compile(texts: ["||disabled.test^$image,third-party\n0.0.0.0 ads.test\n127.0.0.1 localhost", "||disabled.test^$third-party,image,badfilter"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 1)
        XCTAssertTrue(result.chunks[0].contains("ads"))
        XCTAssertFalse(result.chunks[0].contains("disabled"))
    }

    func testBadfilterUsesCaseInsensitivePatternsAndEquivalentPartyAliases() throws {
        let result = try ExtensionFilterRules.compile(texts: ["||Ads.test^$3p,image", "||ads.test^$image,third-party,badfilter"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 0)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    func testUnrepresentableTypesAndConditionalsAreNotBroadened() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/xhr$xmlhttprequest\n/frame$subdocument\n/redirect$redirect=noop\n!#if env_chromium\n/conditional\n!#endif\n/image$image"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 1)
        XCTAssertEqual(result.report.skipped, 4)
        XCTAssertTrue(result.chunks[0].contains("image"))
        XCTAssertFalse(result.chunks[0].contains("conditional"))
    }

    func testRegexAnchorsCannotHideUnrepresentableResourceOptions() throws {
        let types = ["document", "subdocument", "xmlhttprequest", "xhr", "websocket", "ping", "other", "popup"]
        let result = try ExtensionFilterRules.compile(texts: [types.map { "/blocked$/$\($0)" }.joined(separator: "\n")], trustedSites: [])
        XCTAssertEqual(result.report.rules, 0)
        XCTAssertEqual(result.report.skipped, types.count)
        XCTAssertTrue(result.chunks.isEmpty)
    }

    func testAnchoredRegexKeepsBadfilterAndImportantPrecedence() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads$/$image\n/critical$/$image,important\n@@/critical$/$image", "/ads$/$image,badfilter"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 2)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.chunks[0].utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }, ["ignore-previous-rules", "block"])
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertEqual(trigger["url-filter"] as? String, "critical$")
            XCTAssertEqual(trigger["resource-type"] as? [String], ["image"])
        }
    }

    func testUntranslatableTrustedDirectivesAndOversizedPoliciesFailAsAWhole() {
        XCTAssertThrowsError(try ExtensionFilterRules.compile(texts: ["/ads"], trustedSites: ["/arbitrary-regex/"]))
        XCTAssertThrowsError(try ExtensionFilterRules.compile(texts: [String(repeating: "x", count: 65537)], trustedSites: []))
        XCTAssertThrowsError(try ExtensionFilterRules.compile(texts: ["/one\n/two\n@@/allowed"], trustedSites: [], chunkLimit: 1))
    }

    func testConditionalBadfiltersCannotDisableRulesAndStateStopsAtSourceBoundary() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads\n!#if env_other\n/ads$badfilter", "/image$IMAGE\n/xhr$XMLHTTPREQUEST"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 2)
        XCTAssertEqual(result.report.skipped, 1)
    }

    func testTrustedWildcardHostsCannotMatchAHostEmbeddedInAnotherSitesPath() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads"], trustedSites: ["https://*.trusted.test/*"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.chunks[0].utf8)) as? [[String: Any]])
        let trigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let pattern = try XCTUnwrap((trigger["unless-top-url"] as? [String])?.first)
        XCTAssertNotNil("https://sub.trusted.test/path".range(of: pattern, options: .regularExpression))
        XCTAssertNil("https://evil.test/https://sub.trusted.test/path".range(of: pattern, options: .regularExpression))
    }

    func testInvalidImportantExceptionsAndCosmeticRulesStayWithUBlock() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads$important\n@@/ads$important\n##.ad"], trustedSites: [])
        XCTAssertEqual(result.report.rules, 1)
        XCTAssertEqual(result.report.skipped, 2)
        XCTAssertFalse(result.chunks[0].contains("ignore-previous-rules"))
        XCTAssertFalse(result.chunks[0].contains("css-display-none"))
    }

    func testUntypedRulesDoNotCancelDocumentNavigation() throws {
        let result = try ExtensionFilterRules.compile(texts: ["/ads\n@@/allowed\n/important$important"], trustedSites: [])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.chunks[0].utf8)) as? [[String: Any]])
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let types = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(types.contains("document"))
            XCTAssertTrue(types.contains("raw"))
        }
    }

    func testWildcardTrustWithoutALabelBoundaryFailsInsteadOfTrustingSuffixLookalikes() {
        XCTAssertThrowsError(try ExtensionFilterRules.compile(texts: ["/ads"], trustedSites: ["https://*trusted.test/*"]))
    }
}
