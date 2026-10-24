import Foundation
import XCTest
@testable import vane

@MainActor final class ArcRoutingImportTests: XCTestCase {
    func testScanIncludesRoutingFileInImportConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-arc-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = #"{"sidebar":{"containers":[{"spaces":[],"items":[]}]}}"#
        try Data(sidebar.utf8).write(to: root.appendingPathComponent("StorableSidebar.json"))
        let routing = #"{"version":1,"defaultDestination":{"littleArc":{"_0":{"mostRecent":{}}}},"rules":[]}"#
        try Data(routing.utf8).write(to: root.appendingPathComponent("StorableLinkRouting.json"))
        let result = await ArcImport.scan(root)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(ArcImport.summary(scan).contains("Little Vane"))
    }

    private func rule(_ pattern: String, match: String = "contains", destination: [String: Any]) -> [String: Any] {
        ["id": UUID().uuidString, "sourceComponents": [["id": UUID().uuidString,
            "componentType": ["urlMatch": ["_0": [match: [:]], "_1": pattern]]]], "destination": destination]
    }

    private let little: [String: Any] = ["littleArc": ["_0": ["mostRecent": [:]]]]
    private let recent: [String: Any] = ["space": ["_0": ["mostRecent": [:]]]]

    private func routing(_ rules: [[String: Any]], defaultDestination: [String: Any]? = nil) throws -> ArcLinkRouting {
        var top: [String: Any] = ["version": 1, "rules": rules]
        top["defaultDestination"] = defaultDestination
        return try XCTUnwrap(ArcLinkRouting.parse(JSONSerialization.data(withJSONObject: top)))
    }

    func testOrderedRulesMapContainsExactRecentLittleAndImportedSpace() throws {
        let id = UUID()
        let parsed = try routing([
            rule("meet.google.com", destination: little),
            rule("github.com", match: "isEqualTo", destination: recent),
            rule("/work", destination: ["space": ["_0": ["arc-work": [:]]]])
        ], defaultDestination: little)
        let plan = parsed.plan(existing: [], spaceIDs: ["arc-work": id])
        XCTAssertEqual(plan.rules.map(\.pattern), ["meet.google.com", "github.com", "/work"])
        XCTAssertEqual(plan.rules.map(\.match), [.contains, .isEqualTo, .contains])
        XCTAssertEqual(plan.rules.map(\.destination), ["little", "recent", id.uuidString])
        XCTAssertEqual(plan.added, 3)
        XCTAssertEqual(plan.skipped, 0)
        XCTAssertEqual(parsed.defaultTarget, "little")
        let work = Space(id: id, name: "Work", profileID: UUID())
        XCTAssertEqual(AirTraffic.route(url: URL(string: "https://github.com/notnaki/vane")!, rules: plan.rules,
                                        spaces: [work]), .mostRecentSpace)
        XCTAssertNil(AirTraffic.route(url: URL(string: "https://other.github.com/")!, rules: plan.rules, spaces: [work]))
        XCTAssertEqual(AirTraffic.route(url: URL(string: "https://example.com/work")!, rules: plan.rules,
                                        spaces: [work]), .space(id))
    }

    func testUnmappedSpacesAndUnsupportedMatchesAreReportedWithoutBroadeningRules() throws {
        var multiple = rule("one", destination: little)
        multiple["sourceComponents"] = (multiple["sourceComponents"] as! [[String: Any]]) +
            (rule("two", destination: little)["sourceComponents"] as! [[String: Any]])
        let parsed = try routing([
            rule("missing", destination: ["space": ["_0": ["not-imported": [:]]]]),
            rule("unknown", match: "startsWith", destination: little), multiple,
            rule("   ", destination: little), rule("kept", destination: recent)
        ])
        let plan = parsed.plan(existing: [], spaceIDs: [:])
        XCTAssertEqual(plan.rules.map(\.pattern), ["kept"])
        XCTAssertEqual(plan.skipped, 4)
        var counts = ArcImport.Counts()
        counts.routingRulesSkipped = plan.skipped
        XCTAssertTrue(ArcImport.report(counts).contains("4 Air Traffic Control rules were skipped"))
    }

    func testExistingPrecedenceAndRepeatedImportsKeepRulesOnce() throws {
        let existing = AirTraffic.Rule(match: .contains, pattern: "existing", destination: "little")
        let parsed = try routing([rule("existing", destination: little), rule("new", destination: recent),
                                  rule("new", destination: recent)])
        let first = parsed.plan(existing: [existing], spaceIDs: [:])
        XCTAssertEqual(first.rules.map(\.pattern), ["existing", "new"])
        XCTAssertEqual(first.rules.first, existing)
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(first.already, 2)
        let second = parsed.plan(existing: first.rules, spaceIDs: [:])
        XCTAssertEqual(second.rules, first.rules)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.already, 3)
        XCTAssertTrue(parsed.consent.contains("after existing Vane rules"))
    }

    func testAcceptedDefaultReplacesExistingValueAndKeepsExistingRules() throws {
        TestEnvironment.prepare()
        let existing = AirTraffic.Rule(match: .contains, pattern: "existing", destination: "little")
        AirTraffic.rules = [existing]
        UserDefaults.vane.set("space", forKey: LinkTarget.key)
        let parsed = try routing([rule("imported", destination: recent)], defaultDestination: little)
        var counts = ArcImport.Counts()
        ArcImport.importRouting(parsed, unavailable: false, spaceIDs: [:], counts: &counts)
        XCTAssertEqual(AirTraffic.rules.map(\.pattern), ["existing", "imported"])
        XCTAssertEqual(UserDefaults.vane.string(forKey: LinkTarget.key), "little")
        XCTAssertEqual(counts.routingRules, 1)
        XCTAssertEqual(counts.routingDefault, "little")
        let spaceDefault = try routing([], defaultDestination: recent)
        ArcImport.importRouting(spaceDefault, unavailable: false, spaceIDs: [:], counts: &counts)
        XCTAssertEqual(UserDefaults.vane.string(forKey: LinkTarget.key), "space")
    }

    func testAbsentMalformedAndUnsupportedRoutingPreservesPreferences() throws {
        TestEnvironment.prepare()
        let existing = AirTraffic.Rule(match: .isEqualTo, pattern: "existing.example", destination: "recent")
        AirTraffic.rules = [existing]
        UserDefaults.vane.set("space", forKey: LinkTarget.key)
        let malformed = ["not json", #"{"version":2,"rules":[]}"#, #"{"version":1,"rules":{}}"#,
                         #"{"version":true,"rules":[]}"#]
        for data in malformed {
            let parsed = ArcLinkRouting.parse(Data(data.utf8))
            XCTAssertNil(parsed)
            var counts = ArcImport.Counts()
            ArcImport.importRouting(parsed, unavailable: true, spaceIDs: [:], counts: &counts)
            XCTAssertEqual(AirTraffic.rules, [existing])
            XCTAssertEqual(UserDefaults.vane.string(forKey: LinkTarget.key), "space")
            XCTAssertTrue(ArcImport.report(counts).contains("existing link settings were kept"))
        }
        var counts = ArcImport.Counts()
        ArcImport.importRouting(nil, unavailable: false, spaceIDs: [:], counts: &counts)
        XCTAssertEqual(AirTraffic.rules, [existing])
        XCTAssertFalse(counts.routingUnavailable)
        let unsupported = try routing([], defaultDestination: ["unknown": [:]])
        ArcImport.importRouting(unsupported, unavailable: false, spaceIDs: [:], counts: &counts)
        XCTAssertEqual(UserDefaults.vane.string(forKey: LinkTarget.key), "space")
        XCTAssertTrue(counts.routingDefaultUnsupported)
    }

    func testExplicitSpaceStringPayloadUsesOnlyTheImportedIdentity() throws {
        let mapped = UUID()
        let parsed = try routing([rule("one", destination: ["space": ["_0": "arc-work"]])])
        XCTAssertEqual(parsed.plan(existing: [], spaceIDs: ["arc-work": mapped]).rules.first?.destination,
                       mapped.uuidString)
        XCTAssertEqual(parsed.plan(existing: [], spaceIDs: [:]).skipped, 1)
    }


    func testMalformedEnumPayloadsAreSkippedWithoutInventingDestinations() throws {
        var brokenMatch = rule("broken", destination: little)
        brokenMatch["sourceComponents"] = [["componentType": ["urlMatch": ["_0": ["contains": "broken"], "_1": "broken"]]]]
        let parsed = try routing([brokenMatch,
            rule("broken recent", destination: ["space": ["_0": ["mostRecent": 7]]]),
            rule("good", destination: little)
        ], defaultDestination: ["space": [:]])
        XCTAssertEqual(parsed.plan(existing: [], spaceIDs: [:]).rules.map(\.pattern), ["good"])
        XCTAssertEqual(parsed.skippedRules, 2)
        XCTAssertNil(parsed.defaultTarget)
        XCTAssertTrue(parsed.unsupportedDefault)
    }

}
