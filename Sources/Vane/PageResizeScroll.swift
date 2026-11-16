import WebKit

/// A buffered resize lays the page out ahead of the pointer, larger than the
/// window ever is. That layout shortens every scroll range that depends on the
/// viewport, WebKit clamps the positions beyond it, and nothing gives them back
/// when the viewport returns: a page at its end was left a lookahead above it.
/// Remember where each scroller was and put it back as far as each later
/// viewport allows, so only sizes the window really had can move a page.
@MainActor enum PageResizeScroll {
    /// Dispatch before the first buffered frame is assigned: messages reach the
    /// page in order, so this reads the positions the lookahead is about to clamp.
    static func begin(_ web: WKWebView) {
        web.evaluateJavaScript(beginSource, in: nil, in: PageResizeStyle.world) { _ in }
    }

    /// The final viewport can still be in flight; the page keeps restoring for a
    /// moment after this, then forgets the drag.
    static func end(_ web: WKWebView) {
        web.evaluateJavaScript("globalThis.__vaneResizeScroll?.end()", in: nil, in: PageResizeStyle.world) { _ in }
    }

    // ponytail: main frame, light DOM, and a 4ms walk for already-scrolled elements;
    // scrollers in subframes or shadow trees, or past that budget on a huge page,
    // keep WebKit's clamped position. Track them from an injected script if needed.
    private static let beginSource = """
    (() => {
      try {
        let state = globalThis.__vaneResizeScroll;
        if (state) { clearTimeout(state.timer); state.timer = 0; return; }
        // Per scroller and axis: `at` as last seen, `want` to return to (infinite
        // for the end itself), and whether it was at its end when last seen.
        const axes = [['scrollLeft', 'scrollWidth', 'clientWidth'], ['scrollTop', 'scrollHeight', 'clientHeight']];
        const atEnd = (el, [at, size, client]) => el[size] - el[client] - Math.abs(el[at]) <= 1;
        const read = el => axes.map(axis => ({ at: el[axis[0]], want: el[axis[0]], end: atEnd(el, axis) }));
        const wants = new Map();
        const note = el => { if (el.scrollTop || el.scrollLeft) wants.set(el, read(el)); };
        if (document.scrollingElement) note(document.scrollingElement);
        const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_ELEMENT);
        const deadline = performance.now() + 4;
        for (let el, n = 0; (el = walker.nextNode()) && (++n % 256 || performance.now() < deadline);) note(el);
        // Layout clamps a position to the end of its range, so a clamp is exactly
        // a move backward that sits at the end: it still wants to go back. Every
        // other move backward is a real scroll (a carousel realigning to the new
        // width, the page jumping, the user scrolling up) and is where it wants
        // to be. One that moved forward to the end was put there (a log following
        // its content) and means the end, which in a viewport laid out ahead is
        // short of the visible one.
        // A scroll's event runs after the resize event of the same frame, by
        // which time the range it was made in is gone. So a resize settles what
        // moved first, and there forward from the end was following it.
        // ponytail: a scroller the page itself empties below its position mid-drag
        // reads as clamped and returns if the content does, until tracking stops.
        const settle = (el, resizing) => {
          const record = wants.get(el);
          if (!record) { wants.set(el, read(el)); return; }
          axes.forEach((axis, i) => {
            const state = record[i], at = el[axis[0]];
            if (at === state.at) return;
            const forward = Math.abs(at) > Math.abs(state.at), end = atEnd(el, axis);
            if (forward && (end ? state.end || Math.abs(at) >= Math.abs(state.want) : resizing && state.end)) state.want = Math.sign(at) * Infinity;
            else if (!end) state.want = at;
            state.at = at;
            state.end = end;
          });
        };
        const scrolled = event => {
          const el = event.target === document ? document.scrollingElement : event.target;
          if (el && el.nodeType === 1) settle(el, false);
        };
        // Only ever forward, toward what a clamp took: never back over a scroll.
        const restore = () => {
          for (const [el, record] of wants) {
            if (!el.isConnected) { wants.delete(el); continue; }
            settle(el, true);
            const [left, top] = axes.map((axis, i) => {
              const want = isFinite(record[i].want) ? record[i].want : Math.sign(record[i].want) * el[axis[1]];
              return Math.abs(el[axis[0]]) < Math.abs(want) ? want : el[axis[0]];
            });
            if (left !== el.scrollLeft || top !== el.scrollTop) el.scrollTo({ left, top, behavior: 'instant' });
            axes.forEach((axis, i) => { record[i].at = el[axis[0]]; record[i].end = atEnd(el, axis); });
          }
        };
        // Once with the new viewport laid out, and again after the page's own
        // resize handlers have sized what they size.
        const resized = () => { if (wants.size) { restore(); requestAnimationFrame(restore); } };
        // A page hidden mid-drag (into the back/forward cache) never hears its end.
        const stop = () => {
          clearTimeout(state.timer);
          document.removeEventListener('scroll', scrolled, true);
          removeEventListener('resize', resized);
          removeEventListener('pagehide', stop);
          delete globalThis.__vaneResizeScroll;
        };
        state = globalThis.__vaneResizeScroll = { timer: 0, end() {
          restore();
          clearTimeout(state.timer);
          state.timer = setTimeout(stop, 500);
        } };
        document.addEventListener('scroll', scrolled, { capture: true, passive: true });
        addEventListener('resize', resized);
        addEventListener('pagehide', stop);
      } catch (_) { }
    })()
    """
}
