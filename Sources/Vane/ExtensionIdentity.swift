import AppKit
import CryptoKit
import WebKit

/// `chrome.identity`'s web sign-in for system WebKit, which has no such API:
/// `getRedirectURL()` and `launchWebAuthFlow()`. The flow runs in a Vane window with
/// its own web view on the profile's data store. `getAuthToken` and the rest of
/// Chrome's Google-account sign-in stay undefined: there is no Google account to ask.
@MainActor enum ExtensionIdentityAPI {
    /// Never a resource: the host consumes this URL before anything can load it.
    nonisolated static let bridgePath = "/__vane_identity__"
    nonisolated static let permission = "identity"
    /// The answer travels back as `tabs.create`'s rejection, the one reply a worker can
    /// read. The marker tells it from WebKit's own errors.
    nonisolated static let marker = "[vane-identity] "

    // ponytail: like `sidePanel`, a `tabs.create` the host intercepts. Callbacks get the
    // result but no `runtime.lastError`, which only WebKit can set; promises reject.
    nonisolated static let script = #"""
        ;(() => {
          // Chrome's API: Safari app extensions get Safari's (`ExtensionChromiumGaps.safariFlag`).
          if (globalThis[Symbol.for('vane.safari.extension')] === true) return;
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!api?.tabs?.create || !api.runtime?.getManifest || api.identity !== undefined) continue;
              const runtime = api.runtime, tabs = api.tabs, manifest = runtime.getManifest();
              if (!manifest.permissions?.includes('identity')) continue;
              // Chrome's ID for the manifest `key`, as the host derives it; store installs run
              // under their store ID already. The host checks redirects against its own copy.
              const chromeID = key => {
                if (typeof key !== 'string' || key.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(key)) return null;
                const bytes = [...atob(key)].map(c => c.charCodeAt(0)), K = [], H = [];
                for (let n = 2; K.length < 64; n++) {
                  let prime = true;
                  for (let d = 2; d * d <= n; d++) if (n % d === 0) { prime = false; break; }
                  if (!prime) continue;
                  if (H.length < 8) H.push(Math.pow(n, 1 / 2) * 4294967296 | 0);
                  K.push(Math.pow(n, 1 / 3) * 4294967296 | 0);
                }
                const length = bytes.length * 8;
                bytes.push(0x80);
                while (bytes.length % 64 !== 56) bytes.push(0);
                for (let shift = 56; shift >= 0; shift -= 8) bytes.push(shift >= 32 ? Math.floor(length / 2 ** shift) & 255 : (length >>> shift) & 255);
                const r = (x, n) => x >>> n | x << (32 - n), w = [];
                for (let at = 0; at < bytes.length; at += 64) {
                  for (let i = 0; i < 64; i++) w[i] = i < 16
                    ? bytes[at + 4 * i] << 24 | bytes[at + 4 * i + 1] << 16 | bytes[at + 4 * i + 2] << 8 | bytes[at + 4 * i + 3]
                    : (r(w[i - 2], 17) ^ r(w[i - 2], 19) ^ w[i - 2] >>> 10) + w[i - 7] + (r(w[i - 15], 7) ^ r(w[i - 15], 18) ^ w[i - 15] >>> 3) + w[i - 16] | 0;
                  let [a, b, c, d, e, f, g, h] = H;
                  for (let i = 0; i < 64; i++) {
                    const t1 = h + (r(e, 6) ^ r(e, 11) ^ r(e, 25)) + (e & f ^ ~e & g) + K[i] + w[i] | 0;
                    const t2 = (r(a, 2) ^ r(a, 13) ^ r(a, 22)) + (a & b ^ a & c ^ b & c) | 0;
                    [h, g, f, e, d, c, b, a] = [g, f, e, d + t1 | 0, c, b, a, t1 + t2 | 0];
                  }
                  H.forEach((v, i) => H[i] = v + [a, b, c, d, e, f, g, h][i] | 0);
                }
                return H.slice(0, 4).map(v => [...(v >>> 0).toString(16).padStart(8, '0')].map(x => String.fromCharCode(97 + parseInt(x, 16))).join('')).join('');
              };
              // A store install runs under its store ID, which the host also prefers to its key.
              const base = 'https://' + (/^[a-p]{32}$/.test(runtime.id) ? runtime.id : chromeID(manifest.key) ?? runtime.id.toLowerCase()) + '.chromiumapp.org/';
              const marker = '[vane-identity] ';
              const event = Object.freeze({addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false});
              Object.defineProperty(api, 'identity', {configurable: true, value: Object.freeze({
                AccountStatus: Object.freeze({ANY: 'ANY', SYNC: 'SYNC'}),
                getRedirectURL(path) { return base + String(path ?? '').replace(/^\/?/, ''); },
                launchWebAuthFlow(details, callback) {
                  const values = {url: String(details?.url ?? ''), interactive: String(details?.interactive === true)};
                  if (Number.isFinite(details?.timeoutMsForNonInteractive)) values.timeout = String(details.timeoutMsForNonInteractive);
                  if (details?.abortOnLoadForNonInteractive === false) values.abortOnLoad = 'false';
                  const promise = tabs.create({url: runtime.getURL('/__vane_identity__?' + new URLSearchParams(values)), active: false}).then(
                    () => { throw new Error('Authorization page could not be loaded.'); },
                    error => {
                      const message = String(error?.message ?? error), at = message.indexOf(marker);
                      if (at < 0) throw error;
                      const answer = message.slice(at + marker.length);
                      if (answer.startsWith('resolve ')) return answer.slice(8, -1);
                      throw new Error(answer.replace(/^reject /, ''));
                    });
                  if (typeof callback !== 'function') return promise;
                  promise.then(callback, error => { console.error(error); callback(); });
                },
                onSignInChanged: event
              })});
            } catch (error) { console.error(error); }
          }
        })();
        """#

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page))
    }

    static func declared(_ manifest: [String: Any]) -> Bool {
        (manifest["permissions"] as? [String])?.contains(permission) == true
    }

    /// The ID Chrome would give the extension, which its OAuth provider knows it by: the
    /// store's, else the one its manifest `key` names. The script above derives the same.
    nonisolated static func chromeID(storeID: String?, manifest: [String: Any]) -> String? {
        if let storeID { return storeID }
        guard let key = (manifest["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return SHA256.hash(data: key).prefix(16).map { byte in
            String([byte >> 4, byte & 15].map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
        }.joined()
    }

    /// The host of the extension's own redirect URL, `getRedirectURL()`'s.
    nonisolated static func redirectHost(_ chromeID: String) -> String { chromeID.lowercased() + ".chromiumapp.org" }

    /// Only the redirect host itself, over https on its default port; never a look-alike.
    nonisolated static func isRedirect(_ url: URL?, host: String) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == host && (url?.port ?? 443) == 443
    }

    /// Chrome's ceiling for a flow without a window.
    nonisolated static let nonInteractiveTimeout = Duration.seconds(60)

    struct Request: Equatable {
        let url: URL
        let interactive: Bool
        let timeout: Duration
        /// Chrome's `abortOnLoadForNonInteractive`: false waits out the timeout for a page
        /// that redirects from script after it loads.
        let abortOnLoad: Bool

        /// Only the owning extension's bridge URL is a request; anything else is a tab.
        /// `nil` url: the request is the extension's, its page is not one to load.
        nonisolated init?(_ url: URL?, base: URL) throws {
            guard let url, url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.path == bridgePath else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard let page = value("url").flatMap(URL.init(string:)), ["https", "http"].contains(page.scheme?.lowercased()),
                  page.host?.isEmpty == false else { throw ExtensionHost.Failure(marker + "reject Authorization page could not be loaded.") }
            self.url = page
            interactive = value("interactive") == "true"
            abortOnLoad = value("abortOnLoad") != "false"
            let milliseconds = value("timeout").flatMap(Double.init).map { max(0, $0) } ?? .infinity
            timeout = milliseconds < 60_000 ? .milliseconds(milliseconds) : nonInteractiveTimeout
        }
    }
}

/// One `launchWebAuthFlow`: its page in a Vane window (or none, when not interactive)
/// until a navigation reaches the extension's redirect URL, which never loads.
@MainActor final class ExtensionAuthFlow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    nonisolated static let windowIdentifier = NSUserInterfaceItemIdentifier("vane.extension.sign-in")
    let web: WKWebView
    private let url: URL
    private let redirectHost: String
    private let interactive: Bool
    private let abortOnLoad: Bool
    private let title: String
    private(set) var window: NSWindow?
    /// Windows the sign-in page opened, which keep their opener.
    private(set) var popups: [NSWindow] = []
    private var continuation: CheckedContinuation<String, any Error>?
    private var observations: [NSKeyValueObservation] = []
    private var timeout: Task<Void, Never>?
    /// Popups get the same treatment as the sign-in view (its user agent).
    var preparePopup: ((WKWebView) -> Void)?

    init(request: ExtensionIdentityAPI.Request, redirectHost: String, configuration: WKWebViewConfiguration, title: String) {
        url = request.url
        self.redirectHost = redirectHost
        self.title = title
        interactive = request.interactive
        abortOnLoad = request.abortOnLoad
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = Settings.inspectorEnabled
        if interactive { window = makeWindow(for: web) }
        else {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: request.timeout)
                if !Task.isCancelled { self?.cancel("User interaction required.") }
            }
        }
    }

    private func makeWindow(for web: WKWebView) -> NSWindow {
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = Settings.inspectorEnabled
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.identifier = Self.windowIdentifier
        window.title = title
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Whose page this is matters more than the extension's say: show its host.
        observations.append(web.observe(\.url, options: [.initial]) { [weak window] web, _ in
            MainActor.assumeIsolated { window?.subtitle = web.url?.host ?? "" }
        })
        return window
    }

    func run(over parent: NSWindow?) async throws -> String {
        guard !finished else { throw ExtensionHost.Failure("The user did not approve access.") }
        if let window {
            if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                                          y: parent.frame.maxY - window.frame.height - 60)) }
            else { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            // Loads here, not in init, so the caller sets the user agent before the first
            // request, and after the continuation, so nothing can finish without resuming it.
            web.load(URLRequest(url: url))
        }
    }

    /// Chrome's messages, so an extension's own checks still match.
    func cancel(_ message: String = "The user did not approve access.") { finish(.failure(ExtensionHost.Failure(message))) }

    private var finished = false
    private func finish(_ result: Result<String, any Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        observations = []
        for view in [web] + popups.compactMap({ $0.contentView as? WKWebView }) {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
        }
        for window in [window].compactMap({ $0 }) + popups {
            window.delegate = nil
            window.close()
        }
        popups = []
        // Before `run` nothing has loaded, so only a cancel lands here; `run` then refuses.
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard ExtensionIdentityAPI.isRedirect(action.request.url, host: redirectHost) else { return .allow }
        // A subframe at the redirect URL is not the answer, but its code must not reach the network.
        guard action.targetFrame?.isMainFrame != false else { return .cancel }
        finish(.success(action.request.url!.absoluteString))
        return .cancel
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if ExtensionIdentityAPI.isRedirect(webView.url, host: redirectHost) { finish(.success(webView.url!.absoluteString)) }
    }

    /// Chrome's default for a flow without a window: the first load that does not
    /// redirect needs the user, unless the extension asked to wait for the timeout.
    // ponytail: `timeoutMsForNonInteractive` caps at Chrome's minute.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !interactive, abortOnLoad { cancel("User interaction required.") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(webView, error) }

    /// Chrome ends the flow when the sign-in page cannot load; a popup's failure is its own.
    private func failed(_ webView: WKWebView, _ error: any Error) {
        if webView === web, (error as NSError).code != NSURLErrorCancelled { cancel("Authorization page could not be loaded.") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === web { cancel("Authorization page could not be loaded.") } else { close(webView) }
    }

    /// Sign-in pages that open a popup get it in its own window, with its opener, as a tab
    /// would. Flows without a window have nowhere to show one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard interactive, !finished else { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        preparePopup?(popup)
        let window = makeWindow(for: popup)
        popups.append(window)
        window.setFrameOrigin(NSPoint(x: (self.window?.frame.minX ?? 0) + 30, y: (self.window?.frame.minY ?? 0) - 30))
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    private func close(_ popup: WKWebView) {
        guard let window = popups.first(where: { $0.contentView === popup }) else { return }
        popups.removeAll { $0 === window }
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        window.delegate = nil
        window.close()
    }

    func webViewDidClose(_ webView: WKWebView) { webView === web ? cancel() : close(webView) }

    func windowWillClose(_ notification: Notification) {
        if let popup = (notification.object as? NSWindow)?.contentView as? WKWebView, popup !== web { close(popup) }
        else { cancel() }
    }
}
