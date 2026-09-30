import Foundation
import Darwin

if CommandLine.arguments.contains("--install") {
    let fm = FileManager.default
    let source = fm.temporaryDirectory.appendingPathComponent("Vane-xpc-check-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: source) }
    do {
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: source)
        guard getxattr(source.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 else {
            print("FAIL: sandboxed source did not carry quarantine")
            exit(1)
        }
        let target = URL(fileURLWithPath: CommandLine.arguments[2])
        let plist = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
        let tag = info["CFBundleShortVersionString"] as! String
        try UpdateInstaller.install(source: source, target: target, tag: tag, keepPrevious: false)
        for relative in ["", "Contents/MacOS/Vane"] {
            let path = target.appendingPathComponent(relative).path
            guard getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1,
                  errno == ENOATTR else {
                print("FAIL: XPC-installed bundle or executable is quarantined")
                exit(1)
            }
        }
        print("PASS: sandboxed download installed through XPC without bundle or executable quarantine")
        exit(0)
    } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}

// Exercise the production service from a signed, sandboxed bundle. Use a forbidden
// destination: no application directory or installed browser is modified by the test.
do {
    _ = try UpdateInstaller.install(source: URL(fileURLWithPath: CommandLine.arguments[1]),
                                    target: URL(fileURLWithPath: "/tmp/Vane-installer-test/Vane.app"),
                                    tag: "1.0.0", keepPrevious: false)
    print("FAIL: installer accepted an arbitrary destination")
    exit(1)
} catch {
    let rejectedByPolicy = (error as NSError).localizedDescription == "Invalid update destination"
    let expected = CommandLine.arguments.contains("--unauthorized") ? !rejectedByPolicy : rejectedByPolicy
    print("\(expected ? "PASS" : "FAIL"): \(error.localizedDescription)")
    exit(expected ? 0 : 1)
}
