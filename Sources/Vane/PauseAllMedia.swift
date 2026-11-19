import WebKit

/// Pause All Media: the before-a-meeting button. Pause only — it sends the tray's `.pause`,
/// never `.playpause`, so pressing it again on something already paused does nothing.
/// It talks to each playing frame where it already is: no tab is selected, no window is
/// raised, and a sleeping tab (no web view) is never woken. Picture in Picture is paused
/// through its page like any other player and stays open.
///
/// ponytail: only frames the media script has reported — Web Audio with no media element,
/// and anything the script cannot see, keeps playing. Add a TabAudio-level fallback when
/// someone hits that.
@MainActor enum PauseAllMedia {
    nonisolated static let command = MediaTray.Command.pause

    static func run() {
        let frames = MediaState.shared.playingFrames.filter { $0.frame.webView != nil }
        guard !frames.isEmpty else { Toasts.show("Nothing is playing"); return }
        var left = frames.count
        var paused = Set<UUID>()
        for (tab, frame) in frames {
            frame.webView?.callAsyncJavaScript("return await \(MediaTray.command(command));", arguments: [:],
                                               in: frame, in: .page) { result in
                if case .success(let reply) = result, ["element", "session"].contains(reply as? String ?? "") {
                    paused.insert(tab)
                }
                left -= 1
                guard left == 0 else { return }
                Toasts.show(paused.isEmpty ? "Couldn’t pause media"
                            : "Paused media in \(paused.count) tab\(paused.count == 1 ? "" : "s")")
            }
        }
    }

    nonisolated static func check() -> [(String, Bool)] {
        // The page's `drive('pause')` picks 'pause' unconditionally; only 'playpause' reads
        // the player's state and can choose 'play'. That is what makes this idempotent.
        [("pause all sends pause, never the toggle", MediaTray.command(command) == "window.__vaneMedia && window.__vaneMedia('pause')"),
         ("the page's pause never resolves to play",
          MediaTray.script.contains("var action = cmd === 'pause' ? 'pause' :")),
         ("pause all is a menu action the palette lists", PaletteCommand.registered.contains(.pauseAllMedia))]
    }
}
