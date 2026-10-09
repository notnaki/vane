import AppKit
import WebKit

/// Let WebKit follow the display's refresh rate instead of preferring ~60 fps.
/// This must be applied before creating the WKWebView: changing the flag on a live
/// page did not change its animation cadence in the macOS 27 diagnostic.
@MainActor enum PageRendering {
    private static let feature: NSObject? = {
        let features = NSSelectorFromString("_features")
        let key = NSSelectorFromString("key")
        guard WKPreferences.responds(to: features),
              let all = WKPreferences.perform(features)?.takeUnretainedValue() as? [NSObject]
        else { return nil }
        return all.first {
            $0.responds(to: key) &&
            $0.perform(key)?.takeUnretainedValue() as? String == "PreferPageRenderingUpdatesNear60FPSEnabled"
        }
    }()

    static func configure(_ preferences: WKPreferences, reducedMotion: Bool = Motion.reduced) {
        // Private feature API: discover the named feature and guard the selector so
        // an OS that removes either keeps its own defaults. Never use unguarded KVC.
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard let feature, preferences.responds(to: setter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let set = unsafeBitCast(preferences.method(for: setter), to: Setter.self)
        set(preferences, setter, reducedMotion, feature)
        // Disabling this preference requests the display rate; WebKit still owns
        // low-power, visibility, and background-page throttling.
    }
}
