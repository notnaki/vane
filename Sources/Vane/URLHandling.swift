import AppKit

/// Being the system's browser: taking urls from other apps, and asking (once) to be the
/// default. macOS routes `open -a Vane <url>` and every link click in Mail/Slack/Terminal
/// through a GetURL Apple Event, so without this handler Vane launches and shows a blank
/// window instead of the link.
///
/// ponytail: an Apple Event handler rather than an NSApplicationDelegate. main.swift has no
/// delegate to hang `application(_:open:)` off, and adding one to catch two events is more
/// machinery than the events are worth. Upgrade path: if a delegate ever exists for other
/// reasons, delete `handler` and move these two bodies onto it.
///
/// Info.plist keys make-app.sh must emit for any of this to take effect — LaunchServices
/// only offers an app as a browser if the bundle *declares* the schemes:
///
///   <key>CFBundleURLTypes</key>
///   <array>
///     <dict>
///       <key>CFBundleURLName</key>            <string>Web site URL</string>
///       <key>CFBundleTypeRole</key>           <string>Viewer</string>
///       <key>CFBundleURLSchemes</key>
///       <array>
///         <string>http</string>
///         <string>https</string>
///       </array>
///     </dict>
///   </array>
///   <key>CFBundleDocumentTypes</key>
///   <array>
///     <dict>
///       <key>CFBundleTypeName</key>           <string>HTML Document</string>
///       <key>CFBundleTypeRole</key>           <string>Viewer</string>
///       <key>LSHandlerRank</key>              <string>Alternate</string>
///       <key>LSItemContentTypes</key>
///       <array>
///         <string>public.html</string>
///         <string>public.xhtml</string>
///       </array>
///     </dict>
///   </array>
@MainActor enum URLHandling {

    // MARK: - Incoming urls

    /// Call once at launch, before `app.run()`.
    static func registerAppleEventHandler() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(handler, andSelector: #selector(Handler.getURL(_:withReply:)),
                                forEventClass: AEEventClass(kInternetEventClass),
                                andEventID: AEEventID(kAEGetURL))
        // We declare public.html, so "Open With → Vane" on a .html file has to work too;
        // AppKit turns that into an odoc event that nothing would otherwise answer.
        manager.setEventHandler(handler, andSelector: #selector(Handler.openDocuments(_:withReply:)),
                                forEventClass: AEEventClass(kCoreEventClass),
                                andEventID: AEEventID(kAEOpenDocuments))
    }

    /// NSAppleEventManager does not retain its handlers.
    private static let handler = Handler()

    /// Where a link from another app lands: a Little Arc window (Arc's default, and Vane's),
    /// or a tab in the frontmost ordinary window. `LittleArc.route` is the decision on its
    /// own, so it can be proved without a window server.
    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch LittleArc.route(preferLittle: Prefs.openLinksInLittleArc,
                               hasWindow: Windows.main != nil) {
        case .little:    urls.forEach { LittleArc.open($0) }
        case .tab:       urls.forEach { Windows.main?.newTab($0) }
        case .newWindow: Windows.open(urls: urls)
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

        @objc func openDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
            var files: [URL] = []
            if let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
                // Apple Event lists are 1-based, and a single file arrives unwrapped.
                files = list.numberOfItems == 0
                    ? [list.fileURLValue].compactMap { $0 }
                    : (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
            }
            MainActor.assumeIsolated { URLHandling.open(files) }
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
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { error in
            // Only the localized text crosses actor boundaries; NSError is not Sendable.
            guard let reason = error?.localizedDescription else { return }
            Task { @MainActor in
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
        let defaults = UserDefaults.standard
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
