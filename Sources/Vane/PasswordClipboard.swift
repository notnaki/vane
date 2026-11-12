import AppKit

@MainActor enum PasswordClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let currentHostOnly = NSPasteboard.PasteboardType("org.nspasteboard.CurrentHostOnlyType")

    private struct Ownership {
        let board: NSPasteboard
        let changeCount: Int
    }
    private static var owned: [NSPasteboard.Name: Ownership] = [:]

    static func write(_ password: String, to board: NSPasteboard = .general) -> Int {
        board.prepareForNewContents(with: .currentHostOnly)
        board.addTypes([.string, concealed, currentHostOnly], owner: nil)
        board.setString(password, forType: .string)
        board.setString("", forType: concealed)
        board.setString("", forType: currentHostOnly)
        let stamp = board.changeCount
        owned[board.name] = Ownership(board: board, changeCount: stamp)
        return stamp
    }

    /// Normal app termination must not leave a copied password waiting for its expiry task.
    static func clearOwned() {
        let pending = Array(owned.values)
        owned.removeAll()
        for entry in pending {
            clearIfUnchanged(entry.board, changeCount: entry.changeCount)
        }
    }

    /// Even identical content copied again belongs to the next clipboard owner.
    @discardableResult static func clearIfUnchanged(_ board: NSPasteboard, changeCount: Int) -> Bool {
        if owned[board.name]?.changeCount == changeCount { owned[board.name] = nil }
        guard board.changeCount == changeCount else { return false }
        board.clearContents()
        return true
    }
}
