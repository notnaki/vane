import AppKit
import LocalAuthentication
import Security
import WebKit

/// Credentials live in the macOS login keychain as ordinary Internet passwords.
/// ponytail: no vault format and no crypto — the login keychain is already unlocked by the
/// user's login and is already the right place for a password. Settings ▸ Passwords is the
/// management UI over it; Keychain Access.app still opens exactly the same items.
enum Passwords {
    /// One saved login as everything outside this file knows it: which site, which account.
    /// Deliberately *not* the password — a password is read one item at a time, at the
    /// moment something actually needs it, and is never held anywhere that outlives the use.
    struct Login: Identifiable, Hashable, Sendable {
        let host: String
        let account: String
        /// Host and account are the keychain's own primary key for the item, so they are
        /// also what "the same login" means everywhere else — last-used included.
        var id: String { Passwords.key(host: host, account: account) }
    }

    static func key(host: String, account: String) -> String { host + "\n" + account }

    /// ponytail: local items only. Add kSecAttrSynchronizable once the app has a real
    /// Developer ID, and they ride iCloud Keychain to the user's other machines.
    /// 'Vane' as an OSType. Stamped on save and required on every read, so Vane can only
    /// ever see credentials Vane created. Without it the query matches any app's item for
    /// that host — your `gh` login, Safari's, a password manager's — and macOS puts up a
    /// "vane wants to use your confidential information" panel for a secret we have no
    /// business reading.
    private static let creator: NSNumber = 0x5661_6E65

    /// The profile *and instance* discriminator. kSecAttrSecurityDomain is a free-text
    /// attribute that is part of an Internet password's primary key, so two profiles can
    /// hold the same host+account without colliding.
    ///
    /// The real app's default profile deliberately writes *no* security domain: that is
    /// exactly what every item saved before profiles existed looks like, so those items
    /// keep resolving with no migration pass over the keychain.
    ///
    /// A `VANE_DATA_DIR` instance instead namespaces *every* profile, off a hash of that
    /// directory — the same derivation `UserDefaults.vane`'s suite uses. A test instance
    /// therefore cannot read, overwrite or delete the real app's saved logins, and two test
    /// instances cannot see each other's: the domains never coincide.
    private static func domain(_ profileID: UUID) -> String? {
        namespace(profileID: profileID, dataDir: Store.overrideDirectory)
    }

    /// `domain` with the data directory passed in, so the isolation rule is provable
    /// headless — a process only ever has one `VANE_DATA_DIR`.
    static func namespace(profileID: UUID, dataDir: String?) -> String? {
        let profile = profileID == ProfileManager.defaultID
            ? "" : "-" + profileID.uuidString.lowercased()
        guard let dataDir else { return profile.isEmpty ? nil : "vane" + profile }
        return "vane-" + UserDefaults.suiteName(forDataDir: dataDir) + profile
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

    // MARK: Scope

    /// Whether an item carrying this security domain belongs to `scope`.
    ///
    /// The whole point of a separate function: "no security domain" is not expressible as a
    /// `SecItemCopyMatching` query, so a default-profile query matches *every* profile's and
    /// every test instance's item for the same host, and the narrowing has to be done by
    /// hand on the results. Getting it wrong fails open — you read, overwrite or delete
    /// somebody else's login — so it lives in one place and is asserted.
    static func owns(scope: String?, itemDomain: String?) -> Bool {
        scope == nil ? (itemDomain ?? "").isEmpty : itemDomain == scope
    }

    /// The persistent reference of the one item this profile owns for host+account.
    ///
    /// Everything that touches a single item goes through here, because a plain
    /// host+account query is exactly the one that fails open for the default profile.
    /// A persistent ref names *that* item and nothing else, so the read or the delete that
    /// follows cannot land on a neighbour.
    private static func ref(host: String, account: String, profileID: UUID) -> Data? {
        var q = query(host: host, account: account, profileID: profileID)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnPersistentRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return nil }
        let scope = domain(profileID)
        return items.first {
            owns(scope: scope, itemDomain: $0[kSecAttrSecurityDomain as String] as? String)
        }?[kSecValuePersistentRef as String] as? Data
    }

    // MARK: Reading and writing

    /// True when the credential is stored. It can fail: the keychain's primary key for an
    /// Internet password does not include the creator code, so another app's item for the
    /// same site and account collides with ours — the add is refused, and there is nothing
    /// of Vane's to update in its place. Silent failure there is a password the user
    /// believes is saved and is not.
    @discardableResult
    static func save(host: String, account: String, password: String,
                     profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        defer { invalidate() }
        // Add first, then update: a failed add must not leave the login gone. The add comes
        // back errSecDuplicateItem when one is already there, which is the signal to replace
        // its data in place — but only if that item is *ours*, which `ref` is what decides.
        var add = query(host: host, account: account, profileID: profileID)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "\(host) (Vane)"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem,
              let existing = ref(host: host, account: account, profileID: profileID)
        else { return false }
        return SecItemUpdate([kSecValuePersistentRef as String: existing] as CFDictionary,
                             [kSecValueData as String: Data(password.utf8)] as CFDictionary)
            == errSecSuccess
    }

    /// Nil when nothing is stored. With several accounts for one host this is the one the
    /// chooser would put first — see `matches`.
    static func lookup(host: String,
                       profileID: UUID = ProfileManager.activeProfileID) -> (account: String, password: String)? {
        guard let hit = matches(host: host, profileID: profileID).first,
              let secret = password(host: hit.host, account: hit.account, profileID: profileID)
        else { return nil }
        return (hit.account, secret)
    }

    /// Every saved login for one host, best first: whatever was filled here most recently,
    /// then the never-used ones alphabetically. More than one is what raises the chooser on
    /// the page; one keeps the old fill-and-go behaviour.
    ///
    /// Names only. The page needs to know *whether* there is a choice long before anything
    /// needs a password, and answering that must not decrypt anything.
    static func matches(host: String,
                        profileID: UUID = ProfileManager.activeProfileID) -> [Login] {
        rank(all(profileID: profileID).filter { $0.host == host },
             used: lastUsed(profileID: profileID))
    }

    /// One password, decrypted here and now. The only door to plaintext in the app; nothing
    /// caches what comes back out of it.
    static func password(host: String, account: String,
                         profileID: UUID = ProfileManager.activeProfileID) -> String? {
        guard let ref = ref(host: host, account: account, profileID: profileID) else { return nil }
        var out: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: ref,
            kSecReturnData as String: true,
        ] as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The order rule itself, taking its inputs rather than reading them, so it is provable
    /// headless. Ties on the same instant — two fills inside one clock tick — fall back to
    /// the alphabet rather than to whatever order the keychain handed the items over in.
    static func rank(_ logins: [Login], used: [String: Date]) -> [Login] {
        logins.sorted { a, b in
            switch (used[a.id], used[b.id]) {
            case let (x?, y?): x == y ? a.account < b.account : x > y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.account < b.account
            }
        }
    }

    /// Which logins this profile has — sites and usernames, no secrets. Lives here, beside
    /// `creator` and `owns`, because a second copy of that query elsewhere silently returns
    /// nothing, or somebody else's items, the day either of them changes.
    ///
    /// Read through a cache, and the cache holds *only* what this returns: the pane asks for
    /// the whole list on every keystroke in its search field, and a cache of decrypted
    /// passwords sitting in a process for its whole life is exactly what a password manager
    /// must not be. Any write through this file drops it; a change made outside Vane —
    /// Keychain Access, another instance — is picked up on the next launch. ponytail: that
    /// is the ceiling; the upgrade path is a keychain change notification.
    static func all(profileID: UUID = ProfileManager.activeProfileID) -> [Login] {
        cacheLock.lock()
        let hit = cached[profileID]
        cacheLock.unlock()
        if let hit { return hit }
        let fresh = fetch(profileID: profileID)
        cacheLock.lock()
        cached[profileID] = fresh
        cacheLock.unlock()
        return fresh
    }

    /// `nonisolated(unsafe)` plus an explicit lock, for the same reason `UserDefaults.vane`
    /// is: the keychain is reachable from any thread and this is only a read-through copy.
    private nonisolated(unsafe) static var cached: [UUID: [Login]] = [:]
    private static let cacheLock = NSLock()

    private static func invalidate() {
        cacheLock.lock()
        cached.removeAll()
        cacheLock.unlock()
    }

    private static func fetch(profileID: UUID) -> [Login] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: creator,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        let scope = domain(profileID)
        if let scope { q[kSecAttrSecurityDomain as String] = scope }

        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }

        return items.compactMap { item -> Login? in
            guard let host = item[kSecAttrServer as String] as? String,
                  owns(scope: scope, itemDomain: item[kSecAttrSecurityDomain as String] as? String)
            else { return nil }
            return Login(host: host, account: item[kSecAttrAccount as String] as? String ?? "")
        }.sorted { ($0.host, $0.account) < ($1.host, $1.account) }
    }

    @discardableResult
    static func delete(host: String, account: String,
                       profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        defer { invalidate(); forgetUse(host: host, account: account, profileID: profileID) }
        // By reference, not by host+account: the default profile's query also matches every
        // other profile's item for the same site, and a delete that hits one of those is a
        // login silently gone from a profile the user was not even looking at.
        guard let ref = ref(host: host, account: account, profileID: profileID) else { return false }
        return SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: ref,
        ] as CFDictionary) == errSecSuccess
    }

    // MARK: Last used

    /// When each login was last filled, so the chooser can lead with the account you
    /// actually use on that site. A date is not a secret, so plain preferences is the right
    /// store — and being per-profile it follows the credentials it orders.
    private static func usedKey(_ profileID: UUID) -> String {
        ProfileManager.defaultsKey("passwordsLastUsed", profileID)
    }

    static func lastUsed(profileID: UUID = ProfileManager.activeProfileID) -> [String: Date] {
        (UserDefaults.vane.dictionary(forKey: usedKey(profileID)) ?? [:])
            .compactMapValues { ($0 as? Double).map(Date.init(timeIntervalSince1970:)) }
    }

    static func recordUse(host: String, account: String,
                          profileID: UUID = ProfileManager.activeProfileID) {
        var d = UserDefaults.vane.dictionary(forKey: usedKey(profileID)) ?? [:]
        d[key(host: host, account: account)] = Date.now.timeIntervalSince1970
        UserDefaults.vane.set(d, forKey: usedKey(profileID))
    }

    /// A deleted login must not leave its timestamp behind to promote the next login that
    /// happens to be saved under the same host and account.
    private static func forgetUse(host: String, account: String, profileID: UUID) {
        var d = UserDefaults.vane.dictionary(forKey: usedKey(profileID)) ?? [:]
        guard d.removeValue(forKey: key(host: host, account: account)) != nil else { return }
        UserDefaults.vane.set(d, forKey: usedKey(profileID))
    }

    // MARK: Never for this site

    /// Sites the user has said no for. Not a secret and not a credential, so it lives in
    /// preferences beside the last-used stamps — and being per-profile it follows them.
    private static func neverKey(_ profileID: UUID) -> String {
        ProfileManager.defaultsKey("passwordsNeverSaved", profileID)
    }

    static func neverSaved(profileID: UUID = ProfileManager.activeProfileID) -> [String] {
        (UserDefaults.vane.stringArray(forKey: neverKey(profileID)) ?? []).sorted()
    }

    static func isNeverSaved(host: String,
                             profileID: UUID = ProfileManager.activeProfileID) -> Bool {
        neverSaved(profileID: profileID).contains(host.lowercased())
    }

    /// "Never for this site" on the offer. Saying no once is a decision about this password;
    /// saying never is a decision about the site, so it is the only one that is remembered.
    static func neverSave(host: String, profileID: UUID = ProfileManager.activeProfileID) {
        var hosts = Set(neverSaved(profileID: profileID))
        hosts.insert(host.lowercased())
        UserDefaults.vane.set(Array(hosts).sorted(), forKey: neverKey(profileID))
    }

    /// Taking it back, from Settings ▸ Passwords.
    static func allowSaving(host: String, profileID: UUID = ProfileManager.activeProfileID) {
        let hosts = neverSaved(profileID: profileID).filter { $0 != host.lowercased() }
        UserDefaults.vane.set(hosts, forKey: neverKey(profileID))
    }

    /// Renaming an account in the pane is a delete plus a save, and the timestamp is keyed
    /// on the account — so without this, correcting a typo in a username silently demotes
    /// that login to the bottom of its own site's chooser.
    static func renameUse(host: String, from: String, to: String,
                          profileID: UUID = ProfileManager.activeProfileID) {
        var d = UserDefaults.vane.dictionary(forKey: usedKey(profileID)) ?? [:]
        guard let when = d.removeValue(forKey: key(host: host, account: from)) else { return }
        d[key(host: host, account: to)] = when
        UserDefaults.vane.set(d, forKey: usedKey(profileID))
    }

    // MARK: Revealing

    /// Turning a row of bullets into a password asks the Mac who you are first — Touch ID,
    /// an Apple Watch, or the login password. `.deviceOwnerAuthentication` rather than the
    /// biometrics-only policy so a Mac without Touch ID gets the password sheet instead of a
    /// refusal, and so a laptop with the lid shut still has a way through.
    ///
    /// The callback runs on the main actor, because everything that acts on it is a view.
    @MainActor static func authenticate(_ reason: String,
                                        _ done: @escaping @MainActor (Bool) -> Void) {
        // A `VANE_DATA_DIR` instance already points at a throwaway keychain namespace and has
        // no way to answer a Touch ID sheet under automation. Deliberately keyed off the
        // developer switch and nothing else: the real app has no bypass, not even a
        // preference, because a preference that turns this off is the same as not having it.
        if Store.overrideDirectory != nil { done(true); return }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            done(false)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in done(ok) }
        }
    }

    /// Every credential belonging to one profile, for when that profile is deleted.
    /// A non-default profile is one SecItemDelete against its security domain. The default
    /// profile has no domain to key on, so its items are enumerated and the ones carrying
    /// somebody else's domain are skipped.
    static func deleteAll(profileID: UUID) {
        defer { invalidate() }
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
            guard owns(scope: nil, itemDomain: item[kSecAttrSecurityDomain as String] as? String),
                  let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { continue }
            delete(host: host, account: account, profileID: profileID)
        }
    }

    // MARK: check

    /// The three rules that decide whose credentials this process can see, which of them
    /// counts as ours, and which one a login form is offered first. All pure, and all the
    /// kind of thing that fails silently: a namespace collision hands a test instance the
    /// user's real logins, a bad scope test reads or deletes another profile's item, and a
    /// bad ordering just puts the wrong username in the box.
    static func check() -> [(String, Bool)] {
        let other = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let real = namespace(profileID: ProfileManager.defaultID, dataDir: nil)
        let realOther = namespace(profileID: other, dataDir: nil)
        let testA = namespace(profileID: ProfileManager.defaultID, dataDir: "/tmp/a")
        let testB = namespace(profileID: ProfileManager.defaultID, dataDir: "/tmp/b")
        let testAOther = namespace(profileID: other, dataDir: "/tmp/a")

        func login(_ account: String) -> Login { Login(host: "example.com", account: account) }
        let (ada, bob, cam) = (login("ada"), login("bob"), login("cam"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        return [
            ("the real app's default profile stamps no security domain", real == nil),
            ("a second profile is namespaced", realOther == "vane-" + other.uuidString.lowercased()),
            ("a VANE_DATA_DIR instance namespaces even the default profile", testA != nil),
            ("…so it can never match the real app's items", testA != real && testA != realOther),
            ("two data dirs never share a namespace", testA != testB),
            ("…and profiles inside one still differ", testA != testAOther),
            ("the same data dir is stable across launches",
             testA == namespace(profileID: ProfileManager.defaultID, dataDir: "/tmp/a")),

            // The scope test. Every read, write and delete of a single item hangs off this,
            // and every wrong answer here is somebody else's password.
            ("the default profile owns an item with no domain", owns(scope: nil, itemDomain: nil)),
            ("…and an empty domain is the same as none", owns(scope: nil, itemDomain: "")),
            ("…but not another profile's item",
             owns(scope: nil, itemDomain: realOther) == false),
            ("…and not a test instance's item", owns(scope: nil, itemDomain: testA) == false),
            ("a profile owns only its own domain", owns(scope: realOther, itemDomain: realOther)),
            ("…not an undomained one", owns(scope: realOther, itemDomain: nil) == false),
            ("…and not another profile's", owns(scope: realOther, itemDomain: testAOther) == false),

            ("with nothing used, accounts are alphabetical",
             rank([cam, ada, bob], used: [:]).map(\.account) == ["ada", "bob", "cam"]),
            ("the last-used account leads",
             rank([ada, bob, cam], used: [bob.id: now]).map(\.account) == ["bob", "ada", "cam"]),
            ("…and the more recent of two wins",
             rank([ada, bob, cam], used: [bob.id: now, cam.id: now.addingTimeInterval(60)])
                .map(\.account) == ["cam", "bob", "ada"]),
            ("a tie falls back to the alphabet, not to keychain order",
             rank([cam, bob], used: [bob.id: now, cam.id: now]).map(\.account) == ["bob", "cam"]),
            ("a timestamp for a login that is gone changes nothing",
             rank([ada, bob], used: ["gone.example\nx": now]).map(\.account) == ["ada", "bob"]),
            ("one account is one account", rank([ada], used: [:]) == [ada]),
            ("nothing saved ranks to nothing", rank([], used: [ada.id: now]).isEmpty),

            ("a new password is offered as a save",
             PendingSave(host: "example.com", account: "ada", password: "x").title
                == "Save password for example.com?"),
            ("…and a replacement says so",
             PendingSave(host: "example.com", account: "ada", password: "x", update: true).title
                == "Update the password for example.com?"),
        ]
    }
}

/// A save offer waiting on the user. Held only until they answer.
struct PendingSave: Equatable {
    let host: String
    let account: String
    let password: String
    /// This site and account are already saved with a *different* password — so the offer
    /// is to replace one, which is a different question and gets a different title.
    var update = false

    /// Said out loud and drawn at the top of the card. Named so the wording can be asserted:
    /// telling someone you are about to save a password you are in fact about to overwrite
    /// is the one thing this card must not do.
    var title: String {
        update ? "Update the password for \(host)?" : "Save password for \(host)?"
    }
}

/// The account list hanging under a login form's username field, when a site has more than
/// one saved login. Usernames only — the passwords stay in the keychain until one is picked,
/// so nothing secret sits in view state waiting to be screenshotted or read by VoiceOver.
struct PasswordChoice: Equatable {
    let host: String
    let accounts: [String]
    /// Under the username field, in the web view's own coordinates.
    let anchor: CGRect
    /// Which row Return would fill. The first is what Chromium highlights, and it is the
    /// one `Passwords.rank` put there.
    var selected = 0
}

@MainActor enum Autofill {
    /// Its own content world, like PictureInPicture's. Nothing this script defines is on the
    /// page's `window`, so a hostile page cannot replace `__vaneFill` with a function that
    /// keeps whatever it is handed, and cannot post its own messages to `vanepw`.
    static let world = WKContentWorld.world(name: "vane-passwords")

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
      // Where a chooser should hang: under the username field, its width, in CSS pixels
      // relative to the viewport — which is exactly what the web view is showing.
      function anchor() {
        var p = pair(document);
        if (!p) { return null; }
        var r = (p.user || p.pass).getBoundingClientRect();
        return { x: r.left, y: r.bottom, w: r.width };
      }
      window.__vaneAnchor = function () { return JSON.stringify(anchor()); };
      var listOpen = false;
      function send(m) {
        listOpen = !!m.focus;
        webkit.messageHandlers.vanepw.postMessage(m);
      }
      function ours(el) { var p = pair(document); return !!p && (el === p.user || el === p.pass); }
      // Chromium drops its list of saved accounts under the username field the moment you
      // focus it, and Arc inherits that. Capture phase throughout: a site that stops these
      // events from bubbling must not also stop the browser's own chrome from appearing —
      // or, worse, from going away again.
      document.addEventListener('focusin', function (e) {
        if (!ours(e.target)) { return; }
        var a = anchor();
        if (a) { send({ focus: true, x: a.x, y: a.y, w: a.w }); }
      }, true);
      // Everything that means "not interested any more". The list is anchored to a point
      // that stops being true the moment any of these happens, so each one closes it.
      document.addEventListener('focusout', function (e) {
        if (ours(e.target)) { send({ dismiss: 'blur' }); }
      }, true);
      document.addEventListener('mousedown', function (e) {
        if (!ours(e.target)) { send({ dismiss: 'click' }); }
      }, true);
      // Only while the list is actually up. A scroll handler that posts on every wheel
      // event of every page, forever, is a message per frame for a list that is not there.
      window.addEventListener('scroll', function () {
        if (listOpen) { send({ dismiss: 'scroll' }); }
      }, true);
      // A single-page app changes the form under us without a navigation.
      window.addEventListener('popstate', function () { send({ dismiss: 'navigate' }); });
      function offer() {
        var p = pair(document);
        if (!p || !p.pass.value) { return; }
        send({ account: p.user ? p.user.value : '', password: p.pass.value });
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

        // What the History window reads: every visit with its own time, searchable, and a
        // single line deletable without taking the other visits to that page with it.
        store.clearHistory()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        store.record([(URL(string: "https://swift.org/blog")!, "Swift Blog", day),
                      (URL(string: "https://swift.org/blog")!, "Swift Blog", day - 86_400),
                      (URL(string: "https://apple.com")!, "Apple", day - 90_000)])
        let visits = store.history()
        check("history lists every visit, not one row per url", visits.count == 3)
        check("history comes back newest first",
              visits.first?.title == "Swift Blog" && visits.map(\.at) == visits.map(\.at).sorted(by: >))
        check("history search matches a title", store.history(matching: "apple").count == 1)
        check("history search matches a url", store.history(matching: "swift.org").count == 2)
        check("history search is case-insensitive", store.history(matching: "SWIFT").count == 2)
        check("history search escapes LIKE wildcards", store.history(matching: "%").isEmpty)
        check("history search matching nothing comes back empty", store.history(matching: "zzzz").isEmpty)
        if let newest = store.history(matching: "swift.org").first {
            store.deleteVisit(newest.id)
            check("deleting one visit leaves that page's other visits alone",
                  store.history(matching: "swift.org").count == 1)
        } else {
            check("deleting one visit leaves that page's other visits alone", false)
        }

        // ⌥⌘⌫ on a command bar suggestion: the bar rolls a page's visits into one row, so
        // forgetting that row has to take every visit to it — and leave the other pages be.
        store.record([(URL(string: "https://swift.org/blog")!, "Swift Blog", day - 172_800)])
        store.forget(url: "https://swift.org/blog")
        check("forgetting a suggestion takes every visit to that page with it",
              store.history(matching: "swift.org").isEmpty)
        check("…and leaves the other pages alone", store.history(matching: "apple").count == 1)

        check("clearHistory empties visits", { store.clearHistory(); return store.recent().isEmpty }())
        try? FileManager.default.removeItem(at: dir)

        for (label, block) in [("window chrome", Look.check), ("sidebar motion", Motion.check), ("tab archive", Archive.check),
                               ("content blocker", Blocker.check), ("browser import", BrowserImport.check),
                               ("favicons + tabs", Favicons.check), ("url handling", URLHandling.check),
                               ("error pages", ErrorPage.check), ("site permissions", SitePermissions.check),
                               ("site control center", SiteControl.check),
                               ("extensions", ExtensionHost.check),
                               ("pinned extension actions", ExtensionPins.check),
                               ("profiles + spaces", ProfileManager.check),
                               ("spaces", Spaces.check),
                               ("search engines", Search.check),
                               ("search suggestions", SearchSuggestions.check),
                               ("instant links", InstantLinks.check),
                               ("ai chat", AIChat.check),
                               ("certificate trust", CertificateTrust.check),
                               ("crash recovery", Crash.check),
                               ("reader", Reader.check),
                               ("command palette", Palette.check),
                               ("find in page", Find.check),
                               ("clear browsing data", BrowsingData.check),
                               ("tab suspension", Suspension.check),
                               ("keybindings", Keybindings.check),
                               ("shortcuts pane", ShortcutsPane.check),
                               ("history window", HistoryWindow.check),
                               ("library", Library.check),
                               ("downloads", Downloads.check),
                               ("on-device ai", AppleAI.check),
                               ("picture in picture", PictureInPicture.check),
                               ("tidy downloads", TidyDownloads.check),
                               ("tidy tabs", TidyTabs.check),
                               ("tidy titles", TidyTitles.check),
                               ("link previews", Previews.check),
                               ("per-site zoom", Zoom.check),
                               ("export", Export.check),
                               ("tab audio", TabAudio.check),
                               ("https-only", HTTPSOnly.check),
                               ("bangs", Bangs.check),
                               ("sidebar width", SidebarWidth.check),
                               ("peeked window chrome", VaneWindow.check),
                               ("little arc", LittleArc.check),
                               ("air traffic control", AirTraffic.check),
                               ("peek", Peek.check),
                               ("link gestures", TabActions.check),
                               ("recent tab switcher", TabSwitcher.check),
                               ("toasts", Toasts.check),
                               ("pinned folders", Pins.check),
                               ("split view", Split.check),
                               ("mini audio player", MediaTray.check),
                               ("multi-select", Selection.check),
                               ("⌘Q asks before quitting", QuitAsk.check),
                               ("local files", Files.check),
                               ("saved passwords", Passwords.check),
                               ("passwords pane", PasswordsPane.check),
                               ("password chooser", PasswordChooser.check),
                               ("back/forward history menu", NavHistory.check),
                               ("drag landing", Landing.check),
                               ("live folders", GitHub.check)] {
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

        // Not pure: it reads the running bundle's Info.plist, and the bare binary out of
        // .build has none. Two lists of the same UTIs — make-app.sh's CFBundleDocumentTypes
        // and Files.types — are exactly the pair that drifts, and drift here is silent:
        // Finder offers a type Vane then refuses to draw, or Vane draws one Finder never
        // offers. Skipped rather than failed with no bundle, which is what the app runs as.
        print("declared document types")
        if let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] {
            let declared = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
            check("Info.plist declares exactly what Files.opens will open",
                  declared == Set(Files.types.map(\.identifier)))
        } else {
            print("  --    no bundle (running the bare binary), nothing to compare")
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
            WKUserScript(source: Autofill.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true, in: Autofill.world))
        let b = Bridge()
        bridge = b
        cfg.userContentController.add(b, contentWorld: Autofill.world, name: "vanepw")
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
            // In the script's own world, like the app does it — the page world has no
            // `__vaneFill` at all any more, which is the point of the world.
            w.evaluateJavaScript(Autofill.fillJS(account: user, password: pass),
                                 in: nil, in: Autofill.world) { result in
                let filled = try? result.get()
                check("fill reports a form was found", (filled as? Bool) == true)
                w.evaluateJavaScript("window.__state()") { state, _ in
                    let s = (state as? String) ?? ""
                    check("username reached component state", s.contains(user))
                    check("password reached component state", s.contains(pass))
                    check("decoy text field was not mistaken for the username", !s.contains("decoy"))
                    // The whole point of the content world: a page cannot replace the fill
                    // hook with one that keeps whatever the browser hands it.
                    w.evaluateJavaScript("typeof window.__vaneFill + \" \" + typeof window.__vaneAnchor") { kinds, _ in
                        check("the page's own world cannot see the autofill hooks",
                              (kinds as? String) == "undefined undefined")
                    }
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
            // The same handler now carries focus and dismiss notices. Only an offer has a
            // password in it, and only an offer is what this check is watching for.
            guard let b = m.body as? [String: Any], b["focus"] == nil, b["dismiss"] == nil,
                  let password = b["password"] as? String else { return }
            offered = ((b["account"] as? String) ?? "", password)
        }
    }
}
