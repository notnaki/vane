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
        if (e.target && e.target.webkitPresentationMode) {
          webkit.messageHandlers.vanepip.postMessage(e.target.webkitPresentationMode);
        }
      }, true);
      // Auto picture-in-picture: called on the way out of a tab and on the way back in.
      // Everything it refuses to do is a named reason, so a page that will not detach can
      // be asked why from the inspector rather than guessed at.
      window.__vanePiPAuto = function (enter, minW, minH) {
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
      };
      window.__vanePiP = function () {
        var v = biggest();
        if (!v || !v.webkitSetPresentationMode) { return 'unsupported'; }
        var next = v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
        v.webkitSetPresentationMode(next);
        return next;
      };
    })();
    """

    static func toggle(_ tab: Tab?) {
        tab?.web.evaluateJavaScript("window.__vanePiP && window.__vanePiP()")
    }

    // MARK: - Auto picture-in-picture

    /// Smaller than this on screen and it is a thumbnail, a hero loop or an ad, not what the
    /// user was watching — detaching those would fill the corner of the screen with junk
    /// every time a tab was switched. Arc's rule is the same one, by eye.
    static let minAutoSize = CGSize(width: 200, height: 120)

    /// Leaving a tab that is playing a video pops it out; coming back puts it inline again.
    /// On by default, the way Arc ships it, and off is a real preference, so it persists.
    static var autoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoPiP") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPiP") }
    }

    /// Pure, so `check()` can prove the thresholds actually reach the page.
    static func autoCommand(enter: Bool) -> String {
        "window.__vanePiPAuto && window.__vanePiPAuto("
            + "\(enter), \(Int(minAutoSize.width)), \(Int(minAutoSize.height)))"
    }

    /// The tab the user just left. A suspended tab has no page and nothing playing.
    static func enterIfPlaying(_ tab: Tab?) {
        guard autoEnabled, let tab, !tab.suspended else { return }
        tab.web.evaluateJavaScript(autoCommand(enter: true))
    }

    /// The tab the user just came back to. Deliberately *not* gated on `autoEnabled`: a
    /// video detached before the preference was turned off still has to come home.
    static func exitIfAuto(_ tab: Tab?) {
        guard let tab, !tab.suspended else { return }
        tab.web.evaluateJavaScript(autoCommand(enter: false))
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
            ("the toggle helper is exposed to the page", script.contains("window.__vanePiP")),
            ("the listener is capturing, so late players are caught", script.contains(", true)")),
            // Auto-PiP. The decision is made in the page, where the video is, so what is
            // provable here is that the page is asked the right question.
            ("leaving a tab asks the page to detach", autoCommand(enter: true).contains("(true,")),
            ("coming back asks it to go inline", autoCommand(enter: false).contains("(false,")),
            ("the size floor reaches the page", autoCommand(enter: true).hasSuffix("(true, 200, 120)")),
            ("a thumbnail is below the floor", minAutoSize.width >= 200 && minAutoSize.height >= 120),
            ("the auto helper is exposed to the page", script.contains("window.__vanePiPAuto = function")),
            ("a paused video is not detached", script.contains("if (v.paused || v.ended) { return 'idle'; }")),
            ("an audio-only stream is never detached", script.contains("if (!v.videoWidth || !v.videoHeight)")),
            ("a video too small to be watched is left alone", script.contains("return 'small';")),
            ("a picture-in-picture the user opened is never taken away", script.contains("if (autoed &&")),
        ]
    }
}
