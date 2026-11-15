import Foundation
import XCTest
@testable import vane

final class HistoryCSVSecurityTests: XCTestCase {
    func testUntrustedHistoryTextCannotStartSpreadsheetFormulas() throws {
        let titles = ["=1+1", "+SUM(1,2)", "-1+2", "@SUM(A1)", "\tformula", "\rformula", "\nformula", " \t=1", "  +1"]
        for title in titles {
            let input = Export.Row(url: title, title: title, at: Date(timeIntervalSince1970: 1))
            let cells = CSV.rows(Export.historyCSV([input]))
            XCTAssertEqual(cells[1][0], "'" + title)
            XCTAssertEqual(cells[1][1], "'" + title)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Export.historyJSON([input]).utf8)) as? [[String: Any]])
            XCTAssertEqual(json[0]["title"] as? String, title)
        }
    }

    func testOrdinaryHistoryAndPasswordCSVsPreserveExactText() {
        let row = Export.Row(url: "https://example.test/a,b", title: "A \"title\"", at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(Export.parseHistoryCSV(Export.historyCSV([row])), [row])
        XCTAssertEqual(CSV.rows(Export.csv([["=secret", "+account"]]))[0], ["=secret", "+account"])
    }
}
