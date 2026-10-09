import WebKit

/// Only frame handles, random document tokens and dirty flags cross the bridge.
/// Baselines stay in the document's isolated world and disappear with its process.
@MainActor final class DraftProtection: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "vane-drafts")
    static let messageName = "vanedraft"
    private weak var web: WKWebView?
    private var frames: [String: WKFrameInfo] = [:]
    private var mainToken: String?
    private var revision: UInt = 0

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func bind(to web: WKWebView) { self.web = web }

    func reset() { web = nil; frames.removeAll(); mainToken = nil; revision &+= 1 }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web, message.webView === web, let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
        revision &+= 1
        if body["gone"] as? Bool == true {
            frames.removeValue(forKey: token)
            if mainToken == token { mainToken = nil }
            return
        }
        if message.frameInfo.isMainFrame {
            // Reports from outgoing and incoming processes may interleave. Root
            // identity is confirmed by isolated queries; preserve child handles
            // until a probe proves that their frame/document has been replaced.
            mainToken = token
        } else {
            frames[token] = message.frameInfo
        }
    }

    private struct Snapshot: Decodable, Sendable {
        let token: String
        let dirty: Bool
        let children: Int
    }

    private enum Query: Sendable {
        case value(Snapshot), unavailable, detached
    }

    /// WebKit can fail or stop answering. A bounded probe releases the in-flight slot so
    /// the next sweep can retry; an error never becomes a cached permanent exemption.
    private final class Probe {
        var continuation: CheckedContinuation<Query, Never>?
        var timeout: Task<Void, Never>?
        func finish(_ value: Query) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: value)
        }
    }

    private func snapshot(_ web: WKWebView, frame: WKFrameInfo?) async -> Query {
        await withCheckedContinuation { continuation in
            let probe = Probe()
            probe.continuation = continuation
            probe.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                probe.finish(.unavailable)
            }
            web.evaluateJavaScript("JSON.stringify(globalThis.__vaneDraft?.check())", in: frame, in: Self.world) { result in
                switch result {
                case .success(let raw):
                    guard let json = raw as? String,
                          let value = try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)) else {
                        probe.finish(.unavailable)
                        return
                    }
                    probe.finish(.value(value))
                case .failure(let error):
                    let error = error as NSError
                    let detached = error.domain == WKError.errorDomain
                        && error.code == WKError.Code.javaScriptInvalidFrameTarget.rawValue
                    probe.finish(detached ? .detached : .unavailable)
                }
            }
        }
    }

    /// Missing/unregistered frames, changed documents and incomplete checks are uncertain.
    /// Count every frame's direct children to catch embedded frames whose script failed.
    func hasDraft(in web: WKWebView) async -> Bool {
        guard self.web === web else { return true }
        guard case .value(let root) = await snapshot(web, frame: nil), self.web === web,
              !root.dirty else { return true }
        guard root.token == mainToken else {
            // A late report from an outgoing document must not pin the new document
            // forever. The isolated query identifies the current root authoritatively.
            mainToken = root.token
            revision &+= 1
            return true
        }
        let version = revision
        let registered = frames
        var children = root.children
        var childCounts: [String: Int] = [:]
        var checked = 1
        for (token, frame) in registered where token != root.token {
            guard frame.webView === web else {
                if revision == version { frames.removeValue(forKey: token); revision &+= 1 }
                return true
            }
            let value: Snapshot
            switch await snapshot(web, frame: frame) {
            case .value(let checked): value = checked
            case .unavailable:
                // Keep live handles after transient errors/timeouts so the next pass
                // can query them again without waiting for another editing event.
                return true
            case .detached:
                if revision == version { frames.removeValue(forKey: token); revision &+= 1 }
                return true
            }
            guard value.token == token else {
                if revision == version { frames.removeValue(forKey: token); revision &+= 1 }
                return true
            }
            guard !value.dirty else { return true }
            children += value.children
            childCounts[token] = value.children
            checked += 1
        }
        guard children + 1 == checked, revision == version,
              case .value(let freshRoot) = await snapshot(web, frame: nil), freshRoot.token == root.token,
              !freshRoot.dirty, freshRoot.children == root.children, revision == version else { return true }
        // Every child document must still be the clean document sampled above after
        // the first asynchronous pass. Root-only revalidation misses frame edits.
        for (token, frame) in registered {
            guard case .value(let fresh) = await snapshot(web, frame: frame),
                  fresh.token == token, !fresh.dirty, fresh.children == childCounts[token],
                  revision == version else { return true }
        }
        guard case .value(let final) = await snapshot(web, frame: nil), final.token == root.token,
              !final.dirty, final.children == root.children, revision == version,
              self.web === web else { return true }
        return false
    }

    static let script = #"""
    (() => {
      const token = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
      const originals = new Map();
      const observed = new WeakSet();
      let last = null;
      let alive = true;
      const ignored = new Set(['hidden','submit','button','reset','image']);
      function kind(e) {
        if (e.tagName === 'TEXTAREA') return 'value';
        if (e.tagName === 'INPUT' && !ignored.has(e.type)) {
          if (e.type === 'checkbox' || e.type === 'radio') return 'checked';
          return 'value';
        }
        if (e.isContentEditable && !e.parentElement?.isContentEditable) return 'html';
        return null;
      }
      const value = (e, k) => k === 'html' ? e.innerHTML : k === 'checked' ? e.checked : e.value;
      function remember(e) {
        const k = kind(e);
        if (!k || originals.has(e)) return;
        // Standard controls expose their initial state even after script-driven edits.
        const initial = k === 'html' ? e.innerHTML : k === 'checked' ? e.defaultChecked : e.defaultValue;
        originals.set(e, {kind:k, initial, edited:false});
      }
      function discover(root) {
        if (root instanceof Element) remember(root);
        for (const e of root.querySelectorAll?.('*') || []) {
          remember(e);
          if (e.shadowRoot) scan(e.shadowRoot);
        }
      }
      function scan(root) {
        if (!observed.has(root)) {
          observed.add(root);
          observer.observe(root, {subtree:true, childList:true, characterData:true, attributes:true, attributeFilter:['contenteditable']});
          root.addEventListener('beforeinput', before, true);
          root.addEventListener('input', send, true);
          root.addEventListener('change', send, true);
        }
        discover(root);
      }
      function markRich(event, beforeEdit) {
        for (const e of event.composedPath()) if (e instanceof Element) {
          remember(e);
          const original = originals.get(e);
          if (original?.kind === 'html' && !original.edited) {
            // Editor frameworks hydrate saved content asynchronously. Freeze the
            // markup at the first editing intent, before the browser changes it.
            if (beforeEdit) original.initial = e.innerHTML;
            original.edited = true;
          }
        }
      }
      function before(event) { markRich(event, true); }
      function dirty() {
        let result = false;
        for (const [e, original] of originals) {
          if (original.kind === 'html' && !original.edited) {
            if (!e.isConnected) originals.delete(e);
            continue;
          }
          if (value(e, original.kind) !== original.initial) result = true;
          else if (!e.isConnected) originals.delete(e);
        }
        return result;
      }
      function send(event) {
        if (event?.type === 'input' || event?.type === 'change') markRich(event, false);
        const current = dirty();
        if (current === last) return;
        last = current;
        webkit.messageHandlers.vanedraft.postMessage({token, dirty:current});
      }
      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes') remember(record.target);
          for (const node of record.addedNodes) discover(node);
        }
        send();
      });
      // Reset is explicit abandonment. A submit event alone does not establish
      // remote save success; completed navigation gets a fresh document/baseline.
      document.addEventListener('reset', event => {
        queueMicrotask(() => {
          if (event.isTrusted && !event.defaultPrevented) {
            for (const [e, original] of originals) if (e.form === event.target) {
              original.initial = value(e, original.kind);
            }
          }
          send();
        });
      }, true);
      addEventListener('pagehide', () => {
        alive = false;
        webkit.messageHandlers.vanedraft.postMessage({token, gone:true});
      });
      addEventListener('pageshow', () => { alive = true; last = null; send(); });
      globalThis.__vaneDraft = {check:() => {
        if (!alive) throw new Error('retired document');
        scan(document);
        // Hydration advances baselines only at a query boundary, not during
        // mutation delivery before an input-only editor emits its editing event.
        for (const [e, original] of originals) {
          if (original.kind === 'html' && !original.edited) original.initial = e.innerHTML;
        }
        return {token, dirty:dirty(), children:window.length};
      }};
      scan(document);
      send();
    })();
    """#
}
