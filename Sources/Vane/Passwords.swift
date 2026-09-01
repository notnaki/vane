import AppKit
import Security
import WebKit

/// Credentials live in the macOS login keychain as ordinary Internet passwords.
/// ponytail: no vault format, no crypto, no management UI — Keychain Access.app already
/// lists, edits and deletes kSecClassInternetPassword items, and the login keychain is
/// already unlocked by the user's login.
enum Passwords {
    /// ponytail: local items only. Add kSecAttrSynchronizable once the app has a real
    /// Developer ID, and they ride iCloud Keychain to the user's other machines.
    /// 'Vane' as an OSType. Stamped on save and required on every read, so Vane can only
    /// ever see credentials Vane created. Without it the query matches any app's item for
    /// that host — your `gh` login, Safari's, a password manager's — and macOS puts up a
    /// "vane wants to use your confidential information" panel for a secret we have no
    /// business reading.
    private static let creator: NSNumber = 0x5661_6E65

    /// The profile discriminator. kSecAttrSecurityDomain is a free-text attribute that is
    /// part of an Internet password's primary key, so two profiles can hold the same
    /// host+account without colliding.
    ///
    /// The default profile deliberately writes *no* security domain: that is exactly what
    /// every item saved before profiles existed looks like, so those items keep resolving
    /// with no migration pass over the keychain.
    private static func domain(_ profileID: UUID) -> String? {
        profileID == ProfileManager.defaultID ? nil : "vane-" + profileID.uuidString.lowercased()
    }

    private static func query(host: String, account: String? = nil,
                              profileID: UUID) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrCreator as String: creator,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        if let d = domain(profileID) { q[kSecAttrSecurityDomain as String] = d }
        return q
    }

    static func save(host: String, account: String, password: String,
                     profileID: UUID = ProfileManager.activeProfileID) {
        SecItemDelete(query(host: host, account: account, profileID: profileID) as CFDictionary)
        var add = query(host: host, account: account, profileID: profileID)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "\(host) (Vane)"
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Nil when nothing is stored. With several accounts for one host this returns the
    /// first; a picker is the upgrade path, not something to build before it is needed.
    static func lookup(host: String,
                       profileID: UUID = ProfileManager.activeProfileID) -> (account: String, password: String)? {
        var q = query(host: host, profileID: profileID)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        // The default profile's query carries no security domain, so it would otherwise also
        // match another profile's item for the same host.
        if profileID == ProfileManager.defaultID,
           let d = item[kSecAttrSecurityDomain as String] as? String, !d.isEmpty { return nil }
        return (account, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func delete(host: String, account: String,
                       profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        SecItemDelete(query(host: host, account: account, profileID: profileID) as CFDictionary) == errSecSuccess
    }

    /// Every credential belonging to one profile, for when that profile is deleted.
    /// A non-default profile is one SecItemDelete against its security domain. The default
    /// profile has no domain to key on, so its items are enumerated and the ones carrying
    /// somebody else's domain are skipped.
    static func deleteAll(profileID: UUID) {
        if let d = domain(profileID) {
            SecItemDelete([
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrCreator as String: creator,
                kSecAttrSecurityDomain as String: d,
            ] as CFDictionary)
            return
        }
        var out: CFTypeRef?
        let all: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: creator,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        guard SecItemCopyMatching(all as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return }
        for item in items {
            let d = item[kSecAttrSecurityDomain as String] as? String ?? ""
            guard d.isEmpty, let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { continue }
            delete(host: host, account: account, profileID: profileID)
        }
    }
}

/// A save offer waiting on the user. Held only until they answer.
struct PendingSave: Equatable {
    let host: String
    let account: String
    let password: String
}

enum Autofill {
    /// Injected at document end, main frame only — a password field inside a cross-origin
    /// iframe is not ours to touch.
    static let script = """
    (function () {
      // React and friends install their own value setter; assigning .value directly updates
      // the DOM but not the component state, and the site then submits an empty field.
      function setValue(el, v) {
        var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
        if (d && d.set) { d.set.call(el, v); } else { el.value = v; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      // The username is the last text-ish input before the password field.
      function pair(root) {
        var pw = root.querySelector('input[type=password]');
        if (!pw) { return null; }
        var inputs = Array.prototype.slice.call(root.querySelectorAll('input'));
        var user = null;
        for (var i = inputs.indexOf(pw) - 1; i >= 0; i--) {
          var t = (inputs[i].type || 'text').toLowerCase();
          if (t === 'text' || t === 'email' || t === 'tel') { user = inputs[i]; break; }
        }
        return { user: user, pass: pw };
      }
      function offer() {
        var p = pair(document);
        if (!p || !p.pass.value) { return; }
        webkit.messageHandlers.vanepw.postMessage({
          account: p.user ? p.user.value : '',
          password: p.pass.value
        });
      }
      document.addEventListener('submit', offer, true);
      // Plenty of logins never fire submit — a button posts via fetch and then navigates.
      // pagehide catches those. ponytail: best effort; a site that logs in without any
      // navigation at all still slips through.
      window.addEventListener('pagehide', offer);
      window.__vaneFill = function (account, password) {
        var p = pair(document);
        if (!p) { return false; }
        if (p.user && account) { setValue(p.user, account); }
        setValue(p.pass, password);
        return true;   // never auto-submit
      };
    })();
    """

    static func fillJS(account: String, password: String) -> String {
        let args = try! JSONSerialization.data(withJSONObject: [account, password])
        return "window.__vaneFill && window.__vaneFill.apply(null, \(String(decoding: args, as: UTF8.self)))"
    }
}

/// WKUserContentController retains its handlers, and the handler here is the Tab that owns
/// the web view that owns the controller. Break the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// `vane selfcheck` — the runnable check. Round-trips the keychain, then drives the injected
/// script against a real form in a real https origin: fill it, read the values back, submit
/// it, and confirm the offer comes back up. Fails loudly if any link in that chain breaks.
@MainActor enum SelfCheck {
    private static var web: WKWebView?
    private static var holder: NSWindow?
    private static var bridge: Bridge?

    private static let host = "vane-selftest.invalid"
    private static let user = "ada@example.com"
    private static let pass = "correct horse battery staple"

    private static let page = """
    <!doctype html><meta charset=utf-8><body>
    <form id=f>
      <input type=text name=other value=decoy>
      <input type=email id=u name=email>
      <input type=password id=p name=password>
      <button type=submit>Sign in</button>
    </form>
    <script>
      // Stand in for a React-style controlled input: the component state only follows the
      // native value setter plus an input event, never a bare .value assignment.
      var state = { u: '', p: '' };
      document.getElementById('u').addEventListener('input', function (e) { state.u = e.target.value; });
      document.getElementById('p').addEventListener('input', function (e) { state.p = e.target.value; });
      document.getElementById('f').addEventListener('submit', function (e) { e.preventDefault(); });
      window.__state = function () { return JSON.stringify(state); };
    </script></body>
    """

    /// `--pure` stops before anything that needs a keychain ACL or a window server, so the
    /// logic can be proved on a headless CI box. The rest still runs locally, where a real
    /// signed bundle is what makes the keychain assertions meaningful.
    static func run(pureOnly: Bool = false) -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ok    " : "  FAIL  ") + name)
            if !ok { failures += 1 }
        }

        print("store")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-selfcheck-\(ProcessInfo.processInfo.processIdentifier).db")
        try? FileManager.default.removeItem(at: dir)
        let store = Store(path: dir.path)
        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b")!
        store.record(urlA, title: "")
        store.retitle(urlA, title: "Alpha")
        store.record(urlA, title: "Alpha")
        store.record(urlB, title: "Beta")
        check("visits collapse to one row per url", store.recent().count == 2)
        check("title backfills onto an untitled visit", store.recent().first { $0.url == urlA.absoluteString }?.title == "Alpha")
        check("suggest ranks the more-visited url first", store.suggest("example").first?.url == urlA.absoluteString)
        check("a one-character query suggests nothing", store.suggest("e").isEmpty)
        check("bookmark toggles on", store.toggleBookmark(urlB, title: "Beta") == true)
        check("bookmark reads back", store.isBookmarked(urlB))
        check("bookmarked url sorts above history", store.suggest("example").first?.bookmarked == true)
        check("bookmarked url is not also listed as history", store.suggest("example").count == 2)
        check("bookmark toggles off", store.toggleBookmark(urlB, title: "Beta") == false)
        // A literal % in a stored title must not turn the query into a match-everything wildcard.
        store.record(URL(string: "https://example.com/pct")!, title: "100% pure")
        check("LIKE wildcards in the query are escaped", store.suggest("100%").count == 1)
        // Bulk path: real timestamps, not insertion order. Clear first — the rows above are
        // stamped Date.now and would outrank any fixture date.
        store.clearHistory()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        store.record([(URL(string: "https://old.example")!, "Old", old),
                      (URL(string: "https://new.example")!, "New", new)])
        let ordered = store.recent().prefix(2).map(\.url)
        check("bulk insert keeps real visit dates, not insertion order",
              ordered.first == "https://new.example")

        check("bulk bookmarks add", store.addBookmarks([(urlA, "Alpha"), (urlB, "Beta")]) == 2)
        check("re-importing bookmarks adds nothing and deletes nothing",
              store.addBookmarks([(urlA, "Alpha"), (urlB, "Beta")]) == 0 && store.bookmarks().count == 2)

        // Guards the transaction. Per-row inserts are one fsync each; 20k of them took
        // minutes, which is why the importer used to cap at 5000 pages.
        let many = (0..<20_000).map {
            (URL(string: "https://bulk.example/\($0)")!, "Page \($0)", Date.now)
        }
        let began = Date.now
        store.record(many)
        let elapsed = Date.now.timeIntervalSince(began)
        check("20k visits insert in one transaction (took \(String(format: "%.2f", elapsed))s)",
              elapsed < 5 && store.recent(limit: 30_000).count > 20_000)

        check("clearHistory empties visits", { store.clearHistory(); return store.recent().isEmpty }())
        try? FileManager.default.removeItem(at: dir)

        for (label, block) in [("content blocker", Blocker.check), ("browser import", BrowserImport.check),
                               ("favicons + tabs", Favicons.check), ("url handling", URLHandling.check),
                               ("error pages", ErrorPage.check), ("site permissions", SitePermissions.check),
                               ("extensions", ExtensionHost.check),
                               ("profiles + spaces", ProfileManager.check),
                               ("search engines", Search.check),
                               ("certificate trust", CertificateTrust.check),
                               ("crash recovery", Crash.check),
                               ("reader", Reader.check)] {
            print(label)
            for (name, ok) in block() { check(name, ok) }
        }

        print("csv import")
        // Chrome's header, a password holding a comma and escaped quotes, and CRLF.
        let chrome = "name,url,username,password,note\r\n"
            + "GitHub,https://github.com/login,ada,\"pa,ss\"\"word\",\r\n"
        if let r = try? PasswordImport.parse(chrome) {
            check("chrome export parses", r.entries.count == 1)
            check("host is taken from the url", r.entries.first?.host == "github.com")
            check("comma and escaped quote survive", r.entries.first?.password == "pa,ss\"word")
        } else { check("chrome export parses", false) }

        // Safari's header capitalisation, a bare host, and a newline inside a password.
        let safari = "Title,URL,Username,Password,Notes\n"
            + "Bank,bank.example.com,ada@example.com,\"two\nlines\",\n"
            + "Empty,https://nope.example.com,ada,,\n"
        if let r = try? PasswordImport.parse(safari) {
            check("safari export parses", r.entries.count == 1)
            check("bare host without a scheme resolves", r.entries.first?.host == "bank.example.com")
            check("newline inside a quoted password survives", r.entries.first?.password == "two\nlines")
            check("row with no password is skipped, not imported blank", r.skipped == 1)
        } else { check("safari export parses", false) }

        // Firefox quotes every header cell; the field names still match.
        let firefox = "\"url\",\"username\",\"password\",\"httpRealm\"\n"
            + "\"https://mozilla.org\",\"ada\",\"hunter2\",\"\"\n"
        check("firefox export parses", (try? PasswordImport.parse(firefox))?.entries.count == 1)

        var rejected = false
        do { _ = try PasswordImport.parse("a,b,c\n1,2,3\n") } catch { rejected = true }
        check("a file with no password column is rejected, not half-imported", rejected)

        if pureOnly {
            print(failures == 0 ? "\nPASS (pure)" : "\n\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }

        print("keychain round-trip")
        Passwords.delete(host: host, account: user)
        Passwords.save(host: host, account: user, password: pass)
        let hit = Passwords.lookup(host: host)
        check("stored credential reads back", hit?.account == user && hit?.password == pass)
        Passwords.save(host: host, account: user, password: pass + "2")
        check("re-saving updates instead of duplicating", Passwords.lookup(host: host)?.password == pass + "2")
        check("delete removes it", Passwords.delete(host: host, account: user))
        check("lookup after delete is nil", Passwords.lookup(host: host) == nil)

        print("autofill script")
        let cfg = Tab.configuration()
        cfg.userContentController.addUserScript(
            WKUserScript(source: Autofill.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let b = Bridge()
        bridge = b
        cfg.userContentController.add(b, name: "vanepw")
        let w = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
        w.navigationDelegate = b
        web = w
        let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = w
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.orderFront(nil)
        holder = win

        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            print("  FAIL  timed out (a keychain access prompt will do this — re-run and allow)")
            exit(1)
        }

        b.onLoaded = {
            w.evaluateJavaScript(Autofill.fillJS(account: user, password: pass)) { filled, _ in
                check("fill reports a form was found", (filled as? Bool) == true)
                w.evaluateJavaScript("window.__state()") { state, _ in
                    let s = (state as? String) ?? ""
                    check("username reached component state", s.contains(user))
                    check("password reached component state", s.contains(pass))
                    check("decoy text field was not mistaken for the username", !s.contains("decoy"))
                    w.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('submit', {bubbles:true}))") { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            check("submit offered the credential back to the app", b.offered?.0 == user && b.offered?.1 == pass)
                            print(failures == 0 ? "\nPASS" : "\n\(failures) FAILED")
                            exit(failures == 0 ? 0 : 1)
                        }
                    }
                }
            }
        }
        w.loadSimulatedRequest(URLRequest(url: URL(string: "https://\(host)/login")!), responseHTML: page)
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    private final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var offered: (String, String)?
        var onLoaded: (() -> Void)?
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { onLoaded?() }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let b = m.body as? [String: Any] else { return }
            offered = ((b["account"] as? String) ?? "", (b["password"] as? String) ?? "")
        }
    }
}
