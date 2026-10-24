import Foundation
import XCTest
@testable import vane

final class ArcSidebarSplitTests: XCTestCase {
    private func sidebar(_ items: [[String: Any]], pinned: [String], today: [String] = []) throws -> ArcSidebar {
        let all: [[String: Any]] = [
            ["id": "pins", "childrenIds": pinned, "data": ["itemContainer": [:]]],
            ["id": "today", "childrenIds": today, "data": ["itemContainer": [:]]]
        ] + items
        let box: [String: Any] = [
            "spaces": ["space", ["id": "space", "title": "Imported", "profile": ["default": true],
                                     "containerIDs": ["pinned", "pins", "unpinned", "today"]]],
            "items": all.flatMap { [$0["id"]!, $0] }
        ]
        let data = try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [["global": [:]], box]]])
        return try XCTUnwrap(ArcSidebar.parse(data))
    }

    private func tab(_ id: String, url: String? = nil) -> [String: Any] {
        ["id": id, "data": ["tab": ["savedURL": url ?? "https://\(id.lowercased()).example/", "savedTitle": id]]]
    }

    private func split(_ ids: [String], orientation: String = "horizontal", weights: [Double] = [0.5, 0.5],
                       focus: String = "A") -> [String: Any] {
        ["id": "S", "childrenIds": ids, "data": ["splitView": ["layoutOrientation": orientation,
            "itemWidthFactors": weights, "focusItemID": focus, "timeLastActiveAt": 0, "customInfo": [:]]]]
    }

    func testPinnedSplitPreservesEveryPaneAtItsSidebarPosition() throws {
        let parsed = try sidebar([tab("before"), split(["A", "B"]), tab("A"), tab("B"), tab("after")],
                                 pinned: ["before", "S", "after"])
        XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["before", "A", "B", "after"])
    }

    func testUnknownRowsAndNestedContainersPreserveReachableTabs() throws {
        let parsed = try sidebar([
            ["id": "new", "childrenIds": ["nested"], "data": ["futureRow": [:]]],
            ["id": "nested", "childrenIds": ["A", "new"], "data": ["itemContainer": [:]]], tab("A")
        ], pinned: ["new", "A"])
        XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["A"])
    }

    func testOversizedSplitPreservesAllFivePanesRatherThanTruncating() throws {
        let parsed = try sidebar([split(["A", "B", "C", "D", "E"], weights: [1, 1, 1, 1, 1])] +
            ["A", "B", "C", "D", "E"].map { tab($0) }, pinned: ["S"])
        XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["A", "B", "C", "D", "E"])
    }


    func testSplitWithMissingPaneKeepsRemainingPagesAndContinuesAfterIt() throws {
        let parsed = try sidebar([split(["A", "missing", "B"]), tab("A"), tab("B"), tab("after")],
                                 pinned: ["S", "after"])
        XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["A", "B", "after"])
    }


    func testTwoThreeAndFourPanesKeepLayoutOrientationSharesFocusAndPlacement() throws {
        let cases: [(ids: [String], orientation: String, weights: [Double], focus: String, active: Int)] = [
            (["A", "B"], "horizontal", [1, 3], "B", 1),
            (["A", "B", "C"], "vertical", [2, 3, 5], "C", 2),
            (["A", "B", "C", "D"], "horizontal", [1, 2, 3, 4], "A", 0)
        ]
        let expectedWeights = [[0.25, 0.75], [0.2, 0.3, 0.5], [0.1, 0.2, 0.3, 0.4]]
        for (index, fixture) in cases.enumerated() {
            let parsed = try sidebar([tab("before"), split(fixture.ids, orientation: fixture.orientation,
                weights: fixture.weights, focus: fixture.focus), tab("after")] + fixture.ids.map { tab($0) },
                pinned: ["before", "S", "after"])
            let layout = ArcImport.layout(pinned: parsed.spaces[0].pinned, today: [])
            try layout.validate()
            XCTAssertEqual(layout.tabs.map(\.title), ["before"] + fixture.ids + ["after"])
            XCTAssertEqual(layout.pins.tabs, layout.tabs.map { $0.id.uuidString })
            let saved = try XCTUnwrap(layout.splits.first)
            XCTAssertEqual(layout.splits.count, 1)
            XCTAssertEqual(saved.ids, Array(layout.tabs.dropFirst().dropLast()).map { $0.id.uuidString })
            XCTAssertEqual(saved.vertical, fixture.orientation == "vertical")
            XCTAssertEqual(saved.active, fixture.active)
            XCTAssertEqual(saved.weights, expectedWeights[index])
            XCTAssertTrue(parsed.warnings.messages.isEmpty)
            let restored = try JSONDecoder().decode(SpaceLayout.self, from: JSONEncoder().encode(layout))
            XCTAssertEqual(restored, layout)
        }
    }

    func testSameURLPanesRemainDistinctInsideFoldersAndToday() throws {
        let parsed = try sidebar([
            ["id": "folder", "title": "Project", "childrenIds": ["S"], "data": ["list": [:]]],
            split(["A", "B"], focus: "B"), tab("A", url: "https://same.example/"),
            tab("B", url: "https://same.example/"), tab("other", url: "https://same.example/")
        ], pinned: ["folder"], today: ["other"])
        let layout = ArcImport.layout(pinned: parsed.spaces[0].pinned, today: parsed.spaces[0].today)
        try layout.validate()
        XCTAssertEqual(layout.tabs.map(\.title), ["A", "B", "other"])
        XCTAssertEqual(Set(layout.tabs.map(\.id)).count, 3)
        XCTAssertEqual(layout.tabs.map(\.kind), [.pinned, .pinned, .today])
        XCTAssertEqual(layout.pins.entries[1].parent, layout.pins.entries[0].folder?.id)
        XCTAssertEqual(layout.pins.entries[2].parent, layout.pins.entries[0].folder?.id)
        XCTAssertEqual(layout.splits[0].ids, Array(layout.tabs.prefix(2)).map { $0.id.uuidString })
    }

    func testMalformedSplitMetadataFallsBackWithoutDroppingPages() throws {
        let cases: [[String: Any]] = [
            split(["A", "B"], orientation: "diagonal"),
            split(["A", "B"], weights: [0, 1]),
            split(["A", "B"], weights: [1]),
            split(["A", "B"], focus: "gone"),
            split(["A", "A", "B"]),
            ["id": "S", "childrenIds": ["A", "B"], "data": ["splitView": "broken"]]
        ]
        for fixture in cases {
            let parsed = try sidebar([fixture, tab("A"), tab("B")], pinned: ["S", "A"])
            XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["A", "B"])
            XCTAssertEqual(parsed.warnings.flattenedSplits, 1)
            XCTAssertTrue(ArcImport.layout(pinned: parsed.spaces[0].pinned, today: []).splits.isEmpty)
        }
    }

    func testUnknownRowsAreReportedAndTheirChildrenDoNotDisappear() throws {
        let parsed = try sidebar([
            ["id": "new", "childrenIds": ["A"], "data": ["futureRow": [:]]], tab("A")
        ], pinned: ["new", "missing"])
        XCTAssertEqual(parsed.warnings.skippedRowTypes, ["futureRow": 1, "missing item": 1])
        var counts = ArcImport.Counts()
        counts.spaces = 1
        counts.sidebarWarnings = parsed.warnings
        XCTAssertTrue(ArcImport.report(counts).contains("futureRow"))
        XCTAssertTrue(ArcImport.report(counts).contains("missing item"))
        let scan = ArcImport.Scan(root: URL(fileURLWithPath: "/fixture"), sidebar: parsed, profiles: [])
        XCTAssertTrue(ArcImport.summary(scan).contains("futureRow"))
    }


    func testMalformedChildReferenceDoesNotDiscardItsValidNeighbours() throws {
        let parsed = try sidebar([
            ["id": "S", "childrenIds": ["A", 7, "B"], "data": ["splitView": [:]]], tab("A"), tab("B")
        ], pinned: ["S"])
        XCTAssertEqual(ArcSidebar.flatten(parsed.spaces[0].pinned).map(\.title), ["A", "B"])
        XCTAssertEqual(parsed.warnings.flattenedSplits, 1)
        XCTAssertEqual(parsed.warnings.skippedRowTypes["invalid child reference"], 1)
        XCTAssertTrue(parsed.spaces[0].hasSplitViews)
    }

}
