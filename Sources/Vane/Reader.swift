import AppKit
import WebKit

/// Which tabs are currently showing the stripped page. Reader state is per-tab — two tabs
/// on two articles are independent — and lives here rather than as a flag on `Tab` so the
/// whole feature stays in one file.
/// ponytail: a Set of ids keyed off nothing that cleans itself up. A closed tab leaves a
/// UUID behind; 16 bytes per tab you ever opened, freed at quit. Ceiling: move it onto Tab
/// the day something else needs to observe it.
@MainActor final class ReaderState: ObservableObject {
    static let shared = ReaderState()
    @Published fileprivate var tabs: Set<UUID> = []
}

/// Reader mode: throw away the page's chrome and show the article.
///
/// The split is deliberate. The DOM walk has to happen in JavaScript — it needs the live
/// tree, computed link text, `naturalWidth` on images. Everything *after* that (escaping,
/// url resolution, the tag whitelist, the "is this enough text?" decision, the document
/// itself) is plain Swift, so it can be asserted in `check()` with no browser in the room.
/// The JS therefore returns a node tree as JSON, not HTML: markup built in the page's own
/// world is markup a hostile page can shape.
@MainActor enum Reader {

    // MARK: - State

    static func isOn(_ tab: Tab) -> Bool { ReaderState.shared.tabs.contains(tab.id) }

    /// Cleared when the tab navigates anywhere, since the reader document goes with it.
    private static var watch: [UUID: NSKeyValueObservation] = [:]

    // MARK: - Preferences

    /// Applied on entry and live-adjustable afterwards through a CSS custom property, which
    /// is the only knob still reachable once the original DOM is gone.
    static var fontSize: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "readerFontSize")
            return v == 0 ? 19 : clampSize(v)
        }
        set { UserDefaults.standard.set(clampSize(newValue), forKey: "readerFontSize") }
    }

    /// Serif by default — this is a reading view, and the point of it is to not look like a
    /// web page.
    static var serif: Bool {
        get { UserDefaults.standard.object(forKey: "readerSerif") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "readerSerif") }
    }

    static func clampSize(_ v: Int) -> Int { min(max(v, 13), 32) }

    private static let serifStack =
        #""Iowan Old Style", "Palatino Linotype", Palatino, Georgia, "Times New Roman", serif"#
    private static let sansStack =
        #"-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif"#

    static func adjustFontSize(_ delta: Int, in tab: Tab?) {
        fontSize = fontSize + delta
        guard let tab, isOn(tab) else { return }
        tab.web.evaluateJavaScript(
            "document.documentElement.style.setProperty('--r-size','\(fontSize)px')")
    }

    static func setSerif(_ on: Bool, in tab: Tab?) {
        serif = on
        guard let tab, isOn(tab) else { return }
        tab.web.evaluateJavaScript(
            "document.documentElement.style.setProperty('--r-font',\(jsString(on ? serifStack : sansStack)))")
    }

    // MARK: - Entry points

    /// Cheap enough to call on every didFinish: it is the same single DOM pass the real
    /// extraction does, so availability can never disagree with what entering would show.
    static func isAvailable(in web: WKWebView) async -> Bool {
        guard web.url?.scheme?.hasPrefix("http") == true else { return false }
        guard let e = await extract(from: web) else { return false }
        return isEnough(words: e.words)
    }

    static func toggle(_ tab: Tab) { isOn(tab) ? exit(tab) : enter(tab) }

    static func enter(_ tab: Tab) {
        guard !isOn(tab) else { return }
        let id = tab.id
        Task {
            guard let e = await extract(from: tab.web), isEnough(words: e.words) else {
                NSSound.beep()          // nothing to read here; say so rather than blank the page
                return
            }
            let doc = html(for: e, url: tab.web.url)
            // Replacing documentElement.innerHTML is *not* a navigation, which is the whole
            // reason to do it this way: the back/forward list is never touched, so no
            // forward entries get truncated the way loadHTMLString or loadSimulatedRequest
            // would truncate them, and nothing lands in history. Fragment parsing with
            // <html> as the context element starts in "before head", so head/body parse.
            _ = try? await tab.web.evaluateJavaScript(
                "document.documentElement.innerHTML = \(jsString(doc));"
                + "document.scrollingElement && (document.scrollingElement.scrollTop = 0);")
            ReaderState.shared.tabs.insert(id)
            // The reader document dies with any real navigation — a link the user clicked
            // inside it, a redirect, back/forward. Drop the flag when that happens.
            watch[id] = tab.web.observe(\.url, options: [.new]) { _, _ in
                MainActor.assumeIsolated {
                    ReaderState.shared.tabs.remove(id)
                    watch[id] = nil
                }
            }
        }
    }

    /// reload(), not goBack(): entering reader mode never pushed a history entry, so there
    /// is nothing to go back *to* — the tab is still sitting on the same session-history
    /// item it was on. Reload re-fetches that item and hands back the live, scripted page
    /// with the back and forward lists exactly as they were.
    /// ponytail: costs one round trip, and a page reached by POST will ask to re-submit.
    /// Stashing the original innerHTML and putting it back is cheaper but restores a corpse
    /// — inline <script> never re-runs when reinserted that way.
    static func exit(_ tab: Tab) {
        guard ReaderState.shared.tabs.remove(tab.id) != nil else { return }
        watch[tab.id] = nil
        tab.web.reload()
    }

    // MARK: - The extraction contract

    /// One node of the tree the page hands back. Exactly one of `x` (text) and `e` (element
    /// tag) is set; `e == ""` is a wrapper whose children survive but which itself does not.
    struct Node: Decodable {
        var x: String?
        var e: String?
        var a: [String: String]?
        var c: [Node]?
        init(x: String? = nil, e: String? = nil, a: [String: String]? = nil, c: [Node]? = nil) {
            self.x = x; self.e = e; self.a = a; self.c = c
        }
    }

    private struct Payload: Decodable {
        var title: String?
        var byline: String?
        var lead: String?
        var nodes: [Node]?
    }

    struct Extraction {
        var title = ""
        var byline = ""
        var lead = ""
        var nodes: [Node] = []
        var words = 0
    }

    /// The guard rail: how much text the extraction has to have yielded before reader mode
    /// is worth offering. 140 words is roughly three short paragraphs — below it you are on
    /// a listing, a login wall, a product page or a stub, and a reader view of that is worse
    /// than the page. A real article is 400–1500. Deliberately measured in words rather than
    /// bytes, because one long unbroken nav blob would clear a byte threshold.
    ///
    /// ponytail: one number, not a model. A second signal — "at least three real <p>
    /// elements" — was tried and thrown out on real pages: it correctly wanted to reject
    /// apple.com/macbook-pro, except that page has 90 <p> while paulgraham.com, a 12,000
    /// word essay laid out in <table> and <font>, has none. The false positives left over
    /// are wordy marketing pages, and reader mode on one of those is merely useless.
    static let minimumWords = 140
    static func isEnough(words: Int) -> Bool { words >= minimumWords }

    // internal, not private: the throwaway real-page harness drives this directly.
    static func extract(from web: WKWebView) async -> Extraction? {
        let raw: Any? = try? await web.evaluateJavaScript(extractJS)
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return build(p)
    }

    private static func build(_ p: Payload) -> Extraction {
        var e = Extraction()
        e.title = (p.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        e.byline = (p.byline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        e.lead = (p.lead ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        e.nodes = p.nodes ?? []
        // Nearly every article repeats its own headline as the first h1 inside the body.
        if let first = e.nodes.first, let tag = first.e, tag == "h1" || tag == "h2",
           plainText([first]).caseInsensitiveCompare(e.title) == .orderedSame {
            e.nodes.removeFirst()
        }
        e.words = plainText(e.nodes).split(whereSeparator: \.isWhitespace).count
        return e
    }

    /// Word counting and headline de-duplication both need the text without the markup.
    static func plainText(_ nodes: [Node]) -> String {
        var out = ""
        for n in nodes {
            if let t = n.x { out += t }
            if let kids = n.c { out += plainText(kids) }
            if n.e == "p" || n.e == "br" || n.e == "li" { out += " " }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rendering (all of this is offline-testable)

    /// The only tags that reach the reader document. The tag string arrives from the page's
    /// own JavaScript world, so it is re-checked here rather than trusted; anything else is
    /// unwrapped and its text kept.
    static let allowed: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code",
        "ul", "ol", "li", "figure", "figcaption", "img", "a", "em", "strong",
        "b", "i", "br", "hr", "sup", "sub", "dl", "dt", "dd",
    ]

    /// Enough for element content and for a double-quoted attribute value.
    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The page's links are relative to the page, and the reader document replaces the page
    /// in place — so they would still resolve. They are made absolute anyway because that
    /// costs nothing and is the difference between this document being portable and not.
    /// Nil for anything we refuse to emit: javascript:, data:, and whatever else a page
    /// invents. ponytail: dropping data: also drops legitimately inlined images.
    static func resolve(_ raw: String, base: URL?) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s, relativeTo: base)?.absoluteURL,
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto"
        else { return nil }
        return u.absoluteString
    }

    static func render(_ nodes: [Node], base: URL?) -> String {
        var out = ""
        render(nodes, base: base, into: &out)
        return out
    }

    private static func render(_ nodes: [Node], base: URL?, into out: inout String) {
        for n in nodes {
            if let t = n.x { out += esc(t); continue }
            guard let tag = n.e?.lowercased(), allowed.contains(tag) else {
                render(n.c ?? [], base: base, into: &out)   // unknown wrapper: keep the words
                continue
            }
            switch tag {
            case "br", "hr":
                out += "<\(tag)>"
            case "img":
                guard let src = resolve(n.a?["src"] ?? "", base: base) else { continue }
                out += "<img src=\"\(esc(src))\" alt=\"\(esc(n.a?["alt"] ?? ""))\" loading=\"lazy\">"
            case "a":
                guard let href = resolve(n.a?["href"] ?? "", base: base) else {
                    render(n.c ?? [], base: base, into: &out)   // dead link, live words
                    continue
                }
                out += "<a href=\"\(esc(href))\">"
                render(n.c ?? [], base: base, into: &out)
                out += "</a>"
            default:
                out += "<\(tag)>"
                render(n.c ?? [], base: base, into: &out)
                out += "</\(tag)>"
            }
        }
    }

    /// The reader document: head + body, no doctype. It is assigned onto the existing
    /// documentElement, so the parse mode was already settled by the original page.
    /// ponytail: a page served in quirks mode renders this in quirks mode too.
    static func html(for e: Extraction, url: URL?) -> String {
        let body = render(e.nodes, base: url)
        let lead = e.lead.isEmpty ? nil : resolve(e.lead, base: url)
        // og:image is usually the same picture the article already opens with; only show it
        // when the body did not bring one of its own.
        let showLead = lead != nil && !body.contains("<img")
        let host = url?.host ?? ""
        return """
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(e.title))</title>
        <style>
          :root {
            color-scheme: light dark;
            --r-size: \(fontSize)px;
            --r-font: \(serif ? serifStack : sansStack);
            --bg: #fbfaf7; --fg: #1b1b1d; --dim: #6d6d73;
            --line: #e2e0d9; --link: #0a56c2; --code: #f1efe9;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #17181b; --fg: #dedfe4; --dim: #93949c;
              --line: #2d2e34; --link: #7fb0ff; --code: #1f2126;
            }
          }
          html { background: var(--bg); }
          body {
            margin: 0 auto; max-width: 68ch; padding: 4.5rem 1.5rem 9rem;
            background: var(--bg); color: var(--fg);
            font: var(--r-size)/1.65 var(--r-font);
            -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
            overflow-wrap: break-word;
          }
          header { margin: 0 0 2.5rem; }
          h1 { font-size: 1.9em; line-height: 1.15; letter-spacing: -.02em; margin: 0 0 .5rem; }
          .by, .src { font-size: .72em; color: var(--dim); font-family: \(sansStack); }
          .by { margin: 0 0 .2rem; }
          .src { letter-spacing: .04em; text-transform: uppercase; }
          article h1, article h2, article h3, article h4, article h5, article h6 {
            line-height: 1.25; margin: 2em 0 .5em; letter-spacing: -.01em;
          }
          article h1 { font-size: 1.45em; } article h2 { font-size: 1.3em; }
          article h3 { font-size: 1.12em; }
          p, ul, ol, dl { margin: 0 0 1.15em; }
          li { margin: 0 0 .35em; }
          a { color: var(--link); text-underline-offset: .15em; }
          img { max-width: 100%; height: auto; display: block; margin: 1.6em auto; border-radius: 4px; }
          figure { margin: 1.6em 0; }
          figcaption { font: .72em/1.5 \(sansStack); color: var(--dim); text-align: center; }
          blockquote {
            margin: 1.6em 0; padding: 0 0 0 1.1em;
            border-left: 3px solid var(--line); color: var(--dim); font-style: italic;
          }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .82em; }
          pre { background: var(--code); padding: .9em 1em; border-radius: 6px; overflow-x: auto; }
          code { background: var(--code); padding: .1em .3em; border-radius: 3px; }
          pre code { background: none; padding: 0; }
          hr { border: 0; border-top: 1px solid var(--line); margin: 2.5em 0; }
        </style>
        </head>
        <body>
        <header>
          <h1>\(esc(e.title))</h1>
          \(e.byline.isEmpty ? "" : "<p class=\"by\">\(esc(e.byline))</p>")
          \(host.isEmpty ? "" : "<p class=\"src\">\(esc(host))</p>")
        </header>
        <article>
        \(showLead ? "<img src=\"\(esc(lead!))\" alt=\"\">" : "")
        \(body)
        </article>
        </body>
        """
    }

    /// A JS string literal for `s`, via the one encoder already in the stdlib.
    private static func jsString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        var out = String(decoding: d, as: UTF8.self)
        out.removeFirst()      // [
        out.removeLast()       // ]
        return out
    }

    // MARK: - The DOM walk

    /// A cut-down Readability. Score every paragraph-ish block by length, comma count and
    /// its own tag, push that score up to its parent, grandparent and great-grandparent
    /// (halved, then thirded), penalise class and id names that read like furniture, then
    /// discount each candidate by its link density and take the winner's subtree.
    ///
    /// ponytail deliberately skipped: Readability's sibling-append pass, so an article body
    /// split across several equal siblings loses the tail; and <table>, because a table
    /// worth reading and a table used for layout look identical from here.
    static let extractJS = #"""
    (function () {
      var BAD = /combx|comment|com-|contact|foot|masthead|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|widget|nav|menu|share|social|banner|newsletter|subscribe|popup|modal|cookie|breadcrumb|advert|recirc|teaser|paywall|\bads?\b/i;
      var GOOD = /article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story|prose/i;
      var DROP = {SCRIPT:1,STYLE:1,NOSCRIPT:1,IFRAME:1,FORM:1,BUTTON:1,INPUT:1,SELECT:1,
                  TEXTAREA:1,SVG:1,CANVAS:1,VIDEO:1,AUDIO:1,NAV:1,ASIDE:1,FOOTER:1,HEADER:1,
                  OBJECT:1,EMBED:1,TEMPLATE:1,LABEL:1,TABLE:1};
      var KEEP = {P:1,H1:1,H2:1,H3:1,H4:1,H5:1,H6:1,BLOCKQUOTE:1,PRE:1,CODE:1,UL:1,OL:1,LI:1,
                  FIGURE:1,FIGCAPTION:1,IMG:1,A:1,EM:1,STRONG:1,B:1,I:1,BR:1,HR:1,SUP:1,SUB:1,
                  DL:1,DT:1,DD:1};

      function txt(e) { return (e.textContent || '').replace(/\s+/g, ' ').trim(); }
      function sig(e) {
        var c = e.getAttribute ? (e.getAttribute('class') || '') : '';
        return c + ' ' + (e.id || '') + ' ' + (e.getAttribute ? (e.getAttribute('role') || '') : '');
      }
      function density(e) {
        var t = txt(e).length; if (!t) { return 1; }
        var l = 0, a = e.getElementsByTagName('a');
        for (var i = 0; i < a.length; i++) { l += txt(a[i]).length; }
        return Math.min(l / t, 1);
      }

      var scores = new Map(), cands = [];
      function seed(e) {
        var b = 0, t = e.tagName;
        if (t === 'ARTICLE' || e.getAttribute('itemprop') === 'articleBody') { b += 40; }
        else if (t === 'MAIN') { b += 15; }
        else if (t === 'DIV' || t === 'SECTION') { b += 5; }
        else if (t === 'BLOCKQUOTE' || t === 'PRE' || t === 'TD') { b += 3; }
        var g = sig(e);
        if (GOOD.test(g)) { b += 25; }
        if (BAD.test(g)) { b -= 25; }
        var role = e.getAttribute('role');
        if (role === 'navigation' || role === 'complementary' || role === 'banner') { b -= 40; }
        return b;
      }
      function bump(e, s) {
        if (!e || e === document.body || e === document.documentElement) { return; }
        if (!scores.has(e)) { scores.set(e, seed(e)); cands.push(e); }
        scores.set(e, scores.get(e) + s);
      }

      // Only prose blocks seed the scores. Scoring <li> as well sounds harmless and is not:
      // on Wikipedia the reference list is hundreds of comma-heavy list items and it beats
      // the article outright. Lists still survive into the output, they just don't vote.
      var blocks = document.body ? document.body.querySelectorAll('p, pre, blockquote') : [];
      for (var i = 0; i < blocks.length; i++) {
        var t = txt(blocks[i]);
        if (t.length < 25) { continue; }
        var s = 1 + (t.split(',').length - 1) + Math.min(t.length / 100, 3);
        var p1 = blocks[i].parentElement;
        var p2 = p1 && p1.parentElement, p3 = p2 && p2.parentElement;
        bump(p1, s); bump(p2, s / 2); bump(p3, s / 3);
      }

      var best = null, bestScore = 0;
      for (var i = 0; i < cands.length; i++) {
        var sc = scores.get(cands[i]) * (1 - density(cands[i]));
        if (sc > bestScore) { bestScore = sc; best = cands[i]; }
      }
      if (!best) { best = document.querySelector('article') || document.body; }
      if (!best) { return JSON.stringify({ nodes: [] }); }

      var BLOCKY = 'p,div,ul,ol,blockquote,pre,figure,h1,h2,h3,h4,h5,h6,table';
      function ser(n) {
        if (n.nodeType === 3) {
          var v = n.nodeValue.replace(/\s+/g, ' ');
          return /\S/.test(v) ? { x: v } : null;
        }
        if (n.nodeType !== 1) { return null; }
        var tag = n.tagName;
        if (DROP[tag]) { return null; }
        if (tag === 'IMG') {
          var src = n.getAttribute('data-src') || n.getAttribute('src') || '';
          if (!src) {
            var ss = n.getAttribute('srcset') || n.getAttribute('data-srcset') || '';
            if (ss) { src = ss.split(',')[0].trim().split(/\s+/)[0]; }
          }
          // A loaded image narrower than 100px is a spacer, an icon or a tracking pixel.
          if (!src || (n.naturalWidth && n.naturalWidth < 100)) { return null; }
          return { e: 'img', a: { src: src, alt: n.getAttribute('alt') || '' } };
        }
        if (tag === 'BR' || tag === 'HR') { return { e: tag.toLowerCase() }; }
        // Furniture nested inside the article body: share rails, related-story boxes.
        if (n !== best && BAD.test(sig(n)) && txt(n).length < 300) { return null; }
        var kids = [];
        for (var i = 0; i < n.childNodes.length; i++) {
          var k = ser(n.childNodes[i]);
          if (k) { kids.push(k); }
        }
        if (!kids.length) { return null; }
        if (tag === 'A') {
          var href = n.getAttribute('href') || '';
          return href ? { e: 'a', a: { href: href }, c: kids } : { e: '', c: kids };
        }
        if (KEEP[tag]) { return { e: tag.toLowerCase(), c: kids }; }
        // Sites that mark paragraphs up as divs would otherwise run together as one blob.
        if ((tag === 'DIV' || tag === 'SECTION') && !n.querySelector(BLOCKY)) {
          return { e: 'p', c: kids };
        }
        return { e: '', c: kids };
      }

      function meta(sel) { var e = document.querySelector(sel); return e ? (e.getAttribute('content') || '') : ''; }
      var h1 = document.querySelector('h1');
      var title = meta('meta[property="og:title"]') || meta('meta[name="twitter:title"]')
               || (h1 ? txt(h1) : '') || document.title || '';
      // "Headline - Site Name": when the page's own h1 is a prefix of the title, the rest
      // is the site's branding and belongs nowhere near a reading view.
      var head1 = h1 ? txt(h1) : '';
      if (head1.length >= 10 && title.indexOf(head1) === 0) { title = head1; }
      var who = document.querySelector('[rel=author],[itemprop=author],.byline,.author,.c-byline');
      // article:author is a profile *url* as often as it is a name; a url is not a byline.
      function name(v) { return /^https?:/i.test(v) ? '' : v; }
      var byline = name(meta('meta[name="author"]')) || name(meta('meta[property="article:author"]'))
               || (who ? txt(who).slice(0, 140) : '');
      var lead = meta('meta[property="og:image"]') || meta('meta[name="twitter:image"]');

      var root = ser(best);
      var nodes = !root ? [] : (root.e === '' && root.c) ? root.c : [root];
      return JSON.stringify({ title: title, byline: byline, lead: lead, nodes: nodes });
    })()
    """#

    // MARK: - check

    /// Offline only. Everything asserted here is the Swift half: the DOM walk itself needs a
    /// browser and is exercised by loading real pages, not by this.
    static func check() -> [(String, Bool)] {
        let base = URL(string: "https://example.com/news/2026/story.html")!
        func n(_ tag: String, _ kids: [Node]) -> Node { Node(e: tag, c: kids) }
        func t(_ s: String) -> Node { Node(x: s) }

        // Escaping.
        let nasty = render([n("p", [t("5 < 6 & \"seven\" <script>alert(1)</script>")])], base: base)
        let hostileTag = render([Node(e: "script", c: [t("boom")])], base: base)
        let quotedAlt = render([Node(e: "img", a: ["src": "/a.png", "alt": "he said \"hi\""])], base: base)

        // Link resolution.
        let root = render([Node(e: "a", a: ["href": "/other"], c: [t("x")])], base: base)
        let rel = render([Node(e: "a", a: ["href": "next.html"], c: [t("x")])], base: base)
        let proto = render([Node(e: "img", a: ["src": "//cdn.example/p.jpg"])], base: base)
        let abs = render([Node(e: "a", a: ["href": "https://other.test/z"], c: [t("x")])], base: base)
        let js = render([Node(e: "a", a: ["href": "javascript:alert(1)"], c: [t("keep me")])], base: base)
        let dataImg = render([Node(e: "img", a: ["src": "data:image/gif;base64,R0lGOD"])], base: base)

        // Preferences round-trip. Restored so `check()` leaves no footprint.
        let (oldSize, oldSerif) = (UserDefaults.standard.object(forKey: "readerFontSize"),
                                   UserDefaults.standard.object(forKey: "readerSerif"))
        defer {
            UserDefaults.standard.set(oldSize, forKey: "readerFontSize")
            UserDefaults.standard.set(oldSerif, forKey: "readerSerif")
        }
        UserDefaults.standard.removeObject(forKey: "readerFontSize")
        let defaultSize = fontSize
        fontSize = 24
        let roundTrippedSize = fontSize
        fontSize = 400
        let clampedHigh = fontSize
        fontSize = 2
        let clampedLow = fontSize
        fontSize = 24
        serif = false
        let sansDoc = html(for: Extraction(title: "T", nodes: [n("p", [t("body")])], words: 900), url: base)
        serif = true
        let serifDoc = html(for: Extraction(title: "T", nodes: [n("p", [t("body")])], words: 900), url: base)

        // A whole document.
        let article = Extraction(
            title: "Ampersands & <angles>", byline: "Ada Lovelace",
            lead: "/img/lead.jpg",
            nodes: [n("p", [t("one two three")]), n("p", [t("four five")])], words: 900)
        let doc = html(for: article, url: base)
        let anon = html(for: Extraction(title: "T", nodes: [n("p", [t("x")])], words: 900), url: base)

        return [
            // escaping
            ("markup in page text is escaped, not emitted",
             nasty.contains("&lt;script&gt;") && !nasty.contains("<script")),
            ("ampersands and quotes in text are escaped",
             nasty.contains("5 &lt; 6 &amp; &quot;seven&quot;")),
            ("a tag the page invented is unwrapped and its text kept",
             hostileTag == "boom"),
            ("quotes inside an attribute value are escaped",
             quotedAlt.contains("alt=\"he said &quot;hi&quot;\"")),
            ("the title is escaped in both the head and the header",
             doc.contains("<title>Ampersands &amp; &lt;angles&gt;</title>")
             && doc.contains("<h1>Ampersands &amp; &lt;angles&gt;</h1>")),

            // link resolution
            ("a root-relative link resolves against the origin",
             root.contains("href=\"https://example.com/other\"")),
            ("a document-relative link resolves against the directory",
             rel.contains("href=\"https://example.com/news/2026/next.html\"")),
            ("a protocol-relative src takes the page's scheme",
             proto.contains("src=\"https://cdn.example/p.jpg\"")),
            ("an already-absolute link is left alone",
             abs.contains("href=\"https://other.test/z\"")),
            ("a javascript: link is dropped but its words survive",
             js == "keep me"),
            ("a data: image is dropped entirely", dataImg.isEmpty),
            ("with no base url a relative link is dropped, not half-written",
             render([Node(e: "a", a: ["href": "/x"], c: [t("w")])], base: nil) == "w"),

            // preferences
            ("font size defaults to something readable", defaultSize == 19),
            ("font size round-trips through UserDefaults", roundTrippedSize == 24),
            ("font size clamps at both ends", clampedHigh == 32 && clampedLow == 13),
            ("the persisted font size reaches the document", doc.contains("--r-size: 24px")),
            ("the typeface toggle round-trips and reaches the document",
             sansDoc.contains("--r-font: -apple-system") && serifDoc.contains("--r-font: \"Iowan Old Style\"")),

            // the threshold
            ("a stub of a page is not enough for reader mode", isEnough(words: 60) == false),
            ("one word short of the threshold is still not enough",
             isEnough(words: minimumWords - 1) == false),
            ("exactly the threshold is enough", isEnough(words: minimumWords)),
            ("a real article is enough", isEnough(words: 800)),
            ("a synthetic extraction that yields only a stub is refused",
             isEnough(words: build(decode(
                 "{\"nodes\":[{\"e\":\"p\",\"c\":[{\"x\":\"only a handful of words here\"}]}]}"
                 )).words) == false),
            ("a synthetic extraction that yields an article is accepted",
             isEnough(words: build(decode(
                 "{\"nodes\":[{\"e\":\"p\",\"c\":[{\"x\":\""
                 + String(repeating: "word ", count: 200) + "\"}]}]}")).words)),
            ("word count comes from the text, not the markup",
             build(decode("{\"title\":\"T\",\"nodes\":[{\"e\":\"p\",\"c\":[{\"x\":\"one two three\"}]},"
                          + "{\"e\":\"p\",\"c\":[{\"x\":\"four\"}]}]}")).words == 4),
            ("a repeated headline is dropped from the body",
             build(decode("{\"title\":\"Hello\",\"nodes\":[{\"e\":\"h1\",\"c\":[{\"x\":\"Hello\"}]},"
                          + "{\"e\":\"p\",\"c\":[{\"x\":\"body\"}]}]}")).nodes.count == 1),

            // the document
            ("the document adapts to dark mode", doc.contains("prefers-color-scheme: dark")),
            ("the reading column has a measure", doc.contains("max-width: 68ch")),
            ("the byline is shown when there is one", doc.contains("Ada Lovelace")),
            ("no byline means no empty byline line", !anon.contains("class=\"by\"")),
            ("the source host is shown", doc.contains(">example.com<")),
            ("the lead image is resolved against the page url",
             doc.contains("src=\"https://example.com/img/lead.jpg\"")),
            ("the body survives into the document", doc.contains("<p>one two three</p>")),
        ]
    }

    private static func decode(_ json: String) -> Payload {
        (try? JSONDecoder().decode(Payload.self, from: Data(json.utf8))) ?? Payload()
    }
}
