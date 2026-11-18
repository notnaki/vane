import Foundation
import XCTest
@testable import vane

/// An Arc profile whose name matches Vane's default profile ("Personal") must not be merged
/// into that default profile. Arc's `Default` owns it by identity; any other Arc profile must
/// get a profile of its own.
@MainActor final class ArcProfileNameCollisionTests: XCTestCase {
    func testOtherArcProfileNamedLikeVaneDefaultGetsItsOwnProfile() throws {
        TestEnvironment.prepare()
        let defaultName = try XCTUnwrap(
            ProfileManager.shared.profiles.first(where: { $0.id == ProfileManager.defaultID })?.name)
        let scan = ArcImport.Scan(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("arc-collision-\(UUID())"),
            sidebar: ArcSidebar(),
            profiles: [ArcProfile(directory: "Profile 2", name: defaultName)],
            directories: ["Profile 2"])
        var counts = ArcImport.Counts()

        let ids = ArcImport.profileIDs(for: scan, counts: &counts)

        let personal = try XCTUnwrap(ids["Profile 2"])
        XCTAssertNotEqual(personal, ProfileManager.defaultID,
                          "Arc's Profile 2 was merged into Vane's default profile by name")
    }
}
