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
@MainActor enum MediaTray {
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
    /// `held` is the tab the user paused *from the tray*: it stays on the tray with a play
    /// button, or the pause button would be a button that deletes itself. Everything else
    /// falls out of one line — the current tab is never on the tray (you are looking at its
    /// player), a tab that stopped or was closed is not in `tabs` as playing any more, and
    /// when several are playing the tray follows the one the user was in most recently,
    /// which is the one they are most likely to want back.
    static func showing(_ tabs: [Playing], current: UUID?, held: UUID? = nil) -> UUID? {
        tabs.filter { ($0.playing || $0.id == held) && $0.id != current }
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

    /// Anything that is not a message we sent returns nil and changes nothing.
    static func info(from body: Any) -> Info? {
        guard let d = body as? [String: Any] else { return nil }
        // `playing` is the one field every payload carries; without it this is not ours.
        guard let playing = d["playing"] as? Bool else { return nil }
        return Info(title: d["title"] as? String ?? "",
                    artist: d["artist"] as? String ?? "",
                    playing: playing,
                    next: d["next"] as? Bool ?? false,
                    prev: d["prev"] as? Bool ?? false)
    }

    /// The three things the tray can ask the page to do. An enum, so the only strings that
    /// ever reach `evaluateJavaScript` are these three literals — nothing from the page and
    /// nothing from a title is ever evaluated.
    enum Command: String { case playpause, next, prev }

    static func command(_ c: Command) -> String {
        "window.__vaneMedia && window.__vaneMedia('\(c.rawValue)')"
    }

    /// Injected at document **start**, all frames: the wrapper below has to be in place
    /// before the page calls `setActionHandler`, and a page's player is very often in an
    /// iframe. Read-only throughout — it wraps two setters to *notice* what the page does
    /// and always calls the original, so Now Playing and the media keys keep working.
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
      window.__vaneMedia = function (cmd) {
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
      };
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

    @Published private(set) var info: [UUID: MediaTray.Info] = [:]
    /// The tab the user paused from the tray. See `MediaTray.showing`.
    @Published var held: UUID?

    private init() {
        // The tray draws a tab it is not observing, so a `@ObservedObject` on the row would
        // never hear this one start or stop. See `TabAudio.onAnyChange`.
        TabAudio.onAnyChange = { [weak self] _ in self?.objectWillChange.send() }
    }

    /// A message from the injected script.
    func handle(_ body: Any, for tab: Tab) {
        guard let i = MediaTray.info(from: body) else { return }
        info[tab.id] = i
    }

    /// The tab is gone. Without this the map grows by one entry per tab ever opened.
    func forget(_ id: UUID) {
        info[id] = nil
        if held == id { held = nil }
    }

    func send(_ c: MediaTray.Command, to tab: Tab) {
        if c == .playpause { held = tab.id }     // the user is driving this tray now
        tab.web.evaluateJavaScript(MediaTray.command(c))
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
        .onChange(of: store.current) { if media.held == store.current { media.held = nil } }
        // It slides up from under the footer, which is what clips it.
        .clipped()
    }

    private func player(_ tab: Tab) -> some View {
        let info = media.info[tab.id] ?? MediaTray.Info(playing: TabAudio.isPlaying(tab))
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
/// ponytail: an offset on one `Text`, not two copies chasing each other round a loop. It
/// reverses instead of wrapping, which is what a 200pt strip can read anyway. Ceiling: a
/// seamless loop, which needs the string measured and duplicated.
private struct Marquee: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var shifted = false

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }

    var body: some View {
        Text(text)
            .font(Look.rowText)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .offset(x: shifted ? -overflow : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .onChange(of: text) { restart() }
            .onChange(of: overflow) { restart() }
            .onAppear { restart() }
    }

    private func restart() {
        shifted = false
        guard overflow > 0, !reduceMotion else { return }
        withAnimation(.linear(duration: Double(overflow) / Look.marqueeSpeed)
            .delay(Look.marqueePause).repeatForever(autoreverses: true)) { shifted = true }
    }
}

// MARK: - check

extension MediaTray {
    /// The rule and the payload, proved offline: no window server, no WKWebView, no page.
    static func check() -> [(String, Bool)] {
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
               showing([row(a, false, 1)], current: b, held: a) == a)
        assert("a held tab still loses the tray when you go back to it",
               showing([row(a, false, 1)], current: a, held: a) == nil)
        assert("a held tab that was closed takes no tray with it",
               showing([row(b, false, 2)], current: b, held: a) == nil)
        assert("held and playing are both candidates; the most recent tab still wins",
               showing([row(a, false, 9), row(b, true, 1)], current: c, held: a) == a
                   && showing([row(a, false, 1), row(b, true, 9)], current: c, held: a) == b)

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
        assert("the bridge is exposed under one name", script.contains("window.__vaneMedia = function"))
        return out
    }
}

extension MediaTray.Command: CaseIterable {}
