import AppKit

/// The standardized app-icon picker. Layered sources and compiled assets live in AppIcons.
/// Normal uses the catalogue's glass render; Dark leaves the Dock's original composition.
/// macOS has no UIKit alternate-icon API, so choices use applicationIconImage.
@MainActor enum AppIcon {
    /// Where the choice lives. `UserDefaults.vane`, so a test instance on its own data dir
    /// does not repaint the real app's Dock tile.
    static let key = "appIcon"

    /// Picker order. A nil asset keeps AppKit's original composition.
    nonisolated static let catalogue: [(name: String, asset: String?)] = [
        ("Normal", "AppIcon"), ("Dark", nil), ("Galaxy", "AppIcon-Galaxy"),
        ("Candy", "AppIcon-Candy"), ("Neon", "AppIcon-Neon"),
        ("Fluted Glass", "AppIcon-FlutedGlass"), ("Schoolbook", "AppIcon-Schoolbook"),
        ("Luminous", "AppIcon-Luminous"),
    ]

    /// Preserve the original Dock composition for new installs and unavailable assets.
    nonisolated static var `default`: String { "Dark" }

    /// Keep saved choices when the old overlapping labels are retired.
    nonisolated static func canonicalName(_ name: String) -> String {
        switch name {
        case "Default": "Dark"
        case "Glass", "Navy": "Normal"
        default: name
        }
    }

    nonisolated static func overrides(_ name: String) -> Bool {
        canonicalName(name) != `default`
    }

    /// What the Dock draws for the running copy with nothing overriding it — which is what
    /// Dark's preview has to be, since a picker that shows the catalogue render beside
    /// "Dark" would be showing the wrong icon under the right word.
    ///
    /// Captured once, before anything is applied: `restoreAtLaunch` may set an override
    /// seconds later, and `applicationIconImage` would then answer with that instead.
    private static let composed: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    /// Every icon that actually loaded, as the image the Dock will draw once it is chosen.
    /// Normal, Galaxy, and the material variants come from the catalogue by name rather than from
    /// `NSApp.applicationIconImage`, so a bundle whose Finder icon has already been stamped
    /// still offers the real ones back.
    ///
    /// A dev build is the bare binary out of `.build`: no bundle, so no catalogue and no
    /// choice. Dark alone then, and nothing crashes.
    static var variants: [(name: String, image: NSImage)] {
        let bundled: [(name: String, image: NSImage)] = catalogue.compactMap { row in
            guard let asset = row.asset else { return (row.name, composed) }
            return NSImage(named: asset).map { (row.name, $0) }
        }
        if let custom = CustomAppIcon.custom { return bundled + [(CustomAppIcon.name, custom)] }
        return bundled
    }

    /// The chosen icon's name — the default whenever nothing is chosen, or the chosen one is
    /// no longer in the bundle (an older release, a dev build).
    static var current: String {
        let saved = canonicalName(UserDefaults.vane.string(forKey: key) ?? `default`)
        return variants.contains { $0.name == saved } ? saved : `default`
    }

    /// Switch to the icon named `name`: the live Dock tile, the persisted choice, and — when
    /// the bundle can take it — the icon Finder keeps while Vane is quit. Returns whether
    /// that last part happened; the first two always do.
    @discardableResult
    static func apply(_ name: String) -> Bool {
        let name = canonicalName(name)
        guard let v = variants.first(where: { $0.name == name }) else { return false }
        // nil hands the tile back to AppKit, which composes the bundle's own icon — not the
        // same thing as assigning the catalogue render, which is why Dark exists.
        NSApp.applicationIconImage = overrides(name) ? v.image : nil
        UserDefaults.vane.set(name, forKey: key)
        // User images are Dock overrides only; never stamp them onto the signed bundle.
        guard name != CustomAppIcon.name, stamps else { return false }
        // Dark *clears* the custom icon rather than writing one, so the bundle goes back
        // to drawing the icon it ships with.
        return NSWorkspace.shared.setIcon(overrides(name) ? v.image : nil,
                                          forFile: Bundle.main.bundleURL.path, options: [])
    }

    /// Called once at launch, before the first window. The Dock tile belongs to the running
    /// process, so a chosen icon has to be put back every time — and `Updater` replaces the
    /// whole bundle on an in-place update, which takes any stamped Finder icon with it.
    /// Dark is the one choice that does nothing at all: touching the tile to say "leave
    /// it alone" is exactly what would not leave it alone.
    static func restoreAtLaunch() {
        let name = current
        if let saved = UserDefaults.vane.string(forKey: key), saved != canonicalName(saved) {
            UserDefaults.vane.set(name, forKey: key)
        }
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
         ("Dark preserves the Dock's original composition",
          `default` == "Dark" && !overrides("Dark")
              && catalogue.first { $0.name == "Dark" }?.asset == nil),
         ("Normal and Galaxy remain explicit bundled choices",
          catalogue.contains { $0.name == "Normal" && $0.asset == "AppIcon" }
              && catalogue.contains { $0.name == "Galaxy" && $0.asset == "AppIcon-Galaxy" }),
         ("legacy names keep the closest finish after standardization",
          canonicalName("Default") == "Dark" && canonicalName("Glass") == "Normal"
              && canonicalName("Navy") == "Normal" && canonicalName("Galaxy") == "Galaxy"
              && canonicalName("Custom") == "Custom" && !overrides("Default")),
         ("the standardized picker has eight finishes and no old duplicate labels",
          catalogue.map(\.name) == ["Normal", "Dark", "Galaxy", "Candy", "Neon",
                                    "Fluted Glass", "Schoolbook", "Luminous"])]
    }
}
