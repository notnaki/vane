import XCTest
@testable import vane

@MainActor final class PasswordExportAuthorizationTests: XCTestCase {
    func testPasswordExportWaitsForDeviceOwnerAuthenticationAndFailsClosed() {
        var authenticate: (@MainActor (Bool) -> Void)?
        var destinations = 0
        var interaction = Export.Interaction()
        interaction.confirmPlaintext = { true }
        interaction.authenticate = { authenticate = $0 }
        interaction.chooseDestination = { _, _ in destinations += 1; return nil }
        Export.chooseAndExport(.passwords, profileID: UUID(), interaction: interaction)
        XCTAssertNotNil(authenticate)
        XCTAssertEqual(destinations, 0, "Export must not begin while authentication is pending")
        authenticate?(false)
        authenticate?(true)
        XCTAssertEqual(destinations, 0, "Denied or unavailable device authentication must prevent export")
    }

    func testSuccessfulAuthenticationContinuesOnlyTheConfirmedPasswordExport() {
        let profile = UUID()
        var authenticate: (@MainActor (Bool) -> Void)?
        var destinations = 0
        var interaction = Export.Interaction()
        interaction.confirmPlaintext = { true }
        interaction.authenticate = { authenticate = $0 }
        interaction.chooseDestination = { kind, id in
            XCTAssertEqual(kind, .passwords)
            XCTAssertEqual(id, profile)
            destinations += 1
            return nil
        }
        Export.chooseAndExport(.passwords, profileID: profile, interaction: interaction)
        XCTAssertEqual(destinations, 0)
        authenticate?(true)
        authenticate?(true)
        XCTAssertEqual(destinations, 1, "An authentication request may continue export only once")
    }

    func testCancellingPlaintextConfirmationPreventsAuthenticationAndExport() {
        var interaction = Export.Interaction()
        interaction.confirmPlaintext = { false }
        interaction.authenticate = { _ in XCTFail("Cancelled export must not request authentication") }
        interaction.chooseDestination = { _, _ in XCTFail("Cancelled export must not begin"); return nil }
        Export.chooseAndExport(.passwords, profileID: UUID(), interaction: interaction)
    }

    func testBookmarkExportDoesNotRequirePasswordAuthorization() {
        var destinations = 0
        var interaction = Export.Interaction()
        interaction.confirmPlaintext = { XCTFail("Bookmark export does not expose passwords"); return false }
        interaction.authenticate = { _ in XCTFail("Bookmark export does not require password authentication") }
        interaction.chooseDestination = { _, _ in destinations += 1; return nil }
        Export.chooseAndExport(.bookmarks, profileID: UUID(), interaction: interaction)
        XCTAssertEqual(destinations, 1)
    }
}
