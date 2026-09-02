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

/// Bindings come from the registry, and the same closure is handed to the event monitor,
/// so a rebound key and the menu item can never disagree about what they run.
@MainActor private func item(_ command: Command, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
    Keybindings.actions[command] = run
    let act = Act(run)
    keepAlive.append(act)
    let binding = Keybindings.binding(for: command)
    let entry = NSMenuItem(title: command.title, action: #selector(Act.fire),
                           keyEquivalent: binding.menuKeyEquivalent)
    entry.target = act
    entry.keyEquivalentModifierMask = binding.menuModifierMask
    return entry
}

/// Items that must stay first-responder dispatched, so they grey out correctly, but whose
/// key still comes from the registry — with an equivalent action for the monitor.
@MainActor private func responderItem(_ command: Command, _ action: Selector,
                                      _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
    Keybindings.actions[command] = run
    let binding = Keybindings.binding(for: command)
    let entry = NSMenuItem(title: command.title, action: action,
                           keyEquivalent: binding.menuKeyEquivalent)
    entry.keyEquivalentModifierMask = binding.menuModifierMask
    return entry
}

private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let m = NSMenu(title: title)
    items.forEach(m.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = m
    return holder
}

@MainActor private func developItems() -> [NSMenuItem] {
    let inspector = item(.showWebInspector) {
        Inspector.show(Windows.current?.active?.web)
    }
    let console = item(.showJavaScriptConsole) {
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

    let allow = item(.allowWebInspector) {
        Settings.inspectorEnabled.toggle(); rebuild()
    }
    allow.state = Settings.inspectorEnabled ? .on : .off

    return [
        inspector,
        console,
        item(.viewSource) {
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

@MainActor private func readerTypefaceItem() -> NSMenuItem {
    let entry = item(.readerSerif) {
        Reader.setSerif(!Reader.serif, in: Windows.current?.active)
        rebuild()
    }
    entry.state = Reader.serif ? .on : .off
    return entry
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
    let remove = item(.deleteProfile) {
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
        item(.newProfile) {
            guard let name = askForName("Name the new profile") else { return }
            _ = manager.create(name: name)
            rebuild()
        },
        item(.renameProfile) {
            guard let name = askForName("Rename profile", manager.active.name) else { return }
            manager.rename(manager.active.id, to: name)
            rebuild()
        },
        remove,
    ]
}

/// ponytail: one in-flight tidy per app, cancelled by invoking it again — the model call
/// runs ~12s, and a second one would only contend for the single session.
@MainActor private var tidyTask: Task<Void, Never>?

@MainActor private func tidyItems() -> [NSMenuItem] {
    let store = Windows.current
    let tidy = item(.tidyTabs) {
        tidyTask?.cancel()
        guard let s = Windows.current else { return }
        tidyTask = Task { @MainActor in
            guard let groups = await TidyTabs.plan(for: s) else { return }
            TidyTabs.apply(groups, to: s)
            rebuild()                     // so Undo Tidy Tabs enables
        }
    }
    tidy.isEnabled = store.map(TidyTabs.shouldOffer) ?? false
    let undo = item(.undoTidyTabs) {
        guard let s = Windows.current else { return }
        TidyTabs.undo(s)
        rebuild()
    }
    undo.isEnabled = store.map(TidyTabs.canUndo) ?? false
    return [tidy, undo]
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
        item(.newSpace) {
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
        item(.settings) { SettingsWindow.show() },
        .separator(),
        NSMenuItem(title: "Hide Vane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
        NSMenuItem(title: "Quit Vane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
    ]))
    root.addItem(menu("File", [
        item(.newWindow) { Windows.open() },
        item(.newPrivateWindow) { Windows.open(isPrivate: true) },
        item(.newTab) { Windows.current?.newTab(nil) },
        .separator(),
        item(.reopenClosedTab) {
            if let u = ClosedTabs.pop() { (Windows.current ?? Windows.open()).newTab(u) }
        },
        item(.closeTab) { if let s = Windows.current, let c = s.current { s.close(c) } },
        responderItem(.closeWindow, #selector(NSWindow.performClose(_:))) {
            NSApp.keyWindow?.performClose(nil)
        },
        .separator(),
        responderItem(.printPage, #selector(NSView.printView(_:))) {
            NSApp.sendAction(#selector(NSView.printView(_:)), to: nil, from: nil)
        },
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
        item(.reload) { Windows.current?.active?.reload() },
        item(.hardReload) { Windows.current?.active?.hardReload() },
        item(.openLocation) { Windows.current?.focusAddress += 1 },
        item(.find) { Windows.current?.findOpen = true },
        .separator(),
        item(.actualSize) { Windows.current?.active.map(Zoom.reset) },
        item(.zoomIn) { Windows.current?.active.map(Zoom.zoomIn) },
        item(.zoomOut) { Windows.current?.active.map(Zoom.zoomOut) },
        .separator(),
        item(.fullScreen) { NSApp.keyWindow?.toggleFullScreen(nil) },
        .separator(),
        item(.showReader) { Windows.current?.active.map(Reader.toggle) },
        item(.pictureInPicture) { PictureInPicture.toggle(Windows.current?.active) },
        item(.biggerReaderText) { Reader.adjustFontSize(1, in: Windows.current?.active) },
        item(.smallerReaderText) { Reader.adjustFontSize(-1, in: Windows.current?.active) },
        readerTypefaceItem(),
    ]))
    root.addItem(menu("Passwords", [
        item(.fillPassword) { Windows.current?.active?.fillPassword() },
        item(.importPasswords) { PasswordImport.chooseAndImport() },
        item(.importHistoryAndBookmarks) { BrowserImport.chooseAndImport() },
        .separator(),
        item("Export Passwords…", "") { Export.chooseAndExport(.passwords) },
        item(.manageSavedPasswords) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
        },
    ]))
    let makeDefault = item(.makeDefaultBrowser) { URLHandling.makeDefaultBrowser() }
    makeDefault.isEnabled = !URLHandling.isDefaultBrowser
    let blocking = item(.blockAds) { Blocker.enabled.toggle(); rebuild() }
    blocking.state = Blocker.enabled ? .on : .off
    let tidyDownloads = item("Tidy Download Filenames", "") {
        TidyDownloads.enabled.toggle(); rebuild()
    }
    tidyDownloads.state = TidyDownloads.enabled ? .on : .off
    root.addItem(menu("Sites", [
        tidyDownloads,
        blocking,
        item(.addFilterList) { Blocker.chooseAndAddList() },
        .separator(),
        makeDefault,
        .separator(),
        item(.forgetCertificateExceptions) {
            let a = NSAlert()
            a.messageText = "Forget every certificate you chose to trust anyway?"
            a.informativeText = "Those sites will ask again the next time you visit them."
            a.addButton(withTitle: "Forget"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { CertificateTrust.forgetAll() }
        },
        item(.resetMediaPermissions) {
            let a = NSAlert()
            a.messageText = "Forget camera and microphone permissions for every site?"
            a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { SitePermissions.resetAll() }
        },
    ]))
    root.addItem(menu("Profiles", profileItems()))
    root.addItem(menu("Spaces", spaceItems()))
    root.addItem(menu("Tabs", tidyItems()))
    root.addItem(menu("Extensions", [
        item(.installExtension) { ExtensionHost.shared.chooseAndInstall(); rebuild() },
        .separator(),
    ] + ExtensionHost.shared.installed.map { ctx in
        item("Remove " + (ctx.webExtension.displayName ?? "Extension"), "") {
            ExtensionHost.shared.remove(ctx); rebuild()
        }
    }))
    root.addItem(menu("Develop", developItems()))
    root.addItem(menu("Bookmarks", [
        item(.bookmarkPage) { Windows.current?.active?.toggleBookmark(); rebuild() },
        item("Export Bookmarks…", "") { Export.chooseAndExport(.bookmarks) },
        .separator(),
    ] + Store.shared.bookmarks(limit: 40).map { b in
        item(b.title.isEmpty ? b.url : b.title, "") {
            if let u = URL(string: b.url) { Windows.current?.active?.web.load(URLRequest(url: u)) }
        }
    }))
    root.addItem(menu("History", [
        item(.back) { Windows.current?.active?.back() },
        item(.forward) { Windows.current?.active?.forward() },
        .separator(),
        item(.nextTab) { Windows.current?.cycle(1) },
        item(.previousTab) { Windows.current?.cycle(-1) },
        .separator(),
    ] + Store.shared.recent(limit: 25).map { h in
        item(h.title.isEmpty ? h.url : h.title, "") {
            if let u = URL(string: h.url) { Windows.current?.active?.web.load(URLRequest(url: u)) }
        }
    } + [
        .separator(),
        item("Export History (JSON)…", "") { Export.chooseAndExport(.historyJSON) },
        item("Export History (CSV)…", "") { Export.chooseAndExport(.historyCSV) },
        item(.clearHistory) {
            let a = NSAlert()
            a.messageText = "Clear all browsing history?"
            a.informativeText = "Bookmarks and saved passwords are not affected."
            a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { Store.shared.clearHistory() }
        },
    ]))
    return root
}
