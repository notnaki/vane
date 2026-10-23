import Foundation
import Darwin

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("vane-update-preparation-test-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var failures = 0
func check(_ name: String, _ passed: Bool) {
    print("\(passed ? "PASS" : "FAIL"): \(name)")
    if !passed { failures += 1 }
}
func quarantine(_ file: URL) throws {
    let value = "0082;00000000;VanePreparationTest;"
    let result = value.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
func quarantined(_ file: URL) -> Bool {
    getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}
func fixture(_ name: String) throws -> (source: URL, target: URL) {
    let scene = root.appendingPathComponent(name)
    let source = scene.appendingPathComponent("download/Vane.app")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("trusted payload".utf8).write(to: source.appendingPathComponent("payload"))
    try quarantine(source.appendingPathComponent("payload"))
    let target = scene.appendingPathComponent("Applications/Vane.app")
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (source, target)
}
func trusted(_ bundle: URL) -> Bool {
    (try? Data(contentsOf: bundle.appendingPathComponent("payload"))) == Data("trusted payload".utf8)
}

// Regression: preparing an application sibling lets a sandboxed client change a file
// after validation and have the unsandboxed helper remove its quarantine. Simulate that
// interleaving through the preparation boundary; the attacker only inspects Applications.
do {
    let (source, target) = try fixture("mutation")
    let applications = target.deletingLastPathComponent()
    let escaped = applications.appendingPathComponent("attacker-payload")
    let oldTMPDIR = getenv("TMPDIR").map { String(cString: $0) }
    setenv("TMPDIR", applications.path, 1)
    defer {
        if let oldTMPDIR { setenv("TMPDIR", oldTMPDIR, 1) }
        else { unsetenv("TMPDIR") }
    }
    var prepared: URL?
    var attackerWasStripped = false
    var completed = false
    do {
        try UpdateInstallation.installPrepared(source: source, at: target, keepPrevious: false,
            verify: trusted, mayReplaceTarget: { _ in true }, prepare: { copy in
                prepared = copy
                let siblings = try fm.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
                let exposed = siblings.first { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") }
                if let exposed {
                    let payload = exposed.appendingPathComponent("payload")
                    try Data("attacker payload".utf8).write(to: payload)
                    try quarantine(payload)
                }
                // A client can still replace its original download during preparation.
                try Data("changed source".utf8).write(to: source.appendingPathComponent("payload"))
                try UpdateInstallation.removeQuarantine(copy)
                if let exposed {
                    let payload = exposed.appendingPathComponent("payload")
                    attackerWasStripped = !quarantined(payload)
                    try fm.moveItem(at: payload, to: escaped)
                }
            })
        completed = true
    } catch { print("Preparation result: \(error)") }
    check("quarantine removal never touches an attacker-replaceable application sibling", !attackerWasStripped)
    check("source changes cannot alter the prepared update", completed && trusted(target))
    check("the published payload retains its prepared quarantine state",
        completed && !quarantined(target.appendingPathComponent("payload")))
    check("quarantine removal uses a different directory from the published bundle", prepared != nil && prepared != target)
    check("preparation happens outside the caller's source and target directories",
        prepared.map { !$0.path.hasPrefix(source.deletingLastPathComponent().path + "/")
            && !$0.path.hasPrefix(applications.path + "/") } == true)
    check("the caller's changed source retains quarantine", quarantined(source.appendingPathComponent("payload")))
    check("private preparation workspace is removed after success",
        prepared.map { !fm.fileExists(atPath: $0.deletingLastPathComponent().path) } == true)
}

// Each failure must clean its private copy, and failed verification must never prepare.
for phase in ["verification", "preparation", "publication"] {
    let (source, target) = try fixture(phase)
    var privateCopy: URL?
    var preparationRan = false
    var rejected = false
    do {
        try UpdateInstallation.installPrepared(source: source, at: target, keepPrevious: false,
            verify: { copy in
                privateCopy = privateCopy ?? copy
                return phase != "verification" && trusted(copy)
            }, mayReplaceTarget: { _ in phase != "publication" }, prepare: { _ in
                preparationRan = true
                if phase == "preparation" { throw NSError(domain: "fixture", code: 1) }
            })
    } catch { rejected = true }
    check("\(phase) failure refuses publication", rejected && !fm.fileExists(atPath: target.path))
    check("\(phase) failure removes its preparation workspace",
        privateCopy.map { !fm.fileExists(atPath: $0.deletingLastPathComponent().path) } == true)
    check("\(phase) failure preserves source quarantine", quarantined(source.appendingPathComponent("payload")))
    if phase == "verification" { check("unverified copies never reach quarantine removal", !preparationRan) }
}

do {
    let (source, target) = try fixture("symlink")
    let link = source.deletingLastPathComponent().appendingPathComponent("linked.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: source)
    var prepared = false
    var rejected = false
    do {
        try UpdateInstallation.installPrepared(source: link, at: target, keepPrevious: false,
            verify: trusted, mayReplaceTarget: { _ in true }, prepare: { _ in prepared = true })
    } catch { rejected = true }
    check("a symbolic-link source cannot enter private preparation", rejected && !prepared)
    check("symbolic-link rejection preserves source quarantine", quarantined(source.appendingPathComponent("payload")))
}

exit(failures == 0 ? 0 : 1)
