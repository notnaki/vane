import Foundation
import XCTest

/// Source policy coverage for the three SwiftUI host labels; no window server is needed.
final class AddressPillPolicyTests: XCTestCase {
    func testEveryAddressPillElidesFromTheSubdomainEnd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Vane/UI.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct PillBody: View"))
        let end = try XCTUnwrap(source.range(of: "    private var axValue:", range: start.upperBound..<source.endIndex))
        let pill = String(source[start.lowerBound..<end.lowerBound])
        let labels = try NSRegularExpression(pattern: #"Text\(host\)[^\n]*|Text\(address\.isEmpty[^\n]*\n(?:[^\n]*\n)?[^\n]*truncationMode[^\n]*"#)
        let matches = labels.matches(in: pill, range: NSRange(pill.startIndex..., in: pill))
        XCTAssertEqual(matches.count, 4, "Regular, compact, Little Vane, and the toolbar must all retain the real domain")
        for match in matches {
            let range = try XCTUnwrap(Range(match.range, in: pill))
            XCTAssertTrue(pill[range].contains("truncationMode(.head)"), String(pill[range]))
        }
    }
}
