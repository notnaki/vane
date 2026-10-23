import XCTest
@testable import vane

@MainActor final class BootstrapIngressGateTests: XCTestCase {
    func testRecoveryDefersAndDrainsExternalIngressInArrivalOrder() {
        let gate = BootstrapIngressGate()
        gate.block()
        var opened: [String] = []
        for kind in ["Finder files", "reopen", "Dock new window", "external link"] {
            gate.submit { opened.append(kind) }
        }
        XCTAssertTrue(opened.isEmpty)
        gate.complete()
        XCTAssertEqual(opened, ["Finder files", "reopen", "Dock new window", "external link"])
        gate.submit { opened.append("ready") }
        XCTAssertEqual(opened.last, "ready")
        gate.complete()
        XCTAssertEqual(opened.count, 5)
    }
}
