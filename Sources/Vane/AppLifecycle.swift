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

    /// Whether a terminate request has to be refused before it is examined at all.
    ///
    /// The card is answered by `runModal`, so a second request arrives *inside* the first:
    /// AppKit still routes ⌘Q to `terminate:` during a modal session, and so do the Dock's
    /// Quit and a script. Every other way out of `applicationShouldTerminate` ends in
    /// `.terminateNow` — the Apple Event one quits behind the card, and a ⌘Q AppKit no
    /// longer calls fresh does too — and asking again nests a second modal loop on the very
    /// window the first one owns. While the question is up the only answer is the user's.
    nonisolated static func refuses(whileAsking: Bool) -> Bool { whileAsking }

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
            ("a second ⌘Q — or the Dock's Quit — while the card is up is cancelled before "
             + "anything else is asked, rather than quitting behind it or nesting a second "
             + "card inside the first", refuses(whileAsking: true)),
            ("with no card up a terminate is examined as usual", !refuses(whileAsking: false)),
        ]
    }
}

/// Arrival order matters when Finder and external links arrive during recovery.
/// Keep ingress closed until main explicitly finishes migrations and initial restore.
@MainActor final class BootstrapIngressGate {
    private(set) var ready = true
    private var pending: [@MainActor () -> Void] = []
    func block() { ready = false }
    func submit(_ action: @escaping @MainActor () -> Void) {
        if ready { action() } else { pending.append(action) }
    }
    func complete() {
        ready = true
        let actions = pending; pending.removeAll()
        for action in actions { action() }
    }
}

/// What the Dock icon does.
///
/// Vane had no `NSApplicationDelegate` at all — `main.swift` is a bare bootstrap — so with
/// every window closed the app was still running and there was no way back into it: clicking
/// the Dock icon did nothing, and the Dock's own menu offered Quit and nothing else. ⌘N was
/// the only route, and only if a window happened to have focus to receive it.
///
/// A small delegate for application events. Everything else
/// `NSApplicationDelegate` can do is already done in `main.swift`, and moving it here would
/// be a refactor rather than a fix.
@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static let shared = AppLifecycle()

    func applicationWillTerminate(_ notification: Notification) { Blocker.closePrivateRules() }

    private final class MinimizedWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var minimized: [MinimizedWindow] = []

    private let openURLs: @MainActor ([URL]) -> Void
    private let reopenAction: (@MainActor (NSApplication) -> Void)?
    private let openWindow: @MainActor (Bool) -> Void
    private let terminationReply: @MainActor (NSApplication, Bool) -> Void
    init(openURLs: @escaping @MainActor ([URL]) -> Void = { URLHandling.open($0) },
         reopenAction: (@MainActor (NSApplication) -> Void)? = nil,
         openWindow: @escaping @MainActor (Bool) -> Void = { Windows.open(isPrivate: $0) },
         terminationReply: @escaping @MainActor (NSApplication, Bool) -> Void = {
        $0.reply(toApplicationShouldTerminate: $1)
    }) {
        self.openURLs = openURLs; self.reopenAction = reopenAction; self.openWindow = openWindow
        self.terminationReply = terminationReply
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didMiniaturize(_:)),
                           name: NSWindow.didMiniaturizeNotification, object: nil)
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(forgetMinimized(_:)), name: name, object: nil)
        }
    }

    @objc private func didMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        forgetMinimized(notification)
        minimized.append(MinimizedWindow(window))
    }

    @objc private func forgetMinimized(_ notification: Notification) {
        let window = notification.object as? NSWindow
        minimized.removeAll { $0.window == nil || $0.window === window }
    }

    /// AppKit's `flag` includes windows in the Dock. Check the actual windows instead;
    /// floating panels (such as PiP) do not count, matching AppKit's reopen behavior.
    /// The offscreen link-preview renderer is excluded from the Window menu and must
    /// not count as an open user window either.
    /// False back means "handled", so AppKit does not raise a second window.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !bootstrapIngress.ready {
            afterBootstrap { [self] in reopen(in: app) }
            return false
        }
        guard !app.windows.contains(where: {
            !($0 is NSPanel) && !$0.isExcludedFromWindowsMenu && $0.isVisible && !$0.isMiniaturized
        })
        else { return true }
        reopen(in: app)
        return false
    }

    /// Restore the last minimized window, including private, Little Vane and utility
    /// windows. With none minimized, keep the existing browser/session/new-window ladder.
    private func reopen(in app: NSApplication) {
        if let reopenAction { reopenAction(app); return }
        let lastMinimized = minimized.reversed().compactMap(\.window).first { $0.isMiniaturized }
            ?? app.windows.last { !($0 is NSPanel) && $0.isMiniaturized }
        if let last = lastMinimized {
            last.deminiaturize(nil)
            last.makeKeyAndOrderFront(nil)
            return
        }
        if let last = Windows.main?.window {
            // A window in the Dock has to be taken out of it: `makeKeyAndOrderFront` on a
            // miniaturised window orders the Dock tile, not the window.
            if last.isMiniaturized { last.deminiaturize(nil) }
            last.makeKeyAndOrderFront(nil)
            return
        }
        if Session.restore() { return }
        Windows.open()
    }

    /// External Apple Events and Dock commands may arrive while bundle/library
    /// recovery awaits. They must not open a Store or profile before bootstrap finishes.
    func afterBootstrap(_ action: @escaping @MainActor () -> Void) { bootstrapIngress.submit(action) }

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
        afterBootstrap { [self] in openURLs(urls) }
    }

    // MARK: - Quit Vane?

    /// The dialog has been answered and we are the ones asking to terminate: do not ask again.
    private var confirmed = false
    private var askingAboutUnsavedProfiles = false
    private var terminating = false
    private var waitingForBootstrap = false
    /// main.swift installs its asynchronous recovery/bootstrap task before NSApp.run.
    private let bootstrapIngress = BootstrapIngressGate()
    var bootstrapTask: Task<Void, Never>? {
        didSet { if bootstrapTask != nil { bootstrapIngress.block() } }
    }
    func completeBootstrap() {
        bootstrapTask = nil
        if !persistenceExitInProgress { bootstrapIngress.complete() }
    }
    private(set) var persistenceExitInProgress = false
    private var exitEventMonitor: Any?
    private var exitProgress: NSPanel?

    /// Quiesce new user intent while accepted writes and recovery handoff finish.
    /// External ingress remains FIFO queued and is released if the handoff is cancelled.
    @discardableResult
    func beginPersistenceExit() -> Bool {
        guard !persistenceExitInProgress else { return false }
        persistenceExitInProgress = true
        Store.setAdmissionPaused(true)
        bootstrapIngress.block()
        exitEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .pressure, .magnify, .rotate, .swipe
        ]) { _ in nil }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 88),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Vane"
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 28, width: 24, height: 24))
        spinner.style = .spinning; spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Saving changes…")
        label.frame = NSRect(x: 64, y: 28, width: 200, height: 24)
        panel.contentView?.addSubview(spinner); panel.contentView?.addSubview(label)
        panel.center(); panel.orderFront(nil)
        exitProgress = panel
        return true
    }
    private func allowPersistenceExitDialog() {
        exitProgress?.orderOut(nil); exitProgress = nil
        if let monitor = exitEventMonitor { NSEvent.removeMonitor(monitor); exitEventMonitor = nil }
    }
    func endPersistenceExit() {
        allowPersistenceExitDialog()
        persistenceExitInProgress = false
        Store.setAdmissionPaused(false)
        if bootstrapTask == nil { bootstrapIngress.complete() }
    }


    /// ⌘Q with `Prefs.warnBeforeQuit` on and an open user window puts up Arc's "Quit Vane?"
    /// and quits only on its answer. Only a real, fresh ⌘Q is asked about, and the chord is
    /// checked exactly:
    /// a logout sends ⇧⌘Q to the login window and then a quit Apple Event to us, a Dock Quit
    /// or a script arrives as that same event, and any of them arriving while `currentEvent`
    /// still names an old ⌘Q (AppKit swallows the keyUp under ⌘) would otherwise inherit the
    /// question — refusing any of those is how an app becomes the one that cancelled
    /// somebody's logout, or the Dock's Quit that "does nothing". File ▸ Quit Vane with the
    /// pointer is deliberate too, and quits at once.
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        if let bootstrapTask {
            guard !waitingForBootstrap else { return .terminateCancel }
            waitingForBootstrap = true
            Task { [self] in
                await bootstrapTask.value
                completeBootstrap()
                waitingForBootstrap = false
                let decision = applicationShouldTerminate(app)
                if decision != .terminateLater { terminationReply(app, decision == .terminateNow) }
            }
            return .terminateLater
        }
        guard !terminating, !persistenceExitInProgress else { return .terminateCancel }
        // Before every other route out of here, all of which end in a terminate.
        if QuitAsk.refuses(whileAsking: QuitDialog.isUp) { return .terminateCancel }
        guard !askingAboutUnsavedProfiles else { return .terminateCancel }
        var discarded = false
        let savedOrDiscarded = ProfileManager.shared.prepareToQuit {
            askingAboutUnsavedProfiles = true
            defer { askingAboutUnsavedProfiles = false }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Profile changes haven’t been saved"
            alert.informativeText = "Keep Vane open to retry saving. Quitting now will lose the unsaved profile changes."
            alert.addButton(withTitle: "Keep Vane Open")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.buttons.last?.hasDestructiveAction = true
            discarded = alert.runModal() == .alertSecondButtonReturn
            return discarded
        }
        guard savedOrDiscarded else { return .terminateCancel }
        if discarded { return finishTermination(in: app, discarding: true) }
        if let ae = NSAppleEventManager.shared().currentAppleEvent,
           QuitAsk.isQuitAppleEvent(class: ae.eventClass, id: ae.eventID) { return finishTermination(in: app) }
        // Closed windows can linger in AppKit, and the offscreen preview renderer stays
        // visible. Neither needs a warning; minimized user windows still do.
        guard !confirmed, Prefs.warnBeforeQuit,
              app.windows.contains(where: {
                  !$0.isExcludedFromWindowsMenu && ($0.isVisible || $0.isMiniaturized)
              }), let event = app.currentEvent,
              QuitAsk.isQuitChord(type: event.type, characters: event.charactersIgnoringModifiers,
                                  flags: event.modifierFlags),
              QuitAsk.isFresh(event.timestamp, now: ProcessInfo.processInfo.systemUptime)
        else { return finishTermination(in: app) }
        switch QuitDialog.ask(over: app.keyWindow) {
        case .cancel: return .terminateCancel
        case .quitForever: Prefs.warnBeforeQuit = false; fallthrough
        case .quit: confirmed = true; return finishTermination(in: app)
        }
    }

    /// AppKit keeps the event loop alive while ordered workers finish. All accepted
    /// writes are included before acknowledging quit; failed persistence keeps the
    /// existing explicit keep-open / discard choice and dirty recovery marker.
    private func finishTermination(in app: NSApplication, discarding: Bool = false) -> NSApplication.TerminateReply {
        guard beginPersistenceExit() else { return .terminateCancel }
        terminating = true
        Crash.stopAutosave()
        Task { [self] in
            var succeeded = true
            await ImportOperations.drain()
            await PendingSessionTransactions.drain()
            await ProfileManager.shared.waitForTransactions()
            await Library.waitForMoves()
            do { try await EaselStore.drainAllPendingWrites(directory: Store.directory) } catch { succeeded = false }
            do { try await Store.flushAllPendingWrites() } catch { succeeded = false }
            do { try await EaselStore.flushAll(directory: Store.directory) } catch { succeeded = false }
            do { try await Passwords.flushPendingOperations() } catch { succeeded = false }
            if !(await AppIcon.flushPersistence()) { succeeded = false }
            await Updater.markHealthyLaunchAsync()
            if succeeded && !discarding {
                if !(await Crash.markCleanAsync()) { succeeded = false }
            } else {
                // Even explicit discard waits for accepted workers so process exit cannot
                // interrupt a generation or bundle replacement halfway through publication.
                if !Session.enqueueSave() { succeeded = false }
                if !(await Session.flushPersistence()) { succeeded = false }
            }
            // Late navigation completions can enqueue Store work while workers are
            // awaited. Drain again, and inspect/reply in the same MainActor turn.
            for _ in 0..<3 where Store.hasUnflushedWrites {
                do { try await Store.flushAllPendingWrites() } catch { succeeded = false; break }
            }
            if Store.hasUnflushedWrites || ImportOperations.hasPendingOperations || Passwords.hasPendingOperations { succeeded = false }
            if !succeeded { _ = await Crash.markDirtyAsync() }
            if !succeeded && !discarding {
                allowPersistenceExitDialog()
                askingAboutUnsavedProfiles = true
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Changes couldn’t be saved"
                alert.informativeText = "Keep Vane open to retry saving. Quitting now may lose unsaved changes."
                alert.addButton(withTitle: "Keep Vane Open")
                alert.addButton(withTitle: "Quit Without Saving")
                alert.buttons.last?.hasDestructiveAction = true
                let discard = alert.runModal() == .alertSecondButtonReturn
                askingAboutUnsavedProfiles = false
                if !discard {
                    terminating = false; confirmed = false
                    Crash.resumeAutosave()
                    endPersistenceExit()
                    terminationReply(app, false)
                    return
                }
            }
            terminationReply(app, true)
        }
        return .terminateLater
    }

    /// Right-clicking the Dock icon. The two things anyone wants from there, and the two the
    /// File menu leads with.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockItem("New Window") { [self] in afterBootstrap { self.openWindow(false) } })
        menu.addItem(dockItem("New Private Window") { [self] in afterBootstrap { self.openWindow(true) } })
        return menu
    }

    /// ponytail: the same closure-in-an-ObjC-target trick `Menu.swift` uses, kept here rather
    /// than shared, because its version is private and two of these are not worth an
    /// exported type.
    private func dockItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = DockAction(run)
        let item = NSMenuItem(title: title, action: #selector(DockAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action // retain the target for this menu's lifetime
        return item
    }
}

@MainActor private final class DockAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() {
        guard !FirstLaunch.isPresenting else { return }
        run()
    }
}
