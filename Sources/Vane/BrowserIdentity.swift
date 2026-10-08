import Foundation

/// Keep Safari feature detection aligned with the installed WebKit generation.
/// A fixed Version/26.0 makes Google Docs use its pre-26.4 zoom workaround:
/// WKWebView's zero outerWidth then reduces Retina canvas density to one quarter.
enum BrowserIdentity {
    static let prefix = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/"
    static let suffix = " Safari/605.1.15"
    static let oldDefault = prefix + "26.0" + suffix

    static let safari: String = {
        let installed = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return prefix + safariVersion(installed: installed,
            system: ProcessInfo.processInfo.operatingSystemVersion) + suffix
    }()

    /// Safari can update separately from macOS. If its metadata is unavailable,
    /// Safari and macOS share the same version numbering on our macOS 26+ target.
    static func safariVersion(installed: String?, system: OperatingSystemVersion) -> String {
        if let installed {
            let parts = installed.split(separator: ".", omittingEmptySubsequences: false)
            if (2...3).contains(parts.count),
               parts.allSatisfy({ Int($0).map { $0 >= 0 } == true }),
               let major = Int(parts[0]), major >= 26 {
                return installed
            }
        }
        return "\(system.majorVersion).\(system.minorVersion)"
    }

    static func resolve(_ saved: String?) -> String {
        guard let saved, !saved.isEmpty, saved != oldDefault else { return safari }
        return saved
    }
}
