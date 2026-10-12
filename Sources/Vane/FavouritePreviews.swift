import AppKit
import Combine
import WebKit

@MainActor protocol FavouritePreviewLoading: AnyObject {
    func load(_ context: FavouritePreviewContext) async -> FavouritePreviewResult
    func cancel()
}

/// One request across windows. A hidden page uses WebKit's profile store directly;
/// cookies, tokens and page application state never cross into another network stack.
@MainActor final class FavouritePreviews: ObservableObject {
    static let shared = FavouritePreviews(loader: FavouriteWebLoader(), observeSessions: true)
    static let enabledKey = "favouritePreviews"
    static func serviceKey(_ service: FavouritePreviewService) -> String { "favouritePreviews.\(service.rawValue)" }
    static func enabled(_ service: FavouritePreviewService) -> Bool {
        (UserDefaults.vane.object(forKey: enabledKey) as? Bool ?? true)
        && (UserDefaults.vane.object(forKey: serviceKey(service)) as? Bool ?? true)
    }

    @Published private(set) var owner: UUID?
    @Published private(set) var state: FavouritePreviewState = .loading
    private var context: FavouritePreviewContext?
    private let loader: any FavouritePreviewLoading
    private let observeSessions: Bool
    private let now: @MainActor () -> Date
    private var cache = FavouritePreviewCache()
    private var attempts: [FavouritePreviewContext: Date] = [:]
    private var blocked: [UUID: Int] = [:]
    private var observers: [UUID: FavouriteSessionObserver] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sessionRetries = 0
    private var loading = false

    init(loader: any FavouritePreviewLoading, observeSessions: Bool = false, now: @escaping @MainActor () -> Date = { .now }) {
        self.loader = loader; self.observeSessions = observeSessions; self.now = now
    }

    func request(_ context: FavouritePreviewContext, owner: UUID, account: String? = nil,
                 source: WKWebView? = nil, privateSession: Bool = false, sessionRetries: Int = 0) {
        stop()
        self.sessionRetries = sessionRetries
        self.owner = owner; self.context = context; state = .loading
        guard Self.enabled(context.service), !privateSession, blocked[context.profileID] == nil else {
            state = .unavailable; return
        }
        guard !observeSessions || ProfileManager.shared.profiles.contains(where: { $0.id == context.profileID }) else {
            state = .unavailable; return
        }
        if observeSessions, observers[context.profileID] == nil {
            observers[context.profileID] = FavouriteSessionObserver(profileID: context.profileID, previews: self)
        }
        let ticket = generation
        task = Task { [weak self, weak source] in
            guard let self else { return }
            var identity = account
            // The live favourite supplies account proof before any cached data is displayed.
            // Only a matching service/account route can supply it; a wandered favourite cannot.
            if identity == nil, let source, let url = source.url,
               FavouritePreviewContext(profileID: context.profileID, url: url) == context {
                identity = await FavouriteIdentityProbe.read(source, script: DOMFavouritePreviewAdapter(service: context.service).identityScript)
            }
            guard !Task.isCancelled, self.generation == ticket else { return }
            let hit = identity.flatMap { self.cache.lookup(context: context, account: $0, now: self.now()) }
            if let hit, !hit.stale { self.setState(.ready(hit.snapshot)); return }
            if let hit { self.setState(.stale(hit.snapshot)) }
            if let last = self.attempts[context], self.now().timeIntervalSince(last) < 30 {
                if hit == nil { self.setState(.unavailable) }
                return
            }
            // Bound failed refreshes as well as successes. No timer refreshes a closed card.
            self.attempts[context] = self.now()
            if self.attempts.count > 48, let oldest = self.attempts.min(by: { $0.value < $1.value })?.key {
                self.attempts[oldest] = nil
            }
            self.loading = true
            let result = await self.loader.load(context)
            guard !Task.isCancelled, self.generation == ticket, self.owner == owner,
                  Self.enabled(context.service), self.blocked[context.profileID] == nil else { return }
            self.loading = false
            switch result {
            case .ready(let snapshot):
                guard identity == nil || identity == snapshot.account else {
                    self.cache.invalidate(profileID: context.profileID)
                    self.setState(.unavailable); return
                }
                self.cache.store(snapshot, context: context, now: self.now())
                self.setState(.ready(snapshot))
            case .signedOut:
                self.cache.invalidate(profileID: context.profileID)
                self.setState(.signedOut)
            case .unavailable:
                self.setState(hit.map { .stale($0.snapshot) } ?? .unavailable)
            }
        }
    }

    func dismiss(owner: UUID) {
        guard self.owner == owner else { return }
        stop(); self.owner = nil; context = nil; state = .loading
    }
    func invalidate(profileID: UUID) {
        cache.invalidate(profileID: profileID)
        attempts = attempts.filter { $0.key.profileID != profileID }
        if context?.profileID == profileID {
            stop(); owner = nil; context = nil; state = .loading
        }
    }
    /// Session cookies may be set during the first normal page visit. Retire all old
    /// content and allow one bounded restart; repeated changes never become polling.
    func sessionChanged(profileID: UUID) {
        cache.invalidate(profileID: profileID)
        attempts = attempts.filter { $0.key.profileID != profileID }
        guard let context, context.profileID == profileID, let owner else { return }
        if loading && sessionRetries < 1 {
            request(context, owner: owner, sessionRetries: sessionRetries + 1)
        } else {
            stop()
            setState(.unavailable)
        }
    }
    func beginClearing(profileID: UUID) {
        blocked[profileID, default: 0] += 1
        invalidate(profileID: profileID)
    }
    func endClearing(profileID: UUID) {
        invalidate(profileID: profileID)
        if let count = blocked[profileID], count > 1 { blocked[profileID] = count - 1 }
        else { blocked[profileID] = nil }
    }
    func forget(profileID: UUID) {
        invalidate(profileID: profileID)
        observers[profileID]?.detach(); observers[profileID] = nil
    }
    func preferencesChanged() {
        stop(); owner = nil; context = nil; state = .loading
        cache.removeAll(); attempts.removeAll()
    }
    private func stop() {
        generation += 1; task?.cancel(); task = nil; loading = false; loader.cancel()
    }
    private func setState(_ state: FavouritePreviewState) { Motion.animate(Look.quick) { self.state = state } }
}

@MainActor private final class FavouriteSessionObserver: NSObject, WKHTTPCookieStoreObserver {
    let profileID: UUID
    weak var previews: FavouritePreviews?
    let store: WKHTTPCookieStore
    init(profileID: UUID, previews: FavouritePreviews) {
        self.profileID = profileID; self.previews = previews
        store = ProfileManager.dataStore(for: profileID).httpCookieStore
        super.init(); store.add(self)
    }
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            previews?.sessionChanged(profileID: profileID)
        }
    }
    func detach() { store.remove(self) }
}

@MainActor private final class FavouriteIdentityProbe {
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    private func finish(_ value: String?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: value?.isEmpty == false ? value : nil)
    }
    static func read(_ web: WKWebView, script: String) async -> String? {
        let probe = FavouriteIdentityProbe()
        return await withCheckedContinuation { continuation in
            probe.continuation = continuation
            probe.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                probe.finish(nil)
            }
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result { case .success(let value): probe.finish(value as? String); case .failure: probe.finish(nil) }
            }
        }
    }
}

@MainActor final class FavouriteWebLoader: NSObject, FavouritePreviewLoading, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    private var host: PreviewHostWindow?
    private var context: FavouritePreviewContext?
    private var continuation: CheckedContinuation<FavouritePreviewResult, Never>?
    private var deadline: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var reads = 0

    func load(_ context: FavouritePreviewContext) async -> FavouritePreviewResult {
        cancel()
        self.context = context
        let cfg = Tab.configuration(isPrivate: false, profileID: context.profileID)
        cfg.webExtensionController = nil
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(origin: .zero, size: Previews.viewport), configuration: cfg)
        web.customUserAgent = Settings.userAgent
        web.navigationDelegate = self; web.uiDelegate = self
        self.web = web; host = PreviewHostWindow(content: web)
        let ticket = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.generation == ticket else { return }
                    self.finish(.unavailable)
                }
                web.load(URLRequest(url: context.entryURL))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.cancel()
            }
        }
    }
    func cancel() { finish(.unavailable) }
    private func finish(_ result: FavouritePreviewResult) {
        generation += 1
        deadline?.cancel(); deadline = nil; retry?.cancel(); retry = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        // Retire the page, including timers/media, instead of leaving a hidden service polling.
        web?.load(URLRequest(url: URL(string: "about:blank")!))
        host?.orderOut(nil); host?.contentView = nil; host = nil; web = nil
        context = nil; reads = 0
        let pending = continuation; continuation = nil; pending?.resume(returning: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { extract() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.unavailable) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.unavailable) }
    private func extract() {
        guard let web, let context, continuation != nil, reads < 6 else { finish(.unavailable); return }
        reads += 1
        let ticket = generation, adapter = DOMFavouritePreviewAdapter(service: context.service)
        web.evaluateJavaScript(adapter.script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.generation == ticket else { return }
            var parsed = FavouritePreviewResult.unavailable
            if case .success(let value) = result,
               let data = try? JSONSerialization.data(withJSONObject: value),
               let extraction = try? JSONDecoder().decode(FavouritePreviewExtraction.self, from: data) {
                parsed = adapter.parse(extraction)
            }
            if parsed != .unavailable { self.finish(parsed); return }
            self.retry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard let self, self.generation == ticket else { return }
                self.extract()
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let context else { decisionHandler(.cancel); return }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false {
            if url.host == "accounts.google.com" || (context.service == .github && url.host == "github.com" && url.path == "/login") {
                decisionHandler(.cancel); finish(.signedOut); return
            }
            guard url.host == context.service.host, action.targetFrame != nil,
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
                decisionHandler(.cancel); finish(.unavailable); return
            }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard response.canShowMIMEType, (response.response as? HTTPURLResponse).map({ (200..<400).contains($0.statusCode) }) ?? true else {
            decisionHandler(.cancel); finish(.unavailable); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    #if compiler(>=6.4)
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    #endif
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
