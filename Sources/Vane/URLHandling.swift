import AppKit

/// Being the system's browser: taking urls from other apps, and asking (once) to be the
/// default. macOS routes `open -a Vane <url>` and every link click in Mail/Slack/Terminal
/// through a GetURL Apple Event, so without this handler Vane launches and shows a blank
/// window instead of the link.
///
/// ponytail: an Apple Event handler for GetURL only. There is no delegate method for it that
/// does not also swallow `odoc`, and files are better served by the real one —
/// `AppLifecycle.application(_:open:)`, which is where Finder ▸ Open With lands.
///
/// Info.plist keys make-app.sh must emit for any of this to take effect — LaunchServices
/// only offers an app as a browser if the bundle *declares* the schemes, and only lists it
/// in Open With if the bundle declares the document types. `Files.types` is the same list.
@MainActor enum URLHandling {

    // MARK: - Incoming urls

    /// Call once at launch, before `app.run()`.
    static func registerAppleEventHandler() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(handler, andSelector: #selector(Handler.getURL(_:withReply:)),
                                forEventClass: AEEventClass(kInternetEventClass),
                                andEventID: AEEventID(kAEGetURL))
        // Files — "Open With → Vane" on a PDF or an .html — are `odoc`, and AppKit's own
        // handler for that calls `application(_:open:)` on the delegate. See AppLifecycle.
    }

    /// NSAppleEventManager does not retain its handlers.
    private static let handler = Handler()

    /// Where a link from another app lands: whatever an Air Traffic Control rule says, else
    /// a Little Arc window (Arc's default, and Vane's), else a tab in the frontmost ordinary
    /// window. `AirTraffic.route` and `LittleArc.route` are both decisions on their own, so
    /// both can be proved without a window server.
    ///
    /// The rules are asked per url rather than for the batch: three links arriving together
    /// can perfectly well belong in three different places, which is the point of having them.
    static func open(_ urls: [URL]) {
        // A local file only if Vane can draw it. A GetURL/odoc event is attacker-reachable
        // and Launch Services is not the only thing that can send one, so `open -a Vane
        // archive.zip` must not reach a tab — WebKit would treat an unrenderable file as a
        // download and copy it into ~/Downloads.
        // Filtered in place rather than partitioned, because the order of the batch is the
        // order the links were sent in and the loop below relies on it.
        let openable = Set(Files.opens(urls))
        let urls = urls.filter { !$0.isFileURL || openable.contains($0) }
        guard !urls.isEmpty else { return }
        // A loop, not `filter`: `hand` opens windows, and `filter`'s order of evaluation is
        // not the batch's order to rely on for side effects. Three links from one message
        // must arrive in the order they were sent.
        var rest: [URL] = []
        for url in urls where !AirTraffic.hand(url) { rest.append(url) }
        // `hasWindow` is read after the rules have run: a rule that just opened the first
        // window is exactly why the link under it should become a tab in it.
        if !rest.isEmpty {
            switch LittleArc.route(preferLittle: Prefs.openLinksInLittleArc,
                                   hasWindow: Windows.main != nil) {
            case .little:    rest.forEach { LittleArc.open($0) }
            case .tab:       rest.forEach { Windows.main?.newTab($0) }
            case .newWindow: Windows.open(urls: rest)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What we are willing to load from another app. A GetURL event is attacker-reachable
    /// (any process can send one), so nothing but real page loads gets through — a
    /// `javascript:` or `data:` url handed straight to the front tab would run in whatever
    /// origin happened to be there.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else { return nil }
        return url
    }

    private final class Handler: NSObject {
        // The descriptor is unwrapped out here, in the nonisolated event-manager callback,
        // so only Sendable values (a String, an array of URLs) cross onto the main actor.
        @objc func getURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
            let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue
            MainActor.assumeIsolated {
                guard let raw, let url = URLHandling.normalize(raw) else { return }
                URLHandling.open([url])
            }
        }
    }

    // MARK: - Default browser

    /// LaunchServices answers for a concrete url, not a scheme; https is the one that
    /// decides whether the OS thinks you are a browser.
    static var isDefaultBrowser: Bool {
        guard let me = Bundle.main.bundleIdentifier,
              let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let handlerID = Bundle(url: app)?.bundleIdentifier
        else { return false }
        return handlerID == me
    }

    /// macOS 12+ API, so no LSSetDefaultHandlerForURLScheme fallback is reachable at our
    /// 26.0 deployment target. macOS puts up its own "Use Vane as your default browser?"
    /// confirmation; a refusal there comes back as an error, not a silent no-op.
    static func makeDefaultBrowser() {
        let me = Bundle.main.bundleURL
        // https alone is what puts up macOS's one "default web browser?" question. Asking
        // for http in the same breath made a second request race that dialog and fail at
        // once with "The file couldn't be opened" — an alert over a question the user had
        // not answered yet. So http follows only once https has been answered, and a
        // refusal in the system's own dialog is not an error worth a second dialog.
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { error in
            // Only Sendable pieces cross to the main actor; NSError is not.
            let reason = error?.localizedDescription
            let refused = (error as NSError?).map {
                $0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError
            } ?? false
            Task { @MainActor in
                if reason == nil || isDefaultBrowser {
                    NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in }
                    return
                }
                guard !refused, let reason else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t make Vane the default browser"
                alert.informativeText = reason
                    + "\n\nYou can set it by hand in System Settings → Desktop & Dock → Default web browser."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private static let askedKey = "askedToBeDefaultBrowser"

    /// Asked exactly once, ever. A browser that renews this question every launch is a
    /// browser people uninstall.
    static func promptIfNotDefaultOnce() {
        let defaults = UserDefaults.vane
        // Running the bare binary out of .build has no bundle to register; asking there
        // would burn the one question on something LaunchServices would refuse anyway.
        guard Bundle.main.bundleIdentifier != nil,
              !defaults.bool(forKey: askedKey), !isDefaultBrowser else { return }
        defaults.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Make Vane your default browser?"
        alert.informativeText = "Links from other apps will open in Vane. You’ll only be asked once."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { makeDefaultBrowser() }
    }

    // MARK: - check

    /// Pure url-vetting assertions; nothing here touches LaunchServices or the network.
    static func check() -> [(String, Bool)] {
        [
            ("https url from another app is accepted",
             normalize("https://example.com/a?b=c#d")?.absoluteString == "https://example.com/a?b=c#d"),
            ("http url is accepted", normalize("http://example.com") != nil),
            ("file url is accepted (Open With on a .html file)", normalize("file:///tmp/x.html") != nil),
            ("surrounding whitespace is tolerated", normalize("  https://example.com \n") != nil),
            ("javascript: url is refused", normalize("javascript:alert(1)") == nil),
            ("data: url is refused", normalize("data:text/html,<h1>hi") == nil),
            ("scheme match is case-insensitive", normalize("HTTPS://example.com") != nil),
            ("a bare hostname is refused (GetURL always carries a scheme)",
             normalize("example.com") == nil),
            ("empty input is refused", normalize("") == nil),
            ("percent-escapes survive normalization",
             normalize("https://example.com/a%20b")?.absoluteString == "https://example.com/a%20b"),
        ]
    }
}
