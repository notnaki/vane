import AppKit
import Network
import Security
import WebKit

/// Deterministic, real-WebKit smoke checks. Run the packaged app with `browsercheck` and
/// an empty VANE_DATA_DIR. Unlike selfcheck --pure, this needs a logged-in macOS session.
/// Existing SelfCheck owns the keychain/autofill and popup-SPI fixtures; these checks cover
/// navigation, redirects, history, find, form submission, popup creation and private data.
@MainActor enum BrowserChecks {
    private static var runner: Runner?

    static func run() -> Never {
        guard let directory = Store.overrideDirectory,
              FileManager.default.fileExists(atPath: directory),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory),
              entries.isEmpty else {
            fail("browsercheck requires VANE_DATA_DIR pointing to an existing empty directory", code: 2)
        }
        guard Bundle.main.bundleURL.pathExtension == "app", sandboxedSignature() else {
            fail("browsercheck must run inside a signed app bundle with App Sandbox enabled", code: 2)
        }
        let check = Runner(directory: directory)
        runner = check
        // Independent of any awaited WebKit callback. An unavailable process or delegate
        // callback must fail CI instead of leaving a task suspended indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) {
            fail("browsercheck exceeded its 55-second deadline", code: 1)
        }
        Task { await check.run() }
        NSApplication.shared.run()
        fail("browsercheck run loop ended before completion", code: 1)
    }

    /// The browser process cannot unregister a store that its WebKit network process still
    /// has open. The smoke script invokes this command in a fresh process after `run` exits.
    static func cleanupStore() -> Never {
        guard let directory = Store.overrideDirectory,
              FileManager.default.fileExists(atPath: directory) else {
            fail("browsercheck cleanup requires an existing VANE_DATA_DIR", code: 2)
        }
        guard Bundle.main.bundleURL.pathExtension == "app", sandboxedSignature() else {
            fail("browsercheck cleanup must run inside a signed sandboxed app", code: 2)
        }
        // The profile-hop checks open a second isolated profile. Compute only identifiers
        // belonging to this test directory; never touch a production/default WebKit store.
        let profileIDs = Set([ProfileManager.defaultID] + ProfileManager.shared.profiles.map(\.id))
        let ids = profileIDs.compactMap {
            ProfileManager.dataStoreIdentifier(for: $0, dataDirectory: directory)
        }.sorted { $0.uuidString < $1.uuidString }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fail("browsercheck cleanup exceeded its 15-second deadline", code: 1)
        }
        Task {
            // A cold fetchAllDataStoreIdentifiers call crashes WebKit on this macOS release.
            _ = WKProcessPool()
            for id in ids {
                var removed = false
                var lastError: Error?
                for attempt in 0..<20 {
                    let registered = await registeredStoreIdentifiers()
                    if !registered.contains(id) { removed = true; break }
                    lastError = await withCheckedContinuation { continuation in
                        WKWebsiteDataStore.remove(forIdentifier: id) { error in
                            continuation.resume(returning: error)
                        }
                    }
                    if lastError == nil {
                        let remaining = await registeredStoreIdentifiers()
                        if !remaining.contains(id) { removed = true; break }
                    }
                    if attempt < 19 { try? await Task.sleep(for: .milliseconds(250)) }
                }
                if !removed {
                    fail("temporary WebKit store \(id.uuidString) still registered: \(String(describing: lastError))",
                         code: 1)
                }
            }
            print("PASS browsercheck cleanup: \(ids.count) temporary WebKit stores unregistered")
            exit(0)
        }
        NSApplication.shared.run()
        fail("browsercheck cleanup run loop ended before completion", code: 1)
    }

    private static func registeredStoreIdentifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                continuation.resume(returning: ids)
            }
        }
    }

    private static func sandboxedSignature() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    private static func fail(_ text: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("FAIL browsercheck: \(text)\n".utf8))
        exit(code)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor private final class Runner {
        let directory: String
        var server: Server?
        var tabs: [Tab] = []
        var windows: [NSWindow] = []
        var assertions = 0

        init(directory: String) { self.directory = directory }

        func run() async {
            do {
                let server = try Server()
                self.server = server
                try await wait("loopback server starts") { server.port != nil || server.error != nil }
                if let error = server.error { throw Failure(error) }
                guard let port = server.port else { throw Failure("listener has no port") }
                let base = "http://127.0.0.1:\(port)"
                // This defaults suite belongs exclusively to the empty test directory.
                // HTTPS upgrades are tested by SelfCheck; this fixture has no TLS server.
                HTTPSOnly.enabled = false
                let profile = ProfileManager.shared.active.id
                let tab = makeTab(profile: profile)
                let expectedStore = ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: directory)
                try require(expectedStore != nil && tab.web.configuration.websiteDataStore.identifier == expectedStore,
                            "the test data directory has its own named WebKit store")
                try require(tab.web.configuration.websiteDataStore.isPersistent,
                            "the isolated regular store remains persistent")
                try require(expectedStore != profile,
                            "the isolated store cannot collide with an installed profile store")
                let background = TabStore(urls: [URL(string: "\(base)/a")!], profileID: profile)
                let original = background.current
                background.active?.passwordChoice = PasswordChoice(
                    host: "example.test", accounts: ["ada"], anchor: .zero)
                background.openBeside(URL(string: "\(base)/b")!, focus: false)
                try require(background.current == original
                            && background.active?.passwordChoice != nil,
                            "a background link does not interrupt the active tab's password chooser")
                tabs += background.tabs
                let incomingSpace = Space(name: "Incoming", profileID: profile,
                                          tabURLs: [URL(string: "\(base)/a")!])
                let incoming = TabStore(urls: [URL(string: "\(base)/b")!],
                                        profileID: profile, space: incomingSpace)
                try require(incoming.current == incoming.tabs.last?.id,
                            "a URL sent to a new window is selected ahead of existing Space tabs")
                tabs += incoming.tabs
                let pinnedURL = URL(string: "\(base)/pin-home")!
                let pinnedSpace = Space(name: "Pinned", profileID: profile,
                                        pinnedTabURLs: [pinnedURL])
                let requestedPin = TabStore(urls: [pinnedURL], profileID: profile,
                                            space: pinnedSpace)
                try require(requestedPin.active?.homeURL == pinnedURL && requestedPin.palette == nil,
                            "a requested pinned page is shown without opening the New Tab palette")
                tabs += requestedPin.tabs
                TabStore.all.removeAll {
                    $0 === background || $0 === incoming || $0 === requestedPin
                }
                try await load(tab, "\(base)/a", title: "Fixture A")
                try require(tab.history.history().contains { URL(string: $0.url)?.path == "/a" },
                            "normal navigation records a real history visit")

                let hostSource = makeTab(profile: profile)
                try await load(hostSource, "\(base)/host-title", title: "127.0.0.1")
                guard let restoredURL = hostSource.web.url,
                      let restoredState = hostSource.snapshot.state else {
                    throw Failure("host-title page did not expose interaction state")
                }
                let restored = makeTab(profile: profile)
                restored.kind = .pinned
                restored.park(url: restoredURL,
                              Parked(title: "Cached Host Title", state: restoredState))
                restored.resume()
                try await wait("interaction-state page restoration") {
                    restored.web.url == restoredURL && restored.web.title == "127.0.0.1"
                        && !restored.web.isLoading
                }
                try require(restored.title == "Cached Host Title",
                            "interaction-state restoration never publishes its provisional host title")
                try await wait("a final host-shaped title settles") {
                    restored.title == "127.0.0.1"
                }
                try require(restored.title == "127.0.0.1",
                            "a final host-shaped title eventually replaces stale cached text")

                let find = Find()
                await find.run("needle", in: tab, fresh: true)
                try require(find.count == 2 && find.index == 1, "Find selects the first of two visible matches")
                await find.run("needle", in: tab)
                try require(find.count == 2 && find.index == 2, "Find advances to the next real page match")
                await find.run("not-in-this-document", in: tab, fresh: true)
                try require(find.count == 0, "Find reports an actual missing term")

                _ = try await js(tab, "document.getElementById('next').click()")
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(tab.web.canGoBack, "a clicked link creates a back entry")
                tab.web.goBack()
                try await loaded(tab, path: "/a", title: "Fixture A")
                try require(tab.web.canGoForward, "Back exposes the forward entry")
                tab.web.goForward()
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(tab.web.url?.path == "/b", "Forward returns to the linked page")

                let beforeReload = server.requests["/b", default: 0]
                tab.web.reload()
                try await wait("reload reaches the server") { server.requests["/b", default: 0] > beforeReload }
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(server.requests["/b", default: 0] > beforeReload, "Reload fetches a fresh response")

                try await load(tab, "\(base)/redirect", title: "Fixture B", finalPath: "/b")
                try require(server.requests["/redirect", default: 0] == 1 && tab.web.url?.path == "/b",
                            "an HTTP redirect lands on its destination")

                try await load(tab, "\(base)/form", title: "Fixture Form")
                let edited = try await js(tab, """
                    const field = document.getElementById('query');
                    field.value = 'browser smoke';
                    field.dispatchEvent(new Event('input', {bubbles: true}));
                    window.inputState;
                    """)
                try require(edited as? String == "browser smoke", "a form input event reaches page state")
                _ = try await js(tab, "document.getElementById('submit').click()")
                try await loaded(tab, path: "/submitted", title: "Fixture Submitted")
                // HTML GET forms encode spaces as '+'. URLComponents decodes percent
                // escapes but deliberately leaves literal plus signs unchanged.
                let formURL = tab.web.url!.absoluteString.replacingOccurrences(of: "+", with: "%20")
                let submitted = URLComponents(string: formURL)?
                    .queryItems?.first(where: { $0.name == "query" })?.value
                try require(submitted == "browser smoke", "form submission navigates with the edited value")

                // Exercise Tab.createWebViewWith and its real onPopup route, not a stand-in
                // navigation delegate. SelfCheck separately checks gesture SPI/placement.
                tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                var popup: Tab?
                tab.onPopup = { [weak self] configuration, _ in
                    guard let self else { return nil }
                    let child = Tab(popup: configuration, isPrivate: false, profileID: profile)
                    popup = child
                    self.host(child)
                    return child.web
                }
                _ = try await js(tab, """
                    window.fixturePopup = window.open('about:blank', '_blank', 'width=451,height=400');
                    if (window.fixturePopup) {
                        window.fixturePopup.document.write('<title>Fixture Popup</title><body>Popup content</body>');
                        window.fixturePopup.document.close();
                    }
                    """)
                try await wait("popup reaches the Tab callback") { popup != nil }
                guard let popup else { throw Failure("popup callback did not produce a tab") }
                try await wait("popup document renders") { popup.web.title == "Fixture Popup" }
                let popupBody = try await js(popup, "document.body.textContent")
                try require((popupBody as? String)?.contains("Popup content") == true,
                            "the opener writes into the returned popup web view")

                try await load(tab, "\(base)/storage", title: "Fixture Storage")
                _ = try await js(tab, "localStorage.setItem('scope', 'regular')")
                let privateTab = makeTab(profile: profile, isPrivate: true)
                try require(!privateTab.web.configuration.websiteDataStore.isPersistent
                            && privateTab.web.configuration.websiteDataStore.identifier == nil,
                            "private browsing uses an unnamed ephemeral WebKit store")
                let historyBefore = tab.history.history().count
                try await load(privateTab, "\(base)/private", title: "Fixture Private")
                let inherited = try await js(privateTab, "localStorage.getItem('scope') === null")
                try require(inherited as? Bool == true, "private browsing cannot read regular local storage")
                _ = try await js(privateTab, "localStorage.setItem('scope', 'private')")
                let regular = try await js(tab, "localStorage.getItem('scope')")
                try require(regular as? String == "regular", "private writes do not change regular storage")
                let secondPrivate = makeTab(profile: profile, isPrivate: true)
                try await load(secondPrivate, "\(base)/private", title: "Fixture Private")
                let separate = try await js(secondPrivate, "localStorage.getItem('scope') === null")
                try require(separate as? Bool == true, "a fresh private tab has a fresh ephemeral data store")
                try require(tab.history.history().count == historyBefore
                            && !tab.history.history().contains { URL(string: $0.url)?.path == "/private" },
                            "private navigations do not add history records")

                let downloads = Downloads.manager(for: profile)
                let destination = URL(fileURLWithPath: directory).appendingPathComponent("download-fixtures")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                downloads.destinationDirectory = destination
                DownloadLocation.setAskEveryTime(false, for: profile)
                for expected in 1...2 {
                    tab.web.load(URLRequest(url: URL(string: "\(base)/download")!))
                    try await wait("attachment download completes") {
                        downloads.items.filter { $0.status == .done }.count == expected
                    }
                }
                let files = downloads.items.compactMap(\.url)
                try require(files.count == 2 && Set(files).count == 2,
                            "repeated attachment downloads use distinct destinations")
                try require(try files.allSatisfy { try Data(contentsOf: $0) == Data("Vane download fixture\n".utf8) },
                            "real WKDownload writes complete bytes without replacing the earlier file")

                try await profileHopCheck(base: base)

                await clean()
                print("PASS browsercheck: \(assertions) real-WebKit assertions")
                print("Coverage excludes live permissions/devices, upload dialogs, printing, DRM, persisted session relaunch and TLS trust.")
                exit(0)
            } catch {
                await clean()
                fail(String(describing: error), code: 1)
            }
        }

        private func makeTab(profile: UUID, isPrivate: Bool = false) -> Tab {
            let tab = Tab(isPrivate: isPrivate, profileID: profile)
            host(tab)
            return tab
        }

        private func host(_ tab: Tab) {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = tab.web
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFront(nil)
            windows.append(window)
            tabs.append(tab)
        }

        private func load(_ tab: Tab, _ address: String, title: String, finalPath: String? = nil) async throws {
            guard let url = URL(string: address) else { throw Failure("invalid fixture URL") }
            let requestsBefore = server?.requests[url.path, default: 0] ?? 0
            tab.web.load(URLRequest(url: url))
            try await wait("request \(url.path) reaches the server") {
                (self.server?.requests[url.path, default: 0] ?? 0) > requestsBefore
            }
            try await loaded(tab, path: finalPath ?? url.path, title: title)
        }

        private func loaded(_ tab: Tab, path: String, title: String) async throws {
            try await wait("load \(path)") { tab.web.url?.path == path && tab.web.title == title && !tab.web.isLoading }
            let ready = try await js(tab, "document.readyState")
            guard ready as? String == "complete" else { throw Failure("\(path) did not finish loading") }
        }

        private func js(_ tab: Tab, _ source: String) async throws -> Any? {
            // WebKit returns Any, which cannot cross a continuation's sending boundary.
            // Move only serialized data between callbacks and the suspended task.
            let data: Data? = try await withCheckedThrowingContinuation { continuation in
                tab.web.evaluateJavaScript(source) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let value else { continuation.resume(returning: nil); return }
                    do {
                        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                        continuation.resume(returning: data)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return try data.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }

        private func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(8)
            while !predicate() {
                guard Date.now < deadline else { throw Failure("timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        private func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(label) }
            assertions += 1
            print("  ok  \(label)")
        }

        /// A parked profile still belongs to the same window. Exercise both routes back to
        /// it: the Profiles menu and the command bar's open-tab row. The former must write
        /// the outgoing Space before parking it; the latter must actually show the tab.
        private func profileHopCheck(base: String) async throws {
            let manager = ProfileManager.shared
            let first = manager.active
            let second = manager.create(name: "Browsercheck Other")
            guard let firstSpace = manager.ensureSpaces(for: first).first,
                  let secondSpace = manager.ensureSpaces(for: second).first,
                  let firstURL = URL(string: "\(base)/a"),
                  let secondURL = URL(string: "\(base)/b") else {
                throw Failure("profile hop fixture could not create its Spaces")
            }
            let firstStore = Windows.open(profile: first, space: firstSpace)
            guard let window = firstStore.window else { throw Failure("profile hop has no window") }
            firstStore.newTab(firstURL)
            firstStore.palette = nil
            firstStore.switchTo(space: secondSpace)
            guard let secondStore = Windows.current(in: second.id),
                  secondStore.window === window else {
                throw Failure("cross-profile Space switch did not keep the same window")
            }
            secondStore.newTab(secondURL)
            secondStore.palette = nil
            guard let secondTab = secondStore.tabs.last else { throw Failure("second profile has no tab") }
            try await loaded(secondTab, path: "/b", title: "Fixture B")

            _ = Windows.switchTo(profile: first)
            try require(firstStore.window === window && secondStore.isParked,
                        "Profiles menu returns to a parked profile in the same window")
            try require(manager.spaces(for: second.id).first?.tabURLs.contains(secondURL) == true,
                        "Profiles menu saves the outgoing Space before parking it")

            NSApp.activate(ignoringOtherApps: true)
            try require(Windows.reveal(secondTab, in: secondStore),
                        "an open-tab result can reveal a tab in a parked profile")
            try require(secondStore.window === window && secondStore.current == secondTab.id,
                        "revealing a parked tab shows its profile and selects it")
            do {
                try await wait("keyboard focus returns to the revealed page") {
                    window.firstResponder === secondTab.web
                }
            } catch {
                let responder = window.firstResponder
                throw Failure("keyboard focus stayed on \(String(describing: responder)) "
                              + "(key=\(window.isKeyWindow), pageWindow=\(secondTab.web.window === window), "
                              + "palette=\(String(describing: secondStore.palette)))")
            }
            try require(window.firstResponder === secondTab.web,
                        "revealing a parked tab leaves the page ready for typing")

            window.performClose(nil)
            try require(!TabStore.all.contains(where: { $0 === firstStore || $0 === secondStore }),
                        "closing a hopped window removes both of its profile stores")
            window.contentView = nil
            window.delegate = nil
            // tearDown() replaces each closed page with a fresh unloaded WKWebView. Release
            // those fixture tabs before the separate cleanup process unregisters the stores.
            firstStore.tabs.removeAll()
            secondStore.tabs.removeAll()
            ExtensionHost.forget(second.id)
            ProfileManager.releaseDataStore(for: second.id)
        }

        private func clean() async {
            server?.stop()
            defer { UserDefaults.dropScratchSuite(UserDefaults.suiteName(forDataDir: directory)) }
            let profileID = tabs.first(where: { !$0.isPrivate })?.profileID
            var isolatedStore: WKWebsiteDataStore?
            // Defense in depth: clean only the exact named store derived from this empty
            // test directory. Never clean .default() or a profile's production identifier.
            if let regular = tabs.first(where: { !$0.isPrivate }),
               let expected = ProfileManager.dataStoreIdentifier(for: regular.profileID, dataDirectory: directory),
               regular.web.configuration.websiteDataStore.identifier == expected {
                isolatedStore = regular.web.configuration.websiteDataStore
                await isolatedStore?.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
            tabs.forEach { $0.tearDown() }
            windows.forEach { $0.orderOut(nil) }
            tabs.removeAll()
            windows.removeAll()
            if let profileID {
                ExtensionHost.forget(profileID)
                ProfileManager.releaseDataStore(for: profileID)
            }
            isolatedStore = nil
        }
    }

    /// A loopback-only, GET-only HTTP fixture. A real HTTP 302 is necessary here: replacing
    /// a navigation with loadSimulatedRequest would not test WebKit's redirect/reload path.
    @MainActor private final class Server {
        let listener: NWListener
        var port: UInt16?
        var error: String?
        var requests: [String: Int] = [:]
        var connections: [NWConnection] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .ready = state { self?.port = self?.listener.port?.rawValue }
                    if case .failed(let error) = state { self?.error = error.localizedDescription }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, buffer: Data())
                }
            }
            listener.start(queue: .main)
        }

        func stop() { listener.cancel(); connections.forEach { $0.cancel() } }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
                MainActor.assumeIsolated {
                    guard let self, error == nil else { connection.cancel(); return }
                    var buffer = buffer
                    if let data { buffer.append(data) }
                    guard buffer.count < 32768 else { connection.cancel(); return }
                    guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                        if complete { connection.cancel() }
                        else { self.receive(connection, buffer: buffer) }
                        return
                    }
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let path = String(target.split(separator: "?", maxSplits: 1)[0])
                    self.requests[path, default: 0] += 1
                    let attachment = path == "/download"
                    let body = attachment ? "Vane download fixture\n" : self.html(path)
                    let redirect = path == "/redirect"
                    let status = redirect ? "302 Found" : "200 OK"
                    let location = redirect ? "Location: /b\r\n" : ""
                    let contentType = attachment ? "application/octet-stream" : "text/html; charset=utf-8"
                    let disposition = attachment ? "Content-Disposition: attachment; filename=fixture.txt\r\n" : ""
                    let response = "HTTP/1.1 \(status)\r\n\(location)\(disposition)Content-Type: \(contentType)\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }

        private func html(_ path: String) -> String {
            let title: String
            let content: String
            switch path {
            case "/a": title = "A"; content = "<p>needle one</p><p>needle two</p><a id=next href=/b>Next</a>"
            case "/b": title = "B"; content = "<p>Second page</p>"
            case "/form":
                title = "Form"
                content = """
                    <form action=/submitted method=get><input id=query name=query><button id=submit>Submit</button></form>
                    <script>window.inputState='';document.getElementById('query').addEventListener('input',e=>window.inputState=e.target.value);</script>
                    """
            case "/submitted": title = "Submitted"; content = "<p>Form received</p>"
            case "/host-title":
                return "<!doctype html><meta charset=utf-8><title>127.0.0.1</title><body>Host title</body>"
            case "/storage": title = "Storage"; content = "<p>Regular storage</p>"
            case "/private": title = "Private"; content = "<p>Private storage</p>"
            default: title = "Empty"; content = ""
            }
            return "<!doctype html><meta charset=utf-8><title>Fixture \(title)</title><body>\(content)</body>"
        }
    }
}
