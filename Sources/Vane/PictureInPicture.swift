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
        ]
    }
}
