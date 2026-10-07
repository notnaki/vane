import Foundation
import Security

/// A saved credential's web origin. Paths are not origin boundaries; scheme and port are.
/// Legacy Vane items omit their port and mean HTTPS on 443.
struct PasswordOrigin: Hashable, Sendable {
    let host: String
    let scheme: String
    let port: Int

    init(host: String, scheme: String = "https", port: Int? = nil) {
        self.host = host.lowercased()
        self.scheme = scheme
        self.port = port ?? (scheme == "http" ? 80 : 443)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        self.init(host: host, scheme: scheme, port: url.port)
    }

    init?(attributes: [String: Any]) {
        guard let host = attributes[kSecAttrServer as String] as? String else { return nil }
        let proto = attributes[kSecAttrProtocol as String] as? String
        let scheme: String
        if proto == kSecAttrProtocolHTTPS as String { scheme = "https" }
        else if proto == kSecAttrProtocolHTTP as String { scheme = "http" }
        else { return nil }
        let port = (attributes[kSecAttrPort as String] as? NSNumber)?.intValue ?? 0
        guard port == 0 || (1...65535).contains(port), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if port != 0 { components.port = port }
        guard components.url != nil else { return nil }
        self.init(host: host, scheme: scheme, port: port == 0 ? nil : port)
    }

    var isDefaultPort: Bool { port == (scheme == "http" ? 80 : 443) }
    var keychainProtocol: CFString { scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS }
    var url: URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        if !isDefaultPort { parts.port = port }
        return parts.url!
    }

    func key(account: String) -> String {
        // Keep last-used stamps and UI identities for existing default HTTPS credentials.
        let site = scheme == "https" && isDefaultPort ? host : url.absoluteString
        return site + "\n" + account
    }
}
