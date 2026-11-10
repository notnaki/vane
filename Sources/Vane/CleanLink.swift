import AppKit

/// Clean only recognized tracking fields, retaining the original spelling and encoding
/// of every other query field. Generic names such as `ref` can identify page content.
enum CleanLink {
    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "gbraid", "wbraid", "twclid", "ttclid",
        "yclid", "srsltid", "igshid", "mc_cid", "mc_eid", "_ga", "_gl",
    ]

    static func string(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery else { return url.absoluteString }
        let fields = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = fields.filter { field in
            let encodedName = String(field.prefix { $0 != "=" })
            let name = (encodedName.removingPercentEncoding ?? encodedName).lowercased()
            return !name.hasPrefix("utm_") && !trackingNames.contains(name)
        }
        guard kept.count != fields.count else { return url.absoluteString }
        components.percentEncodedQuery = kept.allSatisfy(\.isEmpty) ? nil : kept.joined(separator: "&")
        return components.string ?? url.absoluteString
    }

    @MainActor static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string(for: url), forType: .string)
    }
}
