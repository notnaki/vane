import AppKit
import SwiftUI
import WebKit

/// Arc's Mini Audio Player: leave a tab that is playing and a small player docks into the
/// bottom of the sidebar, just above the footer — artwork, a title that scrolls if it does
/// not fit, transport buttons, and a title you can click to go back to what is playing.
/// Return to the tab and it goes away again, because the page's own player is right there.
///
/// The split here is deliberate: `MediaTray` is the *rule* (which tab, if any, the tray is
/// for) and is pure, so `selfcheck --pure` can drive it; `MediaState` is the live state the
/// page reports; `MediaTrayView` only draws. The rule is the part that is easy to get wrong
/// — two tabs playing, a muted tab, a tab closed while it was the one on the tray — and the
/// part a screenshot cannot prove.
enum MediaTray {
    static let messageName = "vanemedia"

    // MARK: - The rule

    /// What the tray needs to know about one tab. A value, not a `Tab`, so the rule can be
    /// driven headless.
    struct Playing: Equatable {
        let id: UUID
        /// Media running in the page — *not* "audible": a muted tab still has a player, and
        /// Arc keeps the tray up for it with the speaker struck through.
        let playing: Bool
        let lastActive: Date
    }

    /// Which tab the tray is for, or nil for no tray.
    ///
    /// `held` is the tabs the user paused *from the tray*: one stays on the tray with a
    /// play button, or the pause button would be a button that deletes itself. A set rather
    /// than one id, because two windows each have a tray and each can be holding its own.
    /// Everything else falls out of one line — the current tab is never on the tray (you are
    /// looking at its player), a tab that stopped or was closed is not in `tabs` as playing
    /// any more, and when several are playing the tray follows the one the user was in most
    /// recently, which is the one they are most likely to want back.
    static func showing(_ tabs: [Playing], current: UUID?, held: Set<UUID> = []) -> UUID? {
        tabs.filter { ($0.playing || held.contains($0.id)) && $0.id != current }
            // Ties broken on the id so two tabs activated in the same millisecond still
            // pick the same one every time this is evaluated.
            .max { ($0.lastActive, $0.id.uuidString) < ($1.lastActive, $1.id.uuidString) }?.id
    }

    // MARK: - What the page says

    /// The page's own idea of what is playing. Everything here is read out of the page and
    /// never written back into it.
    struct Info: Equatable {
        var title = ""
        var artist = ""
        var playing = false
        /// Whether the page registered a `nexttrack` / `previoustrack` media-session
        /// handler. No handler, no button: a skip button that does nothing is a lie.
        var next = false
        var prev = false

        /// What the tray shows. Arc puts the track and the artist on one line.
        var line: String {
            artist.isEmpty ? title : "\(title) — \(artist)"
        }
    }

    /// The longest title or artist the tray will take. A page can put a megabyte in
    /// `mediaSession.metadata` and this is drawn in a 250pt sidebar, so the cap is about not
    /// handing that to text layout, not about the pixels.
    static let maxText = 200

    /// What the tray is allowed to draw. Control characters — newlines, tabs — become
    /// spaces because the tray is one line, and so do the bidi overrides, which could
    /// otherwise paint a title that reads as a different site's.
    static func clean(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(min(raw.count, maxText))
        var lastWasSpace = true                  // also eats leading whitespace
        for u in raw.unicodeScalars {
            let bad = CharacterSet.controlCharacters.contains(u) || u.properties.isBidiControl
            let c = bad || u.properties.isWhitespace ? " " : Character(u)
            if c == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(c)
            if out.count == maxText { break }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Anything that is not a message we sent returns nil and changes nothing.
    static func info(from body: Any) -> Info? {
        guard let d = body as? [String: Any] else { return nil }
        // `playing` is the one field every payload carries; without it this is not ours.
        guard let playing = d["playing"] as? Bool else { return nil }
        return Info(title: clean(d["title"] as? String ?? ""),
                    artist: clean(d["artist"] as? String ?? ""),
                    playing: playing,
                    next: d["next"] as? Bool ?? false,
                    prev: d["prev"] as? Bool ?? false)
    }

    /// The three things the tray can ask the page to do. An enum, so the only strings that
    /// ever reach `evaluateJavaScript` are these three literals — nothing from the page and
    /// nothing from a title is ever evaluated.
    enum Command: String { case playpause, next, prev }

    /// How fast one frame is allowed to talk. A gate on the interval was wrong: a page
    /// legitimately reports three or four times in the same millisecond as it loads — one
    /// per `setActionHandler`, one for the metadata, one for `play` — and dropping those
    /// keeps the *first*, which is the empty one. A bucket passes the burst and still cuts a
    /// page posting in a loop down to `refill` a second.
    struct Bucket {
        static let burst = 12.0
        static let refill = 8.0

        var tokens = Bucket.burst
        var at: Date

        /// True if this message is allowed through.
        mutating func take(_ now: Date) -> Bool {
            tokens = min(Bucket.burst, tokens + max(0, now.timeIntervalSince(at)) * Bucket.refill)
            at = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }
    }

    static func command(_ c: Command) -> String {
        "window.__vaneMedia && window.__vaneMedia('\(c.rawValue)')"
    }

    /// Injected at document **start**, all frames: the wrapper below has to be in place
    /// before the page calls `setActionHandler`, and a page's player is very often in an
    /// iframe. Read-only throughout — it wraps two setters to *notice* what the page does
    /// and always calls the original, so Now Playing and the media keys keep working.
    ///
    /// ponytail: this one runs in the *page's* world, unlike the picture-in-picture script,
    /// which is isolated. It has to: an isolated world gets its own wrapper for a host
    /// object's methods, so a `setActionHandler` patched from there would never see the
    /// page's own call and the skip buttons would never appear. What that costs is that
    /// `__vaneMedia` is visible to the page — hence the non-writable property below, and
    /// hence every field the page sends being capped and scrubbed in Swift before anything
    /// is drawn. Ceiling: WebKit growing a way to observe media-session handlers, which is
    /// the API this is standing in for.
    ///
    /// ponytail: no artwork. `mediaSession.metadata.artwork` is a url that would have to be
    /// fetched, cached and evicted; the tray draws the tab's favicon, which is already in
    /// the cache and already says which site this is. Ceiling: real album art.
    static let script = """
    (function () {
      var handlers = {}, last = null;
      var ms = navigator.mediaSession;
      function post(msg) {
        var key = JSON.stringify(msg);
        if (key === last) { return; }     // one message per real change, not per event
        last = key;
        webkit.messageHandlers.vanemedia.postMessage(msg);
      }
      // The element the tray's play/pause drives: whatever is running, or failing that the
      // first one on the page, which is what a paused player is.
      function media() {
        var list = document.querySelectorAll('video,audio');
        for (var i = 0; i < list.length; i++) {
          if (!list[i].paused && !list[i].ended) { return list[i]; }
        }
        return list.length ? list[0] : null;
      }
      function report() {
        var m = ms && ms.metadata, e = media();
        post({
          title: m && m.title ? String(m.title) : '',
          artist: m && m.artist ? String(m.artist) : '',
          playing: !!(e && !e.paused && !e.ended),
          next: !!handlers.nexttrack,
          prev: !!handlers.previoustrack
        });
      }
      if (ms && ms.setActionHandler) {
        var orig = ms.setActionHandler.bind(ms);
        // Remembered, not intercepted: there is no way to read back a registered handler,
        // and the tray's skip buttons have to press the page's own, not fake a click.
        ms.setActionHandler = function (action, fn) {
          if (fn) { handlers[action] = fn; } else { delete handlers[action]; }
          orig(action, fn);
          report();
        };
      }
      // A track change writes `metadata` and fires no DOM event, so the setter is where the
      // new title is. The page's own setter still runs first.
      var proto = ms && Object.getPrototypeOf(ms);
      var desc = proto && Object.getOwnPropertyDescriptor(proto, 'metadata');
      if (desc && desc.set) {
        Object.defineProperty(ms, 'metadata', {
          configurable: true,
          get: function () { return desc.get.call(this); },
          set: function (v) { desc.set.call(this, v); report(); }
        });
      }
      function drive(cmd) {
        var e = media();
        if (cmd === 'playpause') {
          // The element first: it is the truth, and a page with no play/pause handler
          // registered still has to answer the button.
          if (e) { if (e.paused) { e.play(); } else { e.pause(); } return 'element'; }
          var h = handlers.play || handlers.pause;
          if (h) { h(); return 'session'; }
          return 'none';
        }
        var skip = cmd === 'next' ? handlers.nexttrack : handlers.previoustrack;
        if (skip) { skip(); return 'session'; }
        return 'none';
      }
      // Non-writable and non-enumerable, so a page cannot swap it for its own function and
      // have the tray's buttons call that instead.
      Object.defineProperty(window, '__vaneMedia', { value: drive });
      // Captured at the document, like the audio and PiP listeners, so a player built after
      // load is covered without re-injecting anything.
      ['play', 'pause', 'ended', 'emptied', 'loadedmetadata'].forEach(function (e) {
        document.addEventListener(e, report, true);
      });
    })();
    """
}

// MARK: - Live state

/// What the pages are saying, app-wide. One store rather than one per window: a tab belongs
/// to exactly one window's strip, and the tray in that window is the only thing that reads
/// its row.
@MainActor final class MediaState: ObservableObject {
    static let shared = MediaState()

    /// Which frame of which tab a report came from. The script runs in every frame, so a
    /// page with three ad iframes sends four reports; keeping them apart is what stops an
    /// advert's empty `{playing: false}` wiping the real player's title.
    /// ponytail: the origin stands in for frame identity, because `WKFrameInfo` is not
    /// stably hashable across messages. Two same-origin iframes therefore share a slot,
    /// which costs nothing: they are the same site, and the playing one wins below.
    private struct Source: Hashable {
        let main: Bool
        let origin: String
    }

    /// A page with more frames than this reporting media is not a media page.
    private static let maxSources = 8

    @Published private var reports: [UUID: [Source: MediaTray.Info]] = [:]
    /// The tabs the user paused from the tray. See `MediaTray.showing`.
    @Published var held: Set<UUID> = []
    /// Tabs whose page is mid-answer to auto picture-in-picture. They stay in the window
    /// until they reply — a page whose view has left the hierarchy has already stopped its
    /// video, and would answer `idle`. See `PictureInPicture.enterIfPlaying`.
    @Published var asking: Set<UUID> = []
    private var buckets: [UUID: [Source: MediaTray.Bucket]] = [:]

    private init() {
        // The tray draws a tab it is not observing, so a `@ObservedObject` on the row would
        // never hear this one start or stop. See `TabAudio.observe`.
        TabAudio.observe { [weak self] _ in self?.objectWillChange.send() }
    }

    /// What the tray shows for a tab: the frame that says it is playing, the main frame if
    /// none does, and nothing if the tab has said nothing at all. The advert in the corner
    /// never outranks the player the user started.
    func info(for id: UUID) -> MediaTray.Info? {
        guard let byFrame = reports[id] else { return nil }
        if let playing = byFrame.first(where: { $0.key.main && $0.value.playing })?.value { return playing }
        if let playing = byFrame.first(where: { $0.value.playing })?.value { return playing }
        return byFrame.first(where: { $0.key.main })?.value ?? byFrame.values.first
    }

    /// Does this tab's page have to stay in the window even though it is not on screen?
    /// WebKit stops a media element the moment its web view leaves the view hierarchy.
    func keepsRunning(_ tab: Tab) -> Bool {
        TabAudio.isPlaying(tab) || tab.pictureInPicture || asking.contains(tab.id)
    }

    /// A message from the injected script, from one frame of one tab.
    func handle(_ body: Any, for tab: Tab, from frame: WKFrameInfo) {
        guard let i = MediaTray.info(from: body) else { return }
        let o = frame.securityOrigin
        let source = Source(main: frame.isMainFrame,
                            origin: "\(o.protocol)://\(o.host):\(o.port)")
        let now = Date.now
        var bucket = buckets[tab.id]?[source] ?? MediaTray.Bucket(at: now)
        let allowed = bucket.take(now)
        buckets[tab.id, default: [:]][source] = bucket
        guard allowed else { return }

        var byFrame = reports[tab.id] ?? [:]
        // A frame with nothing playing and nothing to say is not worth a slot.
        if !i.playing && i.title.isEmpty && i.artist.isEmpty {
            byFrame[source] = nil
        } else {
            byFrame[source] = i
        }
        if byFrame.count > MediaState.maxSources,
           let drop = byFrame.first(where: { !$0.key.main && !$0.value.playing })?.key {
            byFrame[drop] = nil
        }
        reports[tab.id] = byFrame.isEmpty ? nil : byFrame
    }

    /// The tab is gone. Without this the maps grow by one entry per tab ever opened.
    func forget(_ id: UUID) {
        reports[id] = nil
        buckets[id] = nil
        held.remove(id)
        asking.remove(id)
    }

    func send(_ c: MediaTray.Command, to tab: Tab) {
        if c == .playpause { held.insert(tab.id) }   // the user is driving this tray now
        tab.web.evaluateJavaScript(MediaTray.command(c))
    }
}

// MARK: - Pages kept running off screen

/// The pages that have to stay in the window even though they are not the one on screen:
/// anything playing, anything detached into picture-in-picture, and anything mid-answer to
/// auto-PiP. WebKit stops a media element the moment its web view leaves the view
/// hierarchy, so "keep the music on while I read something else" is literally this list —
/// and it is what the mini audio player is a player *for*.
///
/// ponytail: bounded by what is actually making noise, so a window of thirty tabs still
/// carries one extra page. They are `isHidden` (see `WebHost`), which is what keeps them out
/// of the key loop, out of the accessibility tree and out of compositing — measured, that
/// does not stop the media, while taking the view out of the *window* does.
struct OffscreenPages: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var media = MediaState.shared

    /// Everything already drawn in the card — the active tab, or every pane of its split.
    private var onScreen: Set<UUID> {
        if let split = store.activeSplit { return Set(split.tabs) }
        return Set([store.current].compactMap { $0 })
    }

    var body: some View {
        let shown = onScreen
        ZStack {
            ForEach(store.tabs.filter { !shown.contains($0.id) && media.keepsRunning($0) }) { tab in
                WebView(web: tab.web, offscreen: true).id(tab.id)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The tray

/// The player itself. Sits in the sidebar's bottom overlay under the toast, and draws
/// nothing at all unless there is a tab to draw.
struct MediaTrayView: View {
    @EnvironmentObject var store: TabStore
    @ObservedObject private var media = MediaState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tab on the tray, resolved through the pure rule above.
    private var tab: Tab? {
        let rows = store.tabs.map {
            MediaTray.Playing(id: $0.id, playing: TabAudio.isPlaying($0), lastActive: $0.lastActive)
        }
        guard let id = MediaTray.showing(rows, current: store.current, held: media.held)
        else { return nil }
        return store.tabs.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            if let tab { player(tab) }
        }
        // Never wider than the rows above it, same as the toast.
        .padding(.horizontal, Look.inset)
        .animation(reduceMotion ? nil : Look.list, value: tab?.id)
        // Going back to the tab ends the tray's claim on it: the page's own player is on
        // screen again, and a stale hold would bring the tray back on the next switch.
        .onChange(of: store.current) { if let id = store.current { media.held.remove(id) } }
        // It slides up from under the footer, which is what clips it.
        .clipped()
    }

    private func player(_ tab: Tab) -> some View {
        let info = media.info(for: tab.id) ?? MediaTray.Info(playing: TabAudio.isPlaying(tab))
        let muted = TabAudio.isMuted(tab)
        let title = info.title.isEmpty ? TidyTitles.title(for: tab) : info.line
        return HStack(spacing: Look.rowSpacing) {
            SiteIcon(icon: tab.favicon, fallback: "waveform", size: Look.rowIcon)
            // The whole title is the way back: Arc's mini player jumps to the tab that is
            // playing, which is the one thing you always want from it.
            Button { store.current = tab.id } label: {
                Marquee(text: title).foregroundStyle(Look.barText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), playing in another tab")
            .accessibilityHint("Go to the tab")

            if muted {
                glyph("speaker.slash.fill", "Unmute") { TabAudio.toggleMute(tab) }
            }
            if info.prev {
                glyph("backward.fill", "Previous") { media.send(.prev, to: tab) }
            }
            glyph(info.playing ? "pause.fill" : "play.fill", info.playing ? "Pause" : "Play") {
                media.send(.playpause, to: tab)
            }
            if info.next {
                glyph("forward.fill", "Next") { media.send(.next, to: tab) }
            }
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.trayHeight)
        .background(Look.barFill, in: RoundedRectangle(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius, Look.barStroke)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .id(tab.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini audio player")
    }

    private func glyph(_ name: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: name)
                .font(Look.trayGlyph)
                .foregroundStyle(Look.barGlyph)
                .frame(width: Look.control, height: Look.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A title too long for the tray scrolls back and forth rather than truncating — Arc's
/// mini player does, and a track name is exactly the string whose *end* matters.
///
/// ponytail: an offset on one `Text`, not two copies chasing each other round a loop, and
/// SwiftUI's own phase animator rather than a `repeatForever` started by hand — a hand-rolled
/// one is re-started on every layout pass that changes the width, and the overlapping
/// animations stack until the title is dragged clean out of the pill. It reverses instead of
/// wrapping, which is what a 250pt strip can read anyway. Ceiling: a seamless loop, which
/// needs the string measured and duplicated.
private struct Marquee: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    var body: some View {
        // The text goes in an *overlay* on a `Color.clear`, not in the layout: a title long
        // enough to be worth scrolling would otherwise report its full width to the HStack
        // and push the transport buttons off the end of the sidebar.
        Color.clear
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { label }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
    }

    @ViewBuilder private var label: some View {
        let title = Text(text)
            .font(Look.rowText)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        if overflow > 0, !reduceMotion {
            title.phaseAnimator([false, true], trigger: text) { view, away in
                view.offset(x: away ? -overflow : 0)
            } animation: { _ in
                .linear(duration: Double(overflow) / Look.marqueeSpeed).delay(Look.marqueePause)
            }
        } else {
            title
        }
    }
}

// MARK: - check

extension MediaTray {
    /// The rule and the payload, proved offline: no window server, no WKWebView, no page.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
        func row(_ id: UUID, _ playing: Bool, _ at: Double) -> Playing {
            Playing(id: id, playing: playing, lastActive: t0.addingTimeInterval(at))
        }

        // MARK: which tab the tray is for
        assert("no tabs, no tray", showing([], current: nil) == nil)
        assert("a silent browser has no tray",
               showing([row(a, false, 0), row(b, false, 1)], current: a) == nil)
        assert("the tab you are looking at never gets a tray: its own player is right there",
               showing([row(a, true, 1)], current: a) == nil)
        assert("leaving a playing tab docks it",
               showing([row(a, true, 1), row(b, false, 2)], current: b) == a)
        assert("two playing tabs: the tray follows the one you were in most recently",
               showing([row(a, true, 1), row(b, true, 5), row(c, false, 9)], current: c) == b)
        assert("the current tab playing does not hide another tab's tray",
               showing([row(a, true, 1), row(b, true, 5)], current: b) == a)
        assert("the tray goes when the audio stops",
               showing([row(a, false, 1), row(b, false, 2)], current: b) == nil)
        assert("the tray goes when the tab is closed", showing([row(b, false, 2)], current: b) == nil)
        assert("going back to the tab takes the tray away",
               showing([row(a, true, 1), row(b, false, 2)], current: a) == nil)
        // The mute state is drawn, not decided: a muted tab is still `playing`, which is
        // the whole reason the rule asks `isPlaying` and not `isAudible`.
        assert("a muted tab keeps its tray", showing([row(a, true, 1)], current: b) == a)
        assert("the same input always picks the same tab",
               showing([row(a, true, 3), row(b, true, 3)], current: c)
                   == showing([row(b, true, 3), row(a, true, 3)], current: c))

        // MARK: paused from the tray
        assert("a tab paused from the tray keeps the tray, or pause would delete its button",
               showing([row(a, false, 1)], current: b, held: [a]) == a)
        assert("a held tab still loses the tray when you go back to it",
               showing([row(a, false, 1)], current: a, held: [a]) == nil)
        assert("a held tab that was closed takes no tray with it",
               showing([row(b, false, 2)], current: b, held: [a]) == nil)
        assert("held and playing are both candidates; the most recent tab still wins",
               showing([row(a, false, 9), row(b, true, 1)], current: c, held: [a]) == a
                   && showing([row(a, false, 1), row(b, true, 9)], current: c, held: [a]) == b)
        assert("two windows can each hold their own tab",
               showing([row(a, false, 9), row(b, false, 1)], current: c, held: [a, b]) == a)

        // MARK: the page's payload
        let full: [String: Any] = ["title": "Sonata", "artist": "Glenn Gould",
                                   "playing": true, "next": true, "prev": false]
        assert("a full payload parses", info(from: full)
            == Info(title: "Sonata", artist: "Glenn Gould", playing: true, next: true, prev: false))
        assert("title and artist are shown on one line",
               info(from: full)?.line == "Sonata — Glenn Gould")
        assert("a track with no artist is just the track",
               Info(title: "Sonata", playing: true).line == "Sonata")
        assert("a page with no metadata still reports whether it is playing",
               info(from: ["playing": true])
                   == Info(title: "", artist: "", playing: true, next: false, prev: false))
        assert("no skip handlers means no skip buttons",
               info(from: ["playing": true])?.next == false)
        assert("a non-dictionary payload is ignored", info(from: "playing") == nil)
        assert("a payload with no playing flag is ignored",
               info(from: ["title": "Sonata"]) == nil)
        assert("a payload whose playing flag is not a boolean is ignored",
               info(from: ["playing": "yes"]) == nil)
        assert("an empty payload is ignored", info(from: [String: Any]()) == nil)

        // MARK: what a page is allowed to put on the tray
        assert("a title is capped, so a megabyte of it never reaches text layout",
               info(from: ["playing": true, "title": String(repeating: "a", count: 10_000)])?
                   .title.count == maxText)
        assert("newlines and tabs collapse: the tray is one line",
               clean("Nocturne\n\tin\r\nE-flat") == "Nocturne in E-flat")
        assert("control characters do not survive", clean("Son\u{0}ata") == "Son ata")
        assert("a bidi override cannot paint a title as another site's",
               clean("evil\u{202E}moc.knab") == "evil moc.knab")
        assert("surrounding whitespace is trimmed", clean("   Sonata   ") == "Sonata")
        assert("an all-control title comes out empty, not as spaces", clean("\u{0}\u{1}\n") == "")
        assert("ordinary text is left exactly alone", clean("Sonata — Glenn Gould") == "Sonata — Glenn Gould")
        assert("the artist is scrubbed too, not just the title",
               info(from: ["playing": true, "artist": "Glenn\nGould"])?.artist == "Glenn Gould")

        // MARK: how fast a page is allowed to talk
        let t = Date(timeIntervalSince1970: 0)
        var bucket = Bucket(at: t)
        assert("a page's first report is always taken", bucket.take(t))
        assert("a load's burst of reports all get through",
               (0..<Int(Bucket.burst) - 1).allSatisfy { _ in bucket.take(t) })
        assert("a page posting in a loop is cut off", !bucket.take(t))
        assert("and is let back in at the refill rate",
               bucket.take(t.addingTimeInterval(1 / Bucket.refill + 0.001)))
        var idle = Bucket(at: t)
        _ = idle.take(t)
        assert("an hour of silence does not bank more than one burst", {
            let later = t.addingTimeInterval(3600)
            return (0..<Int(Bucket.burst)).allSatisfy { _ in idle.take(later) } && !idle.take(later)
        }())
        assert("a clock that goes backwards does not refill the bucket", {
            var b = Bucket(at: t)
            for _ in 0..<Int(Bucket.burst) { _ = b.take(t) }
            return !b.take(t.addingTimeInterval(-100))
        }())

        // MARK: the commands, which are the only strings that reach the page
        assert("play/pause presses the page's player",
               command(.playpause) == "window.__vaneMedia && window.__vaneMedia('playpause')")
        assert("every command is a fixed literal, never a page string",
               Command.allCases.allSatisfy { command($0).hasSuffix("('\($0.rawValue)')") })

        // MARK: the script says what it claims to
        assert("the script posts to the handler the app registers",
               script.contains("webkit.messageHandlers.\(messageName).postMessage"))
        assert("the script remembers the page's media-session handlers rather than faking them",
               script.contains("handlers[action] = fn") && script.contains("orig(action, fn)"))
        assert("wrapping setActionHandler still calls the page's own, so the media keys work",
               script.contains("var orig = ms.setActionHandler.bind(ms)"))
        assert("a track change is noticed through the metadata setter",
               script.contains("desc.set.call(this, v)"))
        assert("the metadata wrapper reads, never writes",
               script.contains("get: function () { return desc.get.call(this); }"))
        assert("the script covers both media elements", script.contains("'video,audio'"))
        assert("the listeners are capturing, so late players are caught",
               script.contains("document.addEventListener(e, report, true)"))
        assert("skip only fires a handler the page actually registered",
               script.contains("if (skip) { skip(); return 'session'; }"))
        assert("the bridge is exposed under one name, and cannot be overwritten",
               script.contains("Object.defineProperty(window, '__vaneMedia', { value: drive })"))
        return out
    }
}

extension MediaTray.Command: CaseIterable {}
