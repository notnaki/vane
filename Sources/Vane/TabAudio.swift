import AppKit
import WebKit

/// Which tab is making noise, and how to shut it up.
///
/// Detection is `-[WKWebView _isPlayingAudio]`, which is SPI but is *exactly* the question:
/// measured on macOS 26 it is true only while a media element is playing, unmuted and at a
/// volume above zero, and drops to false the moment any one of those stops being true. The
/// public alternative, `requestMediaPlaybackState()`, answers a different question — it
/// still says `.playing` for a video the user muted in the page's own controls, which would
/// put a speaker on a silent tab. It is also poll-only, and this has to drive a tab strip.
/// The property notifies through KVO on the key `_isPlayingAudio`, so the strip updates on
/// the frame the sound starts.
///
/// ponytail: SPI, respondsToSelector-guarded per web view exactly like `_inspector` in
/// Develop.swift and `_close` in Engine.swift. If Apple drops it the JS fallback below
/// takes over and reports the same three facts from the page, one message per change.
/// Ceiling: WebKit's flag covers audio from Web Audio and from frames we never see, which
/// the JS path cannot; losing the SPI is a real downgrade, not a free swap.
///
/// Muting is `-[WKWebView _setPageMuted:]`. `setAllMediaPlaybackSuspended(_:)` is public but
/// it *pauses*, and pausing a video the user is watching in another window is a different
/// and worse feature. Page mute sits under the DOM: it never touches `element.muted`, so a
/// player that writes its own `muted` flag every tick cannot fight it, it covers elements
/// added later for free, and — measured — it survives a navigation inside the same tab, so
/// "mute this tab" outlives the ad break. The JS fallback has to work for all three of
/// those by hand, which is why it is the fallback.
@MainActor enum TabAudio {
    static let messageName = "vaneaudio"

    /// `_WKMediaMutedState`'s audio bit. Capture and screen-capture have their own bits and
    /// are none of our business — muting a tab must not revoke its microphone.
    private static let audioMutedBit: UInt = 1 << 0

    private static let playingSel = Selector(("_isPlayingAudio"))
    private static let setPageMutedSel = Selector(("_setPageMuted:"))
    /// KVO fires on the getter's name, not on the property's (`_playingAudio`). Observing
    /// the property name compiles, installs, and never fires — verified the hard way.
    private static let playingKey = "_isPlayingAudio"

    // MARK: - The page's side

    /// Injected at document end, all frames — an embedded player lives in an iframe, same as
    /// with picture-in-picture. Reports the three raw facts about the loudest element that
    /// is running; the *decision* is made in Swift, where `check()` can drive it.
    static let script = """
    (function () {
      var muted = false, last = null, pending = false;
      function all() { return document.querySelectorAll('video,audio'); }
      // The element the user would actually hear, if any. A page with a silent looping
      // background video and one real player must report the player.
      function loudest() {
        var list = all(), best = null;
        for (var i = 0; i < list.length; i++) {
          var m = list[i];
          if (m.paused || m.ended) { continue; }
          var heard = m.muted ? 0 : m.volume;
          if (!best || heard > best.heard) {
            best = { playing: true, muted: !!m.muted, volume: m.volume, heard: heard };
          }
        }
        return best || { playing: false, muted: false, volume: 0, heard: 0 };
      }
      function report() {
        var s = loudest(), key = s.playing + '/' + s.muted + '/' + s.volume;
        if (key === last) { return; }      // one message per real change, not per event
        last = key;
        webkit.messageHandlers.vaneaudio.postMessage(
          { playing: s.playing, muted: s.muted, volume: s.volume });
      }
      // Captured at the document, like the PiP listener, so a player built after load is
      // covered without re-injecting anything.
      ['play', 'pause', 'ended', 'emptied', 'volumechange'].forEach(function (e) {
        document.addEventListener(e, report, true);
      });
      window.__vaneMute = function (on) {
        muted = !!on;
        var list = all();
        for (var i = 0; i < list.length; i++) { list[i].muted = muted; }
        report();
        return muted;
      };
      // An SPA that swaps its player mid-session, or an ad break that inserts a fresh
      // <video>, has to inherit the mute — otherwise "mute this tab" lasts until the next
      // one. ponytail: coalesced to 4Hz, because this fires on every DOM write on a busy
      // page and querySelectorAll is not free. Ceiling: a player inserted and started
      // inside that window is audible for up to 250ms before it inherits the mute —
      // measured, and the reason page mute is the primary and this is the fallback.
      new MutationObserver(function () {
        if (pending) { return; }
        pending = true;
        setTimeout(function () {
          pending = false;
          if (muted) { window.__vaneMute(true); }
          report();
        }, 250);
      }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    /// The JS fallback's payload. Audible means all three: running, not muted, and turned up.
    /// Anything that is not a message we sent returns nil and changes nothing.
    static func audible(from body: Any) -> Bool? {
        guard let d = body as? [String: Any], let playing = d["playing"] as? Bool else { return nil }
        // A page that reports `playing` and nothing else is taken at its word on the rest:
        // an element with no volume set is at 1 and unmuted.
        let muted = d["muted"] as? Bool ?? false
        let volume = d["volume"] as? Double ?? 1
        return playing && !muted && volume > 0
    }

    // MARK: - Per-tab state

    /// Mute is keyed by tab id, not stored on the web view, for two reasons: a suspended tab
    /// gets a brand new WKWebView on resume, and `check()` has to be able to prove the map's
    /// behaviour without a browser in the room.
    private static var mutedIDs: Set<UUID> = []
    /// The last thing the page or WebKit said about this tab. Only consulted when the SPI is
    /// missing — otherwise the flag is read live.
    private static var audibleIDs: Set<UUID> = []
    private static var sinks: [UUID: (Bool) -> Void] = [:]
    private static var watches: [UUID: Watch] = [:]

    private struct Watch {
        let watcher: Watcher
        weak var web: WKWebView?
    }

    /// KVO for a private key needs `observeValue`, and `Tab` cannot grow an override for it
    /// without every other observer in Engine.swift going through the same door. One object
    /// per tab, holding nothing but the id.
    private final class Watcher: NSObject {
        let id: UUID
        init(id: UUID) { self.id = id }
        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            // WebKit posts this from the main thread, same as every other KVO in this app.
            // The id is copied out first so the closure captures a UUID, not `self`.
            let which = id
            MainActor.assumeIsolated { TabAudio.changed(which) }
        }
    }

    /// True when the observable SPI is there at all. For a menu that wants to disable itself
    /// rather than quietly do nothing — same shape as `Inspector.available`.
    static var available: Bool { WKWebView().responds(to: playingSel) }

    // MARK: - Detection

    private static func playingAudio(_ web: WKWebView?) -> Bool? {
        guard let web, web.responds(to: playingSel) else { return nil }
        return web.value(forKey: playingKey) as? Bool
    }

    /// Is this tab making noise right now. Muted wins outright: `_isPlayingAudio` deliberately
    /// ignores page mute — measured, it stays true under `_setPageMuted:` — because WebKit is
    /// answering "is media running", and we are answering "can the user hear it".
    static func isAudible(_ tab: Tab) -> Bool { audible(id: tab.id, web: tab.web) }

    private static func audible(id: UUID, web: WKWebView?) -> Bool {
        if mutedIDs.contains(id) { return false }
        return playingAudio(web) ?? audibleIDs.contains(id)
    }

    /// Start reporting this tab's audibility. `onChange` is what the tab strip binds to;
    /// call it again after a resume and it re-points at the new web view.
    static func watch(_ tab: Tab, onChange: @escaping (Bool) -> Void) {
        unwatch(tab)
        sinks[tab.id] = onChange
        guard tab.web.responds(to: playingSel) else { return }   // JS messages still arrive
        let w = Watcher(id: tab.id)
        tab.web.addObserver(w, forKeyPath: playingKey, options: [.new], context: nil)
        watches[tab.id] = Watch(watcher: w, web: tab.web)
        onChange(isAudible(tab))
    }

    /// Before the web view is torn down. KVO on a dead observee is a crash, not a leak.
    static func unwatch(_ tab: Tab) {
        guard let w = watches.removeValue(forKey: tab.id) else { return }
        w.web?.removeObserver(w.watcher, forKeyPath: playingKey)
    }

    /// The tab is gone. Without this the maps grow by one entry per tab ever opened.
    static func forget(_ id: UUID) {
        mutedIDs.remove(id)
        audibleIDs.remove(id)
        sinks[id] = nil
        if let w = watches.removeValue(forKey: id) { w.web?.removeObserver(w.watcher, forKeyPath: playingKey) }
    }

    /// A message from the injected script. Malformed bodies change nothing.
    ///
    /// Worth wiring even when the SPI is present: `isAudible` still prefers WebKit's own
    /// flag, so the message costs nothing but a second chance to notice a change WebKit
    /// coalesced away. Note the page's `muted` here is `element.muted` — page mute lives
    /// underneath the DOM and is invisible to the script, which is why `audible(id:web:)`
    /// checks our own map rather than believing either source.
    static func handle(_ body: Any, for tab: Tab) {
        guard let a = audible(from: body) else { return }
        if a { audibleIDs.insert(tab.id) } else { audibleIDs.remove(tab.id) }
        sinks[tab.id]?(isAudible(tab))
    }

    private static func changed(_ id: UUID) {
        let web = watches[id]?.web
        let a = audible(id: id, web: web)
        if a { audibleIDs.insert(id) } else { audibleIDs.remove(id) }
        sinks[id]?(a)
    }

    // MARK: - Muting

    static func isMuted(_ tab: Tab) -> Bool { mutedIDs.contains(tab.id) }
    static func isMuted(_ id: UUID) -> Bool { mutedIDs.contains(id) }

    static func toggleMute(_ tab: Tab) { setMuted(tab, !isMuted(tab)) }

    static func setMuted(_ tab: Tab, _ on: Bool) {
        setMuted(tab.id, on)
        apply(tab)
        sinks[tab.id]?(isAudible(tab))
    }

    /// The map write on its own — no page, no web view, so `check()` can drive it.
    static func setMuted(_ id: UUID, _ on: Bool) {
        if on { mutedIDs.insert(id) } else { mutedIDs.remove(id) }
    }

    /// Push the tab's mute state into its page. Page mute survives navigation on its own, so
    /// this exists for the two moments it cannot: the fallback path, and a resumed tab, whose
    /// WKWebView is a different object that has never been told anything.
    static func reapply(_ tab: Tab) {
        guard isMuted(tab) else { return }      // a freshly loaded page starts unmuted anyway
        apply(tab)
    }

    private static func apply(_ tab: Tab) {
        let on = isMuted(tab)
        if setPageMuted(tab.web, on) { return }
        tab.web.evaluateJavaScript(muteCommand(for: tab.id))
    }

    /// What the fallback sends the page. Pure, so the navigation assertion in `check()` is
    /// about the thing that actually ships.
    static func muteCommand(for id: UUID) -> String {
        "window.__vaneMute && window.__vaneMute(\(isMuted(id)))"
    }

    /// `perform(_:with:)` cannot be used here: the argument is an `NSUInteger` bitfield and
    /// Swift would bridge an Int into an NSNumber and hand WebKit the pointer. Casting the
    /// IMP is the only way to pass a scalar. Returns false when the SPI is gone, which is the
    /// signal to fall back to JS.
    @discardableResult
    private static func setPageMuted(_ web: WKWebView, _ on: Bool) -> Bool {
        guard web.responds(to: setPageMutedSel),
              let m = class_getInstanceMethod(type(of: web), setPageMutedSel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method_getImplementation(m), to: Fn.self)(web, setPageMutedSel,
                                                               on ? audioMutedBit : 0)
        return true
    }

    // MARK: - Offline check

    /// Pure: a decision on a dictionary, a set keyed by UUID, and string containment on the
    /// injected script. No window server, no WKWebView, no page.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // MARK: the audibility decision
        func body(_ playing: Bool, _ muted: Bool, _ volume: Double) -> [String: Any] {
            ["playing": playing, "muted": muted, "volume": volume]
        }
        assert("a playing, unmuted, turned-up element is audible",
               audible(from: body(true, false, 1)) == true)
        assert("a muted element is not audible, however loud it claims to be",
               audible(from: body(true, true, 1)) == false)
        assert("a zero-volume element is not audible", audible(from: body(true, false, 0)) == false)
        assert("a paused element is not audible", audible(from: body(false, false, 1)) == false)
        assert("a barely-audible element still counts", audible(from: body(true, false, 0.01)) == true)
        assert("a payload with no volume is taken as turned up",
               audible(from: ["playing": true]) == true)

        // MARK: payloads we did not send
        assert("a non-dictionary payload is ignored", audible(from: "playing") == nil)
        assert("a payload with no playing flag is ignored",
               audible(from: ["muted": false, "volume": 1.0]) == nil)
        assert("a payload whose playing flag is not a boolean is ignored",
               audible(from: ["playing": "yes"]) == nil)
        assert("an empty payload is ignored", audible(from: [String: Any]()) == nil)

        // MARK: the per-tab mute map
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        // The real maps, put back exactly as they were found — check() runs inside a live app.
        let hadMuted = mutedIDs
        defer { mutedIDs = hadMuted }
        mutedIDs = []
        assert("a tab starts unmuted", !isMuted(a))
        setMuted(a, true)
        assert("muting a tab takes", isMuted(a))
        assert("muting one tab does not mute another", !isMuted(b))
        setMuted(b, true)
        setMuted(b, false)
        assert("unmuting one tab does not unmute another", isMuted(a) && !isMuted(b))
        forget(b)
        assert("closing a tab leaves the others muted", isMuted(a))
        forget(a)
        assert("closing a muted tab drops it from the map", !isMuted(a))

        // MARK: mute survives a navigation
        setMuted(a, true)
        assert("the mute is keyed by tab, so a navigation cannot clear it",
               isMuted(a) && muteCommand(for: a).contains("true"))
        // What the app pushes into the page that just finished loading.
        assert("a page loaded in a muted tab is told to mute itself",
               muteCommand(for: a) == "window.__vaneMute && window.__vaneMute(true)")
        setMuted(a, false)
        assert("a page loaded in an unmuted tab is told to unmute",
               muteCommand(for: a) == "window.__vaneMute && window.__vaneMute(false)")
        forget(a)

        // MARK: the script says what it claims to
        assert("the script posts to the handler the app registers",
               script.contains("webkit.messageHandlers.\(messageName).postMessage"))
        assert("the script reports all three facts, not a verdict",
               script.contains("playing: s.playing") && script.contains("muted: s.muted")
               && script.contains("volume: s.volume"))
        assert("the script covers both media elements", script.contains("'video,audio'"))
        assert("the listeners are capturing, so late players are caught",
               script.contains("document.addEventListener(e, report, true)"))
        assert("the script listens for the events that change audibility",
               ["'play'", "'pause'", "'ended'", "'volumechange'"].allSatisfy(script.contains))
        assert("the fallback mute helper is exposed to the page",
               script.contains("window.__vaneMute = function"))
        assert("the fallback mute is re-applied to elements added later",
               script.contains("MutationObserver") && script.contains("if (muted) { window.__vaneMute(true); }"))

        return out
    }
}
