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
    /// Where `ExtensionWorkerIdentity.prepare` leaves the Chrome ID in the runtime manifest.
    nonisolated static let chromeIDKey = "__vane_chrome_id"
    /// The answer travels back as `tabs.create`'s rejection, the one reply a worker can
    /// read. The marker tells it from WebKit's own errors.
    nonisolated static let marker = "[vane-identity] "

    // ponytail: like `sidePanel`, a `tabs.create` the host intercepts. Callbacks get the
    // result but no `runtime.lastError`, which only WebKit can set; promises reject.
    nonisolated static let script = #"""
        ;(() => {
          for (const api of new Set([globalThis.chrome, globalThis.browser])) {
            try {
              if (!api?.tabs?.create || !api.runtime?.getManifest || api.identity !== undefined) continue;
              const runtime = api.runtime, tabs = api.tabs, manifest = runtime.getManifest();
              if (!manifest.permissions?.includes('identity')) continue;
              const base = 'https://' + (manifest.__vane_chrome_id ?? runtime.id.toLowerCase()) + '.chromiumapp.org/';
              const marker = '[vane-identity] ';
              const event = Object.freeze({addListener() {}, removeListener() {}, hasListener: () => false, hasListeners: () => false});
              Object.defineProperty(api, 'identity', {configurable: true, value: Object.freeze({
                getRedirectURL(path) { return new URL(path ?? '', base).href; },
                launchWebAuthFlow(details, callback) {
                  const values = {url: String(details?.url ?? ''), interactive: String(details?.interactive === true)};
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
    /// store's, else the one its manifest `key` names.
    nonisolated static func chromeID(storeID: String?, manifest: [String: Any]) -> String? {
        if let storeID { return storeID }
        guard let key = (manifest["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return SHA256.hash(data: key).prefix(16).map { byte in
            String([byte >> 4, byte & 15].map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
        }.joined()
    }

    /// The host of the extension's own redirect URL, `getRedirectURL()`'s.
    nonisolated static func redirectHost(manifest: [String: Any], runtimeID: String) -> String {
        ((manifest[chromeIDKey] as? String) ?? runtimeID).lowercased() + ".chromiumapp.org"
    }

    struct Request: Equatable {
        let url: URL
        let interactive: Bool

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
        }
    }
}

/// One `launchWebAuthFlow`: its page in a Vane window (or none, when not interactive)
/// until a navigation reaches the extension's redirect URL, which never loads.
@MainActor final class ExtensionAuthFlow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    nonisolated static let windowIdentifier = NSUserInterfaceItemIdentifier("vane.extension.sign-in")
    let web: WKWebView
    private let redirectHost: String
    private let interactive: Bool
    private(set) var window: NSWindow?
    private var continuation: CheckedContinuation<String, any Error>?
    private var observation: NSKeyValueObservation?

    init(request: ExtensionIdentityAPI.Request, redirectHost: String, configuration: WKWebViewConfiguration, title: String) {
        self.redirectHost = redirectHost
        interactive = request.interactive
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = Settings.inspectorEnabled
        if interactive {
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.identifier = Self.windowIdentifier
            window.title = title
            window.contentView = web
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Whose page this is matters more than the extension's say: show its host.
            observation = web.observe(\.url, options: [.initial]) { [weak window] web, _ in
                MainActor.assumeIsolated { window?.subtitle = web.url?.host ?? "" }
            }
            self.window = window
        }
        web.load(URLRequest(url: request.url))
    }

    func run(over parent: NSWindow?) async throws -> String {
        if let window {
            if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                                          y: parent.frame.maxY - window.frame.height - 60)) }
            else { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// Chrome's messages, so an extension's own checks still match.
    func cancel(_ message: String = "The user did not approve access.") { finish(.failure(ExtensionHost.Failure(message))) }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        observation = nil
        web.stopLoading()
        web.navigationDelegate = nil
        window?.delegate = nil
        window?.close()
        continuation.resume(with: result)
    }

    private func isRedirect(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == redirectHost
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame != false, isRedirect(action.request.url) else { return .allow }
        finish(.success(action.request.url!.absoluteString))
        return .cancel
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if isRedirect(webView.url) { finish(.success(webView.url!.absoluteString)) }
    }

    /// Chrome's default for a flow without a window: the first load that does not
    /// redirect needs the user.
    // ponytail: no `abortOnLoadForNonInteractive: false` or `timeoutMsForNonInteractive`.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !interactive { cancel("User interaction required.") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code != NSURLErrorCancelled { cancel("Authorization page could not be loaded.") }
    }

    /// Sign-in pages that open a popup get it in this window instead.
    // ponytail: no `window.opener`; a second web view is the upgrade if a provider needs one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { cancel() }
    func windowWillClose(_ notification: Notification) { cancel() }
}
