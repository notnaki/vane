import AppKit
import WebKit

@MainActor enum ChromeWebStorePage {
    static let world = WKContentWorld.world(name: "VaneChromeWebStore")
    static let messageName = "vaneStoreInstall"

    static func authorizedSource(id: String, frameURL: URL?, currentURL: URL?, mainFrame: Bool, privateTab: Bool) -> ChromeWebStore? {
        guard mainFrame, !privateTab, let frameURL, let currentURL,
              let frame = try? ChromeWebStore(input: frameURL.absoluteString),
              let current = try? ChromeWebStore(input: currentURL.absoluteString),
              frame.id == id, current.id == id else { return nil }
        return current
    }

    static func receive(_ message: WKScriptMessage, tab: Tab) {
        guard let id = message.body as? String, let web = tab.existingWeb,
              message.webView === web, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "chromewebstore.google.com",
              let source = authorizedSource(id: id, frameURL: message.frameInfo.request.url, currentURL: web.url,
                  mainFrame: message.frameInfo.isMainFrame, privateTab: tab.isPrivate) else { return }
        let host = ExtensionHost.host(for: tab.profileID)
        let document = web.url
        Task { [weak tab, weak web] in
            var result = "cancelled"
            do {
                let accepted = try await host.installStore(source, review: { [weak tab, weak web] review in
                    guard let tab, let web, tab.existingWeb === web, !tab.isPrivate, web.url == document else { return false }
                    return ExtensionConsent.ask(review)
                })
                result = accepted || host.entries.contains(where: { $0.storeID == id }) ? "added" : "cancelled"
            } catch is CancellationError { }
            catch {
                result = "error"
                if let tab, let web, tab.existingWeb === web, web.url == document {
                    ExtensionManagement.showDetails(error.localizedDescription, title: "Could not install extension")
                }
            }
            guard let tab, let web, tab.existingWeb === web, web.url == document else { return }
            _ = try? await web.callAsyncJavaScript("globalThis.__vaneStoreComplete?.(id, result)",
                arguments: ["id": id, "result": result], in: nil, contentWorld: world)
        }
    }

    /// DOM nodes are shared with the store; the bridge and closures are not. Creating
    /// our own button avoids Google's delegated install handlers. A trusted click in
    /// this isolated world is required before any native message is sent.
    static var script: String { #"""
    (() => {
      if (location.origin !== 'https://chromewebstore.google.com' || window !== top) return;
      if (globalThis.__vaneStoreObserver) return;
      let button = null, original = null, originalHidden = false, currentID = null, pending = false;
      const sourceID = () => {
        const parts = location.pathname.split('/');
        return (parts.length === 3 || parts.length === 4) && parts[1] === 'detail' &&
          parts.slice(1).every(Boolean) && /^[a-p]{32}$/.test(parts.at(-1)) ? parts.at(-1) : null;
      };
      function reset() {
        button?.remove(); button = null;
        if (original) original.hidden = originalHidden;
        original = null; currentID = null; pending = false;
      }
      function refresh() {
        const id = sourceID();
        if (id !== currentID) reset();
        if (!id || button?.isConnected) return;
        currentID = id;
        const native = document.querySelector('button[jsname="wQO0od"]') ||
          [...document.querySelectorAll('button')].find(e => /^Add to Chrome$/i.test(e.textContent.trim()));
        button = document.createElement('button');
        button.type = 'button'; button.dataset.vaneStoreInstall = '';
        button.textContent = 'Add to Vane';
        button.title = 'Download this extension and review its access in Vane';
        if (native) {
          original = native; originalHidden = native.hidden;
          button.className = native.className;
          const label = document.createElement('span');
          label.textContent = 'Add to Vane'; button.replaceChildren(label);
          native.before(button); native.hidden = true;
        } else {
          Object.assign(button.style, {position:'fixed',right:'24px',top:'112px',zIndex:'2147483647'});
          document.body.append(button);
        }
        Object.assign(button.style, {padding:'12px 24px',minHeight:'44px',border:'0',borderRadius:'24px',transition:'__VANE_TRANSITION__',
          background:'#0b57d0',color:'#fff',font:'600 14px system-ui',cursor:'pointer'});
        button.addEventListener('click', event => {
          event.preventDefault(); event.stopImmediatePropagation();
          if (!event.isTrusted || pending || sourceID() !== currentID) return;
          pending = true; button.disabled = true; button.textContent = 'Checking…';
          button.style.opacity = '0.65';
          button.setAttribute('aria-busy','true');
          window.webkit.messageHandlers.vaneStoreInstall.postMessage(currentID);
        }, true);
      }
      globalThis.__vaneStoreComplete = (id, result) => {
        if (id !== currentID || !button) return;
        pending = false; button.removeAttribute('aria-busy');
        button.style.opacity = '1';
        button.disabled = result === 'added';
        button.textContent = result === 'added' ? 'Added to Vane' : result === 'error' ? 'Try Again in Vane' : 'Add to Vane';
      };
      const observer = new MutationObserver(refresh);
      globalThis.__vaneStoreObserver = observer;
      observer.observe(document.documentElement, {childList:true,subtree:true});
      window.addEventListener('popstate', refresh);
      refresh();
    })();
    """#.replacingOccurrences(of: "__VANE_TRANSITION__", with: Motion.reduced ? "none" : "opacity 120ms ease-out") }
}
