import Darwin
import WebKit
import XCTest

/// Comparator-only observations of already-live fixture services. Nothing here
/// creates a page, launches a process, changes identity, or samples another app.
@MainActor enum WebKitComparatorAttestation {
    enum Failure: Error { case unavailable }
    enum Scope: String {
        case userAgentIdentity = "ua-identity"
        case passwordContinuation = "password-continuation"
    }
    struct Configuration {
        let products: String
        let requireClient: Bool
    }

    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["VANE_WEBKIT_COMPARATOR_PRODUCTS"] != nil
            || environment["VANE_WEBKIT_COMPARATOR_VERSION"] != nil
            || environment["VANE_WEBKIT_UA_REQUIRE_CLIENT"] != nil
    }

    static func unavailable(_ reason: String) -> Failure {
        XCTFail("WebKit comparator unavailable: \(reason)")
        return .unavailable
    }

    static func configurationIfRequested() throws -> Configuration? {
        guard isRequested else { return nil }
        let environment = ProcessInfo.processInfo.environment
        guard let products = environment["VANE_WEBKIT_COMPARATOR_PRODUCTS"], products.hasPrefix("/"),
              let version = environment["VANE_WEBKIT_COMPARATOR_VERSION"], !version.isEmpty, version.count <= 96,
              version.rangeOfCharacter(from: .controlCharacters) == nil,
              environment["VANE_WEBKIT_UA_REQUIRE_CLIENT"].map({ $0 == "1" }) ?? true else {
            throw unavailable("invalid archive attestation contract")
        }
        let root = NativeFixtureRetirement.canonical(products)
        var isDirectory: ObjCBool = false
        guard root != "/", FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw unavailable("archive products directory is absent")
        }
        let bundle = Bundle(for: WKWebView.self)
        let loaded = NativeFixtureRetirement.canonical(bundle.bundleURL.path)
        guard loaded.hasPrefix(root + "/"), bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version else {
            throw unavailable("loaded framework archive root or public version does not match")
        }
        // Log only bounded public metadata; archive and process paths stay private.
        NativeFixtureDiagnostics.emit("WEBKIT COMPARATOR ATTESTED: frameworkRootMatches=true; WebKit=\(version)")
        return Configuration(products: root, requireClient: environment["VANE_WEBKIT_UA_REQUIRE_CLIENT"] == "1")
    }

    private static func existingPID(of owner: NSObject, selector: Selector) -> Int32? {
        guard owner.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let pid = unsafeBitCast(owner.method(for: selector), to: Getter.self)(owner, selector)
        return pid > 0 ? pid : nil
    }

    private static func existingNetworkPID(of store: WKWebsiteDataStore) -> Int32? {
        let exists = NSSelectorFromString("_networkProcessExists")
        guard store.responds(to: exists) else { return nil }
        typealias Exists = @convention(c) (AnyObject, Selector) -> Bool
        // The existence getter reads networkProcessIfExists(). Only then may the
        // identifier getter use that existing proxy; never create one for attestation.
        guard unsafeBitCast(store.method(for: exists), to: Exists.self)(store, exists) else { return nil }
        return existingPID(of: store, selector: NSSelectorFromString("_networkProcessIdentifier"))
    }

    static func attestServices(_ configuration: Configuration, views: [WKWebView], store: WKWebsiteDataStore) throws {
        func attest(_ executable: String, ownedPID: () -> Int32?) throws {
            guard let pid = ownedPID(), let captured = NativeFixtureDiagnostics.identity(pid),
                  pid != getpid(), captured.start > 0 else {
                throw unavailable("existing owned service identity is unavailable")
            }
            let path = NativeFixtureRetirement.canonical(captured.path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard path.hasPrefix(configuration.products + "/"),
                  name == executable || name == executable + ".Development" else {
                throw unavailable("owned service is outside the archive or has an unexpected executable")
            }
            guard ownedPID() == pid, let observed = NativeFixtureDiagnostics.identity(pid),
                  observed.start == captured.start, observed.path == captured.path else {
                throw unavailable("owned service launch changed during attestation")
            }
        }
        guard !views.isEmpty else { throw unavailable("no live fixture views were supplied") }
        let selector = NSSelectorFromString("_webProcessIdentifier")
        // Callers supply views only after their existing script/load checks. This
        // getter reads the existing main-frame PID and never launches a process.
        for web in views {
            try attest("com.apple.WebKit.WebContent") { existingPID(of: web, selector: selector) }
        }
        try attest("com.apple.WebKit.Networking") { existingNetworkPID(of: store) }
    }

    static func attestFixture(_ testCase: XCTestCase, scope: Scope, views: [WKWebView], store: WKWebsiteDataStore) throws {
        guard let configuration = try configurationIfRequested() else { return }
        try attestServices(configuration, views: views, store: store)
        let className = String(describing: type(of: testCase)).components(separatedBy: ".").last ?? ""
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
        guard let method = testCase.name.components(separatedBy: separators).last(where: { $0.hasPrefix("test") }),
              !className.isEmpty else { throw unavailable("fixture test-case identity is unavailable") }
        NativeFixtureDiagnostics.emit("WEBKIT COMPARATOR FIXTURE SERVICES ATTESTED case=\(className)/\(method) scope=\(scope.rawValue)")
    }
}
