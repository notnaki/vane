import Network
import XCTest

@MainActor final class NavigationHTTPFixtureTests: XCTestCase {
    func testQueuedConnectionDeliveryCannotRestartStoppedFixture() async throws {
        let fixture = try NavigationHTTPFixture()
        defer { fixture.stop() }
        try await compatibilityWait { fixture.port != nil }
        let callback = try XCTUnwrap(fixture.listener.newConnectionHandler)
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        // Replay a delivery already enqueued by Network while this actor still
        // owns stop(). It must not revive the fixture once the callback runs.
        callback(connection)
        fixture.stop()
        try await compatibilityWait { fixture.connectionCallbacks == 1 }
        try await compatibilityWait { fixture.listenerCancelled }
        XCTAssertTrue(fixture.connections.isEmpty, "A queued delivery must be rejected after stop")
    }
}
