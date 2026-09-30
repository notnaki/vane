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
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.0.0"], format: .xml, options: 0)
    try data.write(to: target.appendingPathComponent("Contents/Info.plist"))
    try Data("old".utf8).write(to: target.appendingPathComponent("old-version"))
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
let target = try oldTarget(root)
let nestedTarget = root.appendingPathComponent("Browsers/Vane.app")
do {
    try UpdateInstallation.install(source: source, target: nestedTarget, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [root])
    check("nested Applications installation is supported", !CommandLine.arguments.contains("--unsigned") && unquarantined(nestedTarget))
    _ = BundleReplacement.beginLaunch(at: nestedTarget)
    BundleReplacement.markHealthy(at: nestedTarget)
} catch BundleReplacement.Fault.invalidStage {
    check("nested Applications destination reaches signature validation", CommandLine.arguments.contains("--unsigned"))
} catch { check("nested Applications installation is supported (\(error))", false) }
if CommandLine.arguments.contains("--unsigned") {
    do {
        try UpdateInstallation.install(source: source, target: target, tag: sourceTag,
                                       keepPrevious: false, applicationsDirectories: [root])
        check("unsigned update is rejected", false)
    } catch BundleReplacement.Fault.invalidStage { check("unsigned update is rejected", true) }
    catch { check("unsigned update reaches signature validation (\(error))", false) }
    check("rejected update preserves old app and quarantine", fm.fileExists(atPath: target.appendingPathComponent("old-version").path) && quarantined(source))
    try UpdateInstallation.removeQuarantine(source)
    check("recursive cleanup covers bundle and executable", unquarantined(source) && unquarantined(executable))
} else {
    try UpdateInstallation.install(source: source, target: target, tag: sourceTag,
                                   keepPrevious: false, applicationsDirectories: [root])
    check("installed bundle has no quarantine", unquarantined(target))
    check("installed executable has no quarantine", unquarantined(target.appendingPathComponent("Contents/MacOS/Vane")))
    let stages = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") }
    check("old installation remains recoverable", stages.count == 1 && fm.fileExists(atPath: stages[0].appendingPathComponent("old-version").path))
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
    } catch BundleReplacement.Fault.invalidStage { check("tampered update is rejected", true) }
    catch { check("tampered update reaches signature validation (\(error))", false) }
    check("signature rejection preserves old app and download quarantine", fm.fileExists(atPath: rejectedTarget.appendingPathComponent("old-version").path) && quarantined(tampered))
    do {
        try UpdateInstallation.install(source: source, target: rejectedTarget, tag: "99.0.0",
                                       keepPrevious: false, applicationsDirectories: [rejectedRoot])
        check("advertised version must match signed payload", false)
    } catch BundleReplacement.Fault.invalidStage { check("advertised version must match signed payload", true) }
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
    if CommandLine.arguments.count > 2 {
        let unnotarized = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            try UpdateInstallation.install(source: unnotarized, target: rejectedTarget, tag: try tag(unnotarized),
                                           keepPrevious: false, applicationsDirectories: [rejectedRoot])
            check("unnotarized update is rejected", false)
        } catch { check("unnotarized update is rejected by Gatekeeper (\(error.localizedDescription))", error.localizedDescription == "Gatekeeper rejected the update") }
        check("Gatekeeper rejection preserves old installation", fm.fileExists(atPath: rejectedTarget.appendingPathComponent("old-version").path))
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
