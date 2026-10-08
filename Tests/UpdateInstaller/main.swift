import Foundation
import Darwin

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("Vane-quarantine-check-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}
func tag(_ bundle: URL) throws -> String {
    let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    return info["CFBundleShortVersionString"] as! String
}
func oldTarget(_ directory: URL) throws -> URL {
    let target = directory.appendingPathComponent("Vane.app")
    try fm.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.0.0", "CFBundleIdentifier": "io.github.notnaki.vane", "CFBundlePackageType": "APPL", "CFBundleExecutable": "Vane", "CFBundleVersion": "1"], format: .xml, options: 0)
    try data.write(to: target.appendingPathComponent("Contents/Info.plist"))
    try fm.createDirectory(at: target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: target.appendingPathComponent("Contents/MacOS/Vane"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.appendingPathComponent("Contents/MacOS/Vane").path)
    try fm.createDirectory(at: target.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: target.appendingPathComponent("Contents/Resources/old-version"))
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", target.path]
    sign.standardError = FileHandle.standardError
    try sign.run(); sign.waitUntilExit()
    precondition(sign.terminationStatus == 0)
    return target
}
func quarantined(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}
func unquarantined(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1 && errno == ENOATTR
}
let source = root.appendingPathComponent("incoming/Vane.app")
try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: source)
let sourceTag = try tag(source)
let executable = source.appendingPathComponent("Contents/MacOS/Vane")
let external = root.appendingPathComponent("external")
try Data("external".utf8).write(to: external)
let quarantine = "0282;00000000;Vane;"
for url in [source, executable, external] {
    let status = quarantine.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    precondition(status == 0, "fixture quarantine must be written")
}
// Cleanup must leave unrelated metadata and external symlink targets alone.
let marker = "preserve-me"
_ = marker.withCString { setxattr(source.path, "com.example.vane-test", $0, strlen($0), 0, XATTR_NOFOLLOW) }
let links = root.appendingPathComponent("links")
try fm.createDirectory(at: links, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: links.appendingPathComponent("outside"), withDestinationURL: external)
try UpdateInstallation.removeQuarantine(links)
check("cleanup does not follow external symlinks", quarantined(external))
let linkedSource = root.appendingPathComponent("linked-source.app")
try fm.createSymbolicLink(at: linkedSource, withDestinationURL: source)
let linkDestination = root.appendingPathComponent("link-destination")
try fm.createDirectory(at: linkDestination, withIntermediateDirectories: true)
do {
    try UpdateInstallation.install(source: linkedSource, target: linkDestination.appendingPathComponent("Vane.app"),
                                   tag: sourceTag, keepPrevious: false, applicationsDirectories: [linkDestination])
    check("symlink source root is rejected", false)
} catch { check("symlink source root is rejected", error.localizedDescription == "Invalid update source") }
do {
    try UpdateInstallation.removeQuarantine(linkedSource)
    check("cleanup rejects symlink root", false)
} catch { check("cleanup rejects symlink root", error.localizedDescription == "Invalid update source") }
check("symlink source rejection preserves source quarantine", quarantined(source) && quarantined(executable))
let unrelatedRoot = root.appendingPathComponent("unrelated-destination")
let unrelatedTarget = try oldTarget(unrelatedRoot)
let unrelatedInfo: [String: Any] = ["CFBundleShortVersionString": "0.0.0", "CFBundleIdentifier": "com.example.unrelated"]
try PropertyListSerialization.data(fromPropertyList: unrelatedInfo, format: .xml, options: 0)
    .write(to: unrelatedTarget.appendingPathComponent("Contents/Info.plist"))
do {
    try UpdateInstallation.install(source: source, target: unrelatedTarget, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [unrelatedRoot])
    check("unrelated app named Vane.app is never replaced", false)
} catch {
    check("unrelated app named Vane.app is never replaced", fm.fileExists(atPath: unrelatedTarget.appendingPathComponent("Contents/Resources/old-version").path)
          && !fm.fileExists(atPath: unrelatedRoot.appendingPathComponent(".Vane.app.vane-transaction.json").path))
}
if !CommandLine.arguments.contains("--unsigned") {
    let corruptRoot = root.appendingPathComponent("corrupt-existing")
    let corruptTarget = try oldTarget(corruptRoot)
    let binary = corruptTarget.appendingPathComponent("Contents/MacOS/Vane")
    let handle = try FileHandle(forWritingTo: binary)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("unsigned bytes".utf8)); try handle.close()
    do {
        try UpdateInstallation.install(source: source, target: corruptTarget, tag: sourceTag,
            keepPrevious: false, applicationsDirectories: [corruptRoot])
        check("invalid existing signature cannot become rollback backup", false)
    } catch {
        check("invalid existing signature cannot become rollback backup", fm.fileExists(atPath: corruptTarget.appendingPathComponent("Contents/Resources/old-version").path))
    }
}
let target = try oldTarget(root)
let nestedTarget = root.appendingPathComponent("Browsers/Vane.app")
do {
    try UpdateInstallation.install(source: source, target: nestedTarget, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [root])
    check("nested Applications installation is supported", !CommandLine.arguments.contains("--unsigned") && unquarantined(nestedTarget))
    _ = BundleReplacement.beginLaunch(at: nestedTarget)
    BundleReplacement.markHealthy(at: nestedTarget)
} catch let error as NSError where error.localizedDescription == "Update signature verification failed" {
    check("nested Applications destination reaches signature validation", CommandLine.arguments.contains("--unsigned") && error.userInfo[NSUnderlyingErrorKey] != nil)
} catch { check("nested Applications installation is supported (\(error))", false) }
if CommandLine.arguments.contains("--unsigned") {
    do {
        try UpdateInstallation.install(source: source, target: target, tag: sourceTag,
                                       keepPrevious: false, applicationsDirectories: [root])
        check("unsigned update is rejected", false)
    } catch let error as NSError where error.localizedDescription == "Update signature verification failed" { check("unsigned update is rejected", error.userInfo[NSUnderlyingErrorKey] != nil) }
    catch { check("unsigned update reaches signature validation (\(error))", false) }
    check("rejected update preserves old app and quarantine", fm.fileExists(atPath: target.appendingPathComponent("Contents/Resources/old-version").path) && quarantined(source))
    try UpdateInstallation.removeQuarantine(source)
    check("recursive cleanup covers bundle and executable", unquarantined(source) && unquarantined(executable))
} else {
    try UpdateInstallation.install(source: source, target: target, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [root])
    check("installed bundle has no quarantine", unquarantined(target))
    check("installed executable has no quarantine", unquarantined(target.appendingPathComponent("Contents/MacOS/Vane")))
    let stages = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") }
    check("old installation remains recoverable", stages.count == 1 && fm.fileExists(atPath: stages[0].appendingPathComponent("Contents/Resources/old-version").path))
    check("download remains quarantined", quarantined(source))
    check("replacement enters launch recovery", BundleReplacement.beginLaunch(at: target) == .waitingForHealth)
    BundleReplacement.markHealthy(at: target)
    check("healthy launch completes transaction", BundleReplacement.beginLaunch(at: target) == .unchanged)
    // Equal versions may not replace the app even though the source is valid.
    do {
        try UpdateInstallation.install(source: source, target: target, tag: sourceTag,
                                       keepPrevious: false, applicationsDirectories: [root])
        check("equal version is rejected under transaction lock", false)
    } catch BundleReplacement.Fault.staleTarget { check("equal version is rejected under transaction lock", true) }
    catch { check("equal version is rejected by version policy (\(error))", false) }
    let tampered = root.appendingPathComponent("tampered.app")
    try fm.copyItem(at: source, to: tampered)
    let handle = try FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/MacOS/Vane"))
    try handle.seek(toOffset: 4096)
    let original = try Data(contentsOf: tampered.appendingPathComponent("Contents/MacOS/Vane"))[4096]
    try handle.write(contentsOf: Data([original ^ 0xff]))
    try handle.close()
    let rejectedRoot = root.appendingPathComponent("rejected")
    let rejectedTarget = try oldTarget(rejectedRoot)
    do {
        try UpdateInstallation.install(source: tampered, target: rejectedTarget, tag: sourceTag,
                                       keepPrevious: false, applicationsDirectories: [rejectedRoot])
        check("tampered update is rejected", false)
    } catch let error as NSError where error.localizedDescription == "Update signature verification failed" { check("tampered update is rejected", error.userInfo[NSUnderlyingErrorKey] != nil) }
    catch { check("tampered update reaches signature validation (\(error))", false) }
    check("signature rejection preserves old app and download quarantine", fm.fileExists(atPath: rejectedTarget.appendingPathComponent("Contents/Resources/old-version").path) && quarantined(tampered))
    do {
        try UpdateInstallation.install(source: source, target: rejectedTarget, tag: "99.0.0",
                                       keepPrevious: false, applicationsDirectories: [rejectedRoot])
        check("advertised version must match signed payload", false)
    } catch let error as NSError where error.localizedDescription == "Update version does not match advertised version" { check("advertised version must match signed payload", true) }
    catch { check("advertised version reaches payload validation (\(error))", false) }
    let firstRoot = root.appendingPathComponent("first")
    try fm.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    let firstTarget = firstRoot.appendingPathComponent("Vane.app")
    try UpdateInstallation.install(source: source, target: firstTarget, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [firstRoot])
    check("first install has no quarantine", unquarantined(firstTarget))
    _ = BundleReplacement.beginLaunch(at: firstTarget)
    BundleReplacement.markHealthy(at: firstTarget)
    check("first install completes without a backup", try fm.contentsOfDirectory(at: firstRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("vane-stage") }.isEmpty)
    if CommandLine.arguments.count > 2, !CommandLine.arguments[2].hasPrefix("--") {
        let unnotarized = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            try UpdateInstallation.install(source: unnotarized, target: rejectedTarget, tag: try tag(unnotarized),
                                           keepPrevious: false, applicationsDirectories: [rejectedRoot])
            check("unnotarized update is rejected", false)
        } catch { check("unnotarized update is rejected by Gatekeeper (\(error.localizedDescription))", error.localizedDescription == "Gatekeeper rejected the update") }
        check("Gatekeeper rejection preserves old installation", fm.fileExists(atPath: rejectedTarget.appendingPathComponent("Contents/Resources/old-version").path))
    }
}
if let index = CommandLine.arguments.firstIndex(of: "--fixtures"), index + 1 < CommandLine.arguments.count {
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let expectations = [
        ("identity", "Invalid update bundle identity or version"),
        ("version", "Invalid update bundle identity or version"),
        ("architecture", "Update executable does not support this architecture"),
        ("gatekeeper", "Gatekeeper rejected the update")]
    for (name, expected) in expectations {
        let fixture = fixtures.appendingPathComponent(name + ".app")
        let destination = root.appendingPathComponent("invalid-" + name)
        let previous = try oldTarget(destination)
        do {
            try UpdateInstallation.install(source: fixture, target: previous, tag: "0.0.25",
                keepPrevious: false, applicationsDirectories: [destination])
            check("real signed \(name) fixture rejected", false)
        } catch {
            let actual = error as NSError
            check("real signed \(name) fixture rejected: \(actual)", actual.localizedDescription == expected)
            if name == "gatekeeper" { check("Gatekeeper stderr and status retained", actual.userInfo[NSUnderlyingErrorKey] != nil && actual.code != 0) }
        }
        check("\(name) rejection retains previous installation", fm.fileExists(atPath: previous.appendingPathComponent("Contents/Resources/old-version").path))
    }
}
let markerURL = CommandLine.arguments.contains("--unsigned") ? source : target
check("cleanup preserves unrelated metadata", getxattr(markerURL.path, "com.example.vane-test", nil, 0, 0, XATTR_NOFOLLOW) == marker.utf8.count)
do {
    try UpdateInstallation.install(source: source, target: root.appendingPathComponent("Other.app"), tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [root])
    check("arbitrary destination is rejected", false)
} catch { check("arbitrary destination is rejected", error.localizedDescription == "Invalid update destination") }
let redirect = root.appendingPathComponent("redirect")
try fm.createSymbolicLink(at: redirect, withDestinationURL: root)
do {
    try UpdateInstallation.install(source: source, target: redirect.appendingPathComponent("Vane.app"), tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [redirect])
    check("symlink destination is rejected", false)
} catch { check("symlink destination is rejected", error.localizedDescription == "Invalid update destination") }
exit(failures == 0 ? 0 : 1)
