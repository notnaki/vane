import AppKit

/// Which of the two app icons the Dock draws.
///
/// Both are the same Icon Composer document in two fills — `AppIcon.icon` (the dark one Vane
/// has always shipped) and `AppIcon-Navy.icon` (the lighter navy the website showed) —
/// compiled into one `Assets.car` by `make-app.sh`. So macOS composes them the same way: it
/// shapes the squircle, lights the glass over the V and drops the shadow itself. Navy is a
/// *fill*, not a flat picture; nothing here paints an icon.
///
/// ponytail: no alternate-icon API is involved, because macOS has none —
/// `setAlternateIconName` is UIKit's. Two names in one asset catalogue and one assignment to
/// `NSApp.applicationIconImage` is the whole mechanism.
@MainActor enum AppIcon {
    /// Where the choice lives. `UserDefaults.vane`, so a test instance on its own data dir
    /// does not repaint the real app's Dock tile.
    static let key = "appIcon"

    /// The two the app ships, in the order the picker shows them. `asset` is the name inside
    /// `Assets.car`; `name` is both the label and the value that is persisted, so renaming an
    /// asset cannot silently reset somebody's choice.
    nonisolated static let catalogue: [(name: String, asset: String)] = [
        ("Glass", "AppIcon"), ("Navy", "AppIcon-Navy"),
    ]

    /// The shipped default — the one a bundle draws with nothing overriding it.
    nonisolated static var `default`: String { catalogue[0].name }

    /// Every icon that actually loaded, as the composed image the Dock would draw. Read from
    /// the catalogue by name rather than from `NSApp.applicationIconImage`, so a bundle whose
    /// Finder icon has already been stamped with Navy still offers the real Glass back.
    ///
    /// A dev build is the bare binary out of `.build`: no bundle, so no catalogue and no
    /// choice. One row then, holding the generic icon AppKit hands it, and nothing crashes.
    static var variants: [(name: String, image: NSImage)] {
        let found = catalogue.compactMap { row in NSImage(named: row.asset).map { (row.name, $0) } }
        return found.isEmpty ? [(`default`, NSApp.applicationIconImage)] : found
    }

    /// The chosen icon's name — the default whenever nothing is chosen, or the chosen one is
    /// no longer in the bundle (an older release, a dev build).
    static var current: String {
        let saved = UserDefaults.vane.string(forKey: key) ?? `default`
        return variants.contains { $0.name == saved } ? saved : `default`
    }

    /// Switch to the icon named `name`: the live Dock tile, the persisted choice, and — when
    /// the bundle can take it — the icon Finder keeps while Vane is quit. Returns whether
    /// that last part happened; the first two always do.
    @discardableResult
    static func apply(_ name: String) -> Bool {
        guard let v = variants.first(where: { $0.name == name }) else { return false }
        NSApp.applicationIconImage = v.image          // the Dock tile of the running app
        UserDefaults.vane.set(name, forKey: key)
        guard stamps else { return false }
        // Choosing the default *clears* the custom icon rather than writing one, so the
        // bundle goes back to drawing the icon its own catalogue holds.
        return NSWorkspace.shared.setIcon(name == `default` ? nil : v.image,
                                          forFile: Bundle.main.bundleURL.path, options: [])
    }

    /// Called once at launch, before the first window. The Dock tile belongs to the running
    /// process, so it has to be set every time — and `Updater` replaces the whole bundle on
    /// an in-place update, which takes any stamped Finder icon with it. This is what makes
    /// the choice survive both.
    static func restoreAtLaunch() {
        let name = current
        guard name != `default` else { return }   // nothing to override; the bundle's own icon
        apply(name)
    }

    /// Whether the running copy's bundle can be stamped at all.
    static var stamps: Bool {
        shouldStamp(bundlePath: Bundle.main.bundleURL.path, sandboxed: isSandboxed)
    }

    /// A sandboxed process is given a container as its home; an unsandboxed one keeps the
    /// user's own. Cheaper and more honest than asking `SecTask` for the entitlement, which
    /// answers about the code signature rather than about the kernel's opinion.
    nonisolated static var isSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Whether writing the icon onto the bundle is worth attempting. Pure, so
    /// `selfcheck --pure` can prove both refusals with no bundle to write to.
    ///
    /// `NSWorkspace.setIcon(forFile:)` writes a custom-icon resource and an xattr into the
    /// bundle. Vane is sandboxed, and the sandbox refuses that on its own bundle — the call
    /// just returns false. A translocated copy is worse than refused: it runs from a
    /// read-only random mount that disappears, so a stamp there would be written to nothing.
    ///
    /// ponytail: two string tests rather than a write probe. The one thing a probe would buy
    /// — certainty about an odd install — is not worth writing to somebody's bundle to find
    /// out, and the caller treats the whole stamp as best-effort anyway. Ceiling: the Finder
    /// icon is what the stamp is for, and under the sandbox nobody gets it; the Dock is what
    /// most people mean by "the app icon", and that always changes.
    nonisolated static func shouldStamp(bundlePath: String, sandboxed: Bool) -> Bool {
        guard !sandboxed else { return false }
        guard !bundlePath.contains("/AppTranslocation/") else { return false }
        return bundlePath.hasSuffix(".app")
    }

    // MARK: Offline checks

    nonisolated static func check() -> [(String, Bool)] {
        [("the sandbox refuses to stamp the bundle, so Vane does not ask",
          !shouldStamp(bundlePath: "/Applications/Vane.app", sandboxed: true)),
         ("a translocated copy is never stamped either — its mount is read-only and temporary",
          !shouldStamp(bundlePath: "/private/var/folders/q3/AppTranslocation/9F1/d/Vane.app",
                       sandboxed: false)),
         ("an ordinary unsandboxed install is stamped, so Finder keeps the icon while quit",
          shouldStamp(bundlePath: "/Applications/Vane.app", sandboxed: false)),
         ("the bare dev binary has no bundle to stamp",
          !shouldStamp(bundlePath: "/Users/ada/vane/.build/release/vane", sandboxed: false)),
         ("the shipped default is the first row, so the picker opens on it",
          `default` == catalogue[0].name && catalogue.count == 2)]
    }
}
