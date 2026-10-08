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
if args.first == "browsercheck" { BrowserChecks.run() }
if args.first == "browsercheck-cleanup" { BrowserChecks.cleanupStore() }
if args.first == "import" {
    guard let file = args.dropFirst().first else {
        FileHandle.standardError.write(Data("Usage: vane import <password-export.csv>\n".utf8))
        exit(2)
    }
    do {
        let result = try PasswordImport.importFile(URL(fileURLWithPath: file))
        let report = "imported \(result.imported), skipped \(result.skipped), failed \(result.failed)"
        if result.failed > 0 {
            FileHandle.standardError.write(Data("\(report) — check Keychain access and try again; \(file) is plain text\n".utf8))
            exit(1)
        }
        print("\(report) — now delete \(file), it is plain text")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not import passwords: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// A replacement that failed before its first healthy launch restores the prior app and
// relaunches it. This must happen before any browser window or storage migration begins.
Updater.recoverAtLaunch()

// Recover before any profile migration, preference application or database opens.
// A failed rollback must never let normal startup write over a partial library.
let backupLaunchResult: BackupRestore.Result
do {
    try BackupRestore.claimInstance(Store.directory)
    backupLaunchResult = try BackupRestore(library: BackupLibrary(directory: Store.directory,
        defaults: .vane, domain: UserDefaults.vaneDomain)).recoverAtLaunch()
} catch {
    let alert = NSAlert()
    alert.messageText = "Vane needs data recovery"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(1)
}

// Before the first browser window writes profile and session files.
FirstLaunch.prepare()

// Before the first window, and so before the Dock tile is first drawn: the tile belongs to
// the running process, so a chosen icon has to be put back on every launch. See AppIcon.
AppIcon.restoreAtLaunch()

Crash.begin()
BatterySaver.shared.begin()

// Before any window: the refresh reattaches the compiled rules to every live web view, and
// doing that to pages that are already loading is reconfiguring a load underneath itself.
// Its work is a detached read-and-convert either way — see `Blocker.build`.
Blocker.refresh()

// `vane <url>` beats a restored session; otherwise pick up where the user left off. The url
// is routed exactly as a link from any other app is, so `open -a Vane <url>` and a click in
// Mail land in the same place — a Little Arc, or a window with the page in it.
if let first = args.first, first.hasPrefix("http"), let u = URL(string: first) {
    // A first-launch URL stays visible in the same full window that hosts the welcome.
    // Later launches keep the user's ordinary external-link routing preference.
    if FirstLaunch.needed { Windows.open(urls: [u]) }
    else { URLHandling.open([u]) }
} else if backupLaunchResult == .restored {
    if !Session.restore() { Windows.open() }
} else if !Prefs.restoreSession || !Crash.offerRestore() {
    Windows.open()
}

NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                       object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        Updater.markHealthyLaunch() // a clean early quit also proves the new copy could run
        Crash.markClean()
    }
}

Inspector.configure()
NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                       object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        BackupController.shared.reportLaunch(backupLaunchResult)
        BackupController.shared.begin()
    }
    Task { @MainActor in
        Tab.prepareFirstPage(profileID: ProfileManager.shared.active.id)
    }
    // Keep the previous bundle through startup and the first few seconds of WebKit work.
    // If this copy crashes first, its next launch restores the previous version.
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(5))
        Updater.markHealthyLaunch()
        AppleAI.prewarm() // leave the first page's CPU and disk work ahead of model warming
    }
}
Updater.shared.begin() // a first look five seconds in, then a conditional one on a tick
URLHandling.registerAppleEventHandler()
app.mainMenu = buildMenu()
// Rebound keys are resolved here, before AppKit dispatches menu key equivalents. Commands
// with no registered action fall through untouched. A Little Arc gets first refusal: three
// of its keys mean something else in a window with a sidebar, and the registry would
// otherwise answer for them. See LittleArc.handleKey. A Peek is ahead of both, for the same
// reason: Escape and ⌘O both mean something else in a window with a sidebar, and only
// Peek knows whether one is up. See Peek.handleKey.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
    if FirstLaunch.isPresenting { return $0 }
    return PasswordChooser.handleKey($0) || Peek.handleKey($0) || LittleArc.handleKey($0)
        || Keybindings.handle($0) ? nil : $0
}
app.activate(ignoringOtherApps: true)
if !FirstLaunch.presentIfNeeded() { URLHandling.promptIfNotDefaultOnce() }
app.run()
