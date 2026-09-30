import Foundation
import Security
import Darwin

/// Runs outside the browser sandbox, as the current user (never root). Only a Vane
/// bundle in one of the two Applications directories can be installed. The copied
/// bundle must pass signature and Gatekeeper checks before quarantine is removed.
enum UpdateInstallation {
    static var applicationsDirectories: [URL] {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return [URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications")]
    }

    static func install(source: URL, target: URL, tag: String, keepPrevious: Bool,
                        applicationsDirectories: [URL] = applicationsDirectories) throws {
        guard source.isFileURL, allowed(target, within: applicationsDirectories) else {
            throw failure("Invalid update destination")
        }
        guard let incomingVersion = UpdateVersion(tag) else { throw failure("Invalid update version") }
        try BundleReplacement.install(source: source, at: target, keepPrevious: keepPrevious,
            verify: { staged in
                guard verified(staged), let actual = version(staged) else { return false }
                // The advertised tag must match the signed payload, with semver's padded
                // numeric core and ignored build metadata rather than string equality.
                return !(actual < incomingVersion) && !(incomingVersion < actual)
            }, mayReplaceTarget: { destination in
                guard allowed(destination, within: applicationsDirectories) else { return false }
                guard FileManager.default.fileExists(atPath: destination.path) else { return true }
                guard let installed = version(destination) else { return false }
                return installed < incomingVersion
            }, prepare: prepare)
    }

    private static func allowed(_ target: URL, within roots: [URL]) -> Bool {
        guard target.isFileURL, target.lastPathComponent == "Vane.app" else { return false }
        let normalized = target.standardizedFileURL
        guard normalized.resolvingSymlinksInPath() == normalized else { return false }
        return roots.contains { normalized.path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    static func version(_ bundle: URL) -> UpdateVersion? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return UpdateVersion(version)
    }

    private static func verified(_ bundle: URL) -> Bool {
        // Validate the private, final copy, not the source the client can still modify.
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = UpdateInstaller.requirement(identifier: "io.github.notnaki.vane")
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code,
                  SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement) == errSecSuccess else {
            return false
        }
        return true
    }

    private static func prepare(_ bundle: URL) throws {
        // Preserve Apple's trust assessment. Notarization is checked before removing
        // the first-launch marker, so an unnotarized or revoked release fails closed.
        let assessment = Process()
        assessment.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        assessment.arguments = ["--assess", "--type", "execute", "--ignore-cache", bundle.path]
        assessment.standardOutput = FileHandle.nullDevice
        assessment.standardError = FileHandle.nullDevice
        try assessment.run()
        assessment.waitUntilExit()
        guard assessment.terminationStatus == 0 else {
            throw failure("Gatekeeper rejected the update")
        }
        try removeQuarantine(bundle)
    }

    static func removeQuarantine(_ bundle: URL) throws {
        func remove(_ url: URL) throws {
            // Never follow a symlink out of the bundle or erase unrelated attributes.
            let result = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            if result != 0 && errno != ENOATTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        try remove(bundle)
        var traversalError: Error?
        guard let items = FileManager.default.enumerator(at: bundle,
            includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                traversalError = error
                return false
            }) else { throw failure("Cannot inspect update files") }
        for case let url as URL in items { try remove(url) }
        if let traversalError { throw traversalError }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: UpdateInstaller.serviceName, code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
