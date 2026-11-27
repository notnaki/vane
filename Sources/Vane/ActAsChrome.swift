import Foundation
import WebKit

/// Site Controls' "Act as Chrome": one exact host, in one profile, gets Chrome's identity for
/// sites that turn other browsers away. Off by default, so FairPlay streaming (which needs
/// Safari's identity on some sites) is untouched unless the user asks for it.
///
/// A global Develop → User Agent choice wins: the user already picked an identity for every
/// site, and quietly replacing it on one would make that menu lie.
@MainActor enum ActAsChrome {
    static let chromeUA = Settings.userAgents.first { $0.name == "Chrome" }!.value

    /// Private windows remember nothing on disk, the same way the blocker's exceptions do.
    private static var privateHosts: Set<String> = []

    private static func key(_ profileID: UUID) -> String { ProfileManager.defaultsKey("actAsChromeHosts", profileID) }

    static func hosts(profileID: UUID, isPrivate: Bool) -> Set<String> {
        isPrivate ? privateHosts : Set(UserDefaults.vane.stringArray(forKey: key(profileID)) ?? [])
    }

    static func isOn(_ url: URL?, profileID: UUID, isPrivate: Bool) -> Bool {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return false }
        return hosts(profileID: profileID, isPrivate: isPrivate).contains(host)
    }

    static func set(_ host: String, on: Bool, profileID: UUID, isPrivate: Bool) {
        let host = host.lowercased()
        guard !host.isEmpty else { return }
        var all = hosts(profileID: profileID, isPrivate: isPrivate)
        if on { all.insert(host) } else { all.remove(host) }
        if isPrivate { privateHosts = all }
        else if all.isEmpty { UserDefaults.vane.removeObject(forKey: key(profileID)) }
        else { UserDefaults.vane.set(all.sorted(), forKey: key(profileID)) }
    }

    /// True when Develop has a non-default identity, which then applies here too.
    static var overridden: Bool { Settings.userAgent != safariUA }

    /// The identity a navigation to `url` goes out with.
    static func userAgent(for url: URL?, profileID: UUID, isPrivate: Bool) -> String {
        resolve(global: Settings.userAgent, siteOn: isOn(url, profileID: profileID, isPrivate: isPrivate))
    }

    static func resolve(global: String, siteOn: Bool, safari: String = safariUA) -> String {
        siteOn && global == safari ? chromeUA : global
    }

    static func toggle(_ tab: Tab) {
        guard let url = tab.currentURL, let host = url.host(), !overridden else { return }
        set(host, on: !isOn(url, profileID: tab.profileID, isPrivate: tab.isPrivate),
            profileID: tab.profileID, isPrivate: tab.isPrivate)
        tab.existingWeb?.customUserAgent = userAgent(for: url, profileID: tab.profileID, isPrivate: tab.isPrivate)
        tab.reload()     // the navigation policy picks the new identity for the reload
    }

    /// Called as a main-frame navigation is allowed. The web view's UA covers the page and
    /// its subresources; the guarded per-navigation preference makes the main request's own
    /// header match even across a process swap (the same SPI ExtensionUserAgent relies on).
    static func apply(_ url: URL?, to web: WKWebView, preferences: WKWebpagePreferences, tab: Tab) {
        let ua = userAgent(for: url, profileID: tab.profileID, isPrivate: tab.isPrivate)
        if web.customUserAgent != ua { web.customUserAgent = ua }
        let setter = NSSelectorFromString("_setCustomUserAgent:")
        if preferences.responds(to: setter) { _ = preferences.perform(setter, with: ua) }
    }

    /// Chrome's navigator, whenever the page's UA says Chrome: `vendor` and a minimal
    /// `userAgentData`. Keyed on the UA rather than a host list, so no page can read which
    /// sites have the switch on. A Develop choice of Chrome gets the same consistency.
    static let script = #"""
    (() => {
      const ua = navigator.userAgent, m = / Chrome\/((\d+)[\d.]*)/.exec(ua);
      if (!m || / Edg\//.test(ua) || navigator.vendor === 'Google Inc.') return;
      const full = m[1], major = m[2];
      const brands = [{brand: 'Not)A;Brand', version: '8'}, {brand: 'Chromium', version: major},
                      {brand: 'Google Chrome', version: major}];
      const low = () => ({brands: brands.map(b => ({...b})), mobile: false, platform: 'macOS'});
      const data = Object.freeze({
        brands: Object.freeze(brands.map(b => Object.freeze({...b}))), mobile: false, platform: 'macOS',
        getHighEntropyValues: hints => Promise.resolve(Object.assign(low(), {
          architecture: 'arm', bitness: '64', model: '', platformVersion: '15.0.0', uaFullVersion: full,
          fullVersionList: brands.map(b => ({brand: b.brand, version: b.version === '8' ? '8.0.0.0' : full})),
          wow64: false})),
        toJSON: low,
      });
      const define = (name, value) => Object.defineProperty(Navigator.prototype, name,
        {get() { return value; }, configurable: true, enumerable: true});
      define('vendor', 'Google Inc.');
      define('userAgentData', data);
    })();
    """#

    static func check() -> [(String, Bool)] {
        let chrome = chromeUA, firefox = Settings.userAgents.first { $0.name == "Firefox" }!.value
        let profile = UUID()
        defer { UserDefaults.vane.removeObject(forKey: key(profile)) }
        let site = URL(string: "https://Example.com/a")!, other = URL(string: "https://www.example.com/")!
        set("EXAMPLE.com", on: true, profileID: profile, isPrivate: false)
        let stored = UserDefaults.vane.stringArray(forKey: key(profile)) == ["example.com"]
        let exact = isOn(site, profileID: profile, isPrivate: false) && !isOn(other, profileID: profile, isPrivate: false)
        let privateApart = !isOn(site, profileID: profile, isPrivate: true)
        set("example.com", on: false, profileID: profile, isPrivate: false)
        set("p.test", on: true, profileID: profile, isPrivate: true)
        let privateNotPersisted = UserDefaults.vane.object(forKey: key(profile)) == nil
            && isOn(URL(string: "https://p.test/")!, profileID: UUID(), isPrivate: true)
        set("p.test", on: false, profileID: profile, isPrivate: true)
        return [
            ("act as chrome: off by default", !isOn(site, profileID: UUID(), isPrivate: false)),
            ("act as chrome: stored as the exact lowercased host", stored && exact),
            ("act as chrome: private windows keep their own, in memory", privateApart && privateNotPersisted),
            ("act as chrome: off again removes the key", UserDefaults.vane.object(forKey: key(profile)) == nil),
            ("act as chrome: on uses the Chrome identity", resolve(global: "S", siteOn: true, safari: "S") == chrome),
            ("act as chrome: off keeps the default", resolve(global: "S", siteOn: false, safari: "S") == "S"),
            ("act as chrome: a Develop override wins", resolve(global: firefox, siteOn: true, safari: "S") == firefox),
            ("act as chrome: the Chrome entry is a Chrome UA", chrome.contains(" Chrome/") && !chrome.contains("Version/")),
        ]
    }
}
