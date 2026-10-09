import WebKit

@MainActor enum SiteBoostScripts {
    static let world = WKContentWorld.world(name: "Vane.SiteBoosts")
    static let messageName = "vaneBoost"

    static func install(on controller: WKUserContentController) {
        // A page-world marker lets queued user code reject a replacement document.
        // Store it on Document, whose identity changes even if WebKit reuses a Window.
        controller.addUserScript(WKUserScript(source: pageIdentity, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: runtime, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: "window.__vaneBoost?.post('loaded');", injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true, in: world))
    }

    static let pageIdentity = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol)) return;
      const token = [...crypto.getRandomValues(new Uint32Array(4))].map(n => n.toString(16).padStart(8, '0')).join('');
      Object.defineProperty(document, '__vaneBoostPageToken', {value: token});
    })();
    """#

    static func guardedScript(_ script: String) -> String {
        """
        if (location.origin !== __vaneOrigin || document.__vaneBoostPageToken !== __vaneToken) return 'Page changed. Reload and try again.';
        \(script)
        ;return 'Script applied.';
        """
    }

    static let runtime = #"""
    (() => {
      if (!/^https?:$/.test(location.protocol) || window.__vaneBoost) return;
      const stamp = performance.timeOrigin, origin = location.origin;
      // The live timeOrigin can differ from its captured value. Use a stable per-document identity for visual operations.
      const token = [...crypto.getRandomValues(new Uint32Array(4))].map(value => value.toString(16).padStart(8, '0')).join('');
      const style = new CSSStyleSheet();
      let overlay = null, cover = null, selected = null;
      const sizeSelector = 'p,h1,h2,h3,h4,h5,h6,a,span,li,td,th,button,input,textarea,label,blockquote';
      const sizes = new Map();
      let sizeObserver = null, sizeFrame = null;
      const post = (kind, extra = {}) => window.webkit.messageHandlers.vaneBoost.postMessage({kind, stamp, origin, token, ...extra});
      const selectable = el => el && el.parentElement && el.getRootNode() === document &&
        el !== document.body && document.body?.contains(el) && !el.hasAttribute('data-vane-zap');
      const selector = el => {
        if (!selectable(el)) return null;
        if (el.id) {
          const id = '#' + CSS.escape(el.id);
          if (document.querySelectorAll(id).length === 1) return id;
        }
        const parts = [];
        while (el && el !== document.body && el !== document.documentElement) {
          const name = CSS.escape(el.localName);
          const siblings = [...el.parentElement.children].filter(s => s.localName === el.localName);
          parts.unshift(name + ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')');
          el = el.parentElement;
        }
        const path = 'body > ' + parts.join(' > ');
        return document.querySelectorAll(path).length === 1 ? path : null;
      };
      const restoreSizes = () => {
        for (const [el, old] of sizes) {
          if (old.value) el.style.setProperty('font-size', old.value, old.priority);
          else el.style.removeProperty('font-size');
        }
      };
      const clearSizes = () => {
        sizeObserver?.disconnect(); sizeObserver = null;
        if (sizeFrame !== null) cancelAnimationFrame(sizeFrame); sizeFrame = null;
        restoreSizes(); sizes.clear();
      };
      const scaleText = (nodes, scale) => {
        restoreSizes();
        for (const el of sizes.keys()) if (!el.isConnected) sizes.delete(el);
        for (const el of nodes) {
          if (el.isConnected && !sizes.has(el)) sizes.set(el, {value: el.style.getPropertyValue('font-size'), priority: el.style.getPropertyPriority('font-size')});
        }
        const measured = [...sizes.keys()].map(el => [el, parseFloat(getComputedStyle(el).fontSize)]);
        for (const [el, size] of measured) if (Number.isFinite(size)) el.style.setProperty('font-size', (size * scale) + 'px', 'important');
      };
      const apply = (css, scale = 1) => {
        clearSizes();
        // Constructed stylesheets work under style-src restrictions and leave site sheets intact.
        style.replaceSync(css);
        const others = document.adoptedStyleSheets.filter(sheet => sheet !== style);
        document.adoptedStyleSheets = css.trim() ? [...others, style] : others;
        if (scale === 1) return;
        scaleText(document.querySelectorAll(sizeSelector), scale);
        const pending = new Set();
        sizeObserver = new MutationObserver(records => {
          for (const record of records) for (const node of record.addedNodes) {
            if (node.nodeType !== Node.ELEMENT_NODE || node.hasAttribute('data-vane-zap')) continue;
            if (node.matches(sizeSelector)) pending.add(node);
            for (const child of node.querySelectorAll(sizeSelector)) pending.add(child);
          }
          if (!pending.size || sizeFrame !== null) return;
          sizeFrame = requestAnimationFrame(() => { sizeFrame = null; scaleText(pending, scale); pending.clear(); });
        });
        sizeObserver.observe(document, {childList: true, subtree: true});
      };
      const elementAt = event => {
        if (event.target !== cover) return event.target;
        // A top-document glass intercepts embedded-frame input and selects the frame as a whole.
        cover.style.setProperty('pointer-events', 'none', 'important');
        const el = document.elementFromPoint(event.clientX, event.clientY);
        cover.style.setProperty('pointer-events', 'auto', 'important');
        return el;
      };
      const hover = event => {
        const el = elementAt(event);
        // Highlighting needs eligibility and geometry. Build and validate the unique
        // selector only on pick, against the DOM as it exists at click time.
        selected = selectable(el) ? el : null;
        if (!selected) { overlay.style.display = 'none'; return; }
        const r = selected.getBoundingClientRect();
        Object.assign(overlay.style, {display:'block', left:r.x+'px', top:r.y+'px', width:r.width+'px', height:r.height+'px'});
      };
      const pick = event => {
        event.preventDefault(); event.stopImmediatePropagation();
        const key = selector(elementAt(event));
        if (key) { post('pick', {selector:key}); overlay.style.display = 'none'; selected = null; }
      };
      const block = event => { event.preventDefault(); event.stopImmediatePropagation(); };
      const key = event => {
        if (event.key === 'Escape') { block(event); zap(false); post('done'); }
      };
      const zap = on => {
        zapOff();
        if (!on || !document.body) return;
        api.zapping = true;
        cover = document.createElement('vane-boost-zap-cover'); cover.dataset.vaneZap = ''; cover.dataset.vaneZapCover = '';
        cover.style.cssText = 'position:fixed;inset:0;z-index:2147483646;cursor:crosshair;display:block;background:transparent;';
        document.documentElement.append(cover);
        overlay = document.createElement('vane-boost-zap-highlight'); overlay.dataset.vaneZap = '';
        overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #8b5cf6;border-radius:4px;background:#8b5cf622;box-sizing:border-box;display:none;';
        document.documentElement.append(overlay);
        window.addEventListener('pointermove', hover, true);
        window.addEventListener('click', pick, true);
        window.addEventListener('pointerdown', block, true);
        window.addEventListener('mousedown', block, true);
        window.addEventListener('keydown', key, true);
      };
      const zapOff = () => {
        api.zapping = false;
        window.removeEventListener('pointermove', hover, true);
        window.removeEventListener('click', pick, true);
        window.removeEventListener('pointerdown', block, true);
        window.removeEventListener('mousedown', block, true);
        window.removeEventListener('keydown', key, true);
        cover?.remove(); cover = null; overlay?.remove(); overlay = null; selected = null;
      };
      const api = window.__vaneBoost = {apply, selector, zap, post, zapping:false};
      Object.defineProperty(api, 'documentToken', {value:token});
      window.addEventListener('pagehide', zapOff);
      window.addEventListener('pageshow', event => { if (event.persisted) post('restored'); });
      post('ready');
    })();
    """#
}
