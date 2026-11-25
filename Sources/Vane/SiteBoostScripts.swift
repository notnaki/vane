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
      if (!/^https?:$/.test(location.protocol) || document.__vaneBoostPageToken) return;
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
      let overlay = null, cover = null, selected = null, bubble = null, pending = null, previewing = false;
      const preview = new CSSStyleSheet();
      const sizeSelector = 'p,h1,h2,h3,h4,h5,h6,a,span,li,td,th,button,input,textarea,label,blockquote';
      const sizes = new Map();
      let sizeObserver = null, sizeFrame = null, textScale = 1, alive = true, applyQueued = false;
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
      // CSS can depend on descendants (:has), siblings, and inherited em sizes.
      // Coalesce invalidations, but always restore and measure the full current set.
      const queueSizes = () => {
        if (!alive || textScale === 1 || sizeFrame !== null) return;
        sizeFrame = requestAnimationFrame(() => {
          sizeFrame = null;
          scaleText(document.querySelectorAll(sizeSelector), textScale);
        });
      };
      const watchSizes = () => {
        if (!alive || textScale === 1 || sizeObserver) return;
        sizeObserver = new MutationObserver(queueSizes);
        sizeObserver.observe(document, {childList:true, subtree:true});
      };
      const apply = (css, scale = 1) => {
        clearSizes();
        textScale = scale;
        // Constructed stylesheets work under style-src restrictions and leave site sheets intact.
        style.replaceSync(css);
        const others = document.adoptedStyleSheets.filter(sheet => sheet !== style);
        document.adoptedStyleSheets = css.trim() ? [...others, style] : others;
        watchSizes();
        // Native updates must also take effect in an occluded/background page.
        // A microtask keeps only the latest same-turn update without waiting for paint.
        if (!applyQueued) {
          applyQueued = true;
          queueMicrotask(() => {
            applyQueued = false;
            if (alive && textScale !== 1) scaleText(document.querySelectorAll(sizeSelector), textScale);
          });
        }
      };
      const elementAt = event => {
        if (event.target !== cover) return event.target;
        // A top-document glass intercepts embedded-frame input and selects the frame as a whole.
        cover.style.setProperty('pointer-events', 'none', 'important');
        const el = document.elementFromPoint(event.clientX, event.clientY);
        cover.style.setProperty('pointer-events', 'auto', 'important');
        return el;
      };
      // Classes shared with similar elements: "Zap all related elements" hides every match.
      const related = el => {
        const classes = [...el.classList].filter(c => /^[A-Za-z_-][\w-]*$/.test(c)).slice(0, 4);
        if (!classes.length) return null;
        const key = CSS.escape(el.localName) + classes.map(c => '.' + CSS.escape(c)).join('');
        try { const count = document.querySelectorAll(key).length; return count > 1 ? {key, count} : null; } catch { return null; }
      };
      const showPreview = key => {
        if (!key && !previewing) return;
        previewing = !!key;
        preview.replaceSync(key ? key + ' { outline: 2px solid #ff9500 !important; outline-offset: -2px !important; }' : '');
        const others = document.adoptedStyleSheets.filter(sheet => sheet !== preview);
        document.adoptedStyleSheets = key ? [...others, preview] : others;
      };
      const closeBubble = () => { bubble?.remove(); bubble = null; pending = null; showPreview(null); };
      const chip = (label, color, action) => {
        const b = document.createElement('vane-boost-zap-button'); b.dataset.vaneZap = ''; b.dataset.action = action;
        b.textContent = label;
        b.style.cssText = `all:initial;display:inline-block;cursor:pointer;font:500 12px -apple-system,system-ui,sans-serif;color:#fff;background:${color};padding:6px 10px;border-radius:7px;white-space:nowrap;`;
        return b;
      };
      const openBubble = (el, exact) => {
        closeBubble();
        const group = related(el);
        pending = {exact, related: group?.key ?? null};
        bubble = document.createElement('vane-boost-zap-bubble'); bubble.dataset.vaneZap = '';
        bubble.style.cssText = 'all:initial;position:fixed;z-index:2147483647;display:flex;flex-direction:column;gap:6px;padding:6px;background:#fff;border-radius:12px;box-shadow:0 8px 28px #0004,0 0 0 0.5px #0002;font:11px -apple-system,system-ui,sans-serif;';
        const row = document.createElement('vane-boost-zap-row'); row.dataset.vaneZap = '';
        row.style.cssText = 'all:initial;display:flex;gap:6px;';
        row.append(chip('Zap this', '#ff3b30', 'this'));
        if (group) {
          const all = chip('Zap all related elements', '#ff9500', 'related');
          all.addEventListener('pointerenter', () => showPreview(group.key));
          all.addEventListener('pointerleave', () => showPreview(null));
          row.append(all);
        }
        row.append(chip('Cancel', '#3a3a3c', 'cancel'));
        bubble.append(row);
        if (group) {
          const info = document.createElement('vane-boost-zap-info'); info.dataset.vaneZap = '';
          info.textContent = group.count + '  ' + group.key;
          info.style.cssText = 'all:initial;display:block;padding:0 4px 2px;font:10px ui-monospace,Menlo,monospace;color:#8e8e93;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:360px;';
          bubble.append(info);
        }
        document.documentElement.append(bubble);
        const r = el.getBoundingClientRect(), b = bubble.getBoundingClientRect();
        const left = Math.min(Math.max(8, r.x + r.width / 2 - b.width / 2), innerWidth - b.width - 8);
        const top = r.bottom + 8 + b.height < innerHeight ? r.bottom + 8 : Math.max(8, r.top - b.height - 8);
        Object.assign(bubble.style, {left: left + 'px', top: Math.min(top, innerHeight - b.height - 8) + 'px'});
      };
      const hover = event => {
        if (!event.isTrusted || pending) return;
        const el = elementAt(event);
        // Highlighting needs eligibility and geometry. Build and validate the unique
        // selector only on pick, against the DOM as it exists at click time.
        selected = selectable(el) ? el : null;
        if (!selected) { overlay.style.display = 'none'; return; }
        const r = selected.getBoundingClientRect();
        Object.assign(overlay.style, {display:'block', left:r.x+'px', top:r.y+'px', width:r.width+'px', height:r.height+'px'});
      };
      const pick = event => {
        if (!event.isTrusted) return;
        event.preventDefault(); event.stopImmediatePropagation();
        const action = event.target?.closest?.('vane-boost-zap-button')?.dataset.action;
        if (pending) {
          const choice = action === 'this' ? pending.exact : action === 'related' ? pending.related : null;
          if (choice) post('pick', {selector:choice});
          if (action || !bubble?.contains(event.target)) { closeBubble(); overlay.style.display = 'none'; selected = null; }
          return;
        }
        const el = elementAt(event), key = selector(el);
        if (key) openBubble(el, key);
      };
      const block = event => { if (!event.isTrusted) return; event.preventDefault(); event.stopImmediatePropagation(); };
      const key = event => {
        if (!event.isTrusted) return;
        if (event.key === 'Escape') { block(event); if (pending) closeBubble(); else { zap(false); post('done'); } }
        // Zapping keeps the page focused, so ⌘Z for the last Zap arrives here rather than in the panel.
        else if (event.metaKey && !event.shiftKey && event.key.toLowerCase() === 'z') { block(event); closeBubble(); post('undo'); }
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
        closeBubble();
        cover?.remove(); cover = null; overlay?.remove(); overlay = null; selected = null;
      };
      const api = window.__vaneBoost = {apply, selector, zap, post, zapping:false};
      Object.defineProperty(api, 'documentToken', {value:token});
      window.addEventListener('pagehide', () => {
        alive = false; zapOff();
        sizeObserver?.disconnect(); sizeObserver = null;
        if (sizeFrame !== null) cancelAnimationFrame(sizeFrame); sizeFrame = null;
      });
      window.addEventListener('pageshow', event => {
        alive = true; watchSizes(); queueSizes();
        if (event.persisted) post('restored');
      });
      post('ready');
    })();
    """#
}
