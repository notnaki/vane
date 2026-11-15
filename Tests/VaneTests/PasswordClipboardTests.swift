import AppKit
import XCTest
@testable import vane

@MainActor final class PasswordClipboardTests: XCTestCase {
    func testExpiryClearsOnlyTheOwnedUnchangedClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let stamp = PasswordClipboard.write("disposable", to: board)
        XCTAssertNotNil(board.data(forType: PasswordClipboard.concealed))
        XCTAssertTrue(PasswordClipboard.clearIfUnchanged(board, changeCount: stamp))
        XCTAssertNil(board.string(forType: .string))
    }

    func testNewClipboardContentSurvivesEvenIfTheTextIsIdentical() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let stamp = PasswordClipboard.write("disposable", to: board)
        board.clearContents()
        board.setString("disposable", forType: .string)
        XCTAssertFalse(PasswordClipboard.clearIfUnchanged(board, changeCount: stamp))
        XCTAssertEqual(board.string(forType: .string), "disposable")
    }
    func testTerminationClearsTheOwnedPasswordButPreservesSubsequentCopies() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        _ = PasswordClipboard.write("disposable", to: board)
        PasswordClipboard.clearOnTerminate()
        XCTAssertNil(board.string(forType: .string))
        _ = PasswordClipboard.write("disposable", to: board)
        board.clearContents()
        board.setString("next owner", forType: .string)
        PasswordClipboard.clearOnTerminate()
        XCTAssertEqual(board.string(forType: .string), "next owner")
    }

}
