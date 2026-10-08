import XCTest
@testable import vane

final class SpaceDotBlendTests: XCTestCase {
    func testCommittingDestinationStaysFullyLitBeforeOffsetClears() {
        let destination = UUID()
        for fraction in [0.0, 0.3, 1.0] {
            XCTAssertEqual(SpaceDotBlend.weights(current: destination, target: destination,
                                                 fraction: fraction), [destination: 1])
        }
    }

    func testInterruptedTravelConservesTheTwoDotWeights() {
        let current = UUID(), target = UUID()
        let weights = SpaceDotBlend.weights(current: current, target: target, fraction: 0.3)
        XCTAssertEqual(weights[current], 0.7)
        XCTAssertEqual(weights[target], 0.3)
        XCTAssertEqual(weights.values.reduce(0, +), 1)
    }
}
