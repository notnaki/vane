import AppKit
import SwiftUI

// ponytail: no AppDelegate, no @main App struct — plain top-level bootstrap, same shape
// as Vesta. Everything below is retained because it is global.
let args = Array(CommandLine.arguments.dropFirst())
// Before AppKit is touched at all: the pure checks must not need a window server.
if args.first == "selfcheck", args.contains("--pure") { SelfCheck.run(pureOnly: true) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
// The Dock icon has to lead somewhere when every window is closed, and its menu has to
// offer a window. That is the whole of the delegate; see AppLifecycle.swift.
app.delegate = AppLifecycle.shared
if args.first == "drmcheck"  { DRMCheck.run(url: args.dropFirst().first) }
if args.first == "selfcheck" { SelfCheck.run() }
if args.first == "import", let file = args.dropFirst().first {
    let (n, skipped) = try! PasswordImport.importFile(URL(fileURLWithPath: file))
    print("imported \(n), skipped \(skipped) — now delete \(file), it is plain text")
    exit(0)
}

Crash.begin()

// `vane <url>` beats a restored session; otherwise pick up where the user left off. The url
// is routed exactly as a link from any other app is, so `open -a Vane <url>` and a click in
// Mail land in the same place — a Little Arc, or a window with the page in it.
if let first = args.first, first.hasPrefix("http"), let u = URL(string: first) {
    URLHandling.open([u])
} else if !Prefs.restoreSession || !Crash.offerRestore() {
    Windows.open()
}

NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                       object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { Crash.markClean() }
}

Inspector.configure()
Blocker.refresh()
AppleAI.prewarm()      // first request otherwise pays model load on top of its own latency
URLHandling.registerAppleEventHandler()
app.mainMenu = buildMenu()
// Rebound keys are resolved here, before AppKit dispatches menu key equivalents. Commands
// with no registered action fall through untouched. A Little Arc gets first refusal: three
// of its keys mean something else in a window with a sidebar, and the registry would
// otherwise answer for them. See LittleArc.handleKey. A Peek is ahead of both, for the same
// reason: Escape and ⌘O both mean something else in a window with a sidebar, and only
// Peek knows whether one is up. See Peek.handleKey.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
    Peek.handleKey($0) || LittleArc.handleKey($0) || Keybindings.handle($0) ? nil : $0
}
app.activate(ignoringOtherApps: true)
URLHandling.promptIfNotDefaultOnce()
app.run()
