import AppKit

extension Prefs {
    /// Arc's "Warn before quitting (⌘Q)", on and the same way round. ⌘Q sits next to ⌘W and
    /// a browser is where a slip costs the most; the warning is what a tab-full window is
    /// worth. Stored rather than defaulted so "off" is a real answer that survives a relaunch.
    static var warnBeforeQuit: Bool {
        get { UserDefaults.vane.object(forKey: "warnBeforeQuit") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "warnBeforeQuit") }
    }
}
/// Arc's "Quit Arc?" — the question a stray ⌘Q gets, as pure decisions: which terminate is
/// a keystroke worth asking about, and which is a Dock Quit, a logout or a script that must
/// never be held up. `selfcheck --pure` drives every row without a keyboard.
enum QuitAsk {
    /// Exactly ⌘Q, and nothing else. ⇧⌘Q is the system's log-out chord and arrives here
    /// through the quit Apple Event it sends us; a terminate that carries any other keystroke
    /// (or none) is not the user's ⌘Q either. Pure: the two fields of the event that matter.
    nonisolated static func isQuitChord(type: NSEvent.EventType, characters: String?,
                                        flags: NSEvent.ModifierFlags) -> Bool {
        // Only the four modifiers a chord is made of: caps lock, the numeric-pad bit and the
        // fn bit ride along on ordinary keystrokes and say nothing about what was pressed.
        let chord: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        return type == .keyDown && characters?.lowercased() == "q"
            && flags.intersection(chord) == .command
    }

    /// The Dock's Quit, a logout and `osascript … quit` all arrive as the core suite's
    /// `quit` Apple Event ('aevt'/'quit'). Pure: the two four-char codes.
    nonisolated static func isQuitAppleEvent(class eventClass: AEEventClass, id: AEEventID) -> Bool {
        eventClass == 0x6165_7674 && id == 0x7175_6974   // 'aevt', 'quit'
    }

    /// A keystroke counts only if it is the one being answered now — not one AppKit still
    /// reports as current because its keyUp never arrived. Both times are system uptime.
    nonisolated static func isFresh(_ eventTime: TimeInterval, now: TimeInterval) -> Bool {
        now - eventTime < 1
    }

    static func check() -> [(String, Bool)] {
        [
            ("⌘Q is the chord that asks",
             isQuitChord(type: .keyDown, characters: "q", flags: [.command])),
            ("a capital Q under ⇧ is not it: ⇧⌘Q is the system's log-out chord",
             !isQuitChord(type: .keyDown, characters: "q", flags: [.command, .shift])),
            ("⌥⌘Q is not it either",
             !isQuitChord(type: .keyDown, characters: "q", flags: [.command, .option])),
            ("a bare Q typed into a page is not a quit",
             !isQuitChord(type: .keyDown, characters: "q", flags: [])),
            ("another key held under ⌘ is not a quit",
             !isQuitChord(type: .keyDown, characters: "w", flags: [.command])),
            ("a terminate carrying no keystroke at all — a logout, a script, an installer — is not",
             !isQuitChord(type: .keyDown, characters: nil, flags: [.command])),
            ("nor one carrying the key *up*, or a click",
             !isQuitChord(type: .keyUp, characters: "q", flags: [.command])
                && !isQuitChord(type: .leftMouseUp, characters: "q", flags: [.command])),
            ("caps lock and the numeric-pad bit do not stop a real ⌘Q being one",
             isQuitChord(type: .keyDown, characters: "q",
                         flags: [.command, .numericPad, .capsLock])),
            ("the Dock's Quit arrives as the 'quit' Apple Event, and quits at once",
             isQuitAppleEvent(class: 0x6165_7674, id: 0x7175_6974)),
            ("an open-documents event is not a quit",
             !isQuitAppleEvent(class: 0x6165_7674, id: 0x6F64_6F63)),
            ("a keystroke from this moment is fresh", isFresh(10.0, now: 10.2)),
            ("a ⌘Q AppKit still calls current a minute later is not", !isFresh(10, now: 70)),
        ]
    }
}

/// What the Dock icon does.
///
/// Vane had no `NSApplicationDelegate` at all — `main.swift` is a bare bootstrap — so with
/// every window closed the app was still running and there was no way back into it: clicking
/// the Dock icon did nothing, and the Dock's own menu offered Quit and nothing else. ⌘N was
/// the only route, and only if a window happened to have focus to receive it.
///
/// ponytail: a delegate that answers two questions and holds no state. Everything else
/// `NSApplicationDelegate` can do is already done in `main.swift`, and moving it here would
/// be a refactor rather than a fix.
@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static let shared = AppLifecycle()

    /// Clicking the Dock icon with no windows open. `flag` is false exactly when there is
    /// nothing on screen, which is the case worth answering.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppLifecycle.reopen() }
        return true
    }

    /// The window the user last had, the session they last had, or a new one — in that order,
    /// which is the same ladder `main.swift` climbs at launch.
    /// `Windows.main`, not the last store: a miniaturised Little Arc is not the window
    /// somebody clicking the Dock icon is asking for, and raising it would leave the session
    /// unrestored for good.
    static func reopen() {
        if let last = Windows.main?.window {
            last.makeKeyAndOrderFront(nil)
            return
        }
        if Session.restore() { return }
        Windows.open()
    }

    /// Finder ▸ Open With ▸ Vane, `open -a Vane report.pdf`, and a file dropped on the Dock
    /// icon. Routed through `URLHandling.open` rather than opened here, so a PDF from Finder
    /// lands wherever a link from Mail would — an Air Traffic Control rule, a Little Arc, or
    /// a tab in the front window, per the Open-links-in preference.
    ///
    /// ponytail: the delegate method, which is what URLHandling.swift's note said to do the
    /// day a delegate existed for other reasons. AppKit installs its own `odoc` handler when
    /// it starts up and calls this; the hand-rolled Apple Event handler that used to answer
    /// it is gone with this.
    func application(_ app: NSApplication, open urls: [URL]) {
        URLHandling.open(urls)
    }

    // MARK: - Quit Vane?

    /// The dialog has been answered and we are the ones asking to terminate: do not ask again.
    private var confirmed = false
    /// The dialog is up. AppKit still routes ⌘Q to `terminate:` during a modal session, and
    /// a second one would nest a second modal loop inside the first; while asking, the
    /// answer is "not yet".
    private var asking = false

    /// ⌘Q with `Prefs.warnBeforeQuit` on puts up Arc's "Quit Vane?" and quits only on its
    /// answer. Only a real, fresh ⌘Q is asked about, and the chord is checked exactly:
    /// a logout sends ⇧⌘Q to the login window and then a quit Apple Event to us, a Dock Quit
    /// or a script arrives as that same event, and any of them arriving while `currentEvent`
    /// still names an old ⌘Q (AppKit swallows the keyUp under ⌘) would otherwise inherit the
    /// question — refusing any of those is how an app becomes the one that cancelled
    /// somebody's logout, or the Dock's Quit that "does nothing". File ▸ Quit Vane with the
    /// pointer is deliberate too, and quits at once.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        if let ae = NSAppleEventManager.shared().currentAppleEvent,
           QuitAsk.isQuitAppleEvent(class: ae.eventClass, id: ae.eventID) { return .terminateNow }
        guard !confirmed, Prefs.warnBeforeQuit, let event = app.currentEvent,
              QuitAsk.isQuitChord(type: event.type, characters: event.charactersIgnoringModifiers,
                                  flags: event.modifierFlags),
              QuitAsk.isFresh(event.timestamp, now: ProcessInfo.processInfo.systemUptime)
        else { return .terminateNow }
        if asking { return .terminateCancel }
        asking = true
        defer { asking = false }
        switch QuitDialog.ask(over: app.keyWindow) {
        case .cancel: return .terminateCancel
        case .quitForever: Prefs.warnBeforeQuit = false; fallthrough
        case .quit: confirmed = true; return .terminateNow
        }
    }

    /// Right-clicking the Dock icon. The two things anyone wants from there, and the two the
    /// File menu leads with.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockItem("New Window") { Windows.open() })
        menu.addItem(dockItem("New Private Window") { Windows.open(isPrivate: true) })
        return menu
    }

    /// ponytail: the same closure-in-an-ObjC-target trick `Menu.swift` uses, kept here rather
    /// than shared, because its version is private and two of these are not worth an
    /// exported type.
    private func dockItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = DockAction(run)
        actions.append(action)          // NSMenuItem does not retain its target
        let item = NSMenuItem(title: title, action: #selector(DockAction.fire), keyEquivalent: "")
        item.target = action
        return item
    }

    private var actions: [DockAction] = []
}

@MainActor private final class DockAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
