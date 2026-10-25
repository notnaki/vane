import AppKit
import Security
import Darwin

/// Only identities obtained from Apple-anchored, resource-verified code signatures
/// become Safari runtime IDs. Info.plist team claims and loose manifests never do.
struct SafariExtensionSource: Codable, Equatable, Sendable {
    let appBundleID: String
    let extensionBundleID: String
    let teamID: String
    var appPath: String
    let signatureHash: String

    var runtimeID: String { "\(extensionBundleID) (\(teamID))" }
    var key: String { "/safari-extension/\(teamID)/\(extensionBundleID)" }
    var isValid: Bool {
        Self.validBundleID(appBundleID) && Self.validBundleID(extensionBundleID)
            && teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
            && signatureHash.range(of: #"^[a-f0-9]{40,128}$"#, options: .regularExpression) != nil
            && appPath.hasPrefix("/") && URL(fileURLWithPath: appPath).pathExtension.lowercased() == "app"
    }

    func matches(_ other: Self) -> Bool {
        appBundleID == other.appBundleID && extensionBundleID == other.extensionBundleID && teamID == other.teamID
    }

    struct Candidate: Sendable {
        let source: SafariExtensionSource
        let bundleURL: URL
    }

    private static func validBundleID(_ value: String) -> Bool {
        value.count <= 255 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil
    }

    private static func info(_ url: URL) throws -> [String: Any] {
        let path = url.appendingPathComponent("Contents/Info.plist")
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExtensionCodeStore.Problem("The app bundle’s Info.plist is missing or unreadable.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        let limit = 4 * 1024 * 1024
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0, status.st_size <= limit else { throw ExtensionCodeStore.Problem("The app bundle’s Info.plist is invalid or too large.") }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit,
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ExtensionCodeStore.Problem("The app bundle’s Info.plist is invalid.")
        }
        return value
    }

    struct Signature: Sendable {
        let identifier: String
        let team: String
        let hash: String
    }

    static func verify(_ url: URL) throws -> Signature {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw ExtensionCodeStore.Problem("The selected bundle has no verifiable Apple-issued code signature.") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw ExtensionCodeStore.Problem("The app or Safari extension’s signed code or resources could not be verified. Reinstall the original app from its trusted distributor and try again.")
        }
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let values = signing as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data,
              let bundleID = try info(url)["CFBundleIdentifier"] as? String,
              identifier == bundleID, validBundleID(identifier),
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw ExtensionCodeStore.Problem("The bundle identifier and verified signing identity do not match, or the signing Team ID is missing.")
        }
        // Developer certificates bind the Team ID through their leaf OU. Mac App
        // Store apps are re-signed by Apple's own store certificate instead; its
        // authenticated CodeDirectory supplies the original developer's Team ID.
        // TN3127 documents this store-only OID under the Apple trust anchor.
        var teamRequirement: SecRequirement?
        let expression = "anchor apple generic and (certificate leaf[subject.OU] = \"\(team)\" or certificate leaf[field.1.2.840.113635.100.6.1.9] exists)"
        guard SecRequirementCreateWithString(expression as CFString, [], &teamRequirement) == errSecSuccess,
              let teamRequirement,
              SecStaticCodeCheckValidity(code, flags, teamRequirement) == errSecSuccess else {
            throw ExtensionCodeStore.Problem("The signing Team ID does not match the bundle’s Apple-issued signing certificate.")
        }
        return Signature(identifier: identifier, team: team, hash: hash.map { String(format: "%02x", $0) }.joined())
    }

    /// Enumerate only immediate embedded Safari web extensions; never discover arbitrary
    /// resource folders or use a developer-controlled manifest ID as a signed identity.
    static func candidates(in selection: URL) throws -> [Candidate] {
        let selected = selection.resolvingSymlinksInPath()
        let app: URL
        if selected.pathExtension.lowercased() == "appex" {
            app = selected.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        } else { app = selected }
        guard app.pathExtension.lowercased() == "app" else {
            throw ExtensionCodeStore.Problem("Choose the installed app containing a Safari web extension.")
        }
        let appSignature = try verify(app)
        let plugins = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "appex" }
            .filter { selected.pathExtension.lowercased() != "appex" || $0.resolvingSymlinksInPath() == selected }
        var results: [Candidate] = []
        for url in urls {
            guard url.resolvingSymlinksInPath().deletingLastPathComponent() == plugins.resolvingSymlinksInPath() else {
                throw ExtensionCodeStore.Problem("A Safari extension bundle cannot link outside its containing app.")
            }
            let metadata = try info(url)
            guard (metadata["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension" else { continue }
            let signature = try verify(url)
            guard signature.team == appSignature.team else {
                throw ExtensionCodeStore.Problem("The Safari extension and containing app have different verified signing teams.")
            }
            let source = Self(appBundleID: appSignature.identifier, extensionBundleID: signature.identifier,
                teamID: signature.team, appPath: app.path, signatureHash: signature.hash)
            guard source.isValid else { throw ExtensionCodeStore.Problem("The Safari extension’s verified identity is invalid.") }
            results.append(Candidate(source: source, bundleURL: url))
        }
        guard !results.isEmpty else { throw ExtensionCodeStore.Problem("This app contains no verified Safari web extensions. Choose an app with a Safari web extension, or install an unpacked folder instead.") }
        guard Set(results.map { $0.source.runtimeID }).count == results.count else {
            throw ExtensionCodeStore.Problem("This app contains duplicate Safari extension identities. Reinstall the app before trying again.")
        }
        return results.sorted { $0.source.extensionBundleID < $1.source.extensionBundleID }
    }

    /// Prefer the selected app while it remains installed. If moved/replaced, resolve
    /// by the saved signed identity, never by filename or an unverified bundle ID.
    @MainActor func resolve() async throws -> Candidate {
        guard isValid else { throw ExtensionCodeStore.Problem("Saved Safari extension identity is invalid.") }
        let original = URL(fileURLWithPath: appPath)
        let urls = [original] + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: appBundleID)
        return try await Task.detached(priority: .utility) {
            var found: [Candidate] = []
            var seen = Set<String>()
            for url in urls {
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted,
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                let candidates = try Self.candidates(in: url)
                if let candidate = candidates.first(where: { self.matches($0.source) }) {
                    if url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath() { return candidate }
                    found.append(candidate)
                }
            }
            guard found.count == 1, let candidate = found.first else {
                throw ExtensionCodeStore.Problem(found.isEmpty
                    ? "The installed app or its verified Safari extension is missing or its signing identity changed. Reinstall the original app, then choose Retry. Your installation and settings are retained."
                    : "More than one matching app is installed. Choose Update from App to select the app to use.")
            }
            return candidate
        }.value
    }
}
