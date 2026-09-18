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

    /// The three the app offers, in the order the picker shows them.
    ///
    /// Current is not a picture: it is the absence of one. The Dock composes the bundle's
    /// icon itself, and its composition is not the asset catalogue's — measured, the tile
    /// the Dock draws averages rgb 36,39,56 in the body where `NSImage(named: "AppIcon")`
    /// averages 39,45,81, in either appearance. So "the icon I have today" is a third
    /// answer, and it has to be the default, or choosing the default would change the icon.
    ///
    /// `asset` is the name inside `Assets.car`; nil means no override. `name` is both the
    /// label and the value that is persisted, so renaming an asset cannot silently reset
    /// somebody's choice.
    nonisolated static let catalogue: [(name: String, asset: String?)] = [
        ("Current", nil), ("Glass", "AppIcon"), ("Navy", "AppIcon-Navy"),
    ]

    /// The shipped default — the Dock's own composition, with nothing overriding it.
    nonisolated static var `default`: String { catalogue[0].name }

    /// Whether choosing `name` means putting an image over the Dock's own. Pure, and the
    /// single rule the launch path and the stamp both read.
    nonisolated static func overrides(_ name: String) -> Bool { name != `default` }

    /// What the Dock draws for the running copy with nothing overriding it — which is what
    /// Current's preview has to be, since a picker that shows the catalogue render beside
    /// "Current" would be showing the wrong icon under the right word.
    ///
    /// Captured once, before anything is applied: `restoreAtLaunch` may set an override
    /// seconds later, and `applicationIconImage` would then answer with that instead.
    private static let composed: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    /// Every icon that actually loaded, as the image the Dock will draw once it is chosen.
    /// Glass and Navy come from the catalogue by name rather than from
    /// `NSApp.applicationIconImage`, so a bundle whose Finder icon has already been stamped
    /// still offers the real ones back.
    ///
    /// A dev build is the bare binary out of `.build`: no bundle, so no catalogue and no
    /// choice. Current alone then, and nothing crashes.
    static var variants: [(name: String, image: NSImage)] {
        catalogue.compactMap { row in
            guard let asset = row.asset else { return (row.name, composed) }
            return NSImage(named: asset).map { (row.name, $0) }
        }
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
        // nil hands the tile back to AppKit, which composes the bundle's own icon — not the
        // same thing as assigning the catalogue render, which is why Current exists.
        NSApp.applicationIconImage = overrides(name) ? v.image : nil
        UserDefaults.vane.set(name, forKey: key)
        guard stamps else { return false }
        // Current *clears* the custom icon rather than writing one, so the bundle goes back
        // to drawing the icon it ships with.
        return NSWorkspace.shared.setIcon(overrides(name) ? v.image : nil,
                                          forFile: Bundle.main.bundleURL.path, options: [])
    }

    /// Called once at launch, before the first window. The Dock tile belongs to the running
    /// process, so a chosen icon has to be put back every time — and `Updater` replaces the
    /// whole bundle on an in-place update, which takes any stamped Finder icon with it.
    /// Current is the one choice that does nothing at all: touching the tile to say "leave
    /// it alone" is exactly what would not leave it alone.
    static func restoreAtLaunch() {
        let name = current
        guard overrides(name) else { return }
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
         ("the icon you already have is the default, and choosing it overrides nothing",
          `default` == catalogue[0].name && !overrides(`default`)
              && catalogue[0].asset == nil),
         ("…and the two that are pictures do override it",
          catalogue.dropFirst().allSatisfy { overrides($0.name) && $0.asset != nil }
              && catalogue.count == 3)]
    }
}
