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

/// Arc's hold-to-quit, as a value: press, repeat, release, timeout, and what each of them
/// should do. Pure, so `selfcheck --pure` can drive the whole sequence without a keyboard —
/// which is the only way to prove that letting go really does cancel.
struct QuitHold {
    /// What the caller does with the press.
    enum Step: Equatable {
        /// Terminate now.
        case quit
        /// Put the toast up and start the clock.
        case warn
        /// Already warned and still inside the hold: swallow it.
        case wait
    }

    /// When the key went down, nil once it has come up again.
    private(set) var since: Date?
    /// When the toast went up. A second ⌘Q while it is still showing is a deliberate second
    /// press rather than a slip, and Arc quits on it — nobody who has just been told to hold
    /// ⌘Q and presses it again means "not yet".
    private(set) var warnedAt: Date?

    /// ⌘Q went down. `repeated` is `NSEvent.isARepeat` — holding the key re-fires the menu
    /// item, and those repeats are the same hold, not a new one.
    mutating func press(_ now: Date, repeated: Bool, warn: Bool,
                        hold: TimeInterval, window: TimeInterval) -> Step {
        guard warn else { return .quit }
        if repeated {
            guard let since, now.timeIntervalSince(since) >= hold else { return .wait }
            return .quit
        }
        if let warnedAt, now.timeIntervalSince(warnedAt) < window { return .quit }
        since = now
        warnedAt = now
        return .warn
    }

    /// The key, or the ⌘ under it, came up. The toast stays — it is what tells the user how
    /// to quit — but the hold is over and its clock means nothing any more.
    mutating func release() { since = nil }

    /// The hold's clock came round: quit only if the key never came up.
    func expired(_ now: Date, hold: TimeInterval) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= hold
    }

    static func check() -> [(String, Bool)] {
        let t0 = Date(timeIntervalSince1970: 0)
        let hold: TimeInterval = 1, window: TimeInterval = 3
        func press(_ h: inout QuitHold, _ at: TimeInterval, repeated: Bool = false,
                   warn: Bool = true) -> Step {
            h.press(t0 + at, repeated: repeated, warn: warn, hold: hold, window: window)
        }
        var out: [(String, Bool)] = []

        var off = QuitHold()
        out.append(("with the warning off, ⌘Q quits at once",
                    press(&off, 0, warn: false) == .quit))

        var held = QuitHold()
        out.append(("the first ⌘Q warns instead of quitting", press(&held, 0) == .warn))
        out.append(("a key repeat inside the hold is the same hold, not a second press",
                    press(&held, 0.5, repeated: true) == .wait))
        out.append(("the clock has not run out yet", !held.expired(t0 + 0.5, hold: hold)))
        out.append(("held past the hold, the clock says quit", held.expired(t0 + 1, hold: hold)))
        out.append(("…and so does the next repeat",
                    press(&held, 1.2, repeated: true) == .quit))

        var letGo = QuitHold()
        _ = press(&letGo, 0)
        letGo.release()
        out.append(("letting go before the hold is up cancels the quit",
                    !letGo.expired(t0 + 5, hold: hold)))
        out.append(("a stray repeat after the key came up quits nothing",
                    press(&letGo, 5, repeated: true) == .wait))
        out.append(("a second ⌘Q while the toast is still up quits", press(&letGo, 1) == .quit))

        var again = QuitHold()
        _ = press(&again, 0)
        again.release()
        out.append(("a press after the toast has gone is a first press again, and warns",
                    press(&again, 4) == .warn))
        return out
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

    // MARK: - Hold ⌘Q to Quit

    private var hold = QuitHold()
    private var clock: Task<Void, Never>?
    private var keys: Any?
    /// The hold has been earned and we are the ones asking to terminate: do not warn about
    /// our own request.
    private var confirmed = false

    /// ⌘Q with `Prefs.warnBeforeQuit` on puts Arc's toast up and quits only if the keys are
    /// held (or pressed again while the toast is showing).
    ///
    /// Only a keystroke is warned about. Choosing File ▸ Quit Vane with the pointer is
    /// already deliberate — there is no slip to catch and nothing to hold — and a logout, a
    /// restart or an installer's terminate is not ours to refuse: all of those quit at once.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !confirmed, Prefs.warnBeforeQuit,
              let event = app.currentEvent, event.type == .keyDown else { return .terminateNow }
        switch hold.press(.now, repeated: event.isARepeat, warn: true,
                          hold: Look.quitHold, window: Look.toastDuration) {
        case .quit: return .terminateNow
        case .wait: return .terminateCancel
        case .warn:
            // ⌘Q is one of the chords `Keybindings.reserved` refuses to hand out, so it is
            // spelled through the same formatter rather than typed twice.
            Toasts.show("Hold \(Keybinding("q", .command).display) to Quit")
            arm()
            return .terminateCancel
        }
    }

    /// The clock and the way out of it. Key repeat can be switched off system-wide, so the
    /// timer is what actually quits; the repeats only make it land at the same moment when
    /// they are on. Both the key coming up and the ⌘ being let go cancel, because either can
    /// arrive first and the other may never arrive at all.
    private func arm() {
        clock?.cancel()
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Look.quitHold))
            guard let self, !Task.isCancelled, hold.expired(.now, hold: Look.quitHold) else { return }
            confirmed = true
            letGo()
            NSApp.terminate(nil)
        }
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] e in
            if e.type == .keyUp || !e.modifierFlags.contains(.command) { self?.letGo() }
            return e
        }
    }

    private func letGo() {
        hold.release()
        clock?.cancel()
        clock = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
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
