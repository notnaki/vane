import AppKit
import WebKit

/// Settings → "Erase Everything…": every profile, Space and tab, every saved password,
/// cookie and sign-in, history, bookmarks, extensions and settings, and then Vane starts
/// over. Behind a word the user has to type — a button alone is one mis-click from losing
/// everything, and "are you sure?" is answered by reflex.
@MainActor enum EraseEverything {
    nonisolated static let word = "ERASE"

    /// Exactly the word, spaces forgiven. Case is not: "erase" is a word one types by
    /// accident, "ERASE" is a decision.
    nonisolated static func accepts(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespaces) == word
    }

    static func ask() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase everything and start Vane over?"
        alert.informativeText = "Every profile, Space and tab, every saved password, cookie and "
            + "sign-in, history, bookmarks, extensions and settings. Nothing brings it back. "
            + "Type \(word) to unlock the button."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = word
        alert.accessoryView = field
        let erase = alert.addButton(withTitle: "Erase Everything")
        erase.hasDestructiveAction = true
        erase.isEnabled = false
        alert.addButton(withTitle: "Cancel")
        // The button follows the field: it is only ever pressable while the word is in it,
        // so Return on an empty field does nothing rather than everything.
        let watcher = Watcher { erase.isEnabled = accepts(field.stringValue) }
        field.delegate = watcher
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, accepts(field.stringValue) else { return }
        withExtendedLifetime(watcher) {}
        Task {
            await wipe()
            relaunch()
            // `exit`, not `terminate`: the will-terminate path saves the session and writes
            // the crash marker, which would put two of the files straight back.
            exit(0)
        }
    }

    /// Web data first — its removal is asynchronous and has to finish before the process
    /// goes — then the keychain, then the files and the preferences.
    static func wipe() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for id in ProfileManager.shared.profiles.map(\.id) {
            await ProfileManager.dataStore(for: id).removeData(ofTypes: types, modifiedSince: .distantPast)
            if let sid = ProfileManager.dataStoreIdentifier(for: id, dataDirectory: Store.overrideDirectory) {
                try? await WKWebsiteDataStore.remove(forIdentifier: sid)
            }
        }
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)

        // The keychain is not partitioned by data dir, so only the real installation may
        // take every credential Vane has filed (the GitHub token among them). A data-dir
        // instance takes its own profiles' — the ones filed under a security domain — and
        // leaves the default profile's alone, because those are the real app's.
        if Store.overrideDirectory == nil {
            Passwords.deleteEverything()
        } else {
            for id in ProfileManager.shared.profiles.map(\.id) where id != ProfileManager.defaultID {
                Passwords.deleteAll(profileID: id)
            }
        }

        try? FileManager.default.removeItem(at: Store.directory)
        if let dir = Store.overrideDirectory {
            let suite = UserDefaults.suiteName(forDataDir: dir)
            UserDefaults.vane.removePersistentDomain(forName: suite)
        } else if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        UserDefaults.vane.synchronize()
    }

    /// The same detached shell `Updater.restart` uses: waits for this pid to go, then opens
    /// the bundle again. Whether it manages is not our problem any more.
    private static func relaunch() {
        let path = "'" + Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; "
            + "for i in 1 2 3; do /usr/bin/open \(path) && exit 0; sleep 1; done"]
        try? helper.run()
    }

    private final class Watcher: NSObject, NSTextFieldDelegate {
        let changed: () -> Void
        init(_ changed: @escaping () -> Void) { self.changed = changed }
        func controlTextDidChange(_ note: Notification) { changed() }
    }

    static func check() -> [(String, Bool)] {
        [
            ("the word unlocks it", accepts("ERASE")),
            ("stray spaces are forgiven", accepts("  ERASE ")),
            ("lower case is not the word", !accepts("erase")),
            ("nothing is not the word", !accepts("")),
            ("more than the word is not the word", !accepts("ERASE EVERYTHING")),
        ]
    }
}
