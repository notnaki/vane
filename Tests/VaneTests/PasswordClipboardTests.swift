import AppKit
import XCTest
@testable import vane

@MainActor final class PasswordClipboardTests: XCTestCase {
    func testExpiryClearsOnlyTheOwnedUnchangedClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { PasswordClipboard.clearOwned(); board.releaseGlobally() }
        let stamp = PasswordClipboard.write("disposable", to: board)
        XCTAssertNotNil(board.data(forType: PasswordClipboard.concealed))
        XCTAssertNotNil(board.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.CurrentHostOnlyType")),
                        "Passwords must not be offered to Universal Clipboard")
        XCTAssertTrue(PasswordClipboard.clearIfUnchanged(board, changeCount: stamp))
        XCTAssertNil(board.string(forType: .string))
    }

    func testTerminationClearsOwnedSecretsButPreservesLaterClipboardContent() {
        let owned = NSPasteboard.withUniqueName(), replaced = NSPasteboard.withUniqueName()
        defer { PasswordClipboard.clearOwned(); owned.releaseGlobally(); replaced.releaseGlobally() }
        _ = PasswordClipboard.write("owned-secret", to: owned)
        _ = PasswordClipboard.write("replaced-secret", to: replaced)
        replaced.clearContents()
        replaced.setString("later clipboard", forType: .string)
        PasswordClipboard.clearOwned()
        XCTAssertNil(owned.string(forType: .string))
        XCTAssertEqual(replaced.string(forType: .string), "later clipboard")
    }

    func testNewClipboardContentSurvivesEvenIfTheTextIsIdentical() {
        let board = NSPasteboard.withUniqueName()
        defer { PasswordClipboard.clearOwned(); board.releaseGlobally() }
        let stamp = PasswordClipboard.write("disposable", to: board)
        board.clearContents()
        board.setString("disposable", forType: .string)
        XCTAssertFalse(PasswordClipboard.clearIfUnchanged(board, changeCount: stamp))
        XCTAssertEqual(board.string(forType: .string), "disposable")
    }
}
