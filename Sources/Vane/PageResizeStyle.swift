import WebKit

/// Avoid repeated deep inherited-variable comparisons on variable-heavy pages.
/// WebKit compares old/new CustomPropertyData deeply when their counts match.
/// Unused properties follow the viewport automatically, without rebuilding a
/// stylesheet during sidebar or window drags. Author styles and geometry stay intact.
@MainActor enum PageResizeStyle {
    static let world = WKContentWorld.world(name: "vane.resize-style")

    /// WebKit excludes the public native safe area before applying page zoom.
    nonisolated static func viewportSize(_ size: NSSize, insets: NSEdgeInsets, zoom: CGFloat) -> NSSize? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        let width = (size.width - insets.left - insets.right) / zoom
        let height = (size.height - insets.top - insets.bottom) / zoom
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }

    @discardableResult static func prepare(_ web: WKWebView, nextSize: NSSize? = nil, completion: (() -> Void)? = nil) -> UUID? {
        guard let viewport = viewportSize(nextSize ?? web.bounds.size, insets: web.safeAreaInsets, zoom: web.pageZoom) else { return nil }
        let preparation = UUID()
#if DEBUG
        ResizeTimingDiagnostics.record("style.javascript.dispatched", width: viewport.width, height: viewport.height)
        let traceID = ResizeTimingDiagnostics.stateSink == nil ? nil : UUID()
        let tracePage = traceID.map { _ in String(describing: ObjectIdentifier(web)) }
        if let traceID, let tracePage {
            ResizeTimingDiagnostics.recordState("style.javascript.dispatched", fields: [
                "operation": traceID.uuidString, "page": tracePage,
                "viewport": NSStringFromSize(viewport), "frame": NSStringFromRect(web.frame),
                "bounds": NSStringFromRect(web.bounds), "zoom": String(Double(web.pageZoom))
            ])
        }
#endif
        web.evaluateJavaScript(source + "(\(Double(viewport.width)), \(Double(viewport.height)), '\(preparation.uuidString)')", in: nil, in: world) { result in
#if DEBUG
            let event: String
            switch result {
            case .success: event = "style.javascript.completed"
            case .failure: event = "style.javascript.failed"
            }
            ResizeTimingDiagnostics.record(event, width: viewport.width, height: viewport.height)
            if let traceID, let tracePage {
                ResizeTimingDiagnostics.recordState(event, fields: [
                    "operation": traceID.uuidString, "page": tracePage,
                    "viewport": NSStringFromSize(viewport)
                ])
            }
#endif
            completion?()
        }
        return preparation
    }

    /// Warm a loaded visible page before its first drag, including host-only resizes.
    static func warm(_ web: WKWebView) {
        guard web.window != nil, !web.isHiddenOrHasHiddenAncestor, !web.isLoading else { return }
        prepare(web)
    }

    static func finish(_ web: WKWebView) { finish(web, matching: nil) }

    static func finish(_ web: WKWebView, matching preparation: UUID?) {
#if DEBUG
        ResizeTimingDiagnostics.recordState("style.finish.dispatched", fields: [
            "page": String(describing: ObjectIdentifier(web)), "frame": NSStringFromRect(web.frame)
        ])
#endif
        let expected = preparation.map { "'\($0.uuidString)'" } ?? "null"
        web.evaluateJavaScript("""
        (() => { const state = globalThis.__vaneResizeStyle;
          const expected = \(expected);
          if (state?.active && (expected === null || state.preparation === expected)) {
            state.sheet.disabled = true; state.active = false;
          }
        })()
        """, in: nil, in: world) { _ in }
    }

    private static let source = """
    ((width, height, preparation) => {
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
          state = { sheet, key, active: false, epoch: false, phase: null };
          globalThis.__vaneResizeStyle = state;
        }
        if (!state.built) {
          const rules = [':root {}'];
          // Cyclic thresholds cover every viewport with a 116-property budget plus8 epoch entries.
          // Quantize before mod so floating-point vw conversion cannot miss a wrap.
          // Two/three entries avoid cancelling ordinary one-entry author breakpoints.
          for (const [axis, unit, period, copies] of [['width','vw',41,2],['height','vh',13,3]]) {
            for (let i=1;i<period;i++) {
              const phase = 'mod(round(down, calc(100'+unit+' + 0.001px), 1px), '+period+'px)';
              rules.push('@media(min-'+axis+':calc(100'+unit+' - '+phase+' + '+i+'px)){:root{'+
                Array.from({length:copies},(_,j)=>state.key+'-'+axis+i+'-'+j+':0').join(';')+'}}');
            }
          }
          state.sheet.replaceSync(rules.join(''));
          state.built = true;
        }
        const phase = 2 * (Math.floor(width + 0.001) % 41) + 3 * (Math.floor(height + 0.001) % 13);
        if (state.phase === phase && (state.width !== width || state.height !== height)) {
          // Coalesced jumps can span a complete cycle or cancel between axes.
          // Change only the small epoch rule for those collisions.
          state.epoch = !state.epoch;
          state.sheet.cssRules[0].style.cssText = state.epoch
            ? Array.from({length:8},(_,i)=>state.key+'-e'+i+':0').join(';') : '';
        }
        state.phase = phase;
        state.width = width;
        state.height = height;
        state.preparation = preparation;
        if (!state.active) state.sheet.disabled = false;
        state.active = true;
        if (!document.adoptedStyleSheets.includes(state.sheet))
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, state.sheet];
      } catch (_) { }
    })
    """
}
