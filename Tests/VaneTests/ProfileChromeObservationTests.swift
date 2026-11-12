import Combine
import XCTest
@testable import vane

@MainActor final class ProfileChromeObservationTests: XCTestCase {
    func testActiveProfilePersistenceDoesNotInvalidateWindowMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ProfileManager(directory: directory, sandboxed: true)
        let other = manager.create(name: "Other")
        let chrome = manager.chromeObservation
        var changes = 0
        let observation = chrome.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        manager.active = other
        XCTAssertEqual(manager.active.id, other.id)
        XCTAssertEqual(changes, 0, "A default-profile change must not invalidate window-local chrome")
        _ = manager.create(name: "Metadata changed")
        XCTAssertGreaterThan(changes, 0, "Profile metadata must still reach every retained chrome tree")
        changes = 0
        XCTAssertTrue(manager.saveSpaces([Space(name: "New Space", profileID: other.id)], for: other.id))
        XCTAssertGreaterThan(changes, 0, "Saved Space metadata must remain observable")
    }
}
