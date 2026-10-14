import AppKit
import Combine
import CryptoKit
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
    private let sessionObserverFactory: (UUID, FavouritePreviews) -> FavouriteSessionObserver
    private let now: @MainActor () -> Date
    private var cache = FavouritePreviewCache()
    private var attempts: [FavouritePreviewContext: Date] = [:]
    private var blocked: [UUID: Int] = [:]
    private var observers: [UUID: FavouriteSessionObserver] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sessionRetries = 0
    private var loading = false
    private var loadingOwner: UUID?
    private var preparing = false
    private var preparedState: FavouritePreviewState?
    private var promotionTask: Task<Void, Never>?
    private var accountHint: String?
    private weak var requestSource: WKWebView?

    /// Only one intent is prepared. Opening promotes this work rather than queuing a load.
    func prepare(_ context: FavouritePreviewContext, owner: UUID, source: WKWebView? = nil,
                 privateSession: Bool = false) {
        guard Self.enabled(context.service), !privateSession, !BatterySaver.shared.isActive,
              source?.isLoading != true else { return }
        start(context, owner: owner, source: source, privateSession: privateSession, preparation: true)
    }

    init(loader: any FavouritePreviewLoading, observeSessions: Bool = false, now: @escaping @MainActor () -> Date = { .now },
         sessionObserverFactory: @escaping (UUID, FavouritePreviews) -> FavouriteSessionObserver = { FavouriteSessionObserver(profileID: $0, previews: $1) }) {
        self.loader = loader; self.observeSessions = observeSessions; self.now = now
        self.sessionObserverFactory = sessionObserverFactory
    }

    func request(_ context: FavouritePreviewContext, owner: UUID, account: String? = nil,
                 source: WKWebView? = nil, privateSession: Bool = false, sessionRetries: Int = 0) {
        start(context, owner: owner, account: account, source: source, privateSession: privateSession,
              sessionRetries: sessionRetries, preparation: false)
    }

    private func start(_ context: FavouritePreviewContext, owner: UUID, account: String? = nil,
                       source: WKWebView? = nil, privateSession: Bool = false,
                       sessionRetries: Int = 0, preparation: Bool) {
        if task != nil, self.context == context,
           (self.owner == owner || (self.owner == nil && loading && loadingOwner == owner)), accountHint == account,
           self.sessionRetries == sessionRetries,
           requestSource === source, Self.enabled(context.service), !privateSession,
           blocked[context.profileID] == nil {
            // A quick return reattaches to the already-started, bounded request.
            if self.owner == nil {
                self.owner = owner; preparing = preparation; state = .loading
            }
            // A promotion must not restart WebKit or consume the failed-refresh cooldown.
            if !preparation && preparing { promote(context, source: source) }
            return
        }
        stop()
        preparing = preparation; accountHint = account; requestSource = source
        self.sessionRetries = sessionRetries
        self.owner = owner; self.context = context; state = .loading
        guard Self.enabled(context.service), !privateSession, blocked[context.profileID] == nil else {
            state = .unavailable; return
        }
        guard !observeSessions || ProfileManager.shared.profiles.contains(where: { $0.id == context.profileID }) else {
            state = .unavailable; return
        }
        if observeSessions, observers[context.profileID] == nil {
            observers[context.profileID] = sessionObserverFactory(context.profileID, self)
        }
        let ticket = generation
        task = Task(priority: preparation ? .background : .utility) { [weak self, weak source] in
            guard let self else { return }
            // Establish the session baseline before the hidden page can write cookies.
            let session = await self.observers[context.profileID]?.synchronize()
            guard !Task.isCancelled, self.generation == ticket else { return }
            var identity = account
            let liveProof = source?.url.flatMap { FavouritePreviewContext(profileID: context.profileID, url: $0) } == context
            // The live favourite supplies account proof before any cached data is displayed.
            // Only a matching service/account route can supply it; a wandered favourite cannot.
            if identity == nil, let source, let url = source.url,
               FavouritePreviewContext(profileID: context.profileID, url: url) == context {
                identity = await FavouriteIdentityProbe.read(source, script: DOMFavouritePreviewAdapter(service: context.service).identityScript)
            }
            guard !Task.isCancelled, self.generation == ticket,
                  Self.enabled(context.service), self.blocked[context.profileID] == nil else { return }
            let hit = identity.flatMap { self.cache.lookup(context: context, account: $0, now: self.now()) }
                ?? (identity == nil && !liveProof ? session.flatMap { self.cache.lookup(context: context, session: $0, now: self.now()) } : nil)
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
            self.loading = true; self.loadingOwner = owner
            var result = FavouritePreviewResult.unavailable
            if liveProof, let source, !source.isLoading {
                result = await FavouriteIdentityProbe.extraction(source, service: context.service)
                guard !Task.isCancelled, self.generation == ticket else { return }
            }
            if result == .unavailable { result = await self.loader.load(context) }
            guard !Task.isCancelled, self.generation == ticket, (self.owner == owner || self.owner == nil),
                  Self.enabled(context.service), self.blocked[context.profileID] == nil else { return }
            // Verification is still in-flight work: cancellation here must permit a retry.
            defer { if self.generation == ticket { self.loading = false; self.loadingOwner = nil } }
            switch result {
            case .ready(let snapshot):
                // Account proof can change while WebKit is loading. Recheck a source
                // that supplied it before either caching or displaying authenticated data.
                if liveProof {
                    guard let source else { self.setState(.unavailable); return }
                    let live = await FavouriteIdentityProbe.read(source, script: DOMFavouritePreviewAdapter(service: context.service).identityScript)
                    guard !Task.isCancelled, self.generation == ticket,
                          Self.enabled(context.service), self.blocked[context.profileID] == nil else { return }
                    guard source.url.flatMap({ FavouritePreviewContext(profileID: context.profileID, url: $0) }) == context,
                          live == snapshot.account else {
                        self.cache.invalidate(profileID: context.profileID)
                        self.setState(.unavailable); return
                    }
                }
                guard identity == nil || identity == snapshot.account else {
                    self.cache.invalidate(profileID: context.profileID)
                    self.setState(.unavailable); return
                }
                // Recheck the cookie proof after loading, including notifications that
                // WebKit may have coalesced, before attaching it to a cached account.
                let currentSession = await self.observers[context.profileID]?.synchronize()
                guard !Task.isCancelled, self.generation == ticket else { return }
                self.cache.store(snapshot, context: context, now: self.now(), session: currentSession == session ? session : nil)
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
        if loading && !BatterySaver.shared.isActive {
            // Let this one user-initiated request fill the cache. The loader's existing
            // deadline still retires WebKit; no closed-card refresh or polling begins.
            self.owner = nil; state = .loading; preparing = false; preparedState = nil
            promotionTask?.cancel(); promotionTask = nil
            return
        }
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
        guard let context, context.profileID == profileID else { return }
        guard let owner else { stop(); return }
        if loading && !preparing && sessionRetries < 1 {
            request(context, owner: owner, account: accountHint, source: requestSource,
                    sessionRetries: sessionRetries + 1)
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
        // Cancellation is not a failed refresh. A deliberate return may retry immediately.
        if loading, let context { attempts[context] = nil }
        generation += 1; task?.cancel(); task = nil; loading = false; loadingOwner = nil; loader.cancel()
        preparing = false; preparedState = nil; accountHint = nil; requestSource = nil
        promotionTask?.cancel(); promotionTask = nil
    }
    private func promote(_ context: FavouritePreviewContext, source: WKWebView?) {
        preparing = false
        guard let prepared = preparedState else { return }
        preparedState = nil
        let snapshot: FavouritePreviewSnapshot
        switch prepared {
        case .ready(let value), .stale(let value): snapshot = value
        default: setState(prepared); return
        }
        // Proof collected during the earlier dwell must still hold when the card opens.
        if source == nil && !observeSessions { setState(prepared); return }
        let ticket = generation
        promotionTask = Task { [weak self, weak source] in
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            let verified: Bool
            if let source, source.url.flatMap({ FavouritePreviewContext(profileID: context.profileID, url: $0) }) == context {
                let identity = await FavouriteIdentityProbe.read(source, script: DOMFavouritePreviewAdapter(service: context.service).identityScript)
                verified = source.url.flatMap({ FavouritePreviewContext(profileID: context.profileID, url: $0) }) == context && identity == snapshot.account
            } else if let session = await self.observers[context.profileID]?.synchronize() {
                verified = self.cache.lookup(context: context, session: session, now: self.now())?.snapshot.account == snapshot.account
            } else { verified = false }
            guard !Task.isCancelled, self.generation == ticket else { return }
            guard verified else {
                self.stop(); self.cache.invalidate(profileID: context.profileID)
                self.setState(.unavailable); return
            }
            // A refresh may have finished during the probe; don't replace it with stale data.
            if self.state == .loading { self.setState(prepared) }
        }
    }

    private func setState(_ state: FavouritePreviewState) {
        guard owner != nil else { return }
        if preparing { preparedState = state; return }
        Motion.animate(Look.quick) { self.state = state }
    }
}

/// Ignore page/analytics cookie churn. Keep only in-memory digests of authentication
/// cookies; sign-out, deletion and account replacement still invalidate all cached data.
struct FavouriteSessionFingerprint: Equatable {
    private struct Cookie: Hashable {
        let domain, path, name: String
        let digest: Data
    }
    private var cookies: Set<Cookie>
    func hasAuthentication(for service: FavouritePreviewService) -> Bool {
        cookies.contains { cookie in
            if service == .github {
                return cookie.domain == "github.com" && ["user_session", "__Host-user_session_same_site"].contains(cookie.name)
            }
            return cookie.domain != "github.com" && ["SID", "LSID", "__Secure-1PSID", "__Secure-3PSID"].contains(cookie.name)
        }
    }
    init(_ cookies: [HTTPCookie]) {
        self.cookies = Set(cookies.compactMap { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let names: Set<String>
            if domain == "github.com" {
                names = ["user_session", "__Host-user_session_same_site", "logged_in", "dotcom_user"]
            } else if ["google.com", "accounts.google.com", "mail.google.com", "calendar.google.com"].contains(domain) {
                names = ["SID", "HSID", "SSID", "APISID", "SAPISID", "LSID", "__Host-GAPS", "ACCOUNT_CHOOSER", "MULTILOGIN", "multi_login",
                         "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID"]
            } else { return nil }
            guard names.contains(cookie.name) else { return nil }
            return Cookie(domain: domain, path: cookie.path, name: cookie.name,
                          digest: Data(SHA256.hash(data: Data(cookie.value.utf8))))
        })
    }
}

@MainActor final class FavouriteSessionObserver: NSObject, WKHTTPCookieStoreObserver {
    let profileID: UUID
    weak var previews: FavouritePreviews?
    let store: WKHTTPCookieStore
    private var fingerprint: FavouriteSessionFingerprint?
    private var update: Task<Void, Never>?
    private var dirty = false
    init(profileID: UUID, previews: FavouritePreviews, store: WKHTTPCookieStore? = nil) {
        self.profileID = profileID; self.previews = previews
        self.store = store ?? ProfileManager.dataStore(for: profileID).httpCookieStore
        super.init(); self.store.add(self)
        refresh()
    }
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    func refresh() {
        dirty = true
        guard update == nil else { return }
        // Serialize/coalesce reads so an older callback cannot overwrite newer proof.
        update = Task { @MainActor [weak self] in
            guard let self else { return }
            while dirty && !Task.isCancelled {
                dirty = false
                let values = await withCheckedContinuation { continuation in
                    store.getAllCookies { continuation.resume(returning: $0) }
                }
                let next = FavouriteSessionFingerprint(values)
                guard !Task.isCancelled else { return }
                let changed = fingerprint.map { $0 != next } ?? false
                fingerprint = next
                if changed { previews?.sessionChanged(profileID: profileID) }
            }
            update = nil
        }
    }
    func ready() async { await update?.value }
    func synchronize() async -> FavouriteSessionFingerprint? {
        refresh()
        await ready()
        return fingerprint
    }
    func detach() { store.remove(self); update?.cancel(); update = nil }
}

@MainActor private final class FavouriteIdentityProbe {
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    private func finish(_ value: String?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: value?.isEmpty == false ? value : nil)
    }
    static func extraction(_ web: WKWebView, service: FavouritePreviewService) async -> FavouritePreviewResult {
        let adapter = DOMFavouritePreviewAdapter(service: service)
        guard let raw = await read(web, script: "JSON.stringify(\(adapter.script))"),
              let value = try? JSONDecoder().decode(FavouritePreviewExtraction.self, from: Data(raw.utf8)) else { return .unavailable }
        return adapter.parse(value)
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
        host?.orderOut(nil); host?.contentView = nil; host?.close(); host = nil; web = nil
        context = nil; reads = 0
        let pending = continuation; continuation = nil; pending?.resume(returning: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if webView === web { extract() } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === web { finish(.unavailable) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === web { finish(.unavailable) } }
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
        guard Self.acceptsResponse(isMainFrame: response.isForMainFrame,
                                   canShowMIMEType: response.canShowMIMEType,
                                   statusCode: (response.response as? HTTPURLResponse)?.statusCode) else {
            decisionHandler(.cancel); finish(.unavailable); return
        }
        decisionHandler(.allow)
    }
    static func acceptsResponse(isMainFrame: Bool, canShowMIMEType: Bool, statusCode: Int?) -> Bool {
        // Auxiliary frames (including Google's cookie rotation page) can fail while
        // the main service document remains readable. Only that document owns the load.
        !isMainFrame || (canShowMIMEType && (statusCode.map { (200..<400).contains($0) } ?? true))
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
