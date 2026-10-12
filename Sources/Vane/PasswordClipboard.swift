import AppKit

@MainActor enum PasswordClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func write(_ password: String, to board: NSPasteboard = .general) -> Int {
        board.clearContents()
        board.declareTypes([.string, concealed], owner: nil)
        board.setString(password, forType: .string)
        board.setString("", forType: concealed)
        return board.changeCount
    }

    /// Even identical content copied again belongs to the next clipboard owner.
    @discardableResult static func clearIfUnchanged(_ board: NSPasteboard, changeCount: Int) -> Bool {
        guard board.changeCount == changeCount else { return false }
        board.clearContents()
        return true
    }
}
