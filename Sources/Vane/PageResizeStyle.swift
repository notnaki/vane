import WebKit

/// Avoid repeated deep inherited-variable comparisons on variable-heavy pages.
/// WebKit compares old/new CustomPropertyData deeply when their counts match.
/// A bounded set of unused entries makes that comparison cheap during live resize;
/// the page's geometry, viewport and author declarations stay unchanged.
@MainActor enum PageResizeStyle {
    static let world = WKContentWorld.world(name: "vane.resize-style")

    static func prepare(_ web: WKWebView, nextSize: NSSize? = nil) {
        let zoom = web.pageZoom
        let dx = nextSize.map { ($0.width - web.bounds.width) / zoom } ?? 0
        let dy = nextSize.map { ($0.height - web.bounds.height) / zoom } ?? 0
        guard dx.isFinite, dy.isFinite else { return }
        web.evaluateJavaScript(source + "(\(Double(dx)),\(Double(dy)))", in: nil, in: world) { _ in }
    }

    /// Install invisible, bounded viewport hints while a loaded page is shown,
    /// before its first drag. Author declarations and geometry stay unchanged.
    static func warm(_ web: WKWebView) {
        guard web.window != nil, !web.isHiddenOrHasHiddenAncestor, !web.isLoading else { return }
        let width = web.bounds.width / web.pageZoom, height = web.bounds.height / web.pageZoom
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        web.evaluateJavaScript(source + "(0,0,\(Double(width)),\(Double(height)))", in: nil, in: world) { _ in }
    }

    static func finish(_ web: WKWebView) {
        web.evaluateJavaScript("""
        (() => { const state = globalThis.__vaneResizeStyle;
          if (state?.band) { state.sheet.replaceSync(':root {}'); state.band = null; }
        })()
        """, in: nil, in: world) { _ in }
    }

    private static let source = """
    ((dx, dy, warmWidth = null, warmHeight = null) => {
      try {
        if (!document.documentElement || !globalThis.CSSStyleSheet || !document.adoptedStyleSheets) return;
        let state = globalThis.__vaneResizeStyle;
        if (!state) {
          const computed = getComputedStyle(document.documentElement);
          let count = 0;
          for (let i = 0; i < computed.length && count < 128; i++) {
            if (computed[i].startsWith('--')) count++;
          }
          if (count < 128) return;
          const sheet = new CSSStyleSheet();
          const key = '--vane-resize-' + [...crypto.getRandomValues(new Uint32Array(4))]
            .map(value => value.toString(16)).join('-');
          state = { sheet, key, band: null, epoch: false };
          globalThis.__vaneResizeStyle = state;
        }
        const width = Math.floor(warmWidth ?? innerWidth + dx), height = Math.floor(warmHeight ?? innerHeight + dy);
        const band = state.band;
        if (!band || (dx !== 0 && (width < band.x + 3 || width >= band.x + 37)) ||
            (dy !== 0 && (height < band.y + 1 || height >= band.y + 11))) {
          const x = Math.max(0, width - 20), y = Math.max(0, height - 6), rules = [];
          state.epoch = !state.epoch;
          if (state.epoch) {
            rules.push(':root{' + Array.from({length:8},(_,i)=>state.key+'-e'+i+':0').join(';') + '}');
          }
          // At most80 width +36 height +8 epoch entries. Within this band,
          // media queries update counts without invalidating the stylesheet.
          for (let i=0;i<40;i++) rules.push('@media(min-width:'+(x+i)+'px){:root{'+
            state.key+'-w'+i+'a:0;'+state.key+'-w'+i+'b:0}}');
          for (let i=0;i<12;i++) rules.push('@media(min-height:'+(y+i)+'px){:root{'+
            state.key+'-h'+i+'a:0;'+state.key+'-h'+i+'b:0;'+state.key+'-h'+i+'c:0}}');
          state.sheet.replaceSync(rules.join(''));
          state.band = {x,y};
        }
        if (!document.adoptedStyleSheets.includes(state.sheet))
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, state.sheet];
      } catch (_) { }
    })
    """
}
