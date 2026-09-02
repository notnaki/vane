import AppKit
import WebKit

/// HTTPS-only browsing. Every plain-http main-frame navigation is retried over https, and
/// when https genuinely is not on offer the tab stops on an interstitial instead of quietly
/// loading the page in the clear.
///
/// This is the other half of a promise Vane already makes: `Tab.secureHost` refuses to fill
/// or save a password on anything but https. A browser that will not autofill over http but
/// will happily render the login form over http is telling the user two different things. So
/// the default here is ON — off is a real preference, on is the one that agrees with the
/// rest of the app.
///
/// ponytail: no probing, no HSTS preload list, no "try https, silently fall back" like
/// Chrome's HTTPS-First. We upgrade and let WebKit fail; failing is the point, because a
/// silent fallback is exactly the downgrade this is meant to stop. Ceiling: the user pays
/// one connection timeout on a genuinely http-only host — see `check()`'s notes and the
/// timings in the harness.
@MainActor enum HTTPSOnly {

    /// Swapped out under `check()` so assertions never touch the user's real preferences.
    static var defaults: UserDefaults = .standard

    // MARK: - The preference

    /// ponytail: one global switch, not per profile like `Blocker.enabled`. "Some profiles
    /// browse in the clear" is not a thing anyone wants; the *exceptions* are what needs to
    /// be per profile, and they are. Upgrade path if that is ever wrong: the same
    /// `ProfileManager.defaultsKey` trick used below.
    static var enabled: Bool {
        get { defaults.object(forKey: "httpsOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "httpsOnly") }
    }

    // MARK: - Exceptions

    /// One key per profile holding a list of hosts, rather than one key per (profile, host)
    /// the way `CertificateTrust` does it. Per-profile isolation is then structural — there
    /// is no prefix sweep that could reach into another profile's keys — and deleting a
    /// profile is one `removeObject`.
    static let exceptionsKey = "httpsOnlyExceptions"

    private static func key(_ profileID: UUID) -> String {
        ProfileManager.defaultsKey(exceptionsKey, profileID)
    }

    static func exceptions(profileID: UUID = ProfileManager.activeProfileID) -> [String] {
        (defaults.array(forKey: key(profileID)) as? [String]) ?? []
    }

    static func isExcepted(host: String, profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        exceptions(profileID: profileID).contains(canonical(host))
    }

    /// Only ever called from the branch where the user clicked through the interstitial *and*
    /// then through the alert. Never inferred from a failure, a redirect, or a retry — the
    /// whole point of `CertificateTrust`'s discipline is that nothing but a person saying yes
    /// can write one of these.
    static func allow(host: String, profileID: UUID = ProfileManager.activeProfileID) {
        let h = canonical(host)
        guard !h.isEmpty else { return }
        var list = exceptions(profileID: profileID)
        guard !list.contains(h) else { return }
        list.append(h)
        defaults.set(list, forKey: key(profileID))
    }

    /// Exact host, never a suffix match: an exception for `example.com` must not cover
    /// `evil.example.com`, and forgetting one must not take the other down with it.
    static func forget(host: String, profileID: UUID = ProfileManager.activeProfileID) {
        let h = canonical(host)
        defaults.set(exceptions(profileID: profileID).filter { $0 != h }, forKey: key(profileID))
    }

    /// nil profile means every profile — what the "forget everything" menu item wants.
    static func forgetAll(profileID: UUID? = nil) {
        guard let profileID else {
            for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(exceptionsKey) {
                defaults.removeObject(forKey: k)
            }
            return
        }
        defaults.removeObject(forKey: key(profileID))
    }

    private static func canonical(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }

    // MARK: - The upgrade

    /// http → https, or nil when there is nothing to do: a scheme that is not http, a host
    /// with no certificate to have (loopback, LAN, mDNS), or a host the user has excepted.
    ///
    /// Pure in the sense that matters — no network, no alerts, no navigation — though it does
    /// read the stored exceptions. `enabled` is deliberately *not* consulted here; whether
    /// the feature is on is `decide`'s question, and keeping it out makes this assertable
    /// either way round.
    static func upgrade(_ url: URL, profileID: UUID = ProfileManager.activeProfileID) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        guard !isLocal(host) else { return nil }
        guard !isExcepted(host: host, profileID: profileID) else { return nil }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        // An explicit :80 survives the scheme change and points https at the cleartext port,
        // which never answers. Dropping it is the only reading of "upgrade this" that works.
        if c.port == 80 { c.port = nil }
        return c.url
    }

    /// Hosts where https is not a reasonable thing to ask for. This deliberately mirrors the
    /// locality test in `Search.scheme(for:)` — that function sends `localhost`, `127.0.0.1`
    /// and `192.168.1.1` to http on purpose, and it would be absurd for the address bar to
    /// choose http and this to immediately overrule it.
    ///
    /// ponytail: the logic is copied, not shared, because `Search`'s version is private and
    /// this file owns nothing over there. Ceiling: two copies of "is this a LAN address" that
    /// have to be changed together.
    static func isLocal(_ host: String) -> Bool {
        let h = canonical(host)
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "local" || h.hasSuffix(".local") { return true }         // mDNS / Bonjour
        if let v4 = ipv4(h) {
            switch (v4[0], v4[1]) {
            case (127, _): return true                                   // 127.0.0.0/8
            case (10, _): return true                                    // 10.0.0.0/8
            case (172, 16...31): return true                             // 172.16.0.0/12
            case (192, 168): return true                                 // 192.168.0.0/16
            case (169, 254): return true                                 // link-local, no cert ever
            default: return false
            }
        }
        if h.contains(":") {                                             // ipv6 literal
            if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }      // loopback
            if h.hasPrefix("fe80:") { return true }                      // link-local
            // fc00::/7 unique-local — the ipv6 answer to 10/8 and 192.168/16.
            if let first = h.split(separator: ":").first, first.count >= 2 {
                let p = first.prefix(2).lowercased()
                if p == "fc" || p == "fd" { return true }
            }
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else { return nil }
        return octets
    }

    // MARK: - The redirect loop

    /// The thing that actually goes wrong. A site that answers https with a 301 back to http
    /// turns naive "upgrade every http navigation" into an infinite bounce: we upgrade, it
    /// downgrades, we upgrade. So every upgrade is written down, and an http navigation to a
    /// host we *just* sent to https is not an upgrade candidate — it is proof that https on
    /// that host does not work, and it goes to the interstitial.
    /// When each host was last sent to https. Two different questions are asked of it, with
    /// two different windows — see `loopWindow` and `attemptHorizon`.
    ///
    /// ponytail: one map for the whole app, not one per tab. Two tabs opening the same http
    /// host inside ten seconds means the second one sees the first one's attempt and stops on
    /// the interstitial. Rare, recoverable (the interstitial offers the way through), and the
    /// alternative is threading a Tab identity through a policy function that has none.
    private static var attempts: [String: Date] = [:]

    /// Short on purpose. A redirect back to http comes back inside one round trip; a user who
    /// types the same http address again a minute later deserves a fresh attempt rather than
    /// being told forever that the site is broken.
    static let loopWindow: TimeInterval = 10

    /// How long an upgrade stays attributable to us. Longer than `loopWindow` because the
    /// other question — "did this https failure come from something we did?" — cannot be
    /// answered until the connection gives up, and giving up takes `upgradeTimeout`.
    static let attemptHorizon: TimeInterval = 60

    /// Measured, and the reason this exists: `http://93.184.215.14/` upgrades to https, and
    /// port 443 is silently dropped rather than refused, so URLSession's 60-second default
    /// runs all the way out. Sixty seconds of nothing is a hang, not an error. Fifteen is
    /// long enough for a slow handshake on a bad connection and short enough to still feel
    /// like a browser. ponytail: one constant, no adaptive anything.
    static let upgradeTimeout: TimeInterval = 15

    /// What the caller should load for an upgrade. The only reason this is not just
    /// `URLRequest(url:)` at the call site is the timeout.
    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = upgradeTimeout
        return r
    }

    /// The second loop, and the one that is easy to miss. `loadSimulatedRequest` — how the
    /// interstitial (and `ErrorPage`) gets rendered at the failing url — is a real navigation
    /// and comes straight back through `decidePolicyFor`. Without this latch, `.block` renders
    /// a page whose own load is blocked, which renders a page whose own load is blocked.
    /// Measured, not theorised: the harness caught it by never finding the link on the page.
    private static var showing: String?

    static func forgetLoopState() { attempts = [:]; showing = nil }

    private static func recentlyUpgraded(_ host: String, now: Date) -> Bool {
        guard let at = attempts[canonical(host)] else { return false }
        return now.timeIntervalSince(at) < loopWindow
    }

    private static func noteUpgrade(_ host: String, now: Date) {
        attempts = attempts.filter { now.timeIntervalSince($0.value) < attemptHorizon }
        attempts[canonical(host)] = now
    }

    /// The other half of "stop and ask". A redirect back to http is only one way https can
    /// be unavailable; the commoner one is that nothing answers on 443 at all. When an
    /// upgrade *we* made fails at the connection, the honest page to show is the same
    /// interstitial — otherwise the user gets "the secure connection failed" and no way to
    /// reach the exception, which is a dead end rather than a choice.
    ///
    /// Returns the original http url to show the interstitial for, or nil to let `ErrorPage`
    /// handle it as usual.
    static func downgradeOffer(after error: Error, url: URL,
                               profileID: UUID = ProfileManager.activeProfileID,
                               now: Date = .now) -> URL? {
        let e = error as NSError
        // Deliberately narrow. A bad *certificate* is `CertificateTrust`'s question and it
        // has a better answer than plaintext; a DNS failure means http will not work either;
        // an http status is not a connection failure at all.
        guard e.domain == NSURLErrorDomain,
              [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
               NSURLErrorSecureConnectionFailed, NSURLErrorNetworkConnectionLost].contains(e.code)
        else { return nil }
        guard url.scheme?.lowercased() == "https", let host = url.host,
              let at = attempts[canonical(host)], now.timeIntervalSince(at) < attemptHorizon,
              !isExcepted(host: host, profileID: profileID) else { return nil }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "http"
        guard let http = c.url else { return nil }
        showing = http.absoluteString      // the interstitial's own load must get through
        return http
    }

    // MARK: - The decision

    enum Decision: Equatable {
        /// Let WebKit get on with it.
        case allow
        /// Cancel and load this instead.
        case upgrade(URL)
        /// Cancel and show `interstitial(for:)` at this url. https is not available here.
        case block(URL)
        /// The interstitial's own "continue" link. Ask, and only then load this http url.
        case confirm(URL)
    }

    /// The whole policy, with the WebKit types factored out so it can be asserted offline.
    /// `now` is injected for the same reason.
    static func decide(url: URL?, isMainFrame: Bool,
                       profileID: UUID = ProfileManager.activeProfileID,
                       now: Date = .now) -> Decision {
        guard let url else { return .allow }
        // Answered before `enabled`: the sentinel only ever comes from a page we rendered
        // ourselves, and a user who has already clicked through it is owed the alert even if
        // they flipped the switch off in another window in the meantime.
        if let target = insecureTarget(url) { return .confirm(target) }
        // One shot, spent immediately: the interstitial we just asked for is allowed to load
        // at the url it is about, and nothing else is.
        if showing == url.absoluteString { showing = nil; return .allow }
        guard enabled, isMainFrame else { return .allow }
        guard let up = upgrade(url, profileID: profileID) else { return .allow }
        guard let host = url.host else { return .allow }
        // We already sent this host to https and here it is back on http. Stop.
        if recentlyUpgraded(host, now: now) {
            showing = url.absoluteString
            return .block(url)
        }
        noteUpgrade(host, now: now)
        return .upgrade(up)
    }

    /// ponytail: main frame only. Cancelling a subresource or an iframe would break the page
    /// with nowhere to put the explanation, and WebKit already blocks mixed content on an
    /// https page — which, once this is on, is every page.
    static func decide(_ action: WKNavigationAction,
                       profileID: UUID = ProfileManager.activeProfileID,
                       now: Date = .now) -> Decision {
        decide(url: action.request.url,
               isMainFrame: action.targetFrame?.isMainFrame ?? false,
               profileID: profileID, now: now)
    }

    // MARK: - The way back out

    /// The interstitial has no script bridge — it is loaded with `loadSimulatedRequest` into
    /// an ordinary web view. So "continue" is a navigation to a scheme nothing else claims,
    /// which comes straight back through `decide`.
    ///
    /// ponytail: a page could navigate itself here to raise the alert. It cannot get past it —
    /// the alert defaults to Go Back and the button that proceeds has no key equivalent, same
    /// as `CertificateTrust` — so the worst a hostile page buys is one modal it cannot answer.
    static let insecureScheme = "x-vane-insecure"

    /// Percent-encoded down to alphanumerics, so whatever the url contains is inert in every
    /// context the interstitial puts it in.
    static func sentinel(for url: URL) -> URL? {
        guard let body = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: insecureScheme + ":" + body)
    }

    static func insecureTarget(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == insecureScheme else { return nil }
        let body = url.absoluteString.dropFirst(insecureScheme.count + 1)
        guard let decoded = body.removingPercentEncoding,
              let target = URL(string: decoded),
              target.scheme?.lowercased() == "http" else { return nil }
        return target
    }

    /// The second gate. The interstitial was the first — its default action is Go Back — so
    /// this is one alert rather than `CertificateTrust`'s two, and it keeps the same shape:
    /// Go Back is the default, the button that proceeds is destructive and has no key
    /// equivalent, so neither Return nor Escape can reach it.
    ///
    /// Returns whether to load, and is the *only* thing in this file that writes an exception.
    @discardableResult
    static func confirmAndRemember(_ url: URL,
                                   profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        guard let host = url.host else { return false }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Load “\(host)” without encryption?"
        alert.informativeText = """
            This site does not answer over https, so everything between you and it travels in \
            the clear: anyone on the same network, and every network in between, can read what \
            you send and change what comes back.

            Vane will stop upgrading this one site until you forget it. Every other site keeps \
            its https-only protection, and Vane will still refuse to fill a saved password here.
            """
        alert.addButton(withTitle: "Go Back")
        let proceed = alert.addButton(withTitle: "Load Insecurely")
        proceed.keyEquivalent = ""
        proceed.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        allow(host: host, profileID: profileID)
        return true
    }

    // MARK: - The interstitial

    /// Same visual language as `ErrorPage.html` — same tokens, same type, same card — because
    /// they are the same kind of moment and should not look like two different browsers.
    /// The order of the actions is the message: Go Back is the button, continuing is a line
    /// of muted text underneath it.
    static func interstitial(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let shown = url.absoluteString
        let go = sentinel(for: url)?.absoluteString ?? ""
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(host)) doesn’t support https</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #ffffff; --fg: #1c1c1e; --dim: #6b6b70;
            --line: #e3e3e6; --card: #f7f7f8;
            --accent: #0a6cff; --accent-fg: #ffffff;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #16171a; --fg: #ececf0; --dim: #9a9aa2;
              --line: #2c2d32; --card: #1e1f23;
              --accent: #3b86ff; --accent-fg: #08131f;
            }
          }
          html, body { height: 100%; }
          body {
            margin: 0; background: var(--bg); color: var(--fg);
            font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            display: flex; align-items: center; justify-content: center;
            padding: 32px; box-sizing: border-box;
          }
          main { max-width: 30rem; width: 100%; }
          h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 .6rem; letter-spacing: -.02em; }
          p { margin: 0 0 1.25rem; color: var(--dim); }
          .url {
            display: block; background: var(--card); border: 1px solid var(--line);
            border-radius: 8px; padding: .6rem .75rem; margin: 0 0 1.5rem;
            font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            color: var(--fg); word-break: break-all;
          }
          button {
            font: inherit; font-weight: 500; color: var(--accent-fg);
            background: var(--accent); border: 0; border-radius: 8px;
            padding: .5rem 1.1rem; cursor: pointer;
          }
          button:active { opacity: .8; }
          .risky { display: block; margin-top: 1.5rem; font-size: 13px; color: var(--dim); }
          .risky a { color: var(--dim); }
          .code { margin-top: 1.75rem; font-size: 11px; color: var(--dim);
                  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        </style>
        </head><body><main>
          <h1>This site doesn’t support a secure connection</h1>
          <p>Vane asked \(escape(host)) for an encrypted connection and did not get one — it
             either sent Vane back to plain http or never answered on the secure port.
             Everything you send here, and everything you read here, would travel in the clear,
             where anyone on the network between you and it can read it or change it on the
             way.</p>
          <code class="url">\(escape(shown))</code>
          <button onclick="history.back()">Go Back</button>
          <span class="risky">Sure it’s safe?
            <a href="\(escape(go))">Continue to the insecure site</a> —
            Vane will ask once more, and will remember your answer for \(escape(host)) only.</span>
          <div class="code">HTTPS-only mode</div>
        </main></body></html>
        """
    }

    /// Same escaping as `ErrorPage`. The only thing interpolated into an attribute is the
    /// sentinel, which is already percent-encoded to alphanumerics before it gets here.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - check

    /// Offline. Runs against a throwaway defaults suite that is deleted afterwards, so the
    /// user's real preference and exceptions are neither read nor written, and nothing here
    /// opens a socket, a window or an alert.
    static func check() -> [(String, Bool)] {
        let suite = "vane.httpsonly.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        let realAttempts = attempts
        forgetLoopState()
        defer {
            defaults = real
            attempts = realAttempts
            scratch.removePersistentDomain(forName: suite)
        }

        let p = ProfileManager.defaultID
        let other = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        func u(_ s: String) -> URL { URL(string: s)! }
        func up(_ s: String) -> String { upgrade(u(s), profileID: p)?.absoluteString ?? "<nil>" }

        var out: [(String, Bool)] = [
            ("an ordinary http url upgrades", up("http://example.com/a?b=1#c")
                == "https://example.com/a?b=1#c"),
            ("a bare http host upgrades", up("http://example.com") == "https://example.com"),
            ("an explicit :80 is dropped, not carried to https",
             up("http://example.com:80/x") == "https://example.com/x"),
            ("a non-default port is kept", up("http://example.com:8080/x")
                == "https://example.com:8080/x"),
            ("userinfo and the query survive the rewrite",
             up("http://a:b@example.com/p?q=1%20a") == "https://a:b@example.com/p?q=1%20a"),
            ("an already-https url is left alone", up("https://example.com") == "<nil>"),
            ("localhost is left alone", up("http://localhost:3000/x") == "<nil>"),
            ("a .localhost subdomain is left alone", up("http://api.localhost/x") == "<nil>"),
            ("127.0.0.1 is left alone", up("http://127.0.0.1:8080") == "<nil>"),
            ("the rest of 127/8 is left alone", up("http://127.13.0.9") == "<nil>"),
            ("10/8 is left alone", up("http://10.0.0.5") == "<nil>"),
            ("172.16/12 is left alone", up("http://172.16.4.1") == "<nil>"),
            ("the far end of 172.16/12 is left alone", up("http://172.31.255.254") == "<nil>"),
            ("172.15 and 172.32 are NOT private and do upgrade",
             up("http://172.15.0.1") == "https://172.15.0.1"
             && up("http://172.32.0.1") == "https://172.32.0.1"),
            ("192.168/16 is left alone", up("http://192.168.1.1") == "<nil>"),
            ("169.254/16 link-local is left alone", up("http://169.254.1.1") == "<nil>"),
            ("the ipv6 loopback is left alone", up("http://[::1]:8080/x") == "<nil>"),
            ("ipv6 unique-local is left alone", up("http://[fd00::1]/x") == "<nil>"),
            ("a .local mDNS name is left alone", up("http://printer.local/setup") == "<nil>"),
            ("a name merely ending in 'local' still upgrades",
             up("http://mylocal.com") == "https://mylocal.com"),
            ("a public ip literal does upgrade", up("http://93.184.216.34/") == "https://93.184.216.34/"),
            ("a non-http scheme is left alone", up("about:blank") == "<nil>"),
            ("file: is left alone", up("file:///tmp/x.html") == "<nil>"),
            ("mailto: is left alone", up("mailto:ada@example.com") == "<nil>"),
            ("data: is left alone", up("data:text/html,hi") == "<nil>"),
            ("an http url with no host is left alone", up("http:///nohost") == "<nil>"),
            ("the scheme test is case-insensitive", up("HTTP://Example.com") == "https://Example.com"),
        ]

        // Exceptions: round trip, exactness, and the per-profile wall.
        out.append(("an unvisited host has no exception", isExcepted(host: "old.example", profileID: p) == false))
        allow(host: "old.example", profileID: p)
        out.append(("an exception reads back", isExcepted(host: "old.example", profileID: p)))
        out.append(("host matching is case-insensitive", isExcepted(host: "OLD.example", profileID: p)))
        out.append(("an excepted host stops upgrading", up("http://old.example/x") == "<nil>"))
        out.append(("an exception does not cover a subdomain",
                    isExcepted(host: "evil.old.example", profileID: p) == false
                    && up("http://evil.old.example") == "https://evil.old.example"))
        out.append(("an exception does not cover a host that merely ends the same way",
                    isExcepted(host: "notold.example", profileID: p) == false))
        out.append(("adding the same exception twice stores it once",
                    { allow(host: "old.example", profileID: p); return exceptions(profileID: p).count == 1 }()))
        out.append(("an exception in one profile does NOT apply in another",
                    isExcepted(host: "old.example", profileID: other) == false))
        out.append(("the other profile still upgrades that host",
                    upgrade(u("http://old.example"), profileID: other)?.absoluteString
                        == "https://old.example"))
        allow(host: "other.example", profileID: other)
        forget(host: "old.example", profileID: p)
        out.append(("forget(host:) drops that exception", isExcepted(host: "old.example", profileID: p) == false))
        out.append(("forget(host:) leaves the other profile alone",
                    isExcepted(host: "other.example", profileID: other)))
        allow(host: "a.example", profileID: p)
        allow(host: "b.example", profileID: p)
        forgetAll(profileID: p)
        out.append(("forgetAll(profileID:) empties that profile", exceptions(profileID: p).isEmpty))
        out.append(("forgetAll(profileID:) leaves other profiles alone",
                    isExcepted(host: "other.example", profileID: other)))
        forgetAll()
        out.append(("forgetAll() empties every profile",
                    exceptions(profileID: p).isEmpty && exceptions(profileID: other).isEmpty))

        // The preference.
        out.append(("https-only defaults to on, agreeing with password autofill", enabled))
        enabled = false
        out.append(("turning it off persists", enabled == false))
        out.append(("with it off, nothing is upgraded",
                    decide(url: u("http://example.com"), isMainFrame: true, profileID: p) == .allow))
        out.append(("upgrade() still answers with it off, because the switch is decide()'s job",
                    up("http://example.com") == "https://example.com"))
        enabled = true

        // decide(): the frame rule and the plain cases.
        forgetLoopState()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        out.append(("a main-frame http navigation is upgraded",
                    decide(url: u("http://example.com/"), isMainFrame: true, profileID: p, now: t0)
                        == .upgrade(u("https://example.com/"))))
        forgetLoopState()
        out.append(("a subframe is left alone",
                    decide(url: u("http://ads.example/"), isMainFrame: false, profileID: p, now: t0) == .allow))
        out.append(("an https navigation is allowed",
                    decide(url: u("https://example.com/"), isMainFrame: true, profileID: p, now: t0) == .allow))
        out.append(("localhost is allowed, not upgraded and not blocked",
                    decide(url: u("http://localhost:3000/"), isMainFrame: true, profileID: p, now: t0) == .allow))
        out.append(("a nil url is allowed rather than crashing",
                    decide(url: nil, isMainFrame: true, profileID: p, now: t0) == .allow))

        // The loop hazard. A site that answers https with a redirect back to http.
        forgetLoopState()
        let first = decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p, now: t0)
        let bounce = decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p,
                            now: t0.addingTimeInterval(0.4))
        out.append(("the first http hit at a host is upgraded",
                    first == .upgrade(u("https://loop.example/"))))
        out.append(("https bouncing straight back to http is BLOCKED, not upgraded again",
                    bounce == .block(u("http://loop.example/"))))
        out.append(("the bounce is detected across paths too, not just the identical url",
                    decide(url: u("http://loop.example/landing"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(0.6)) == .block(u("http://loop.example/landing"))))
        out.append(("a different host in the same moment is unaffected",
                    decide(url: u("http://fine.example/"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(0.5)) == .upgrade(u("https://fine.example/"))))
        out.append(("after the window closes the host gets a fresh attempt",
                    decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(loopWindow + 1))
                        == .upgrade(u("https://loop.example/"))))

        // The second loop: rendering the interstitial is itself a navigation to that same
        // http url, and it must not be blocked in turn.
        forgetLoopState()
        _ = decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p, now: t0)
        let stop = decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p,
                          now: t0.addingTimeInterval(0.2))
        out.append(("blocking arms the interstitial's own load", stop == .block(u("http://loop.example/"))))
        out.append(("the interstitial's simulated request is let through, not blocked again",
                    decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(0.21)) == .allow))
        out.append(("the pass is one shot — the next real navigation blocks again",
                    decide(url: u("http://loop.example/"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(0.22)) == .block(u("http://loop.example/"))))
        out.append(("the pass is for that exact url only",
                    decide(url: u("http://loop.example/elsewhere"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(0.23)) == .block(u("http://loop.example/elsewhere"))))

        // The case that would false-positive a naive detector: the upgraded url legitimately
        // redirects somewhere else first, and only that third host comes back as http.
        forgetLoopState()
        let a = decide(url: u("http://a.example/"), isMainFrame: true, profileID: p, now: t0)
        // https://a.example → https://b.example: never seen as http, so nothing to decide.
        let viaHTTPS = decide(url: u("https://b.example/"), isMainFrame: true, profileID: p,
                              now: t0.addingTimeInterval(0.2))
        // …which then sends us to http://b.example. b was never upgraded, so upgrade it once.
        let b = decide(url: u("http://b.example/"), isMainFrame: true, profileID: p,
                       now: t0.addingTimeInterval(0.3))
        let bBounce = decide(url: u("http://b.example/"), isMainFrame: true, profileID: p,
                             now: t0.addingTimeInterval(0.4))
        out.append(("a hop through another https host is not mistaken for a loop",
                    a == .upgrade(u("https://a.example/")) && viaHTTPS == .allow
                    && b == .upgrade(u("https://b.example/"))))
        out.append(("only the host that actually came back on http is blocked",
                    bBounce == .block(u("http://b.example/"))))
        out.append(("blocking one host in a chain leaves the earlier hop unblocked",
                    { attempts["a.example"] = nil
                      return decide(url: u("http://a.example/"), isMainFrame: true, profileID: p,
                                    now: t0.addingTimeInterval(0.5))
                          == .upgrade(u("https://a.example/")) }()))
        // An excepted host must never reach the loop detector at all — it is .allow forever.
        forgetLoopState()
        allow(host: "kept.example", profileID: p)
        out.append(("an excepted host is allowed twice running, never blocked",
                    decide(url: u("http://kept.example/"), isMainFrame: true, profileID: p, now: t0) == .allow
                    && decide(url: u("http://kept.example/"), isMainFrame: true, profileID: p,
                              now: t0.addingTimeInterval(0.1)) == .allow))
        forgetAll()

        // An https attempt that fails at the connection, rather than redirecting back down.
        func fail(_ code: Int, _ domain: String = NSURLErrorDomain) -> NSError {
            NSError(domain: domain, code: code, userInfo: [:])
        }
        forgetLoopState()
        _ = decide(url: u("http://dead.example/x"), isMainFrame: true, profileID: p, now: t0)
        let offered = downgradeOffer(after: fail(NSURLErrorTimedOut), url: u("https://dead.example/x"),
                                     profileID: p, now: t0.addingTimeInterval(upgradeTimeout))
        out.append(("a timeout on a host we upgraded offers the original http url back",
                    offered == u("http://dead.example/x")))
        out.append(("the offer outlives the loop window — it cannot land before the timeout does",
                    upgradeTimeout > loopWindow && attemptHorizon > upgradeTimeout))
        out.append(("the offer arms the interstitial's own load",
                    decide(url: u("http://dead.example/x"), isMainFrame: true, profileID: p,
                           now: t0.addingTimeInterval(upgradeTimeout)) == .allow))
        out.append(("a refused connection also offers it",
                    downgradeOffer(after: fail(NSURLErrorCannotConnectToHost),
                                   url: u("https://dead.example/x"), profileID: p,
                                   now: t0.addingTimeInterval(1)) != nil))
        out.append(("a failed tls handshake also offers it",
                    downgradeOffer(after: fail(NSURLErrorSecureConnectionFailed),
                                   url: u("https://dead.example/x"), profileID: p,
                                   now: t0.addingTimeInterval(1)) != nil))
        out.append(("a bad CERTIFICATE does not — that is CertificateTrust's question, and it "
                    + "has a better answer than plaintext",
                    downgradeOffer(after: fail(NSURLErrorServerCertificateUntrusted),
                                   url: u("https://dead.example/x"), profileID: p,
                                   now: t0.addingTimeInterval(1)) == nil))
        out.append(("a dns failure does not — http would not resolve either",
                    downgradeOffer(after: fail(NSURLErrorCannotFindHost),
                                   url: u("https://dead.example/x"), profileID: p,
                                   now: t0.addingTimeInterval(1)) == nil))
        out.append(("an https failure on a host we never upgraded offers nothing",
                    downgradeOffer(after: fail(NSURLErrorTimedOut), url: u("https://other.example/"),
                                   profileID: p, now: t0.addingTimeInterval(1)) == nil))
        out.append(("an http failure offers nothing — there is nothing to fall back to",
                    downgradeOffer(after: fail(NSURLErrorTimedOut), url: u("http://dead.example/x"),
                                   profileID: p, now: t0.addingTimeInterval(1)) == nil))
        out.append(("the offer expires with the attempt",
                    downgradeOffer(after: fail(NSURLErrorTimedOut), url: u("https://dead.example/x"),
                                   profileID: p, now: t0.addingTimeInterval(attemptHorizon + 1)) == nil))
        allow(host: "dead.example", profileID: p)
        out.append(("an excepted host is never offered a downgrade it already has",
                    downgradeOffer(after: fail(NSURLErrorTimedOut), url: u("https://dead.example/x"),
                                   profileID: p, now: t0.addingTimeInterval(1)) == nil))
        forgetAll()
        out.append(("an upgraded request carries a shorter leash than the 60s default",
                    request(u("https://x.example")).timeoutInterval == upgradeTimeout))

        // The way back out.
        let target = u("http://plain.example/a?b=1&c=2")
        let s = sentinel(for: target)!
        out.append(("the sentinel round-trips the exact url", insecureTarget(s) == target))
        out.append(("the sentinel is inert — nothing but alphanumerics after the colon",
                    s.absoluteString.dropFirst(insecureScheme.count + 1)
                        .allSatisfy { $0.isLetter || $0.isNumber || $0 == "%" }))
        out.append(("a sentinel navigation asks rather than loading",
                    decide(url: s, isMainFrame: true, profileID: p, now: t0) == .confirm(target)))
        out.append(("a sentinel wrapping a non-http url is refused",
                    insecureTarget(u(insecureScheme + ":" + "https%3A%2F%2Fx.example")) == nil))
        out.append(("a sentinel with junk in it is refused",
                    insecureTarget(u(insecureScheme + ":%%%")) == nil))
        out.append(("an ordinary url is not mistaken for a sentinel",
                    insecureTarget(u("http://example.com")) == nil))

        // The interstitial. Two layers between a hostile address and the markup: Foundation
        // percent-encodes what is not legal in a url (angle brackets, quotes), and `escape`
        // catches what is legal and still meaningful in HTML — `&` above all, which would
        // otherwise break the continue link as well as being wrong.
        let hostile = URL(string: "http://evil.example/\"><script>alert(1)</script>?a=1&b=2",
                          encodingInvalidCharacters: true)!
        let page = interstitial(for: hostile)
        out.append(("the interstitial names the host", page.contains("evil.example")))
        out.append(("the interstitial says https is not supported",
                    page.contains("doesn’t support a secure connection")))
        out.append(("the interstitial adapts to dark mode", page.contains("prefers-color-scheme: dark")))
        out.append(("Go Back is the button", page.contains(">Go Back</button>")))
        out.append(("continuing is offered, worded as the risk it is",
                    page.contains("Continue to the insecure site")))
        out.append(("continuing is NOT the default action — it is a link under the button",
                    page.range(of: ">Go Back</button>")!.lowerBound
                        < page.range(of: "Continue to the insecure site")!.lowerBound))
        out.append(("a hostile url lands in the page as text, never as a tag",
                    !page.contains("<script>alert(1)</script>") && !page.contains("<script")
                    && page.contains("%3Cscript%3E")))
        out.append(("the ampersands in the url are escaped rather than left raw",
                    page.contains("a=1&amp;b=2") && !page.contains("a=1&b=2")))
        out.append(("the quote that would have closed the href never appears raw",
                    !page.contains("\">") || !page.contains("evil.example/\"")))
        out.append(("the continue link carries a sentinel for exactly this url",
                    page.contains(sentinel(for: hostile)!.absoluteString)))
        out.append(("nothing hostile survives into the link attribute",
                    !page.contains("href=\"\(insecureScheme):http://")))
        out.append(("the interstitial has no script block of its own", !page.contains("<script")))
        return out
    }
}
