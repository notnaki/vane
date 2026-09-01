import AppKit
import SwiftUI

// ponytail: no AppDelegate, no @main App struct — plain top-level bootstrap, same shape
// as Vesta. Everything below is retained because it is global.
let args = Array(CommandLine.arguments.dropFirst())
// Before AppKit is touched at all: the pure checks must not need a window server.
if args.first == "selfcheck", args.contains("--pure") { SelfCheck.run(pureOnly: true) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if args.first == "drmcheck"  { DRMCheck.run(url: args.dropFirst().first) }
if args.first == "selfcheck" { SelfCheck.run() }
if args.first == "import", let file = args.dropFirst().first {
    let (n, skipped) = try! PasswordImport.importFile(URL(fileURLWithPath: file))
    print("imported \(n), skipped \(skipped) — now delete \(file), it is plain text")
    exit(0)
}

// `vane <url>` beats a restored session; otherwise pick up where the user left off.
if let first = args.first, first.hasPrefix("http"), let u = URL(string: first) {
    Windows.open(urls: [u])
} else if !Session.restore() {
    Windows.open()
}

NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                       object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { Session.save() }
}

Inspector.configure()
Blocker.refresh()
URLHandling.registerAppleEventHandler()
app.mainMenu = buildMenu()
app.activate(ignoringOtherApps: true)
URLHandling.promptIfNotDefaultOnce()
app.run()
