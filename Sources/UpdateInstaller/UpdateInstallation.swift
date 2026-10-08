import Foundation
import Security
import Darwin
import MachO

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
        guard realDirectory(source) else { throw failure("Invalid update source") }
        guard let incomingVersion = UpdateVersion(tag) else { throw failure("Invalid update version") }
        try BundleReplacement.install(source: source, at: target, keepPrevious: keepPrevious,
            verify: { staged in
                guard realDirectory(staged), bundleInfo(staged) != nil,
                      let actual = version(staged) else { throw failure("Invalid update bundle identity or version") }
                guard compatibleExecutable(staged) else {
                    throw failure("Update executable does not support this architecture")
                }
                try verifySignature(staged)
                // The advertised tag must match the signed payload, with semver's padded
                // numeric core and ignored build metadata rather than string equality.
                guard !(actual < incomingVersion) && !(incomingVersion < actual) else {
                    throw failure("Update version does not match advertised version")
                }
                return true
            }, mayReplaceTarget: { destination in
                guard allowed(destination, within: applicationsDirectories) else { return false }
                guard FileManager.default.fileExists(atPath: destination.path) else { return true }
                guard realDirectory(destination), bundleInfo(destination) != nil,
                      let installed = version(destination) else { return false }
                // A corrupt installation is not a usable rollback candidate. Local
                // ad-hoc Vane builds are allowed, but their contents must still be sealed.
                guard (try? verifySignature(destination, pinned: false)) != nil else { return false }
                return installed < incomingVersion
            }, prepare: prepare)
    }

    static func verifyForRelaunch(_ bundle: URL) throws {
        guard realDirectory(bundle), bundleInfo(bundle) != nil, version(bundle) != nil,
              compatibleExecutable(bundle) else { throw failure("Invalid Vane relaunch bundle") }
        try verifySignature(bundle)
    }

    static func recoverablePrevious(_ bundle: URL) -> Bool {
        guard realDirectory(bundle), bundleInfo(bundle) != nil, version(bundle) != nil else { return false }
        return (try? verifySignature(bundle, pinned: false)) != nil
    }

    private static func realDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
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

    private static func bundleInfo(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "io.github.notnaki.vane",
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable == (executable as NSString).lastPathComponent,
              executable != ".", executable != ".." else { return nil }
        let binary = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard binary.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return info
    }

    private static func compatibleExecutable(_ bundle: URL) -> Bool {
        #if arch(arm64)
        let architecture = NSNumber(value: CPU_TYPE_ARM64)
        #else
        let architecture = NSNumber(value: CPU_TYPE_X86_64)
        #endif
        return Bundle(url: bundle)?.executableArchitectures?.contains(architecture) == true
    }

    private static func verifySignature(_ bundle: URL, pinned: Bool = true) throws {
        // Validate the private, final copy, not the source the client can still modify.
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = pinned ? UpdateInstaller.requirement(identifier: "io.github.notnaki.vane")
                          : "identifier \"io.github.notnaki.vane\""
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw failure("Cannot inspect update signature", status: status)
        }
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, requirement != nil else {
            throw failure("Cannot create update signature requirement", status: status)
        }
        var detail: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code,
            SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement, &detail)
        guard status == errSecSuccess else {
            let underlying = detail?.takeRetainedValue() as Error?
            throw failure("Update signature verification failed", status: status, underlying: underlying)
        }
    }

    private static func prepare(_ bundle: URL) throws {
        // Preserve Apple's trust assessment. Notarization is checked before removing
        // the first-launch marker, so an unnotarized or revoked release fails closed.
        let assessment = Process()
        assessment.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        assessment.arguments = ["--assess", "--type", "execute", "--ignore-cache", bundle.path]
        assessment.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        assessment.standardError = errors
        try assessment.run()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        assessment.waitUntilExit()
        guard assessment.terminationStatus == 0 else {
            throw failure("Gatekeeper rejected the update", status: assessment.terminationStatus,
                          underlying: NSError(domain: "Gatekeeper", code: Int(assessment.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(detail.suffix(2000))]))
        }
        try removeQuarantine(bundle)
    }

    static func removeQuarantine(_ bundle: URL) throws {
        // Foundation enumerates through a symlink at its root even though it does not
        // descend through symlink children. Require a private directory before walking.
        guard realDirectory(bundle) else { throw failure("Invalid update source") }
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

    private static func failure(_ message: String, status: Int32 = 2, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        else if status != 2 { info[NSUnderlyingErrorKey] = NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return NSError(domain: UpdateInstaller.serviceName, code: Int(status), userInfo: info)
    }
}
