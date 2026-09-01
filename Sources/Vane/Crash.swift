import AppKit

/// Surviving a crash. `Session` only writes on a clean quit and on window close, so a
/// WebKit content-process take-down or a kill takes the whole session with it.
///
/// Two halves, both deliberately dumb:
///  - a marker file that exists while Vane is running. Present at launch ⇒ the last run
///    never got to clean it up ⇒ it crashed.
///  - a timer that re-saves the session periodically, so the file on disk is never more
///    than one interval stale.
///
/// ponytail: a zero-byte file and a Timer. No crash reporter, no signal handlers, no
/// atexit — a signal handler can't safely touch UserDefaults or WebKit anyway, which is
/// the whole reason the marker is written *up front* instead of on the way down.
/// Ceiling: a force-quit or a logout that kills the app looks identical to a crash, so the
/// user gets an unnecessary "reopen tabs?" prompt. Cheap price for never losing a session.
@MainActor enum Crash {

    /// Pointed at a temp directory under `check()`; nil means the real Store directory.
    private static var directory: URL?
    private static var marker: URL {
        (directory ?? Store.directory).appendingPathComponent("running")
    }

    /// 30 seconds. Long enough that it is nothing next to what a browser writes anyway
    /// (a few hundred bytes of urls, once), short enough that the worst case is losing the
    /// last half-minute of tab changes. Crucially it is *time*-based, not navigation-based:
    /// a redirect-heavy site can fire twenty navigations a second and still cost one write.
    static let interval: TimeInterval = 30

    private static var timer: Timer?
    private static var lastSave: Date = .distantPast
    private static var crashed = false

    /// True when the previous run did not shut down cleanly. Fixed at `begin()`, so it
    /// keeps answering the same way for the rest of the launch.
    static var didCrashLastLaunch: Bool { crashed }

    /// The save itself, behind a variable so `check()` can count calls without writing to
    /// the user's real session.json.
    static var write: () -> Void = { Session.save() }

    /// Call before restoring anything — the marker has to be read before it is rewritten.
    static func begin(now: Date = .now) {
        crashed = FileManager.default.fileExists(atPath: marker.path)
        try? Data().write(to: marker)
        lastSave = now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { _ = autosave() }
        }
    }

    /// Normal termination. Save once more, then clear the marker so the next launch knows
    /// this one ended on purpose.
    static func markClean() {
        timer?.invalidate()
        timer = nil
        write()
        try? FileManager.default.removeItem(at: marker)
    }

    /// Throttled: returns false when it was called again too soon. The timer alone would
    /// be enough, but going through here means any other caller (a future "save on tab
    /// close") can't turn the session file into a write amplifier.
    @discardableResult
    static func autosave(now: Date = .now) -> Bool {
        guard now.timeIntervalSince(lastSave) >= interval else { return false }
        lastSave = now
        write()
        return true
    }

    /// Stands in for `Session.restore()` in main.swift. On a clean launch it *is*
    /// `Session.restore()` — the alert only exists on the crash path, so the normal
    /// restore is untouched.
    @discardableResult
    static func offerRestore() -> Bool {
        guard crashed else { return Session.restore() }
        let alert = NSAlert()
        alert.messageText = "Vane quit unexpectedly the last time it was open."
        alert.informativeText = "Reopen the windows and tabs from that session?"
        alert.addButton(withTitle: "Reopen Tabs")   // default: the user's work is the safe choice here
        alert.addButton(withTitle: "Start Fresh")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return Session.restore()
    }

    // MARK: - check

    /// Runs entirely in a temp directory against a counting stand-in for the session save;
    /// the real ~/Library/Application Support/Vane is never read or written.
    static func check() -> [(String, Bool)] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-crashcheck-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let realWrite = write
        var saves = 0
        directory = temp
        write = { saves += 1 }
        defer {
            timer?.invalidate()
            timer = nil
            directory = nil
            write = realWrite
            crashed = false
            lastSave = .distantPast
            try? FileManager.default.removeItem(at: temp)
        }
        func markerExists() -> Bool { FileManager.default.fileExists(atPath: marker.path) }

        var out: [(String, Bool)] = []
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // First launch ever: no marker, so nothing crashed.
        out.append(("a first launch with no marker is not a crash", { begin(now: t0); return !didCrashLastLaunch }()))
        out.append(("launching writes the dirty marker", markerExists()))

        // Clean quit.
        markClean()
        out.append(("a clean shutdown clears the marker", !markerExists()))
        out.append(("a clean shutdown saves the session one last time", saves == 1))

        // Launch after that clean quit.
        begin(now: t0)
        out.append(("the launch after a clean shutdown is not a crash", !didCrashLastLaunch))

        // Crash: the marker is simply never cleared, and the next begin() sees it.
        out.append(("the marker survives a run that never cleans up", markerExists()))
        begin(now: t0)
        out.append(("a launch that finds the marker reports a crash", didCrashLastLaunch))
        out.append(("the crashed launch re-arms the marker for itself", markerExists()))

        // ...and the launch after *that* one, if it quits cleanly, is clean again. This is
        // the sequence that a sticky flag would get wrong.
        markClean()
        begin(now: t0)
        out.append(("a clean launch after a crashed one is not itself a crash", !didCrashLastLaunch))
        markClean()

        // Throttling. begin() stamps lastSave, so the clock starts at the launch.
        saves = 0
        begin(now: t0)
        out.append(("launching does not immediately autosave", saves == 0))
        out.append(("an autosave one second in is throttled away",
                    autosave(now: t0.addingTimeInterval(1)) == false && saves == 0))
        out.append(("an autosave just short of the interval is still throttled",
                    autosave(now: t0.addingTimeInterval(interval - 0.5)) == false && saves == 0))
        out.append(("an autosave at the interval writes",
                    autosave(now: t0.addingTimeInterval(interval)) == true && saves == 1))
        out.append(("a second autosave right after the first is throttled",
                    autosave(now: t0.addingTimeInterval(interval + 1)) == false && saves == 1))
        out.append(("the throttle window restarts from the last write, not from launch",
                    autosave(now: t0.addingTimeInterval(interval * 2)) == true && saves == 2))
        // Fifty navigations in a second must cost nothing.
        let before = saves
        for i in 0..<50 { autosave(now: t0.addingTimeInterval(interval * 2 + Double(i) / 50)) }
        out.append(("fifty calls inside one interval cost one write at most", saves == before))
        markClean()
        out.append(("markClean flushes past the throttle", saves == before + 1))
        return out
    }
}
