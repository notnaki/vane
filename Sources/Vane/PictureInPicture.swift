import AppKit
import WebKit

/// Picture-in-picture. WebKit already puts a PiP button in its own media controls, so this
/// exists for the two things the page's controls cannot do: put it on a menu item and a
/// rebindable key, and let the rest of the app know a tab is playing in a detached window.
///
/// ponytail: driven from JS, because macOS has no API for this — WKWebView's
/// `allowsPictureInPictureMediaPlayback` is `API_AVAILABLE(ios(9_0))` and does not exist
/// here. `webkitSetPresentationMode` is the same non-standard hook Safari's own UI uses.
@MainActor enum PictureInPicture {
    static let messageName = "vanepip"

    /// Injected at document end, all frames: a video worth detaching is very often in an
    /// iframe (every embedded player is), unlike the password form, which must stay
    /// main-frame only.
    static let script = """
    (function () {
      // Whether *we* detached this page's video on the way out of the tab. Kept in the page
      // rather than in Swift because it dies with the video it is about: a navigation takes
      // both away, and coming back to a tab must never yank a PiP window the user opened.
      var autoed = false;
      function biggest() {
        var vs = Array.prototype.slice.call(document.querySelectorAll('video'));
        if (!vs.length) { return null; }
        vs.sort(function (a, b) {
          return b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight;
        });
        return vs[0];
      }
      // Fires on the video element; captured at the document so one listener covers videos
      // added later by the player.
      document.addEventListener('webkitpresentationmodechanged', function (e) {
        var mode = e.target && e.target.webkitPresentationMode;
        if (!mode) { return; }
        // Left picture-in-picture by any route — the PiP window's own close button, the
        // page's controls, going fullscreen — so our claim on it is over. Without this a
        // detach the *user* started next would be read as ours and yanked back inline.
        if (mode !== 'picture-in-picture') { autoed = false; }
        webkit.messageHandlers.vanepip.postMessage(mode);
      }, true);
      // Auto picture-in-picture: called on the way out of a tab and on the way back in.
      // Everything it refuses to do is a named reason, so a page that will not detach can
      // be asked why from the inspector rather than guessed at.
      function auto(enter, minW, minH) {
        var v = biggest();
        if (!v || !v.webkitSetPresentationMode) { return 'unsupported'; }
        if (enter) {
          if (v.paused || v.ended) { return 'idle'; }
          // An <audio> is never a candidate, and neither is a <video> carrying an
          // audio-only stream: videoWidth is 0 until there are actual frames.
          if (!v.videoWidth || !v.videoHeight) { return 'audio'; }
          // A thumbnail, a hero loop or a tracking pixel is not what the user is watching.
          if (v.clientWidth < minW || v.clientHeight < minH) { return 'small'; }
          if (v.webkitPresentationMode !== 'inline') { return 'already'; }
          v.webkitSetPresentationMode('picture-in-picture');
          autoed = true;
          return 'pip';
        }
        if (autoed && v.webkitPresentationMode === 'picture-in-picture') {
          v.webkitSetPresentationMode('inline');
          autoed = false;
          return 'inline';
        }
        return 'kept';
      }
      // ⌥⌘P. Whatever it does, this detach is the user's from here on: coming back to the
      // tab must not undo a picture-in-picture they asked for by hand.
      function toggle() {
        var v = biggest();
        if (!v || !v.webkitSetPresentationMode) { return 'unsupported'; }
        var next = v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
        v.webkitSetPresentationMode(next);
        autoed = false;
        return next;
      }
      // Non-writable and non-enumerable: a page cannot swap either helper for its own
      // function and have us call it. ponytail: the names are still *readable*, so a page
      // that goes looking can tell it is in Vane. Ceiling: no global at all, which needs the
      // handler map somewhere a page cannot reach — see MediaPlayer.swift for why that is
      // not free.
      Object.defineProperty(window, '__vanePiP', { value: toggle });
      Object.defineProperty(window, '__vanePiPAuto', { value: auto });
    })();
    """

    /// The script and its message handler live in their own content world, so `__vanePiP`
    /// is not on the page's `window` at all: a page cannot replace it, and a page's own
    /// `__vanePiP` cannot reach us. The media bridge cannot do this — see MediaPlayer.swift.
    static let world = WKContentWorld.world(name: "vane")

    static func toggle(_ tab: Tab?) {
        tab?.web.evaluateJavaScript("window.__vanePiP && window.__vanePiP()", in: nil,
                                    in: world, completionHandler: nil)
    }

    // MARK: - Auto picture-in-picture

    /// Leaving a tab that is playing a video pops it out; coming back puts it inline again.
    /// On by default, the way Arc ships it, and off is a real preference, so it persists.
    static let prefKey = "autoPiP"

    static var autoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: prefKey) }
    }

    /// Pure, so `check()` can prove the thresholds actually reach the page.
    static func autoCommand(enter: Bool) -> String {
        "window.__vanePiPAuto && window.__vanePiPAuto("
            + "\(enter), \(Int(Look.minAutoPiP.width)), \(Int(Look.minAutoPiP.height)))"
    }

    /// The tab the user just left. A suspended tab has no page and nothing playing.
    ///
    /// The page has to still be in the window when it answers — a video whose view has left
    /// the hierarchy has already stopped — so the tab is marked as being asked, which is
    /// what keeps it mounted (`OffscreenPages`), and unmarked the moment it replies.
    static func enterIfPlaying(_ tab: Tab?) {
        guard autoEnabled, let tab, !tab.suspended else { return }
        let id = tab.id                 // the closure carries a UUID, never the Tab
        MediaState.shared.asking.insert(id)
        tab.web.evaluateJavaScript(autoCommand(enter: true), in: nil, in: world) { _ in
            MainActor.assumeIsolated { _ = MediaState.shared.asking.remove(id) }
        }
    }

    /// The tab the user just came back to. Deliberately *not* gated on `autoEnabled`: a
    /// video detached before the preference was turned off still has to come home.
    static func exitIfAuto(_ tab: Tab?) {
        guard let tab, !tab.suspended else { return }
        tab.web.evaluateJavaScript(autoCommand(enter: false), in: nil, in: world,
                                   completionHandler: nil)
    }

    /// WebKit reports `inline`, `fullscreen` or `picture-in-picture`. Anything else is a
    /// message we did not send.
    static func state(from body: Any) -> Bool? {
        switch body as? String {
        case "picture-in-picture": true
        case "inline", "fullscreen": false
        default: nil
        }
    }

    static func check() -> [(String, Bool)] {
        [
            ("picture-in-picture reads as active", state(from: "picture-in-picture") == true),
            ("inline reads as inactive", state(from: "inline") == false),
            // Fullscreen is not PiP: a tab that went fullscreen and back must not be left
            // marked as detached, which would keep it pinned open against suspension.
            ("fullscreen reads as inactive", state(from: "fullscreen") == false),
            ("an unknown mode is ignored", state(from: "wat") == nil),
            ("a non-string payload is ignored", state(from: 42) == nil),
            ("the toggle helper is exposed, and cannot be overwritten",
             script.contains("Object.defineProperty(window, '__vanePiP', { value: toggle })")),
            ("the listener is capturing, so late players are caught", script.contains(", true)")),
            // Auto-PiP. The decision is made in the page, where the video is, so what is
            // provable here is that the page is asked the right question.
            ("leaving a tab asks the page to detach", autoCommand(enter: true).contains("(true,")),
            ("coming back asks it to go inline", autoCommand(enter: false).contains("(false,")),
            ("the size floor reaches the page", autoCommand(enter: true).hasSuffix("(true, 200, 120)")),
            ("a thumbnail is below the floor",
             Look.minAutoPiP.width >= 200 && Look.minAutoPiP.height >= 120),
            ("the auto helper is exposed, and cannot be overwritten",
             script.contains("Object.defineProperty(window, '__vanePiPAuto', { value: auto })")),
            ("a paused video is not detached", script.contains("if (v.paused || v.ended) { return 'idle'; }")),
            ("an audio-only stream is never detached", script.contains("if (!v.videoWidth || !v.videoHeight)")),
            ("a video too small to be watched is left alone", script.contains("return 'small';")),
            ("a picture-in-picture the user opened is never taken away", script.contains("if (autoed &&")),
            // The other half of that: our claim has to *end*, or a detach the user started
            // after ours would be read as ours.
            ("⌥⌘P hands the detach back to the user",
             script.contains("v.webkitSetPresentationMode(next);") && script.range(
                 of: "v.webkitSetPresentationMode(next);").map {
                     script[$0.upperBound...].prefix(60).contains("autoed = false;")
                 } == true),
            ("leaving picture-in-picture by any route drops our claim",
             script.contains("if (mode !== 'picture-in-picture') { autoed = false; }")),
            ("the preference has one key, shared with Settings", prefKey == "autoPiP"),
        ]
    }
}
