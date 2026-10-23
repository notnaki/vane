import Foundation

/// Packaged apps keep SwiftPM's resource bundle under Contents/Resources. Older SwiftPM
/// accessors search beside the app or at the original build path and can trap after install.
enum AppResources {
    static let bundle = resolve(appBundle: .main) { Bundle.module }

    /// Keep the generated accessor inside a closure: it must never initialize when the
    /// installed app already supplies its resources. Command-line builds use its fallback.
    static func resolve(appBundle: Bundle, fallback: () -> Bundle) -> Bundle {
        if let resources = appBundle.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("Vane_vane.bundle", isDirectory: true)) {
            return packaged
        }
        return fallback()
    }
}
