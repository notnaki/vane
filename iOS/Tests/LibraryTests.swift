import XCTest
@testable import Vane

/// The two promises sync rests on: records go back to iCloud exactly as they came, and
/// records made here use the Mac's identities, so the Mac never sees a duplicate.
@MainActor final class LibraryTests: XCTestCase {
    func testUnknownFieldsRoundTripAndMacIdentities() async throws {
        let library = Library(deviceID: "device-\(UUID())")
        let profile = UUID(), space = UUID()
        let macSpace = ICloudItem(category: .spaces, id: space.uuidString, profileID: profile, parentID: nil, fields: [
            "name": Data(#""Work""#.utf8), "position": Data("0".utf8), "tint": Data("0.4".utf8), "futureField": Data(#"{"a":1}"#.utf8)])
        try await library.apply([macSpace], deleted: [], enabled: library.categories)
        let captured = try await library.capture(library.categories)
        XCTAssertEqual(captured.first { $0.key == macSpace.key }, macSpace, "fields the app doesn't show must go back unchanged")
        XCTAssertEqual(library.spaces.first { $0.id == space }?.name, "Work")

        // ICloudLibraryAdapter: id = SHA-256 of "<profile UUID>|<url>", url as a JSON string.
        let url = URL(string: "https://example.com/a")!
        library.addFavourite(url, profile: profile)
        let favourite = try XCTUnwrap(library.items.values.first { $0.category == .favourites && $0.profileID == profile })
        XCTAssertEqual(favourite.id, ICloudIdentity.digest("\(profile)|https://example.com/a"))
        XCTAssertEqual(favourite.fields["url"], try JSONEncoder().encode("https://example.com/a"))

        // A theme edit writes what the Mac's Spaces.setThemeColors writes, and drops its exact palette.
        var themed = try XCTUnwrap(library.spaces.first { $0.id == space })
        themed.colors = ["#6CBAD9", "#F29BBB"]
        library.setTheme(themed)
        let edited = try XCTUnwrap(library.items[macSpace.key])
        XCTAssertEqual(edited.fields["colorHex"], try JSONEncoder().encode("#6CBAD9"))
        XCTAssertEqual(edited.fields["colors"], try JSONEncoder().encode(["#6CBAD9", "#F29BBB"]))
        XCTAssertNil(edited.fields["themePalette"])
        XCTAssertEqual(edited.fields["futureField"], macSpace.fields["futureField"])

        try await library.apply([], deleted: [macSpace], enabled: library.categories)
        XCTAssertNil(library.spaces.first { $0.id == space })
        library.remove(favourite.key)
    }

    /// Incognito tabs never reach iCloud, history or the saved session.
    func testIncognitoLeavesNothing() async throws {
        let library = Library(deviceID: "device-\(UUID())")
        XCTAssertNil(library.publishingProfile(for: SpaceRow.incognito.id), "Incognito tabs must not be published as open tabs")
        let browser = Browser()
        let before = browser.history.count
        browser.switchSpace(SpaceRow.incognito.id)
        browser.open(URL(string: "https://example.com/secret")!)
        let tab = try XCTUnwrap(browser.selected)
        XCTAssertTrue(tab.isPrivate)
        tab.onChange(); tab.onLoaded()
        XCTAssertEqual(browser.history.count, before)
        let saved = try JSONDecoder().decode([Tab.Saved].self, from: Data(contentsOf: Store.directory.appending(path: "tabs.json")))
        XCTAssertFalse(saved.contains { $0.id == tab.id })
        browser.close(tab)
    }
}
