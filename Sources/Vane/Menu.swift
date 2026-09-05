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

private extension NSMenuItem {
    /// `performTextFinderAction:` asks the sender which action it is, and the answer is the
    /// tag — so a standard find item needs one set inline.
    func tagged(_ tag: Int) -> NSMenuItem {
        self.tag = tag
        return self
    }
}

private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let m = NSMenu(title: title)
    items.forEach(m.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = m
    return holder
}

/// An item AppKit already implements: it is dispatched down the responder chain, so it
/// greys out on its own and works in a web view, a text field and the address bar alike.
/// Deliberately outside the registry — nobody rebinds Copy, and forty spelling toggles in
/// the Shortcuts pane would bury the shortcuts anybody actually looks for.
private func standard(_ title: String, _ action: Selector, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
    entry.keyEquivalentModifierMask = mods
    return entry
}

/// The Find submenu's next/previous. AppKit dispatches `performTextFinderAction:` and asks
/// the *sender* which action it is, so the tag is the whole difference between them. The
/// key still comes from the registry, and the monitor sends the same selector at the
/// responder chain with the same sender.
@MainActor private func finderItem(_ command: Command, _ action: NSTextFinder.Action) -> NSMenuItem {
    let selector = #selector(NSResponder.performTextFinderAction(_:))
    let binding = Keybindings.binding(for: command)
    let entry = NSMenuItem(title: command.title, action: selector,
                           keyEquivalent: binding.menuKeyEquivalent)
    entry.keyEquivalentModifierMask = binding.menuModifierMask
    entry.tag = action.rawValue
    Keybindings.actions[command] = { NSApp.sendAction(selector, to: nil, from: entry) }
    return entry
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
/// Not private: the sidebar's "Rename Space…" is the same prompt, and two copies of an
/// alert is exactly how two prompts drift apart.
@MainActor func askForName(_ title: String, _ initial: String = "") -> String? {
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

/// Arc keeps passwords and per-site controls in Settings, not in the menu bar; Vane's live
/// as submenus of the app menu so the bar stays Arc's ten menus wide.
@MainActor private func passwordItems() -> [NSMenuItem] {
    [

        item(.fillPassword) { Windows.current?.active?.fillPassword() },
        item(.importPasswords) { PasswordImport.chooseAndImport() },
        .separator(),
        item("Export Passwords…", "") { Export.chooseAndExport(.passwords) },
        item(.manageSavedPasswords) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
        },
    ]
}

@MainActor private func siteItems() -> [NSMenuItem] {
    let blocking = item(.blockAds) { Blocker.enabled.toggle(); rebuild() }
    blocking.state = Blocker.enabled ? .on : .off
    let tidyDownloads = item("Tidy Download Filenames", "") {
        TidyDownloads.enabled.toggle(); rebuild()
    }
    tidyDownloads.state = TidyDownloads.enabled ? .on : .off
    let httpsOnly = item("HTTPS-Only Mode", "") { HTTPSOnly.enabled.toggle(); rebuild() }
    httpsOnly.state = HTTPSOnly.enabled ? .on : .off
    return [
        httpsOnly,
        item("Forget HTTPS-Only Exceptions…", "") {
            let a = NSAlert()
            a.messageText = "Forget every site you allowed to load without encryption?"
            a.informativeText = "Those sites will be upgraded to https again, and will ask "
                + "before ever loading in the clear."
            a.addButton(withTitle: "Forget"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { HTTPSOnly.forgetAll() }
        },
        .separator(),
        tidyDownloads,
        blocking,
        item(.addFilterList) { Blocker.chooseAndAddList() },
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
    ]
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
    // `Windows.main`, not `current`: every item here moves rows around a sidebar, and a
    // Little Arc in front of the browser window has none. See LittleArc.swift.
    let store = Windows.main
    let tidy = item(.tidyTabs) {
        tidyTask?.cancel()
        guard let s = Windows.main else { return }
        tidyTask = Task { @MainActor in
            guard let groups = await TidyTabs.plan(for: s) else { return }
            let before = s.tabs.map(\.id)
            TidyTabs.apply(groups, to: s)
            rebuild()                     // so Undo Tidy Tabs enables
            // Only if anything moved: a tidy that changed nothing has nothing to undo, and
            // `canUndo` would still say yes for an earlier tidy nobody undid.
            if s.tabs.map(\.id) != before {
                Toasts.show("Tidied tabs", action: ("Undo", { [weak s] in
                    guard let s else { return }
                    TidyTabs.undo(s)
                    rebuild()
                }), in: s)
            }
        }
    }
    tidy.isEnabled = store.map(TidyTabs.shouldOffer) ?? false
    let undo = item(.undoTidyTabs) {
        guard let s = Windows.main else { return }
        TidyTabs.undo(s)
        rebuild()
    }
    undo.isEnabled = store.map(TidyTabs.canUndo) ?? false
    let clear = item(.clearTabs) { clearTabs() }
    clear.isEnabled = store.map { s in s.tabs.contains { $0.kind == .today } } ?? false
    let favourite = item(.favouriteTab) {
        guard let s = Windows.main, let c = s.current else { return }
        s.toggleFavourite(c)
    }
    let pin = item(.pinTab) {
        guard let s = Windows.main, let c = s.current else { return }
        s.togglePinned(c)
    }
    // The titles say what the item will do to *this* tab, the way Arc's do.
    if let t = store?.active {
        favourite.title = t.kind == .favourite ? "Unfavourite Tab" : "Favourite Tab"
        pin.title = t.kind == .pinned ? "Unpin Tab" : "Pin Tab"
    }
    favourite.isEnabled = store?.active != nil
    pin.isEnabled = store?.active != nil
    // Arc walks the sidebar with ⌥⌘↑/↓ and holds ⌃⇥ for the switcher: the MRU row in
    // TabSwitcher.swift, which every further ⌃⇥ steps through until ⌃ comes up.
    let navigation = [
        item(.previousTab) { Windows.current?.cycle(-1) },
        item(.nextTab) { Windows.current?.cycle(1) },
        item(.tabSwitcher) { TabSwitching.shared.step(1) },
        item(.tabSwitcherBackwards) { TabSwitching.shared.step(-1) },
    ]
    // Split View. Arc keeps these in the Tabs menu, and their enabled state is what says
    // whether there is a split to act on at all. `Windows.main` throughout, never
    // `Windows.current`: a Little Arc has no sidebar and no strip to hold a split, and ⌃⇧=
    // over one used to split the popup rather than the window behind it — which is also the
    // window whose state greyed these items out.
    let addSplit = item(.addSplit) { Windows.main?.addSplit() }
    addSplit.isEnabled = store?.active != nil
    let removeSplit = item(.removeSplit) { Windows.main?.removeSplitPane() }
    let nextPane = item(.nextPane) { Windows.main?.focusNextPane() }
    let separate = item("Separate All Tabs", "", []) {
        guard let s = Windows.main, let split = s.activeSplit else { return }
        s.separateSplit(split)
    }
    for entry in [removeSplit, nextPane, separate] {
        entry.isEnabled = store?.activeSplit != nil
    }
    let split = [addSplit, removeSplit, nextPane, separate]
    return [favourite, pin, .separator(), tidy, undo, clear, .separator()]
        + split + [.separator()] + navigation
}

// MARK: - File

/// ⌘O. A local file opens in a tab of its own; `loadFileURL` is the only load a WKWebView
/// will accept for a file url, and it needs the read access spelled out.
@MainActor private func openFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Open a file in a new tab"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let store = Windows.current ?? Windows.open()
    store.newBlankTab().web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
}

/// ⇧⌘S. ponytail: one format — a web archive, the same single file Safari's Save As
/// defaults to, written by WebKit itself. A "Page Source"/"PDF" picker is three more code
/// paths for a menu item nobody visits twice.
@MainActor private func savePageAs() {
    guard let tab = Windows.current?.active, let url = tab.currentURL else { return }
    let panel = NSSavePanel()
    let base = TidyTitles.title(for: tab)
    panel.nameFieldStringValue = (base.isEmpty ? (url.host ?? "Page") : base) + ".webarchive"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    tab.web.createWebArchiveData { result in
        guard case .success(let data) = result else { return }
        try? data.write(to: destination)
    }
}

/// File ▸ Share. ponytail: the system picker anchored to the window, not a submenu built
/// from `NSSharingService.sharingServices(forItems:)` — that call is deprecated, and the
/// picker is the one macOS keeps up to date with whatever the user has enabled.
@MainActor private func sharePage() {
    guard let url = Windows.current?.active?.currentURL,
          let view = NSApp.keyWindow?.contentView else { return }
    let picker = NSSharingServicePicker(items: [url])
    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
}

// MARK: - Archive

/// Arc's Archive menu opens the Library at a section. Vane's Library is one popover on the
/// sidebar's footer, so both rows land in the same place — and the sidebar has to be
/// showing for the popover to have anything to hang off.
@MainActor private func showLibrary() {
    guard let store = Windows.main else { return }
    store.sidebarShown = true
    store.libraryOpen = true
}

/// ⇧⌘C. Arc's, and the one browser shortcut everybody misses when it is missing.
@MainActor private func copyPageURL() {
    guard let u = Windows.current?.active?.currentURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(u.absoluteString, forType: .string)
    axAnnounce("Link copied.")
    Toasts.show("Copied URL")
}

/// ⇧⌘K, and the sidebar's `Clear`: today's tabs go to the archive, not to the bin.
/// Archiving every tab would leave the window with nothing showing, which is exactly what
/// Arc does — the sidebar stays, the page area goes bare and the search bar is a keystroke
/// away. Favourites and pinned tabs are untouched.
@MainActor private func clearTabs() {
    guard let s = Windows.main else { return }
    let doomed = s.tabs.filter { $0.kind == .today }
    guard !doomed.isEmpty else { return }
    doomed.forEach { s.archive($0.id) }
    axAnnounce("Archived \(doomed.count) tab\(doomed.count == 1 ? "" : "s").")
}

@MainActor private func spaceItems() -> [NSMenuItem] {
    // The Space menu is the browser window's, whatever is in front: a Little Arc is in no
    // Space and cannot switch into one.
    let store = Windows.main
    let spaces = store?.spaces ?? []
    // Arc's order: New Space, Manage Spaces…, the two arrows, then the Spaces themselves
    // wearing ⌃1…⌃9 — the shortcut sits on the row it switches to, not on a hidden twin.
    let switchers = spaces.enumerated().map { n, space in
        let entry = item(space.name, "") { Windows.main?.switchTo(space: space); rebuild() }
        entry.state = store?.currentSpaceID == space.id ? .on : .off
        if let command = Command(rawValue: "goToSpace\(n + 1)") {
            let binding = Keybindings.binding(for: command)
            entry.keyEquivalent = binding.menuKeyEquivalent
            entry.keyEquivalentModifierMask = binding.menuModifierMask
            Keybindings.actions[command] = { Windows.main?.switchTo(spaceNumber: n + 1); rebuild() }
        }
        return entry
    }
    let nav = [
        item(.previousSpace) { Windows.main?.cycleSpace(-1); rebuild() },
        item(.nextSpace) { Windows.main?.cycleSpace(1); rebuild() },
    ]
    for entry in nav { entry.isEnabled = spaces.count > 1 }
    return [
        item(.newSpace) {
            // Arc's New Space appears first and is named in place — see `NewSpaceButton`.
            _ = Windows.main?.newSpace()
            rebuild()
        },
        item("Manage Spaces…", "") { SettingsWindow.show() },
        .separator(),
    ] + nav + [.separator()] + switchers + [
        .separator(),
        // Arc has no Profiles menu: a profile is a property of a Space, so this is where
        // the switcher lives.
        menu("Profiles", profileItems()),
    ]
}

/// Arc's Window ▸ Show All Little Arc Windows: they all come to the front together, or they
/// all get out of the way together. The title says which of the two it will do, so "Show"
/// never hides — `toggleAll` rebuilds the menu, because its own title is what just changed.
/// The windows themselves are in the list below it, because AppKit files every titled window
/// into this menu on its own.
/// ponytail: not greyed out with none open. NSMenu auto-enables any item whose target
/// answers its action, so greying this would take a `validateMenuItem:` on Menu.swift's
/// closure holder — for a row that already does nothing when there is nothing to show.
@MainActor private func littleArcWindows() -> NSMenuItem {
    let verb = LittleArc.allShowing ? "Hide" : "Show"
    return item("\(verb) All Little Arc Windows", "") { LittleArc.toggleAll() }
}

/// Menus carry live state (checkmarks, the bookmarks and history lists), so they are
/// rebuilt rather than mutated in place.
@MainActor func rebuild() { NSApp.mainMenu = buildMenu() }

@MainActor func buildMenu() -> NSMenu {
    let root = NSMenu()
    let makeDefaultApp = item(.makeDefaultBrowser) { URLHandling.makeDefaultBrowser() }
    makeDefaultApp.isEnabled = !URLHandling.isDefaultBrowser
    root.addItem(menu("Vane", [
        NSMenuItem(title: "About Vane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
        .separator(),
        item(.settings) { SettingsWindow.show() },
        .separator(),
        // Arc keeps both of these in the app menu; Vane had them filed under Passwords and
        // Sites, where nobody looking for them would think to open.
        item(.importHistoryAndBookmarks) { BrowserImport.chooseAndImport() },
        makeDefaultApp,
        .separator(),
        menu("Passwords", passwordItems()),
        menu("Sites", siteItems()),
        .separator(),
        NSMenuItem(title: "Hide Vane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
        standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                 [.command, .option]),
        standard("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        NSMenuItem(title: "Quit Vane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
    ]))
    root.addItem(menu("File", [
        item(.newTab) { Windows.current?.newTab(nil) },
        item(.newWindow) { Windows.open() },
        item(.newPrivateWindow) { Windows.open(isPrivate: true) },
        .separator(),
        item(.openLocation) { Windows.current?.openPalette(.address) },
        item(.openFile) { openFile() },
        .separator(),
        // Arc's ⌘W: a Today tab is archived rather than destroyed, and a favourite or a
        // pinned tab just loses its page and stays in the sidebar.
        item(.closeTab) { Windows.current?.closeOrArchive() },
        responderItem(.closeWindow, #selector(NSWindow.performClose(_:))) {
            NSApp.keyWindow?.performClose(nil)
        },
        .separator(),
        item(.savePageAs) { savePageAs() },
        responderItem(.printPage, #selector(NSView.printView(_:))) {
            NSApp.sendAction(#selector(NSView.printView(_:)), to: nil, from: nil)
        },
        item(.sharePage) { sharePage() },
    ]))
    root.addItem(menu("Edit", [
        NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z"),
        NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z"),
        .separator(),
        NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
        NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
        standard("Paste and Match Style", NSSelectorFromString("pasteAsPlainText:"), "v",
                 [.command, .option, .shift]),
        standard("Delete", #selector(NSText.delete(_:)), "", []),
        NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        .separator(),
        menu("Find", [
            item(.find) { Windows.current?.findOpen = true },
            // Not `finderItem`: Vane's find bar is WebKit's search, not an NSTextFinder,
            // so these run the bar's own next/previous — which is also what the ⌘G the
            // event monitor sees runs. See Find.advance.
            item(.findNext) { Find.advance(forward: true) },
            item(.findPrevious) { Find.advance(forward: false) },
            standard("Use Selection for Find", #selector(NSResponder.performTextFinderAction(_:)), "e")
                .tagged(NSTextFinder.Action.setSearchString.rawValue),
        ]),
        menu("Spelling and Grammar", [
            standard("Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), ":"),
            standard("Check Document Now", NSSelectorFromString("checkSpelling:"), ";"),
            .separator(),
            standard("Check Spelling While Typing", NSSelectorFromString("toggleContinuousSpellChecking:")),
            standard("Check Grammar With Spelling", NSSelectorFromString("toggleGrammarChecking:")),
            standard("Correct Spelling Automatically", NSSelectorFromString("toggleAutomaticSpellingCorrection:")),
        ]),
        menu("Substitutions", [
            standard("Show Substitutions", NSSelectorFromString("orderFrontSubstitutionsPanel:")),
            .separator(),
            standard("Smart Copy/Paste", NSSelectorFromString("toggleSmartInsertDelete:")),
            standard("Smart Quotes", NSSelectorFromString("toggleAutomaticQuoteSubstitution:")),
            standard("Smart Dashes", NSSelectorFromString("toggleAutomaticDashSubstitution:")),
            standard("Smart Links", NSSelectorFromString("toggleAutomaticLinkDetection:")),
            standard("Data Detectors", NSSelectorFromString("toggleAutomaticDataDetection:")),
            standard("Text Replacement", NSSelectorFromString("toggleAutomaticTextReplacement:")),
        ]),
        menu("Transformations", [
            standard("Make Upper Case", NSSelectorFromString("uppercaseWord:")),
            standard("Make Lower Case", NSSelectorFromString("lowercaseWord:")),
            standard("Capitalize", NSSelectorFromString("capitalizeWord:")),
        ]),
        menu("Speech", [
            standard("Start Speaking", NSSelectorFromString("startSpeaking:")),
            standard("Stop Speaking", NSSelectorFromString("stopSpeaking:")),
        ]),
        .separator(),
        standard("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)),
                 " ", [.command, .control]),
        standard("Start Dictation…", NSSelectorFromString("startDictation:")),
    ]))
    root.addItem(menu("View", [
        item(.reload) { Windows.current?.active?.reload() },
        item(.hardReload) { Windows.current?.active?.hardReload() },
        item(.toggleSidebar) { Windows.current?.sidebarShown.toggle() },
        item(.copyPageURL) { copyPageURL() },
        .separator(),
        item(.actualSize) { Windows.current?.active.map(Zoom.reset) },
        item(.zoomIn) { Windows.current?.active.map(Zoom.zoomIn) },
        item(.zoomOut) { Windows.current?.active.map(Zoom.zoomOut) },
        .separator(),
        item(.fullScreen) { NSApp.keyWindow?.toggleFullScreen(nil) },
        .separator(),
        item(.showReader) { Windows.current?.active.map(Reader.toggle) },
        item(.pictureInPicture) { PictureInPicture.toggle(Windows.current?.active) },
        item(.muteTab) { Windows.current?.active.map(TabAudio.toggleMute) },
        item(.biggerReaderText) { Reader.adjustFontSize(1, in: Windows.current?.active) },
        item(.smallerReaderText) { Reader.adjustFontSize(-1, in: Windows.current?.active) },
        readerTypefaceItem(),
        .separator(),
        // Arc files its developer tools under View; a top-level Develop menu is Safari's.
        menu("Developer", developItems()),
    ]))
    root.addItem(menu("Spaces", spaceItems()))
    root.addItem(menu("Tabs", tidyItems()))
    // Arc's Archive menu, in Arc's order — the recent-pages list it replaces now lives in
    // the History window, where it can be searched instead of being the last 25 rows of a
    // menu nobody can scroll.
    root.addItem(menu("Archive", [
        item(.back) { Windows.current?.active?.back() },
        item(.forward) { Windows.current?.active?.forward() },
        .separator(),
        item(.viewArchive) { showLibrary() },
        item(.viewHistory) { HistoryWindow.show() },
        item(.showDownloads) { showLibrary() },
        .separator(),
        item(.reopenClosedTab) {
            if let u = ClosedTabs.pop() { (Windows.main ?? Windows.open()).newTab(u) }
        },
        .separator(),
        item("Export History (JSON)…", "") { Export.chooseAndExport(.historyJSON) },
        item("Export History (CSV)…", "") { Export.chooseAndExport(.historyCSV) },
        .separator(),
        item(.clearArchive) {
            guard let store = Windows.main else { return }
            let archive = Archive.shared(for: store.profileID)
            let a = NSAlert()
            a.messageText = "Clear the archive?"
            a.informativeText = "\(archive.entries.count) archived tab"
                + (archive.entries.count == 1 ? "" : "s")
                + " will be forgotten. The pages stay in your history."
            a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            if a.runModal() == .alertFirstButtonReturn { archive.clear() }
        },
        item(.clearHistory) {
            let a = NSAlert()
            a.messageText = "Clear all browsing history?"
            a.informativeText = "Bookmarks and saved passwords are not affected."
            a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { Store.shared.clearHistory() }
        },
        .separator(),
        // Arc has no Bookmarks menu; what Vane imports from other browsers lives here.
        menu("Bookmarks", [

            item(.bookmarkPage) { Windows.current?.active?.toggleBookmark(); rebuild() },
            item("Export Bookmarks…", "") { Export.chooseAndExport(.bookmarks) },
            .separator(),
        ] + Store.shared.bookmarks(limit: 40).map { b in
            item(b.title.isEmpty ? b.url : b.title, "") {
                if let u = URL(string: b.url) { Windows.current?.active?.web.load(URLRequest(url: u)) }
            }
        }),
    ]))
    root.addItem(menu("Extensions", [
        item(.installExtension) { ExtensionHost.shared.chooseAndInstall(); rebuild() },
        .separator(),
    ] + ExtensionHost.shared.installed.map { ctx in
        item("Remove " + (ctx.webExtension.displayName ?? "Extension"), "") {
            ExtensionHost.shared.remove(ctx); rebuild()
        }
    }))
    // Standard, and standard is the point: ⌘M was dead until this menu existed, and the
    // window list is AppKit's to fill in once it knows which menu is the Window menu.
    let window = menu("Window", [
        responderItem(.minimizeWindow, #selector(NSWindow.performMiniaturize(_:))) {
            NSApp.keyWindow?.performMiniaturize(nil)
        },
        standard("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item(.showLibrary) { showLibrary() },
        .separator(),
        littleArcWindows(),
        standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
    ])
    root.addItem(window)
    NSApp.windowsMenu = window.submenu
    // AppKit files a window into this menu as it is ordered front — and the menu is thrown
    // away and rebuilt every time a checkmark moves, taking the list with it. Saying it
    // again about every window is what keeps the list there; `changeWindowsItem` adds or
    // updates, so repeating it cannot double anything up.
    for w in NSApp.windows where !w.isExcludedFromWindowsMenu && !w.title.isEmpty {
        NSApp.changeWindowsItem(w, title: w.title, filename: false)
    }
    let help = menu("Help", [
        item(.vaneHelp) {
            if let u = URL(string: "https://github.com/notnaki/vane") { NSWorkspace.shared.open(u) }
        },
        item(.keyboardShortcutsHelp) { SettingsWindow.show(tab: "shortcuts") },
    ])
    root.addItem(help)
    NSApp.helpMenu = help.submenu
    return root
}
