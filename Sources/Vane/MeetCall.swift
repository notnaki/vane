import WebKit

/// Meet's call is a document, not one video: detaching a participant's <video>
/// loses the other participants, the shared screen, and the call controls.
@MainActor enum MeetCall {
    static let messageName = "vanemeetcall"
    static let world = WKContentWorld.world(name: "vane-meet-call")

    static func supports(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == "meet.google.com"
    }

    // The material icon's name is independent of Meet's display language. A visible
    // hang-up button distinguishes an actual call (including camera/mic off, or alone)
    // from the lobby's live camera preview. Keep this site adapter out of other pages.
    static let script = """
    (() => {
      if (location.protocol !== 'https:' || location.hostname !== 'meet.google.com') return;
      const token = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
      let alive = true, timer = null, last = null;
      function active() {
        if (!alive) return false;
        return Array.from(document.querySelectorAll('button,[role="button"]')).some(button => {
          const icon = Array.from(button.querySelectorAll('span,i')).some(icon => icon.textContent.trim() === 'call_end');
          const label = /^(leave call|leave the call|hang up)$/i.test(button.getAttribute('aria-label') || '');
          if (!icon && !label) return false;
          return button.getClientRects().length > 0 && button.checkVisibility({checkOpacity: true, checkVisibilityCSS: true});
        });
      }
      function report() {
        timer = null;
        const next = active();
        if (next === last) return;
        last = next;
        webkit.messageHandlers.vanemeetcall.postMessage({token, active: next});
      }
      function schedule() {
        if (alive && timer === null) timer = setTimeout(report, 250);
      }
      const observer = new MutationObserver(schedule);
      function start() {
        observer.observe(document.documentElement, {subtree: true, childList: true, characterData: true,
          attributes: true, attributeFilter: ['hidden','aria-hidden','aria-label','style','class']});
        report();
      }
      Object.defineProperty(window, '__vaneMeetCallState', {value: () => ({token, active: active(), alive})});
      addEventListener('pagehide', () => {
        alive = false; observer.disconnect(); clearTimeout(timer); timer = null; report();
      });
      addEventListener('pageshow', event => { if (event.persisted) { alive = true; last = null; start(); } });
      addEventListener('resize', schedule);
      start();
    })();
    """

    static func receive(_ message: WKScriptMessage, tab: Tab) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "meet.google.com",
              supports(tab.existingWeb?.url),
              let body = message.body as? [String: Any], let token = body["token"] as? String,
              token.count <= 80 else { return }
        // Re-read in the current document, rather than trusting a queued report from
        // a former document with the same origin/URL. The isolated token is not page-writable.
        refresh(tab, expectedToken: token)
    }

    static func refresh(_ tab: Tab, expectedToken: String? = nil) {
        guard let web = tab.existingWeb, !tab.tornDown, !tab.suspended, supports(web.url) else { return }
        let request = UUID()
        tab.meetCallRead = request
        let generation = tab.permissionGeneration
        web.evaluateJavaScript("window.__vaneMeetCallState && window.__vaneMeetCallState()", in: nil, in: world) { [weak tab] result in
            guard let tab, tab.existingWeb === web, !tab.tornDown, !tab.suspended,
                  tab.meetCallRead == request, tab.permissionGeneration == generation,
                  supports(web.url), case .success(let value) = result,
                  let state = value as? [String: Any],
                  let token = state["token"] as? String,
                  expectedToken == nil || token == expectedToken,
                  let active = state["active"] as? Bool else { return }
            let calling = active && state["alive"] as? Bool == true
            let wasCalling = tab.inMeetCall
            if tab.inMeetCall != calling {
                tab.inMeetCall = calling
                MediaState.shared.objectWillChange.send()
            }
            if calling { CallPopout.callBecameActive(tab) }
            else if wasCalling { CallPopout.reset(tab) }
        }
    }

    static func reset(_ tab: Tab) {
        tab.meetCallRead = UUID()
        tab.inMeetCall = false
        CallPopout.reset(tab)
        MediaState.shared.objectWillChange.send()
    }
}
