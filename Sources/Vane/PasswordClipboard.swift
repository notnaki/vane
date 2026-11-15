import AppKit

@MainActor enum PasswordClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static var owned: (board: NSPasteboard, changeCount: Int)?

    static func write(_ password: String, to board: NSPasteboard = .general) -> Int {
        board.prepareForNewContents(with: .currentHostOnly)
        board.declareTypes([.string, concealed], owner: nil)
        board.setString(password, forType: .string)
        board.setString("", forType: concealed)
        owned = (board, board.changeCount)
        return board.changeCount
    }

    static func clearOnTerminate() {
        if let owned { clearIfUnchanged(owned.board, changeCount: owned.changeCount) }
        owned = nil
    }

    /// Even identical content copied again belongs to the next clipboard owner.
    @discardableResult static func clearIfUnchanged(_ board: NSPasteboard, changeCount: Int) -> Bool {
        guard board.changeCount == changeCount else { return false }
        board.clearContents()
        return true
    }
}
