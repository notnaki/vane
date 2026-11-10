import AppKit

/// Passwords live only in the modal controls and the in-flight backup operation;
/// they are never written to preferences, Keychain, or a recovery point.
@MainActor enum BackupPasswordPrompt {
    enum ExportChoice { case encrypted(String), unencrypted, cancelled }

    static func export() -> ExportChoice {
        let alert = NSAlert()
        alert.messageText = "Protect your backup"
        let explanation = "Use a long, unique password to protect your browsing data. Keep it somewhere safe; Vane cannot recover it. Local recovery points are not encrypted."
        alert.informativeText = explanation
        alert.addButton(withTitle: "Export Encrypted")
        alert.addButton(withTitle: "Export Without Password")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let password = field("Backup password"), confirmation = field("Confirm password")
        let stack = NSStackView(views: [password, confirmation])
        stack.orientation = .vertical; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        password.widthAnchor.constraint(equalToConstant: 320).isActive = true
        confirmation.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = password
        defer { password.stringValue = ""; confirmation.stringValue = "" }
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard !password.stringValue.isEmpty else {
                    alert.informativeText = "Enter a password, or choose Export Without Password.\n\n" + explanation
                    continue
                }
                guard password.stringValue == confirmation.stringValue else {
                    alert.informativeText = "The passwords do not match. Try again.\n\n" + explanation
                    confirmation.stringValue = ""
                    continue
                }
                return .encrypted(password.stringValue)
            case .alertSecondButtonReturn: return .unencrypted
            default: return .cancelled
            }
        }
    }

    static func unlock(message: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Unlock backup"
        alert.informativeText = message ?? "Enter the password used when this backup was exported."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let password = field("Backup password")
        alert.accessoryView = password
        alert.window.initialFirstResponder = password
        defer { password.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return password.stringValue
    }

    private static func field(_ label: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = label
        field.setAccessibilityLabel(label)
        return field
    }
}
