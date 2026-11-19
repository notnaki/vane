import WebKit

/// Pause All Media: the before-a-meeting button. Pause only — `pauseAll` pauses every
/// running element in a frame and presses the page's own pause, and never plays, so
/// pressing it again on something already paused does nothing. It talks to each playing
/// frame where it already is: no tab is selected, no window is raised, and a sleeping tab
/// (no web view) is never woken. Picture in Picture is paused through its page like any
/// other player and stays open. Live calls are left alone: a Meet tab is skipped, and the
/// page script skips any element fed by a `MediaStream`.
///
/// ponytail: Web Audio with no media element cannot be paused from here; the toast counts
/// it as still playing rather than pretending. Add a TabAudio-level pause when someone
/// hits that.
@MainActor enum PauseAllMedia {
    nonisolated static let command = MediaTray.Command.pauseAll
    /// A page's pause handler is page code and may never settle; the toast does not wait on it.
    static let patience: Duration = .seconds(1)

    private final class Run {
        var left: Int
        var paused = Set<UUID>()
        var done = false
        init(_ left: Int) { self.left = left }
    }

    static func run() {
        let media = MediaState.shared
        let calls = Set(Suspension.allTabs.filter(\.inMeetCall).map(\.id))
        let frames = media.playingFrames.filter { $0.frame.webView != nil && !calls.contains($0.tab) }
        let state = Run(frames.count)
        func finish() {
            guard !state.done else { return }
            state.done = true
            Toasts.show(summary(paused: state.paused, still: stillPlaying().subtracting(calls)))
        }
        guard !frames.isEmpty else { finish(); return }
        for (tab, frame) in frames {
            frame.webView?.callAsyncJavaScript("return await \(MediaTray.command(command));", arguments: [:],
                                               in: frame, in: .page) { result in
                switch result {
                case .success(let reply) where ["element", "session"].contains(reply as? String ?? ""):
                    state.paused.insert(tab)
                case .success: break  // 'none': nothing to pause, the frame's report stays
                case .failure: media.drop(frame, of: tab)  // the frame is gone
                }
                state.left -= 1
                if state.left == 0 { finish() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: patience)
            finish()
        }
    }

    /// Recounted after the replies: tabs whose frames still report playing, plus tabs WebKit
    /// says are audible with no reporting frame at all (Web Audio, or a page the script can't see).
    private static func stillPlaying() -> Set<UUID> {
        let media = MediaState.shared
        return Set(media.playingFrames.filter { $0.frame.webView != nil }.map(\.tab))
            .union(TabAudio.playingIDs.filter { media.info(for: $0) == nil })
    }

    nonisolated static func summary(paused: Set<UUID>, still: Set<UUID>) -> String {
        func tabs(_ n: Int) -> String { "\(n) tab\(n == 1 ? "" : "s")" }
        let done = paused.subtracting(still).count
        switch (done, still.count) {
        case (0, 0): return "Nothing is playing"
        case (_, 0): return "Paused \(tabs(done))"
        case (0, let s): return "\(tabs(s)) still playing"
        case (let d, let s): return "Paused \(tabs(d)) · \(tabs(s)) still playing"
        }
    }

    nonisolated static func check() -> [(String, Bool)] {
        let script = MediaTray.script
        let branch: Substring = {
            guard let a = script.range(of: "cmd === 'pauseAll'"),
                  let b = script.range(of: "return did ?", range: a.upperBound..<script.endIndex) else { return "" }
            return script[a.lowerBound..<b.upperBound]
        }()
        let a = UUID(), b = UUID()
        return [
            ("pause all sends pauseAll, never the toggle",
             MediaTray.command(command) == "window.__vaneMedia && window.__vaneMedia('pauseAll')"),
            ("the page's pauseAll exists", !branch.isEmpty),
            ("pauseAll never plays", !branch.contains("play(") && !branch.contains("handlers.play")
                && !branch.contains("'play'")),
            ("pauseAll pauses every running element and the page's pause",
             branch.contains("el.pause()") && branch.contains("handlers.pause(")
                && branch.contains("[videos, audios]")),
            ("pauseAll leaves MediaStream (call) elements alone",
             branch.contains("el.srcObject instanceof MediaStream")),
            ("pause all is a menu action the palette lists", PaletteCommand.registered.contains(.pauseAllMedia)),
            ("nothing paused and nothing audible says so", summary(paused: [], still: []) == "Nothing is playing"),
            ("an audible tab is never 'nothing is playing'", summary(paused: [], still: [a]) == "1 tab still playing"),
            ("a tab still playing is not counted as paused",
             summary(paused: [a, b], still: [b]) == "Paused 1 tab · 1 tab still playing"),
            ("paused tabs are counted", summary(paused: [a, b], still: []) == "Paused 2 tabs"),
        ]
    }
}
