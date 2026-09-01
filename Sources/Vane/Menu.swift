import AppKit

/// Menu items whose action is just a closure. NSMenuItem needs an ObjC target, so this is
/// the smallest thing that gives one; `keepAlive` stops ARC eating them.
private final class Act: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
@MainActor private var keepAlive: [Act] = []

@MainActor private func item(_ title: String, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command,
                  _ run: @escaping () -> Void) -> NSMenuItem {
    let act = Act(run)
    keepAlive.append(act)
    let i = NSMenuItem(title: title, action: #selector(Act.fire), keyEquivalent: key)
    i.target = act
    i.keyEquivalentModifierMask = mods
    return i
}

private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let m = NSMenu(title: title)
    items.forEach(m.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = m
    return holder
}

@MainActor private func developItems() -> [NSMenuItem] {
    let inspector = item("Show Web Inspector", "i", [.command, .option]) {
        Inspector.show(Windows.current?.active?.web)
    }
    let console = item("Show JavaScript Console", "c", [.command, .option]) {
        Inspector.showConsole(Windows.current?.active?.web)
    }
    // The SPI is the only way in from a menu item; without it, say so rather than
    // offering a item that quietly does nothing.
    if !Inspector.available || !Settings.inspectorEnabled {
        for i in [inspector, console] {
            i.isEnabled = false
            i.toolTip = Settings.inspectorEnabled
                ? "Unavailable on this macOS — use right-click → Inspect Element"
                : "Turn on “Allow Web Inspector” first"
        }
    }

    let agents = NSMenu(title: "User Agent")
    for ua in Settings.userAgents {
        let entry = item(ua.name, "") { Settings.userAgent = ua.value; rebuild() }
        entry.state = Settings.userAgent == ua.value ? .on : .off
        agents.addItem(entry)
    }
    let agentHolder = NSMenuItem(title: "User Agent", action: nil, keyEquivalent: "")
    agentHolder.submenu = agents

    let allow = item("Allow Web Inspector", "") {
        Settings.inspectorEnabled.toggle(); rebuild()
    }
    allow.state = Settings.inspectorEnabled ? .on : .off

    return [
        inspector,
        console,
        item("View Source", "u", [.command, .option]) {
            if let s = Windows.current { s.active?.viewSource(into: s) }
        },
        .separator(),
        agentHolder,
        .separator(),
        allow,
    ]
}

/// One-line text prompt. ponytail: an NSAlert with an accessory field, not a window — a
/// name is one string and this is not the settings surface.
@MainActor private func askForName(_ title: String, _ initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

@MainActor private func profileItems() -> [NSMenuItem] {
    let manager = ProfileManager.shared
    let switchers = manager.profiles.map { profile in
        let entry = item(profile.name, "") {
            _ = Windows.switchTo(profile: profile)
            rebuild()          // switchTo does not rebuild, and every checkmark below moved
        }
        entry.state = manager.active.id == profile.id ? .on : .off
        return entry
    }
    // delete() refuses on the last profile; disable rather than let it fail in an alert.
    let remove = item("Delete Profile…", "") {
        let active = manager.active
        let alert = NSAlert()
        alert.messageText = "Delete the profile “\(active.name)”?"
        alert.informativeText = "Its history, bookmarks, saved passwords, cookies and "
            + "extensions are deleted with it. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn, manager.delete(active.id) {
            _ = Windows.switchTo(profile: manager.active)
            rebuild()
        }
    }
    remove.isEnabled = manager.profiles.count > 1

    return switchers + [
        .separator(),
        item("New Profile…", "") {
            guard let name = askForName("Name the new profile") else { return }
            _ = manager.create(name: name)
            rebuild()
        },
        item("Rename Profile…", "") {
            guard let name = askForName("Rename profile", manager.active.name) else { return }
            manager.rename(manager.active.id, to: name)
            rebuild()
        },
        remove,
    ]
}

@MainActor private func spaceItems() -> [NSMenuItem] {
    let store = Windows.current
    let switchers = (store?.spaces ?? []).map { space in
        let entry = item(space.name, "") { Windows.current?.switchTo(space: space); rebuild() }
        entry.state = store?.currentSpaceID == space.id ? .on : .off
        return entry
    }
    return switchers + [
        .separator(),
        item("New Space…", "") {
            guard let name = askForName("Name the new space") else { return }
            _ = Windows.current?.newSpace(named: name)
            rebuild()
        },
    ]
}

/// Menus carry live state (checkmarks, the bookmarks and history lists), so they are
/// rebuilt rather than mutated in place.
@MainActor func rebuild() { NSApp.mainMenu = buildMenu() }

@MainActor func buildMenu() -> NSMenu {
    let root = NSMenu()
    root.addItem(menu("Vane", [
        NSMenuItem(title: "About Vane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
        .separator(),
        item("Settings…", ",") { SettingsWindow.show() },
        .separator(),
        NSMenuItem(title: "Hide Vane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
        NSMenuItem(title: "Quit Vane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
    ]))
    root.addItem(menu("File", [
        item("New Window", "n") { Windows.open() },
        item("New Private Window", "N", [.command, .shift]) { Windows.open(isPrivate: true) },
        item("New Tab", "t") { Windows.current?.newTab(nil) },
        .separator(),
        item("Reopen Closed Tab", "T", [.command, .shift]) {
            if let u = ClosedTabs.pop() { (Windows.current ?? Windows.open()).newTab(u) }
        },
        item("Close Tab", "w") { if let s = Windows.current, let c = s.current { s.close(c) } },
        NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W"),
        .separator(),
        NSMenuItem(title: "Print…", action: #selector(NSView.printView(_:)), keyEquivalent: "p"),
    ]))
    root.addItem(menu("Edit", [
        NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
        NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
        .separator(),
        NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
        NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
        NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
    ]))
    root.addItem(menu("View", [
        item("Reload Page", "r") { Windows.current?.active?.reload() },
        item("Reload Ignoring Cache", "R", [.command, .shift]) { Windows.current?.active?.hardReload() },
        item("Open Location…", "l") { Windows.current?.focusAddress += 1 },
        item("Find…", "f") { Windows.current?.findOpen = true },
        .separator(),
        item("Actual Size", "0") { Windows.current?.active?.web.pageZoom = 1 },
        item("Zoom In", "+") { Windows.current?.active.map { $0.web.pageZoom *= 1.1 } },
        item("Zoom Out", "-") { Windows.current?.active.map { $0.web.pageZoom /= 1.1 } },
        .separator(),
        item("Enter Full Screen", "f", [.command, .control]) { NSApp.keyWindow?.toggleFullScreen(nil) },
    ]))
    root.addItem(menu("Passwords", [
        item("Fill Password", "l", [.command, .shift]) { Windows.current?.active?.fillPassword() },
        item("Import Passwords…", "") { PasswordImport.chooseAndImport() },
        item("Import History & Bookmarks…", "") { BrowserImport.chooseAndImport() },
        item("Manage Saved Passwords…", "") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
        },
    ]))
    let makeDefault = item("Make Vane the Default Browser", "") { URLHandling.makeDefaultBrowser() }
    makeDefault.isEnabled = !URLHandling.isDefaultBrowser
    let blocking = item("Block Ads and Trackers", "") { Blocker.enabled.toggle(); rebuild() }
    blocking.state = Blocker.enabled ? .on : .off
    root.addItem(menu("Sites", [
        blocking,
        item("Add Filter List…", "") { Blocker.chooseAndAddList() },
        .separator(),
        makeDefault,
        .separator(),
        item("Forget Certificate Exceptions…", "") {
            let a = NSAlert()
            a.messageText = "Forget every certificate you chose to trust anyway?"
            a.informativeText = "Those sites will ask again the next time you visit them."
            a.addButton(withTitle: "Forget"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { CertificateTrust.forgetAll() }
        },
        item("Reset Camera & Microphone Permissions…", "") {
            let a = NSAlert()
            a.messageText = "Forget camera and microphone permissions for every site?"
            a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { SitePermissions.resetAll() }
        },
    ]))
    root.addItem(menu("Profiles", profileItems()))
    root.addItem(menu("Spaces", spaceItems()))
    root.addItem(menu("Extensions", [
        item("Install Extension…", "") { ExtensionHost.shared.chooseAndInstall(); rebuild() },
        .separator(),
    ] + ExtensionHost.shared.installed.map { ctx in
        item("Remove " + (ctx.webExtension.displayName ?? "Extension"), "") {
            ExtensionHost.shared.remove(ctx); rebuild()
        }
    }))
    root.addItem(menu("Develop", developItems()))
    root.addItem(menu("Bookmarks", [
        item("Bookmark This Page", "d") { Windows.current?.active?.toggleBookmark(); rebuild() },
        .separator(),
    ] + Store.shared.bookmarks(limit: 40).map { b in
        item(b.title.isEmpty ? b.url : b.title, "") {
            if let u = URL(string: b.url) { Windows.current?.active?.web.load(URLRequest(url: u)) }
        }
    }))
    root.addItem(menu("History", [
        item("Back", "[") { Windows.current?.active?.back() },
        item("Forward", "]") { Windows.current?.active?.forward() },
        .separator(),
        item("Next Tab", "\u{0019}", [.control, .shift]) { Windows.current?.cycle(1) },
        item("Previous Tab", "\t", [.control]) { Windows.current?.cycle(-1) },
        .separator(),
    ] + Store.shared.recent(limit: 25).map { h in
        item(h.title.isEmpty ? h.url : h.title, "") {
            if let u = URL(string: h.url) { Windows.current?.active?.web.load(URLRequest(url: u)) }
        }
    } + [
        .separator(),
        item("Clear History", "") {
            let a = NSAlert()
            a.messageText = "Clear all browsing history?"
            a.informativeText = "Bookmarks and saved passwords are not affected."
            a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { Store.shared.clearHistory() }
        },
    ]))
    return root
}
