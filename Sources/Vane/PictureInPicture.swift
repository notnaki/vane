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
      // Whether the inline that is about to happen is one *we* asked for. The PiP window's
      // ⤢ leaves picture-in-picture still playing, which is the user asking for the tab
      // back; this is how that is told apart from our own auto-exit.
      var ours = false;
      // The mode before this one. Leaving *fullscreen* lands in the same listener as
      // leaving picture-in-picture, still playing, and only the latter is a ⤢.
      var last = 'inline';
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
        var mine = ours;
        ours = false;
        var from = last;
        last = mode;
        // Left picture-in-picture by any route — the PiP window's own close button, the
        // page's controls, going fullscreen — so our claim on it is over. Without this a
        // detach the *user* started next would be read as ours and yanked back inline.
        if (mode !== 'picture-in-picture') { autoed = false; }
        webkit.messageHandlers.vanepip.postMessage(mode);
        // The PiP window has two buttons and the page cannot see either. WebCore tells them
        // apart for us: -pipActionStop: (×) pauses the element and *then* exits, while
        // -pipShouldClose: (⤢) exits still playing. So an inline nobody here asked for, with
        // the video still running, is the user hitting ⤢ — "put this back and take me to it".
        // × lands here paused and says nothing extra: the video is home, and no tab switches.
        if (mode === 'inline' && from === 'picture-in-picture' && !mine && !e.target.paused) {
          webkit.messageHandlers.vanepip.postMessage('return');
        }
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
          ours = true;
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
        ours = (next === 'inline');
        v.webkitSetPresentationMode(next);
        autoed = false;
        return next;
      }
      // evaluateJavaScript(in: nil) only ever reaches the main frame, and the video worth
      // detaching is usually in an iframe, so a frame that holds one says so and Swift
      // remembers which frame to aim the toggle at. ponytail: last announcer wins — a tiny
      // ad iframe that loads after the player takes the aim with it. Ceiling: rank the
      // announcements by video size, which needs them to keep arriving as the page changes.
      document.addEventListener('loadedmetadata', function () {
        webkit.messageHandlers.vanepip.postMessage('has-video');
      }, true);
      if (biggest()) { webkit.messageHandlers.vanepip.postMessage('has-video'); }
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
        guard let tab else { return }
        run("window.__vanePiP && window.__vanePiP()", in: tab)
    }

    /// Runs `js` in the frame that announced a video. A frame that has gone without a
    /// main-frame navigation — an ad iframe pulled out of the DOM — answers with an error,
    /// and is forgotten on the spot so the next press reaches the main frame again.
    /// `weak`: a completion handler is no reason to keep a closed tab alive.
    private static func run(_ js: String, in tab: Tab, then: (@MainActor () -> Void)? = nil) {
        tab.web.evaluateJavaScript(js, in: tab.pipFrame, in: world) { [weak tab] result in
            MainActor.assumeIsolated {
                if case .failure = result, let tab, tab.pipFrame != nil { tab.pipFrame = nil }
                then?()
            }
        }
    }

    /// The user hit the PiP window's ⤢: the video is already back in its tab, and the tab is
    /// what they asked for. The window too — a PiP video is very often watched over a
    /// minimised window, which is how it got detached in the first place.
    static func returnToTab(_ tab: Tab) {
        guard let store = TabStore.all.first(where: { $0.everyTab.contains { $0 === tab } })
        else { return }
        store.reveal(tab.id)           // goes to its Space first if the window is stashing it
        guard let window = store.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // The PiP panel is non-activating by design, so Vane is very often not the app in
        // front when ⤢ is clicked — and a key window in a background app is invisible.
        NSApp.activate()
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
        run(autoCommand(enter: true), in: tab) { _ = MediaState.shared.asking.remove(id) }
    }

    /// The tab the user just came back to. Deliberately *not* gated on `autoEnabled`: a
    /// video detached before the preference was turned off still has to come home.
    static func exitIfAuto(_ tab: Tab?) {
        guard let tab, !tab.suspended else { return }
        run(autoCommand(enter: false), in: tab)
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
            // Aiming: `evaluateJavaScript(in: nil)` only ever reaches the main frame, so an
            // embedded player answers 'unsupported' unless the frame holding it says so.
            ("a frame with a video announces itself",
             script.contains("webkit.messageHandlers.vanepip.postMessage('has-video')")),
            ("a video that arrives later announces itself too",
             script.contains("document.addEventListener('loadedmetadata'")),
            ("the announcement is not mistaken for a mode", state(from: "has-video") == nil),
            // The ⤢. Both PiP buttons come back as 'inline'; only "still playing" separates
            // them, and only if our own exits are marked before they happen.
            ("the request for the tab is not mistaken for a mode", state(from: "return") == nil),
            ("only a playing video nobody here sent inline asks for the tab",
             script.contains("if (mode === 'inline' && from === 'picture-in-picture' && !mine && !e.target.paused) {")
                 && script.contains("webkit.messageHandlers.vanepip.postMessage('return')")),
            // Esc out of a playing fullscreen video lands in the same listener as the ⤢.
            ("…and only when it was in picture-in-picture, not fullscreen",
             script.range(of: "var from = last;").map {
                 script[$0.upperBound...].prefix(40).contains("last = mode;")
             } == true),
            ("the auto exit is marked as ours, so it does not read as the ⤢",
             script.range(of: "v.webkitSetPresentationMode('inline');").map {
                 script[..<$0.lowerBound].suffix(40).contains("ours = true;")
             } == true),
            ("⌥⌘P going inline is marked as ours too",
             script.range(of: "v.webkitSetPresentationMode(next);").map {
                 script[..<$0.lowerBound].suffix(40).contains("ours = (next === 'inline');")
             } == true),
            ("the mark is cleared by the mode change it was set for",
             script.range(of: "var mine = ours;").map {
                 script[$0.upperBound...].prefix(20).contains("ours = false;")
             } == true),
        ]
    }
}
