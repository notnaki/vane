import XCTest
@testable import vane

@MainActor final class PaletteActionRankingTests: XCTestCase {
    private func sections(_ query: String, titles: [String]) -> (leading: [String], trailing: [String]) {
        Palette.commandSections(query, commands: Palette.rank(query, titles, key: { $0 }), title: { $0 })
    }

    func testStrongActionTermsLeadByTitleOrWordPrefix() {
        let titles = ["Pin Tab", "Spinning Board", "Archive Tab", "Add Split View", "Mute Tab", "Unmute Tab"]
        for (query, expected) in [("pin", "Pin Tab"), ("archive", "Archive Tab"),
                                  ("split", "Add Split View"), ("mute", "Mute Tab")] {
            let result = sections(query, titles: titles)
            XCTAssertEqual(result.leading, [expected], query)
            XCTAssertFalse(result.trailing.contains(expected), "A promoted action must occur only once")
        }
        XCTAssertEqual(sections("  PIN TAB\n", titles: titles).leading, ["Pin Tab"])
        XCTAssertEqual(sections("edit", titles: ["Édit Site"]).leading, ["Édit Site"])
    }

    func testShortFuzzyAndMidwordMatchesRemainInTheTail() {
        for (query, titles) in [("pi", ["Pin Tab"]), ("pnt", ["Pin Tab"]),
                                 ("pin", ["Spinning Board", "Unpin Tab"]), ("", ["Pin Tab"])] {
            let result = sections(query, titles: titles)
            XCTAssertTrue(result.leading.isEmpty, query)
            XCTAssertEqual(result.trailing, Palette.rank(query, titles, key: { $0 }))
        }
    }

    func testOnlyBestStrongActionLeadsAndEqualScoresKeepCatalogueOrder() {
        let titles = ["Tab One", "Tab Two", "Rename Tab", "Archive Tab"]
        let ranked = Palette.rank("tab", titles, key: { $0 })
        let result = sections("tab", titles: titles)
        XCTAssertEqual(result.leading, ["Tab One"])
        XCTAssertEqual(result.trailing, Array(ranked.dropFirst()))
        XCTAssertEqual(Set(result.leading + result.trailing), Set(ranked))
        XCTAssertEqual(result.leading.count + result.trailing.count, ranked.count)
    }

    func testLeadingActionSurvivesHistoryCapAndLateSuggestionsAfterAStrongTab() {
        let commands = sections("pin", titles: ["Pin Tab", "Spinning Board"])
        let history = (0..<50).map { "history:\($0)" }
        let layout = Feel03PaletteLayout(leading: ["strong-tab", "typed"] + commands.leading,
            trailing: Array((["weak-tab", "archive"] + commands.trailing).prefix(24)),
            assistant: "assistant", acceptsSuggestions: true)
        for suggestions in [[], history] {
            let rows = Feel03PaletteLayout.visible(layout.rows(suggestions: suggestions),
                limit: 24, retaining: nil, id: { $0 })
            XCTAssertEqual(Array(rows.prefix(3)), ["strong-tab", "typed", "Pin Tab"])
            XCTAssertEqual(rows.filter { $0 == "Pin Tab" }, ["Pin Tab"])
            XCTAssertLessThanOrEqual(rows.count, 24)
        }
    }

    func testSearchRemainsTheDefaultWhenAnActionIsPromoted() {
        let commands = sections("pin", titles: ["Pin Tab"])
        let layout = Feel03PaletteLayout(leading: ["typed"] + commands.leading,
            trailing: commands.trailing, assistant: "assistant", acceptsSuggestions: true)
        let rows = layout.rows(suggestions: ["history"])
        XCTAssertEqual(rows.first, "typed", "Return must retain its search/navigation default")
        XCTAssertEqual(Array(rows.prefix(2)), ["typed", "Pin Tab"])
        XCTAssertEqual(rows.filter { $0 == "Pin Tab" }.count, 1)
    }
}
