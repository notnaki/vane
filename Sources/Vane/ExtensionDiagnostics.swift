import Foundation
import WebKit

/// Folder validation and host limitations, independent of installation consent.
@MainActor enum ExtensionDiagnostics {
    static let unsupportedAPIs: Set<String> = [
        "browser.contextMenus", "browser.menus",
        "browser.runtime.sendNativeMessage", "browser.runtime.connectNative"
    ]
    static let unsupportedPermissions: Set<String> = ["contextMenus", "menus", "nativeMessaging"]

    static func limitations(_ manifest: [String: Any], extension ext: WKWebExtension) -> [String] {
        let recognized = Set(ext.requestedPermissions.union(ext.optionalPermissions).map(\.rawValue))
        let declared = Set(((manifest["permissions"] as? [String] ?? [])
                            + (manifest["optional_permissions"] as? [String] ?? []))
            .filter { !$0.contains("://") && $0 != "<all_urls>" })
        var issues = declared.subtracting(recognized).sorted().map {
            "\($0): this WebKit version does not recognize this capability."
        }
        for permission in declared.intersection(unsupportedPermissions).sorted() {
            issues.append("\(permission): Vane does not provide " + (permission == "nativeMessaging"
                ? "connections to native messaging hosts." : "extension items in page menus."))
        }
        for (key, detail) in [
            ("commands", "extension keyboard shortcuts"),
            ("chrome_url_overrides", "replacement browser pages"),
            ("side_panel", "extension side panels"),
            ("devtools_page", "extension developer-tools panels"),
            ("omnibox", "extension search keywords"),
            ("oauth2", "Chrome identity integration")
        ] where manifest[key] != nil {
            issues.append("\(key): Vane does not provide \(detail).")
        }
        return issues
    }

    /// WebKit records absent optional display metadata as errors too. Keep these
    /// visible, but do not reject previously working folders without a description.
    static func blockingErrors(_ errors: [any Error], manifest: [String: Any]) -> [any Error] {
        errors.filter { error in
            let value = error as NSError
            return !(manifest["description"] == nil && value.domain == WKWebExtension.errorDomain
                && value.code == WKWebExtension.Error.invalidManifestEntry.rawValue
                && value.localizedDescription.contains("`description`"))
        }
    }

    /// WebKit can parse a manifest while deferring resource errors until first use.
    /// Check executable/UI/ruleset entry points now, before any context can run.
    static func validateResources(_ manifest: [String: Any], in folder: URL) throws {
        var resources: [(String, String)] = []
        func single(_ value: Any?, _ key: String) {
            if let path = value as? String { resources.append((key, path)) }
        }
        func list(_ value: Any?, _ key: String) {
            for path in value as? [String] ?? [] { resources.append((key, path)) }
        }
        if let background = manifest["background"] as? [String: Any] {
            single(background["service_worker"], "background.service_worker")
            single(background["page"], "background.page")
            list(background["scripts"], "background.scripts")
        }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            list(script["js"], "content_scripts.js")
            list(script["css"], "content_scripts.css")
        }
        for key in ["action", "browser_action", "page_action"] {
            if let action = manifest[key] as? [String: Any] { single(action["default_popup"], "\(key).default_popup") }
        }
        single(manifest["options_page"], "options_page")
        single((manifest["options_ui"] as? [String: Any])?["page"], "options_ui.page")
        if let dnr = manifest["declarative_net_request"] as? [String: Any] {
            for rule in dnr["rule_resources"] as? [[String: Any]] ?? [] { single(rule["path"], "declarative_net_request.rule_resources.path") }
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (key, path) in resources {
            let resource = folder.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resource.path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: resource.path) else {
                throw ExtensionHost.Failure("\(key): “\(path)” is missing or unreadable. Restore that file or fix manifest.json, then retry.")
            }
            guard !path.isEmpty, resource.path.hasPrefix(root) else {
                throw ExtensionHost.Failure("\(key): “\(path)” must point to a file inside the extension folder. Fix manifest.json and retry.")
            }
        }
    }

    static func describe(_ errors: [any Error]) -> String {
        var seen: Set<String> = []
        return errors.flatMap { details($0, depth: 0) }.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    private static func details(_ error: any Error, depth: Int) -> [String] {
        if error is ExtensionHost.Failure { return [error.localizedDescription] }
        let error = error as NSError
        var result = ["\(error.localizedDescription) [\(error.domain):\(error.code)]"]
        if let reason = error.localizedFailureReason { result.append(reason) }
        if let recovery = error.localizedRecoverySuggestion { result.append(recovery) }
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            result += details(underlying, depth: depth + 1)
        }
        return result
    }
}
