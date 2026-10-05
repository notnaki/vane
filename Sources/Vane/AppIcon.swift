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
        ("Fluted Glass", "AppIcon-FlutedGlass"), ("Fluted Glass Dark", "AppIcon-FlutedGlassDark"),
        ("Schoolbook", "AppIcon-Schoolbook"),
        ("Luminous", "AppIcon-Luminous"),
    ]

    /// Preserve the original Dock composition for new installs and unavailable assets.
    nonisolated static var `default`: String { "Dark" }

    /// Keep saved choices when the old overlapping labels are retired.
    nonisolated static func canonicalName(_ name: String) -> String {
        switch name {
        case "Default", "Custom": "Dark"
        case "Glass", "Navy": "Normal"
        default: name
        }
    }

    nonisolated static func overrides(_ name: String) -> Bool {
        canonicalName(name) != `default`
    }

    /// Dark's preview comes from the shipped plate, independent of persisted Finder stamps.
    private static let composed: NSImage = {
        // Finder may already hold the last selection. Read the shipped plate for Dark's
        // preview rather than mistaking that persisted custom icon for the default.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    /// Every icon that actually loaded, as the image the Dock will draw once it is chosen.
    /// Normal, Galaxy, and the material variants come from the catalogue by name rather than from
    /// `NSApp.applicationIconImage`, so a bundle whose Finder icon has already been stamped
    /// still offers the real ones back.
    ///
    /// A dev build is the bare binary out of `.build`: no bundle, so no catalogue and no
    /// choice. Dark alone then, and nothing crashes.
    static var variants: [(name: String, image: NSImage)] {
        catalogue.compactMap { row in
            guard let asset = row.asset else { return (row.name, composed) }
            return NSImage(named: asset).map { (row.name, $0) }
        }
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
        guard canPersist else { return false }
        let image = overrides(name) ? v.image : nil
        if isSandboxed {
            // Send a bounded raster payload while still on the main actor.
            let data: Data?
            if let image {
                let plate = NSImage(size: NSSize(width: 512, height: 512))
                plate.lockFocus()
                image.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
                plate.unlockFocus()
                guard let encoded = plate.tiffRepresentation else { return false }
                data = encoded
            } else { data = nil }
            return AppIconPersistence.setIcon(data)
        }
        return NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }

    /// Called once at launch, before the first window. The Dock tile belongs to the running
    /// process, so a chosen icon has to be put back every time — and `Updater` replaces the
    /// whole bundle on an in-place update, which takes any stamped Finder icon with it.
    /// Dark clears any previous stamp and hands the running tile back to AppKit.
    static func restoreAtLaunch() {
        let name = current
        if let saved = UserDefaults.vane.string(forKey: key), saved != canonicalName(saved) {
            UserDefaults.vane.set(canonicalName(saved), forKey: key)
        }
        // Also clear an old stamp for Dark after relaunch or an update.
        guard overrides(name) || canPersist else { return }
        // An unavailable asset is a temporary fallback; retain its saved selection.
        guard canonicalName(UserDefaults.vane.string(forKey: key) ?? `default`) == name else { return }
        apply(name)
    }

    /// Read-only translocation mounts and bare SwiftPM binaries have no persistent target.
    static var canPersist: Bool { shouldPersist(bundlePath: Bundle.main.bundlePath) }

    nonisolated static var isSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    nonisolated static func shouldPersist(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") && !bundlePath.contains("/AppTranslocation/")
    }

    // MARK: Offline checks

    nonisolated static func check() -> [(String, Bool)] {
        [("an installed bundle can retain the icon through the sandbox's helper",
          shouldPersist(bundlePath: "/Applications/Vane.app")),
         ("a translocated copy is never stamped either — its mount is read-only and temporary",
          !shouldPersist(bundlePath: "/private/var/folders/q3/AppTranslocation/9F1/d/Vane.app")),
         ("the bare dev binary has no bundle to stamp",
          !shouldPersist(bundlePath: "/Users/ada/vane/.build/release/vane")),
         ("Dark preserves the Dock's original composition",
          `default` == "Dark" && !overrides("Dark")
              && catalogue.first { $0.name == "Dark" }?.asset == nil),
         ("Normal and Galaxy remain explicit bundled choices",
          catalogue.contains { $0.name == "Normal" && $0.asset == "AppIcon" }
              && catalogue.contains { $0.name == "Galaxy" && $0.asset == "AppIcon-Galaxy" }),
         ("legacy names keep the closest finish after standardization",
          canonicalName("Default") == "Dark" && canonicalName("Glass") == "Normal"
              && canonicalName("Navy") == "Normal" && canonicalName("Galaxy") == "Galaxy"
              && canonicalName("Custom") == "Dark" && !overrides("Default")),
         ("the standardized picker has nine finishes and no old duplicate labels",
          catalogue.map(\.name) == ["Normal", "Dark", "Galaxy", "Candy", "Neon",
                                    "Fluted Glass", "Fluted Glass Dark", "Schoolbook", "Luminous"])]
    }
}
