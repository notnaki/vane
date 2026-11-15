import XCTest
@testable import vane

@MainActor final class AITabIndexTests: XCTestCase {
    func testUntrustedExtremeIndicesAreDroppedBeforeConversion() {
        let groups = AppleAI.tidyGroups([(name: "Valid", tabs: [Int.min, -1, 0, 1, Int.max, 2, 1])], ids: ["a", "b"])
        XCTAssertEqual(groups?.first?.ids, ["a", "b"])
    }
}
