import Foundation
import CryptoKit
import ExtensionResourceBridge
import Security
import WebKit

/// A resource view and synchronous bootstrap for MV3 navigator identity. Apple's system
/// WebKit still owns execution, HTTP user agents, storage and extension permissions.
@MainActor enum ExtensionWorkerIdentity {
    private static var association: UInt8 = 0

    private final class Runtime: NSObject {
        let identity: String
        init(identity: String) { self.identity = identity }
    }

    static func identity(of ext: WKWebExtension) -> String? { runtime(of: ext)?.identity }
    private static func runtime(of ext: WKWebExtension) -> Runtime? {
        objc_getAssociatedObject(ext, &association) as? Runtime
    }

    static func usesWorker(_ ext: WKWebExtension) -> Bool {
        (ext.manifest["manifest_version"] as? Int) == 3 && VaneExtensionUsesServiceWorker(ext)
    }

    /// Check exact bytes against the resource seal before adding any Vane code.
    /// Disk verification alone would leave a check/read race for signed sources.
    nonisolated static func validateSignedResources(_ resources: [String: Data], bundleURL: URL,
                                                    signatureHash: String) throws {
        var code: SecStaticCode?, info: CFDictionary?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data,
              hash.map({ String(format: "%02x", $0) }).joined() == signatureHash else {
            throw ExtensionHost.Failure("The accepted Safari extension signature changed. Choose Update from App to review it.")
        }
        for (path, data) in resources {
            guard SecCodeValidateFileResource(code, ("Resources/" + path) as CFString, data as CFData, []) == errSecSuccess else {
                throw ExtensionHost.Failure("An accepted Safari extension resource does not match its signature. Choose Update from App.")
            }
        }
    }

    static func prepare(_ original: WKWebExtension, resources originalResources: [String: Data],
                        manifest: [String: Any], userAgent: String) throws -> WKWebExtension {
        guard usesWorker(original) else { return original }
        guard WebKitStartup.revalidatesExtensionResources else {
            throw ExtensionHost.Failure("This WebKit version cannot safely refresh extension worker resources. The extension has not been started.")
        }
        guard let manifestBytes = originalResources["manifest.json"],
              let snapshotManifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              NSDictionary(dictionary: snapshotManifest).isEqual(to: manifest),
              let background = manifest["background"] as? [String: Any] else {
            throw ExtensionHost.Failure("The extension manifest changed while preparing its worker identity. Retry with the accepted source.")
        }
        let generated = background["service_worker"] == nil
        let declared = (background["service_worker"] as? String).map { [$0] }
            ?? (background["scripts"] as? [String] ?? [])
        guard !declared.isEmpty else { throw ExtensionHost.Failure("The extension has no worker script resource.") }
        let base = URL(string: "https://vane.invalid/")!
        let scripts = try declared.map { path -> URL in
            guard let components = URLComponents(string: path), components.scheme == nil, components.host == nil,
                  let url = URL(string: path, relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.query == nil, url.fragment == nil,
                  originalResources[String(url.path.dropFirst())] != nil else {
                throw ExtensionHost.Failure("The extension background script must be a resource inside its own extension.")
            }
            return url
        }
        let modules = background["type"] as? String == "module"
        let paths = scripts.map { $0.path(percentEncoded: true) }
        let firstPath = String(scripts[0].path.dropFirst())
        let directory: String
        if !generated, let slash = firstPath.lastIndex(of: "/") { directory = String(firstPath[...slash]) }
        else { directory = "" }
        // Adjacent explicit wrappers preserve the worker's API base directory for
        // relative importScripts. Generated workers retain their virtual root.
        // Canonical vendor URLs preserve module identity, including entry cycles.
        let template = try bootstrap(userAgent: userAgent, token: "")
        let templateEntry = try entrySource(bootstrap: template, modulePath: modules ? "__VANE_IDENTITY_MODULE__" : nil, scripts: paths)
        var digest = SHA256()
        func include(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        include(Data("Vane MV3 navigator resources 3 revalidated".utf8))
        include(Data(directory.utf8)); include(Data(template.utf8)); include(Data(templateEntry.utf8))
        for name in originalResources.keys.sorted() { include(Data(name.utf8)); include(originalResources[name]!) }
        let token = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let modulePath = "__vane_worker_identity_" + token + ".mjs"
        let entryPath = directory + "__vane_worker_entry_" + token + ".js"
        var resources = originalResources
        guard resources[entryPath] == nil, !modules || resources[modulePath] == nil else {
            throw ExtensionHost.Failure("The extension conflicts with its worker identity resources.")
        }
        let shim = try bootstrap(userAgent: userAgent, token: token)
        if modules { resources[modulePath] = Data(shim.utf8) }
        resources[entryPath] = Data(try entrySource(bootstrap: shim, modulePath: modules ? modulePath : nil, scripts: paths).utf8)
        var runtimeManifest = manifest, runtimeBackground = background
        var entryURL = URLComponents()
        entryURL.path = "/" + entryPath
        runtimeBackground["service_worker"] = entryURL.percentEncodedPath
        if generated { runtimeBackground["preferred_environment"] = ["service_worker"] }
        runtimeManifest["background"] = runtimeBackground
        resources["manifest.json"] = try JSONSerialization.data(withJSONObject: runtimeManifest, options: [.sortedKeys])
        var error: NSError?
        guard let ext = VaneCreateResourceExtension(resources, &error) else {
            throw error ?? ExtensionHost.Failure("Extension worker identity initialization is unavailable.")
        }
        objc_setAssociatedObject(ext, &association, Runtime(identity: userAgent), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return ext
    }

    /// Vendor scripts remain separate, unmodified Scripts or canonical Modules.
    /// Keep their parsing/directive semantics and let native loading enforce CSP.
    static func entrySource(bootstrap: String, modulePath: String?, scripts: [String]) throws -> String {
        if let modulePath {
            return "import '/\(modulePath)';\n" + (try scripts.map { path in
                let literal = try JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed])
                return "import \(String(decoding: literal, as: UTF8.self));"
            }).joined(separator: "\n") + "\n"
        }
        let paths = try JSONSerialization.data(withJSONObject: scripts)
        return bootstrap + "\nimportScripts(...\(String(decoding: paths, as: UTF8.self)));\n"
    }

    static func bootstrap(userAgent: String, token: String) throws -> String {
        let config = try JSONSerialization.data(withJSONObject: ["ua": userAgent, "token": token], options: [.sortedKeys])
        return """
        ;(() => {
          if (typeof ServiceWorkerGlobalScope === 'undefined' || !(globalThis instanceof ServiceWorkerGlobalScope)) return;
          const config = \(String(decoding: config, as: UTF8.self));
          const marker = Symbol.for('vane.worker.identity.' + config.token);
          if (!globalThis[marker]) {
            const proto = WorkerNavigator.prototype;
            Object.defineProperties(proto, {
              userAgent: {get: () => config.ua, configurable: true},
              appVersion: {get: () => config.ua.replace(/^Mozilla\\//, ''), configurable: true}
            });
            if (navigator.userAgent !== config.ua) throw new Error('Vane worker identity bootstrap failed');
            Object.defineProperty(globalThis, marker, {value: true});
          }
          if (navigator.userAgent !== config.ua) throw new Error('Vane worker identity bootstrap failed');
        })();
        """
    }

}
