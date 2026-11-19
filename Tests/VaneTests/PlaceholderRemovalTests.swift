import Foundation
import XCTest
@testable import vane

/// The empty Space a default profile is born with is removed before an import writes its
/// Spaces, and a placeholder that holds tabs is kept.
@MainActor final class PlaceholderRemovalTests: XCTestCase {
    func testEmptyPlaceholderNamedAfterTheProfileIsRemoved() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = try XCTUnwrap(manager.profiles.first { $0.id == ProfileManager.defaultID })
        let placeholder = manager.createSpace(name: profile.name, in: ProfileManager.defaultID)

        ArcImport.removeEmptyPlaceholder(in: ProfileManager.defaultID)

        XCTAssertFalse(manager.spaces(for: ProfileManager.defaultID).contains { $0.id == placeholder.id },
                       "An empty placeholder named after its profile should be removed")
    }

    func testPlaceholderWithTabsIsKept() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = try XCTUnwrap(manager.profiles.first { $0.id == ProfileManager.defaultID })
        var placeholder = manager.createSpace(name: profile.name, in: ProfileManager.defaultID)
        placeholder.tabURLs = [try XCTUnwrap(URL(string: "https://example.test/keep"))]
        XCTAssertTrue(manager.updateSpace(placeholder))

        ArcImport.removeEmptyPlaceholder(in: ProfileManager.defaultID)

        XCTAssertTrue(manager.spaces(for: ProfileManager.defaultID).contains { $0.id == placeholder.id },
                      "A placeholder that still holds tabs must not be deleted")
        _ = Spaces.delete(placeholder.id, in: ProfileManager.defaultID)
    }
}
