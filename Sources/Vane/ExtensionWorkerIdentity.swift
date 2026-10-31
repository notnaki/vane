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
        guard let manifestBytes = originalResources["manifest.json"],
              let snapshotManifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              NSDictionary(dictionary: snapshotManifest).isEqual(to: manifest),
              let background = manifest["background"] as? [String: Any],
              let declared = background["service_worker"] as? String ?? (background["scripts"] as? [String])?.first else {
            throw ExtensionHost.Failure("The extension manifest changed while preparing its worker identity. Retry with the accepted source.")
        }
        // Resolve vendor code inside the extension. Explicit entries retain their
        // path and relative imports, with a content version in the runtime URL.
        let base = URL(string: "https://vane.invalid/")!
        guard let components = URLComponents(string: declared), components.scheme == nil, components.host == nil,
              let url = URL(string: declared, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.query == nil, url.fragment == nil else {
            throw ExtensionHost.Failure("The extension worker must be a resource inside its own extension.")
        }
        let path = String(url.path.dropFirst())
        guard let bytes = originalResources[path], let source = String(data: bytes, encoding: .utf8) else {
            throw ExtensionHost.Failure("The extension worker is missing or is not valid UTF-8 JavaScript.")
        }
        let modules = background["type"] as? String == "module"
        let generated = background["service_worker"] == nil
        let scriptPaths = try (background["scripts"] as? [String] ?? []).map { declared -> String in
            guard let components = URLComponents(string: declared), components.scheme == nil, components.host == nil,
                  let url = URL(string: declared, relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.query == nil, url.fragment == nil,
                  originalResources[String(url.path.dropFirst())] != nil else {
                throw ExtensionHost.Failure("The extension background script must be a resource inside its own extension.")
            }
            return url.path(percentEncoded: true)
        }
        func wrapper(shim: String, module: String) throws -> String {
            if modules {
                return "import '/\(module)';\n" + (try scriptPaths.map { path in
                    let literal = try JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed])
                    return "import \(String(decoding: literal, as: UTF8.self));"
                }).joined(separator: "\n")
            }
            let paths = try JSONSerialization.data(withJSONObject: scriptPaths)
            return shim + "\nimportScripts(...\(String(decoding: paths, as: UTF8.self)));\n"
        }
        // The token binds the complete accepted resources, selected identity and
        // derived bootstrap bytes. Identical reloads may reuse identical code;
        // any changed input gets a distinct registration URL before vendor code.
        let template = try bootstrap(userAgent: userAgent, token: "")
        let templateEntry = try generated ? wrapper(shim: template, module: "__VANE_IDENTITY_MODULE__")
            : inject(source, bootstrap: template, modulePath: modules ? "__VANE_IDENTITY_MODULE__" : nil)
        var digest = SHA256()
        func include(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        include(Data("Vane MV3 navigator resources 1".utf8))
        include(Data(template.utf8)); include(Data(templateEntry.utf8))
        for name in originalResources.keys.sorted() { include(Data(name.utf8)); include(originalResources[name]!) }
        let token = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let stem = "__vane_worker_identity_" + token
        let modulePath = stem + ".mjs", entryPath = "__vane_worker_entry_" + token + ".js"
        var resources = originalResources
        guard resources[modulePath] == nil, resources[entryPath] == nil else {
            throw ExtensionHost.Failure("The extension conflicts with its worker identity resources.")
        }
        let shim = try bootstrap(userAgent: userAgent, token: token)
        if modules { resources[modulePath] = Data(shim.utf8) }
        var runtimeManifest = manifest, runtimeBackground = background
        if generated {
            // Preserve vendor script URLs; only WebKit's virtual generated worker
            // is replaced with an equivalent, versioned import wrapper.
            resources[entryPath] = Data(try wrapper(shim: shim, module: modulePath).utf8)
            runtimeBackground["service_worker"] = entryPath
            runtimeBackground["preferred_environment"] = ["service_worker"]
        } else {
            resources[path] = Data(try inject(source, bootstrap: shim, modulePath: modules ? modulePath : nil).utf8)
            runtimeBackground["service_worker"] = url.path(percentEncoded: true) + "?__vane_worker_identity=" + token
        }
        runtimeManifest["background"] = runtimeBackground
        resources["manifest.json"] = try JSONSerialization.data(withJSONObject: runtimeManifest, options: [.sortedKeys])
        var error: NSError?
        guard let ext = VaneCreateResourceExtension(resources, &error) else {
            throw error ?? ExtensionHost.Failure("Extension worker identity initialization is unavailable.")
        }
        objc_setAssociatedObject(ext, &association, Runtime(identity: userAgent), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return ext
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

    /// Keep complete classic directive prologues intact, including their ASI.
    /// Modules instead import a synchronous first dependency before vendor imports.
    static func inject(_ source: String, bootstrap: String, modulePath: String? = nil) throws -> String {
        let text = Array(source.unicodeScalars)
        func has(_ value: String, _ at: Int) -> Bool {
            let value = Array(value.unicodeScalars)
            return at + value.count <= text.count && text[at..<(at + value.count)].elementsEqual(value)
        }
        func line(_ c: Unicode.Scalar) -> Bool { [10, 13, 0x2028, 0x2029].contains(c.value) }
        func trivia(_ start: Int) throws -> (end: Int, newline: Bool) {
            var i = start, newline = false
            while i < text.count {
                if text[i].properties.isWhitespace || text[i].value == 0xFEFF {
                    newline = newline || line(text[i]); i += 1
                } else if has("//", i) || has("<!--", i) || has("-->", i) {
                    while i < text.count && !line(text[i]) { i += 1 }
                } else if has("/*", i) {
                    i += 2
                    while i < text.count && !has("*/", i) { newline = newline || line(text[i]); i += 1 }
                    guard i < text.count else { throw ExtensionHost.Failure("The extension worker has an unterminated comment.") }
                    i += 2
                } else { break }
            }
            return (i, newline)
        }
        func continuesExpression(_ i: Int) -> Bool {
            guard i < text.count else { return false }
            if has("++", i) || has("--", i) { return false } // Restricted postfix line break.
            if "([.`/+*-<>=&|^%,?:".unicodeScalars.contains(text[i]) { return true }
            if has("!=", i) { return true }
            for word in ["in", "instanceof"] where has(word, i) {
                let end = i + word.count
                if end == text.count || !(text[end].properties.isXIDContinue || text[end] == "$" || text[end] == "_") { return true }
            }
            return false
        }
        var prefix = text.first?.value == 0xFEFF ? 1 : 0
        if has("#!", prefix) {
            while prefix < text.count && !line(text[prefix]) { prefix += 1 }
            if prefix < text.count { prefix += 1 }
        }
        var insertion = prefix, cursor = prefix
        if modulePath == nil {
            while cursor < text.count {
                let start = try trivia(cursor).end
                guard start < text.count, text[start] == "'" || text[start] == "\"" else { break }
                let quote = text[start]
                var end = start + 1
                while end < text.count && text[end] != quote {
                    if text[end] == "\\" {
                        end += 1
                        if end < text.count && text[end] == "\r" && has("\n", end + 1) { end += 1 }
                    } else if line(text[end]) { throw ExtensionHost.Failure("The extension worker has an invalid string literal.") }
                    end += 1
                }
                guard end < text.count else { throw ExtensionHost.Failure("The extension worker has an unterminated string literal.") }
                end += 1
                let after = try trivia(end)
                if after.end < text.count && text[after.end] == ";" {
                    insertion = after.end + 1; cursor = insertion
                } else if after.end == text.count || (after.newline && !continuesExpression(after.end)) {
                    insertion = end; cursor = after.end
                } else { break }
            }
        }
        let head = String(String.UnicodeScalarView(text[..<insertion]))
        let tail = String(String.UnicodeScalarView(text[insertion...]))
        let code = modulePath.map { "import '/\($0)';" } ?? bootstrap
        return head + "\n" + (modulePath == nil ? ";" : "") + code + "\n" + tail
    }

}
