import SwiftUI
import WebKit

/// The url under the pointer, in a small capsule at the bottom-left of the page card — the
/// status bar every browser has and Arc keeps. Ordinary hover waits `Look.statusDelay`;
/// holding an opening modifier shows the destination and action immediately.
enum StatusBar {
    static let messageName = "vanehover"

    /// Posts the hovered link's absolute href, or "" when the pointer leaves a link, leaves
    /// the page, or presses a button (a click is a navigation, and the bar has nothing more
    /// to say about it). Capturing listeners on the document, so a page that stops
    /// propagation on its own anchors still reports them. Idempotent: WebKit re-runs user
    /// scripts on back/forward cache restores.
    struct Hover: Equatable {
        var url: String
        var target: LinkInteraction.Target = .main
    }

    static let script = """
    (function () {
      if (window.__vaneHover) return; window.__vaneHover = true;
      var last = null;
      function frameNamed(root, name) {
        try {
          var frame = root.frames[name];
          if (frame && frame.window === frame) return true;
        } catch (e) {}
        for (var i = 0; i < root.frames.length; i++) {
          if (frameNamed(root.frames[i], name)) return true;
        }
        return false;
      }
      function target(a) {
        var base = document.querySelector('base[target]');
        var name = (a.getAttribute('target') || (base && base.getAttribute('target')) || '_self');
        var lower = name.toLowerCase();
        if (lower === '_blank') return 'newWindow';
        if (lower === '_self' || lower === '_top' || lower === '_parent' || name === window.name)
          return 'main';
        return frameNamed(window, name) ? 'subframe' : 'newWindow';
      }
      function send(a) {
        var body = a ? {url: a.href, target: target(a)} : '';
        var key = JSON.stringify(body);
        if (key === last) return;
        last = key;
        try { webkit.messageHandlers.\(messageName).postMessage(body); } catch (e) {}
      }
      function link(el) {
        return el && el.closest ? el.closest('a[href], area[href]') : null;
      }
      document.addEventListener('mouseover', function (e) {
        var a = link(e.target);
        if (a) send(a);
      }, true);
      document.addEventListener('mouseout', function (e) {
        var a = link(e.target);
        if (!a) return;
        var to = link(e.relatedTarget);
        if (to !== a) send(to);
      }, true);
      // Refresh a dynamically changed href/target while the pointer stays over the link.
      document.addEventListener('keydown', function () {
        send(document.querySelector('a[href]:hover, area[href]:hover'));
      }, true);
      document.addEventListener('mousedown', function () { send(null); }, true);
      window.addEventListener('scroll', function () { send(null); }, true);
      window.addEventListener('pagehide', function () { send(null); });
      window.addEventListener('blur', function () { send(null); });
    })();
    """

    nonisolated static func hover(from body: Any) -> Hover? {
        if let raw = body as? String, !raw.isEmpty { return Hover(url: raw) }
        guard let body = body as? [String: Any], let raw = body["url"] as? String,
              !raw.isEmpty, let target = body["target"] as? String,
              let destination = LinkInteraction.Target(rawValue: target) else { return nil }
        return Hover(url: raw, target: destination)
    }

    /// The legacy string shape is also accepted for a restored page's older script.
    nonisolated static func link(from body: Any) -> String? { hover(from: body)?.url }

    /// What the capsule shows for a url. The `https://` every link has is dropped, the way
    /// Chrome and Arc drop it; `http://` stays, because a plain-http link is worth seeing.
    /// A bare `/` path goes too. Anything longer than `max` keeps its head and its tail with
    /// an ellipsis between — the host and the file are the parts that say where a link goes.
    nonisolated static func display(_ raw: String, max: Int = Look.statusMaxChars) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == (s.hasPrefix("http://") ? 3 : 1) {
            s = String(s.dropLast())
        }
        guard s.count > max, max >= 8 else { return s }
        let head = (max - 1) * 3 / 5
        let tail = max - 1 - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }

    nonisolated static func check() -> [(String, Bool)] {
        let long = "https://example.com/" + String(repeating: "abc/", count: 40) + "file.html"
        let shown = display(long, max: 40)
        return [
            ("https:// is dropped", display("https://example.com/docs") == "example.com/docs"),
            ("http:// stays, because it is worth seeing", display("http://example.com/docs") == "http://example.com/docs"),
            ("a bare trailing slash goes", display("https://example.com/") == "example.com"),
            ("…for http too", display("http://example.com/") == "http://example.com"),
            ("a path's trailing slash stays", display("https://example.com/docs/") == "example.com/docs/"),
            ("mailto links are shown as they are", display("mailto:ada@example.com") == "mailto:ada@example.com"),
            ("a hash link is shown as it is", display("https://example.com/page#top") == "example.com/page#top"),
            ("stray whitespace is trimmed", display("  https://example.com/a \n") == "example.com/a"),
            ("a long url is elided to the limit", shown.count == 40),
            ("…keeping its head", shown.hasPrefix("example.com/abc/")),
            ("…and its tail", shown.hasSuffix("file.html")),
            ("…with one ellipsis between", shown.filter { $0 == "…" }.count == 1),
            ("a url at the limit is untouched", display(String(repeating: "x", count: 40), max: 40).count == 40),
            ("the limit itself is generous enough for a host and a file", Look.statusMaxChars >= 60),
            ("an empty message means nothing is hovered", link(from: "") == nil),
            ("a non-string message means nothing is hovered", link(from: 3) == nil),
            ("a link message is passed through", link(from: "https://a.example") == "https://a.example"),
            ("the script is idempotent across bfcache restores", script.contains("__vaneHover")),
            ("the script speaks to its own handler", script.contains("messageHandlers.\(messageName)")),
        ] + PillState.check()
    }
}

/// The bottom-left capsule, including an immediate explanation while modifiers are held.
struct StatusBarView: View {
    @ObservedObject var tab: Tab
    @State private var shown: StatusBar.Hover?
    @State private var pending: Task<Void, Never>?
    @State private var modifiers: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LinkInteraction.Preferences.littleKey, store: .vane) private var littleLinks = true
    @AppStorage(LinkInteraction.Preferences.shiftKey, store: .vane) private var shiftPeek = true
    @AppStorage(Peek.prefKey, store: .vane) private var automaticPeek = true

    private var preferences: LinkInteraction.Preferences {
        .init(littleLinks: littleLinks, shiftPeek: shiftPeek, automaticPeek: automaticPeek)
    }

    private func hint(for hover: StatusBar.Hover) -> String? {
        guard let url = URL(string: hover.url) else { return nil }
        return LinkInteraction.hint(to: url, context: tab.linkContext(target: hover.target),
                                    modifiers: modifiers, preferences: preferences)
    }

    var body: some View {
        Group {
            if let shown {
                let suffix = hint(for: shown)
                let fullSplit = suffix == " in Split View" && tab.linkSplitIsFull?() == true
                HStack(spacing: 0) {
                    if suffix != nil {
                        Text(fullSplit ? "Cannot open " : "Open ")
                            .foregroundStyle(Look.barText).fixedSize()
                    }
                    Text(suffix == nil ? StatusBar.display(shown.url) : shown.url)
                        .fontWeight(suffix == nil ? .regular : .semibold)
                        .foregroundStyle(suffix == nil ? Look.barText : .white)
                        .lineLimit(1).truncationMode(.middle)
                    if let suffix {
                        Text(suffix + (fullSplit ? " (4 panes maximum)" : ""))
                            .foregroundStyle(Look.barText).fixedSize()
                    }
                }
                .font(Look.small)
                .padding(.horizontal, Look.rowInset)
                .frame(height: Look.statusHeight)
                .background(Look.barFill, in: .capsule)
                .background(Look.barMaterial, in: .capsule)
                .overlay { Capsule().strokeBorder(Look.barStroke, lineWidth: 1) }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Look.statusFade, value: shown)
        .onChange(of: tab.hoveredLink, initial: true) { _, link in schedule(link) }
        .onChange(of: modifiers) { _, _ in schedule(tab.hoveredLink) }
        .onAppear {
            modifiers = NSEvent.modifierFlags
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                modifiers = event.modifierFlags
                return event
            }
        }
        .onDisappear {
            pending?.cancel()
            shown = nil
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func schedule(_ link: StatusBar.Hover?) {
        pending?.cancel()
        guard let link else { shown = nil; return }
        if shown != nil || hint(for: link) != nil { shown = link; return }
        pending = Task {
            try? await Task.sleep(for: .seconds(Look.statusDelay))
            guard !Task.isCancelled else { return }
            shown = link
        }
    }
}

/// The two small things the address pill says about the page besides its host: that it is
/// not secure, and that it is zoomed. Pure rules, so they can be proved without a page.
enum PillState {
    /// Arc shows nothing for a secure page and a warning for one that is not: plain http, a
    /// certificate the user clicked through, or a secure page that loaded insecure content.
    /// A page with no scheme (nothing loaded, about:, a file) is not "insecure" — there is
    /// no connection to speak of.
    nonisolated static func insecure(scheme: String?, onlySecureContent: Bool, trusted: Bool) -> Bool {
        switch scheme?.lowercased() {
        case "http":  return true
        case "https": return !onlySecureContent || !trusted
        default:      return false
        }
    }

    /// Which glyph: a broken lock for plain http, a warning for a secure page with a problem.
    nonisolated static func glyph(scheme: String?) -> String {
        scheme?.lowercased() == "http" ? "lock.slash" : "exclamationmark.triangle"
    }

    /// The zoom chip's label, or nil at 100 % — the pill is quiet until the page is not at
    /// its natural size. Rounded to whole percent so the ladder's 0.85 reads "85%".
    nonisolated static func zoomLabel(_ level: Double) -> String? {
        guard level.isFinite, abs(level - 1) >= 0.005 else { return nil }
        return "\(Int((level * 100).rounded()))%"
    }

    nonisolated static func check() -> [(String, Bool)] {
        [
            ("https with nothing wrong is not flagged", !insecure(scheme: "https", onlySecureContent: true, trusted: true)),
            ("plain http is flagged", insecure(scheme: "http", onlySecureContent: true, trusted: true)),
            ("HTTP in capitals is still http", insecure(scheme: "HTTP", onlySecureContent: true, trusted: true)),
            ("https with mixed content is flagged", insecure(scheme: "https", onlySecureContent: false, trusted: true)),
            ("https over a clicked-through certificate is flagged", insecure(scheme: "https", onlySecureContent: true, trusted: false)),
            ("nothing loaded is not insecure", !insecure(scheme: nil, onlySecureContent: false, trusted: false)),
            ("a file is not insecure", !insecure(scheme: "file", onlySecureContent: false, trusted: true)),
            ("about: is not insecure", !insecure(scheme: "about", onlySecureContent: false, trusted: true)),
            ("http wears the broken lock", glyph(scheme: "http") == "lock.slash"),
            ("a secure page with a problem wears the warning", glyph(scheme: "https") == "exclamationmark.triangle"),
            ("100 % shows no chip", zoomLabel(1.0) == nil),
            ("125 % shows 125%", zoomLabel(1.25) == "125%"),
            ("85 % shows 85%, not 84%", zoomLabel(0.85) == "85%"),
            ("115 % rounds to 115%", zoomLabel(1.15) == "115%"),
            ("a hair off 100 % is still 100 %", zoomLabel(1.0001) == nil),
            ("an old off-ladder level still reads as a whole percent", zoomLabel(1.2100000000000002) == "121%"),
            ("nonsense shows no chip", zoomLabel(.nan) == nil && zoomLabel(.infinity) == nil),
        ]
    }
}
